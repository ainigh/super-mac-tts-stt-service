import AVFoundation
import Foundation
import VoiceCore

/// Says things out loud, one after another. Text given while it's talking waits its turn; `stop`
/// drops everything. Each sentence is made while the one before it plays, so there are no gaps.
/// On the main thread.
final class SpeechPlayer: ObservableObject {
    @Published private(set) var speaking = false
    @Published private(set) var paused = false
    /// The sentence being said now, and the word being said (a range in it).
    @Published private(set) var current = ""
    @Published private(set) var word: NSRange?
    /// Where the sentence being said starts in the whole text given (UTF-16), for lighting it up there.
    @Published private(set) var currentOffset = 0
    @Published var problem: String?
    /// Nothing left to say (it finished, not stopped).
    var onDone: (() -> Void)?
    /// What it says goes through Super Face (the avatar) while that's running; else it's said here.
    var throughFace = false

    private struct Line {
        var text: String
        var voice: Voice
        var speed: Double
        /// Which `enqueue` it came from.
        var item: Int
        /// Where it starts in that item's text (UTF-16).
        var offset: Int
        /// Said by Super Face: the whole item in one line (the face cuts it into sentences itself).
        var face = false
        /// Who's saying it (Tom, Jerry, Jane), for the face.
        var who: String?
    }

    /// The engine shared with a microphone, echo cancelled (AI Listen's), or nil: its own.
    let echo: EchoCancel?
    private let engine: AVAudioEngine
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: Double(PCM.speakRate), channels: 1)!
    private var lines: [Line] = []
    /// What to do once each item (by number) has been heard.
    private var itemDone: [Int: () -> Void] = [:]
    private var ahead: (line: Line, audio: Task<[Float], Error>)?
    private var playing: Line?
    /// A sentence is being made or played.
    private var busy = false
    /// Counts stops, so audio made or played for what was stopped is dropped.
    private var epoch = 0
    private var items = 0
    // For lighting up the word: when the line started, how long it is, time spent paused.
    private var lineStarted = Date()
    private var lineLength = 0.0
    private var pausedAt: Date?
    private var pausedFor = 0.0
    private var ticker: Timer?

    init(shared: EchoCancel? = nil) {
        self.echo = shared
        engine = shared?.engine ?? AVAudioEngine()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        // The engine stopped under it (the audio device changed, or voice processing was given up):
        // the sentence being said would never finish, so it's said again.
        shared?.whenStopped { [weak self] in self?.interrupted() }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, !self.engine.isRunning else { return }      // still running: nothing to do
            self.interrupted()
        }
    }

    /// The engine stopped while it was talking: what was being said is said again from that
    /// sentence, with everything still queued.
    private func interrupted() {
        guard busy || !lines.isEmpty else { return }
        // What Super Face is saying doesn't go through this engine: it carries on.
        if playing?.face == true { return }
        var again: [Line] = []
        if let playing { again.append(playing) }
        if let ahead { again.append(ahead.line) }
        again += lines
        let done = itemDone
        stop()
        lines = again
        itemDone = done
        if !lines.isEmpty {
            speaking = true
            next()
        }
    }

    /// Queues `text`; returns how many things are waiting to be said (counting it).
    @discardableResult
    func enqueue(_ text: String, voice: Voice, speed: Double) -> Int {
        add(text, voice: voice, speed: speed)
        return pendingItems
    }

    /// Queues `text` and returns its number; `done` runs on the main thread once all of it has
    /// been heard (not if it's stopped first; nothing to say, it runs at once).
    @discardableResult
    func add(_ text: String, voice: Voice, speed: Double, who: String? = nil, done: (() -> Void)? = nil) -> Int {
        items += 1
        let item = items
        let ns = text as NSString
        var searchFrom = 0
        var any = false
        let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if throughFace, FaceLink.shared.speaks, !whole.isEmpty {
            lines.append(Line(text: whole, voice: voice, speed: speed, item: item, offset: 0, face: true, who: who))
            any = true
        }
        for sentence in any ? [] : SpokenText.sentences(text) {
            let r = ns.range(of: sentence, range: NSRange(location: searchFrom, length: ns.length - searchFrom))
            let offset = r.location == NSNotFound ? searchFrom : r.location
            if r.location != NSNotFound { searchFrom = r.location + r.length }
            lines.append(Line(text: sentence, voice: voice, speed: speed, item: item, offset: offset))
            any = true
        }
        if let done {
            if any { itemDone[item] = done } else { DispatchQueue.main.async(execute: done) }
        }
        if !speaking {
            current = ""
            word = nil
        }
        if !lines.isEmpty || busy { speaking = true }
        if !busy { next() }
        return item
    }

    /// A line has been heard: if it was its item's last, the item is done.
    private func heard(_ line: Line) {
        guard let done = itemDone[line.item] else { return }
        if lines.contains(where: { $0.item == line.item }) || ahead?.line.item == line.item { return }
        itemDone[line.item] = nil
        done()
    }

    /// Says `text`, dropping anything that was going on.
    func say(_ text: String, voice: Voice, speed: Double) {
        stop()
        enqueue(text, voice: voice, speed: speed)
    }

    private var pendingItems: Int {
        var all = Set(lines.map(\.item))
        if let ahead { all.insert(ahead.line.item) }
        if let playing { all.insert(playing.item) }
        return all.count
    }

    /// Stops and empties the queue; returns how many things were dropped.
    @discardableResult
    func stop() -> Int {
        let dropped = pendingItems
        epoch += 1
        lines = []
        itemDone = [:]
        ahead?.audio.cancel()
        ahead = nil
        playing = nil
        busy = false
        player.stop()
        halt()
        ticker?.invalidate()
        speaking = false
        paused = false
        pausedAt = nil
        word = nil
        // What the face was given stops there too (only what this app gave it).
        if throughFace, dropped > 0, FaceLink.shared.up {
            let face = FaceLink.shared.client
            Task.detached { await face.stop() }
        }
        return dropped
    }

    func pause() {
        guard speaking, !paused else { return }
        player.pause()
        paused = true
        pausedAt = Date()
    }

    func resume() {
        guard paused else { return }
        paused = false
        if let pausedAt { pausedFor += Date().timeIntervalSince(pausedAt) }
        pausedAt = nil
        if busy, engine.isRunning { player.play() }
    }

    private func render(_ line: Line) -> Task<[Float], Error> {
        guard line.face else {
            return Task.detached(priority: .userInitiated) {
                try await Neural.shared.speak(line.text, voice: line.voice, speed: line.speed)
            }
        }
        // Said by the face: done (no audio here) once it's been said. If the face isn't there
        // after all, or its voice is still downloading, it's said here instead.
        let face = FaceLink.shared.client
        return Task.detached(priority: .userInitiated) {
            do {
                _ = try await face.speak(line.text, voice: line.voice.id, speed: line.speed, who: line.who)
                return []
            } catch {
                NSLog("Super Face didn't say it (%@): said here instead", String(describing: error))
                if (error as? FaceClient.Problem) == .unreachable { DispatchQueue.main.async { FaceLink.shared.lost() } }
                var samples: [Float] = []
                for sentence in SpokenText.sentences(line.text) {
                    try Task.checkCancellation()
                    samples += try await Neural.shared.speak(sentence, voice: line.voice, speed: line.speed)
                }
                return samples
            }
        }
    }

    /// Plays the next sentence (made ahead, or made now), or finishes.
    private func next() {
        let item: (line: Line, audio: Task<[Float], Error>)
        if let ahead {
            item = ahead
            self.ahead = nil
        } else if !lines.isEmpty {
            let line = lines.removeFirst()
            item = (line, render(line))
        } else {
            finished()
            return
        }
        busy = true
        playing = item.line
        let mine = epoch
        Task.detached { [weak self] in
            let result = await item.audio.result
            DispatchQueue.main.async {
                guard let self, mine == self.epoch else { return }
                switch result {
                case .success(let audio): self.play(item.line, audio)
                case .failure(let error): self.failed("Couldn't speak: \(error.localizedDescription)")
                }
            }
        }
    }

    private func play(_ line: Line, _ audio: [Float]) {
        // Make the next one while this one plays.
        if ahead == nil, !lines.isEmpty {
            let l = lines.removeFirst()
            ahead = (l, render(l))
        }
        guard !audio.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.count)),
              let data = buffer.floatChannelData?[0] else {
            let mine = epoch
            heard(line)
            if mine == epoch { next() }
            return
        }
        audio.withUnsafeBufferPointer { data.update(from: $0.baseAddress!, count: audio.count) }
        buffer.frameLength = AVAudioFrameCount(audio.count)
        if !engine.isRunning || echo != nil {
            do {
                if let echo {
                    try echo.start(for: "voice")
                } else {
                    engine.prepare()
                    try engine.start()
                }
            } catch {
                failed("Couldn't play: \(error.localizedDescription)")
                return
            }
        }
        problem = nil
        current = line.text
        currentOffset = line.offset
        word = nil
        lineStarted = Date()
        lineLength = Double(audio.count) / Double(PCM.speakRate)
        pausedFor = 0
        pausedAt = paused ? Date() : nil
        let mine = epoch
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, mine == self.epoch else { return }
                self.busy = false
                self.playing = nil
                self.heard(line)
                // Being heard may have stopped it (a delivery that cut in): then there's no next.
                guard mine == self.epoch else { return }
                self.next()
            }
        }
        if !paused { player.play() }
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Lights up the word being said, spreading the line's time over its words.
    private func tick() {
        guard busy, !paused, lineLength > 0 else { return }
        let elapsed = Date().timeIntervalSince(lineStarted) - pausedFor
        word = SpokenText.wordRange(in: current, at: elapsed / lineLength)
    }

    /// It can't be said: everything's dropped, but those waiting on it are told it's over, as when
    /// it finishes (else they'd wait for ever: AI Listen standing down, what was held till it's quiet).
    private func failed(_ why: String) {
        let waiting = Array(itemDone.values)
        stop()
        problem = why
        waiting.forEach { $0() }
        onDone?()
    }

    private func finished() {
        busy = false
        playing = nil
        ticker?.invalidate()
        player.stop()
        halt()
        speaking = false
        paused = false
        word = nil
        onDone?()
    }

    /// The engine stops, unless it's shared and the microphone still needs it.
    private func halt() {
        if let echo { echo.stop(for: "voice") } else if engine.isRunning { engine.stop() }
    }

    /// Says a few words in `voice`, so choosing one lets you hear it.
    static func preview(_ voice: Voice, speed: Double) {
        sampler.say("Hi, I'm \(voice.name). This is how I sound.", voice: voice, speed: speed)
    }

    private static let sampler = SpeechPlayer()
}
