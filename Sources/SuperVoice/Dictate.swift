import AppKit
import AVFoundation
import SwiftUI
import VoiceCore

/// Listens to the microphone and writes down what's said. The audio is cut into phrases at the
/// pauses (PhraseCutter) and each phrase is written down whole by Parakeet, in order; while a
/// phrase is still being said, it's written down every so often to show it live. Nothing said is
/// thrown away (phrases wait while the model downloads, and stopping writes down the last one). A
/// microphone change (AirPods connecting) carries on.
///
/// Dictating, `text` grows until it's stopped. With `pauseToEnd` set (always listening), a pause
/// that long ends what was said: it goes to `onUtterance` and listening carries on fresh. With
/// `holdIfUnfinished` too, a pause after something that sounds unfinished ("…and the") waits that
/// much longer, and talking again carries on the same utterance. On the main thread.
final class Recorder: ObservableObject {
    static let shared = Recorder()

    let pauseToEnd: Double?
    let holdIfUnfinished: Double?
    var onUtterance: ((String) -> Void)?
    /// Whether to check each phrase before writing it down (on the main thread, as it's cut): nil,
    /// no; else whether a voice is playing just now. See `screen`.
    var screening: (() -> Bool?)?
    /// Checks a phrase (16 kHz samples) off the main thread, given whether a voice was playing:
    /// true drops it (it was the voice, not the user), false keeps it.
    var screen: ((_ samples: [Float], _ playing: Bool) async -> Bool)?

    /// The engine shared with a voice, echo cancelled (AI Listen's), or nil: its own.
    let echo: EchoCancel?

    init(pauseToEnd: Double? = nil, holdIfUnfinished: Double? = nil, shared: EchoCancel? = nil) {
        self.pauseToEnd = pauseToEnd
        self.holdIfUnfinished = holdIfUnfinished
        self.echo = shared
        engine = shared?.engine ?? AVAudioEngine()
    }

    @Published private(set) var on = false
    /// Stopped, and the last words are still being written down.
    @Published private(set) var finishing = false
    /// What's been said so far.
    @Published private(set) var text = ""
    /// How loud it is, 0 to 1.
    @Published private(set) var level: Float = 0
    @Published private(set) var started: Date?
    @Published var problem: String?

    private let engine: AVAudioEngine
    private let lock = NSLock()
    private var resampler: Resampler?            // used on the audio thread, under the lock
    private var cutter = PhraseCutter(pause: 0.8)
    private var rewiring: NSObjectProtocol?
    /// Seconds of audio heard this time.
    private(set) var heardSeconds = 0.0

    private var done = ""
    private var guess = ""
    /// Phrases waiting to be written down, oldest first (`send`: it ends an utterance; `playing`:
    /// whether a voice was playing as it was said, nil when that isn't checked).
    private var waiting: [(samples: [Float], send: Bool, playing: Bool?)] = []
    private var writing = false
    /// Counts clears, so what's written down for something cleared is dropped.
    private var generation = 0
    private var phraseNumber = 0
    private var guessing = false
    private var ticker: Timer?
    /// What was said sounded unfinished: when it's sent anyway, if nothing more is said.
    private var holdTimer: Timer?
    /// Any sound at all (not digital silence) has come from the microphone since it opened.
    private var signal = false
    /// Asked to listen (start) and not since stopped: the microphone opens only if still wanted
    /// once permission comes back.
    private var wanted = false

    func start() {
        wanted = true
        problem = nil
        if on {
            writeNext()                             // "Try again" after the model failed
            return
        }
        Self.authorize { [weak self] problem in
            guard let self else { return }
            if let problem { self.problem = problem } else { self.begin() }
        }
    }

    /// Stops listening. What was said last is still written down (`finishing` meanwhile).
    func stop() {
        wanted = false
        guard on else { return }
        closeMic()
        if let last = cutter.flush() { enqueue(last, send: pauseToEnd != nil) }
        cutter.reset()
        // Held for more that won't come now: it goes as it is (or with the last phrase, once written).
        if holdTimer != nil {
            holdTimer?.invalidate()
            holdTimer = nil
            if !writing && waiting.isEmpty { sendDone() }
        }
        finishing = writing || !waiting.isEmpty
    }

    /// Forgets what's been written down (and anything waiting).
    func clear() {
        holdTimer?.invalidate()
        holdTimer = nil
        generation += 1
        cutter.reset()
        waiting = []
        done = ""
        guess = ""
        text = ""
        heardSeconds = 0
    }

    private func closeMic() {
        ticker?.invalidate()
        if let rewiring { NotificationCenter.default.removeObserver(rewiring) }
        rewiring = nil
        engine.inputNode.removeTap(onBus: 0)
        if let echo { echo.stop(for: "mic") } else { engine.stop() }
        on = false
        level = 0
        started = nil
    }

    private func begin() {
        guard wanted, !on else { return }
        _ = Neural.shared.earModel()                // start getting it, if it isn't here yet
        if let problem = openMic() {
            self.problem = problem
            return
        }
        rewiring = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: .main) { [weak self] _ in self?.rewire() }
        cutter = PhraseCutter(pause: pauseToEnd ?? 0.8)
        signal = false
        on = true
        watchForSilence()
        started = Date()
        finishing = false
        ticker = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in self?.guessLive() }
        writeNext()
    }

    /// Taps the microphone and starts the engine; nil, or what went wrong.
    private func openMic() -> String? {
        // Voice processing changes the microphone's format: on first, then the format is read.
        echo?.prepare()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return "No microphone found" }
        lock.lock()
        resampler = Resampler(from: format)
        lock.unlock()
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.heard(buffer)
        }
        do {
            if let echo {
                try echo.start(for: "mic")
            } else {
                engine.prepare()
                try engine.start()
            }
        } catch {
            input.removeTap(onBus: 0)
            return "Couldn't start the microphone: \(error.localizedDescription)"
        }
        return nil
    }

    /// The microphone changed: the engine has stopped, so start it again on the new one.
    private func rewire() {
        guard on else { return }
        // Voice processing starting up changes the configuration too, with the engine still
        // running: nothing to do (starting again would only change it again, round and round).
        if echo != nil, engine.isRunning { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        if let problem = openMic() {
            self.problem = problem
            stop()
        }
    }

    /// On the audio thread.
    private func heard(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let samples = resampler?.convert(buffer) ?? []
        lock.unlock()
        let l = Self.level(buffer)
        let live = Self.anySound(buffer)
        DispatchQueue.main.async {
            guard self.on else { return }
            if live { self.signal = true }
            self.level = self.level * 0.5 + l * 0.5
            self.heardSeconds += Double(samples.count) / Double(PCM.listenRate)
            for phrase in self.cutter.add(samples) {
                self.enqueue(phrase.samples, send: phrase.paused && self.pauseToEnd != nil)
            }
        }
    }

    private func enqueue(_ samples: [Float], send: Bool = false) {
        phraseNumber += 1
        waiting.append((samples, send, screening?()))
        // Always listening with nothing writing it down (the model failed): don't pile up forever.
        if pauseToEnd != nil, waiting.count > 30 { waiting.removeFirst(waiting.count - 30) }
        writeNext()
    }

    /// Writes down the oldest waiting phrase, then the next, one at a time so they stay in order.
    private func writeNext() {
        guard !writing, let item = waiting.first else {
            if !writing && waiting.isEmpty { finishing = false }
            return
        }
        writing = true
        let mine = generation
        let screen = self.screen
        Task.detached { [weak self] in
            var said = ""
            var problem: String?
            // A quiet microphone (voice processing's is) is turned up to what the models expect.
            let audio = PCM.lifted(item.samples)
            do {
                // One of the voices talking, not the user: dropped unheard.
                if let playing = item.playing, let screen, await screen(audio, playing) {
                    said = ""
                } else {
                    said = try await Neural.shared.write(audio).text
                }
            } catch {
                problem = error.localizedDescription
            }
            let heard = said, failure = problem
            DispatchQueue.main.async { self?.written(heard, send: item.send, problem: failure, generation: mine) }
        }
    }

    private func written(_ said: String, send: Bool, problem: String?, generation mine: Int) {
        writing = false
        guard mine == generation else {
            writeNext()
            return
        }
        if let problem {
            // The model isn't there (no network the first time?): the phrase waits for "Try again".
            self.problem = "Couldn't write it down: \(problem)"
            finishing = false
            return
        }
        if !waiting.isEmpty { waiting.removeFirst() }
        done = Self.join(done, said.trimmingCharacters(in: .whitespacesAndNewlines))
        if waiting.isEmpty { guess = "" }
        text = Self.join(done, guess)
        if send {
            holdTimer?.invalidate()
            holdTimer = nil
            if let hold = holdIfUnfinished, on, TurnEnd.unfinished(done) {
                // It sounds like more is coming: wait a little longer for it.
                holdTimer = Timer.scheduledTimer(withTimeInterval: hold, repeats: false) { [weak self] _ in self?.release() }
            } else {
                sendDone()
            }
        }
        writeNext()
    }

    /// The hold is over: sent, unless they're talking again (then the next pause decides).
    private func release() {
        holdTimer = nil
        guard !cutter.spoke, !writing, waiting.isEmpty else { return }
        sendDone()
    }

    private func sendDone() {
        let all = done
        done = ""
        guess = ""
        text = ""
        if !all.isEmpty { onUtterance?(all) }
    }

    /// While a phrase is being said, writes down what's been said of it so far, to show it live.
    private func guessLive() {
        guard on, !guessing, !writing, waiting.isEmpty, cutter.spoke,
              cutter.open.count > PhraseCutter.rate / 2, Neural.shared.ears.isReady else { return }
        guessing = true
        let mine = (generation, phraseNumber)
        let audio = cutter.open
        Task.detached { [weak self] in
            let said = (try? await Neural.shared.write(PCM.lifted(audio)).text) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.guessing = false
                guard mine == (self.generation, self.phraseNumber), self.on, self.waiting.isEmpty else { return }
                self.guess = said.trimmingCharacters(in: .whitespacesAndNewlines)
                self.text = Self.join(self.done, self.guess)
            }
        }
    }

    static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    /// Echo cancelled, a microphone that gives nothing but silence (some devices, with voice
    /// processing) would never hear anything: after five seconds of it, voice processing is given
    /// up and the microphone opened again without it.
    private func watchForSilence() {
        guard let echo, echo.cancelsEcho else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.on, !self.signal, echo.cancelsEcho else { return }
            self.closeMic()
            echo.giveUp()
            if let problem = self.openMic() {
                self.problem = problem
                return
            }
            self.on = true
            self.started = Date()
            self.ticker = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in self?.guessLive() }
            self.rewiring = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: self.engine,
                                                                   queue: .main) { [weak self] _ in self?.rewire() }
        }
    }

    /// Anything but digital silence in the buffer.
    static func anySound(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let data = buffer.floatChannelData?[0] else { return false }
        for i in 0..<Int(buffer.frameLength) where abs(data[i]) > 1e-7 { return true }
        return false
    }

    /// Loudness of a buffer, 0 (quiet) to 1 (loud), on a decibel scale.
    static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-6))
        return max(0, min(1, (db + 55) / 45))
    }

    /// Asks for the microphone; the answer is nil, or what to switch on.
    static func authorize(_ done: @escaping (String?) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                done(granted ? nil : "The microphone is off for Super Voice: turn it on in System Settings → Privacy & Security → Microphone")
            }
        }
    }
}

/// Record, talk as long as you like, stop; edit it, keep it in the library, or copy it.
struct DictateView: View {
    @EnvironmentObject var service: Service
    @EnvironmentObject var library: Library
    @ObservedObject var recorder = Recorder.shared
    /// What's in the box: what was dictated, and any edits. Kept if the window closes.
    @AppStorage("dictationDraft") private var draft = ""
    @State private var note: String?

    var body: some View {
        Page(title: "Dictate", subtitle: "Talk for as long as you like; pauses don't stop it",
             symbol: "mic.fill", colors: [Palette.pink, Palette.orange]) {
            if let status = Neural.status(service.neural.ears, what: "speech recognition") {
                Notice(text: status, tint: .blue, symbol: "arrow.down.circle")
            }
            if let problem = recorder.problem {
                HStack {
                    Notice(text: problem)
                    if problem.contains("System Settings") {
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                        }
                    } else if problem.contains("write it down") {
                        Button("Try again") { recorder.start() }
                    }
                }
            }
            recordBar
            TextEditor(text: Binding(get: { shown }, set: { if !busy { draft = $0 } }))
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if shown.isEmpty {
                        Text(recorder.on ? "Listening…" : "Press Record and start talking.")
                            .foregroundStyle(.tertiary).padding(16).allowsHitTesting(false)
                    }
                }
            HStack(spacing: 8) {
                Button("Keep in library") { keep() }
                    .buttonStyle(PillButton(tint: Palette.pink, filled: true))
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Copy") {
                    service.copy(draft)
                    flash("Copied")
                }
                .buttonStyle(PillButton(tint: .secondary, filled: false))
                .disabled(busy || draft.isEmpty)
                Button("Read back") { service.reader.say(draft, voice: service.voice, speed: service.settings.speed) }
                    .buttonStyle(PillButton(tint: .secondary, filled: false))
                    .disabled(busy || draft.isEmpty)
                Button("Clear") {
                    draft = ""
                    recorder.clear()
                }
                .buttonStyle(PillButton(tint: .secondary, filled: false))
                .disabled(busy || draft.isEmpty)
                Spacer()
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(.secondary) }
                Text(counted(shown.split(whereSeparator: \.isWhitespace).count, "word")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .onChange(of: recorder.finishing) { _, finishing in
            if !finishing && !recorder.on { take() }
        }
        .onChange(of: recorder.on) { _, on in
            if !on && !recorder.finishing { take() }
        }
    }

    private var busy: Bool { recorder.on || recorder.finishing }

    /// What the box shows: the draft, and while recording, what's being said after it.
    private var shown: String {
        busy ? Recorder.join(draft.trimmingCharacters(in: .whitespacesAndNewlines), recorder.text) : draft
    }

    private var recordBar: some View {
        HStack(spacing: 12) {
            Button {
                recorder.on ? recorder.stop() : startRecording()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: recorder.on ? "stop.fill" : "record.circle")
                    Text(recorder.on ? "Stop" : "Record")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Capsule().fill(recorder.on ? Palette.red : Palette.pink))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: .command)
            .disabled(recorder.finishing)
            if recorder.on {
                LevelMeter(level: recorder.level)
                if let started = recorder.started {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(Captions.clock(context.date.timeIntervalSince(started)))
                            .font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            } else if recorder.finishing {
                ProgressView().controlSize(.small)
                Text("Writing down the last words…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// Recording adds to what's in the box.
    private func startRecording() {
        recorder.clear()
        recorder.start()
    }

    /// What was dictated joins the draft.
    private func take() {
        let said = recorder.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        draft = Recorder.join(draft.trimmingCharacters(in: .whitespacesAndNewlines), said)
        recorder.clear()
    }

    private func keep() {
        let item = LibraryRecord(kind: .dictation, text: draft.trimmingCharacters(in: .whitespacesAndNewlines))
        library.add(item)
        draft = ""
        flash("Kept in the library")
    }

    private func flash(_ s: String) {
        note = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if note == s { note = nil } }
    }
}

/// A row of bars that rise with the microphone's level.
struct LevelMeter: View {
    var level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<12, id: \.self) { i in
                Capsule()
                    .fill(Float(i) / 12 < level ? Palette.pink : Color.primary.opacity(0.12))
                    .frame(width: 3, height: 6 + CGFloat(i % 4) * 3)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}
