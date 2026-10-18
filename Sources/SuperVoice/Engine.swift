import AVFoundation
import FluidAudio
import Foundation
import VoiceCore

// The speech models, through FluidAudio (Core ML, on the Neural Engine): Kokoro-82M for the voices
// and Parakeet TDT v3 to write down what's said. Each is downloaded once, the first time it's
// needed; after that everything works offline.

/// The two models: loaded (downloaded the first time) when first wanted, then kept. Everything
/// published is changed on the main thread.
final class Neural: ObservableObject {
    static let shared = Neural()

    /// Kokoro, the voices (on the main thread, for views).
    @Published private(set) var voices: ModelState = .notLoaded
    /// Parakeet, the listening.
    @Published private(set) var ears: ModelState = .notLoaded

    /// The same, for any thread (the server's).
    var voicesNow: ModelState { lock.lock(); defer { lock.unlock() }; return voicesState }
    var earsNow: ModelState { lock.lock(); defer { lock.unlock() }; return earsState }
    private var voicesState: ModelState = .notLoaded
    private var earsState: ModelState = .notLoaded

    private func set(voices state: ModelState) {
        lock.lock()
        voicesState = state
        lock.unlock()
        main { self.voices = state }
    }

    private func set(ears state: ModelState) {
        lock.lock()
        earsState = state
        lock.unlock()
        main { self.ears = state }
    }

    private var voiceLoad: Task<KokoroAneManager, Error>?
    private var earLoad: Task<AsrManager, Error>?
    private let lock = NSLock()

    /// Kokoro has been loaded on this Mac before (so it's on disk, and loading won't download).
    private var voicesDownloaded: Bool {
        get { UserDefaults.standard.bool(forKey: "kokoroDownloaded") }
        set { UserDefaults.standard.set(newValue, forKey: "kokoroDownloaded") }
    }

    private var earsDownloaded: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    }

    /// Kokoro, loading it if it isn't yet. Any thread.
    func voiceModel() -> Task<KokoroAneManager, Error> {
        lock.lock()
        defer { lock.unlock() }
        if let voiceLoad { return voiceLoad }
        voicesState = voicesDownloaded ? .loading : .downloading(nil)
        let state = voicesState
        main { self.voices = state }
        let load = Task.detached(priority: .userInitiated) { () async throws -> KokoroAneManager in
            let model = KokoroAneManager(defaultVoice: Voice.fallback.id)
            try await model.initialize(preloadVoices: Set(Voice.all.map(\.id)))
            return model
        }
        voiceLoad = load
        Task.detached { [weak self] in
            let result = await load.result
            guard let self else { return }
            switch result {
            case .success:
                self.voicesDownloaded = true
                self.set(voices: .ready)
            case .failure(let error):
                self.lock.lock()
                self.voiceLoad = nil            // try again next time
                self.lock.unlock()
                self.set(voices: .failed(error.localizedDescription))
            }
        }
        return load
    }

    /// Parakeet, loading it if it isn't yet. Any thread.
    func earModel() -> Task<AsrManager, Error> {
        lock.lock()
        defer { lock.unlock() }
        if let earLoad { return earLoad }
        earsState = earsDownloaded ? .loading : .downloading(nil)
        let state = earsState
        main { self.ears = state }
        let load = Task.detached(priority: .userInitiated) { [weak self] () async throws -> AsrManager in
            let models = try await AsrModels.downloadAndLoad(version: .v3, progressHandler: { progress in
                let done = progress.fractionCompleted
                guard let self, case .downloading = self.earsNow, done < 1 else { return }
                self.set(ears: .downloading(done))
            })
            let asr = AsrManager()
            try await asr.loadModels(models)
            return asr
        }
        earLoad = load
        Task.detached { [weak self] in
            let result = await load.result
            guard let self else { return }
            switch result {
            case .success:
                self.set(ears: .ready)
            case .failure(let error):
                self.lock.lock()
                self.earLoad = nil
                self.lock.unlock()
                self.set(ears: .failed(error.localizedDescription))
            }
        }
        return load
    }

    /// Reads `text` in `voice`: 24 kHz mono samples.
    func speak(_ text: String, voice: Voice, speed: Double) async throws -> [Float] {
        let model = try await voiceModel().value
        return try await model.synthesizeDetailed(text: text, voice: voice.id, speed: Float(speed)).samples
    }

    /// Writes down 16 kHz mono audio. Very short audio is padded (the model wants at least a bit).
    func write(_ samples: [Float]) async throws -> Recognized {
        let asr = try await earModel().value
        var audio = samples
        if audio.count < PCM.listenRate { audio += [Float](repeating: 0, count: PCM.listenRate - audio.count) }
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(audio, decoderState: &state)
        let words = buildWordTimings(from: result.tokenTimings ?? []).map {
            TimedWord(word: $0.word, start: $0.startTime, end: $0.endTime)
        }
        return Recognized(text: result.text, words: words)
    }

    /// "Getting the voices ready… 40%": what a tool shows while a model loads; nil once it's there.
    static func status(_ state: ModelState, what: String) -> String? {
        switch state {
        case .notLoaded, .ready: return nil
        case .loading: return "Loading \(what)…"
        case .downloading(let done):
            let first = "Getting \(what) ready (the first time it downloads it)…"
            guard let done, done > 0, done < 1 else { return first }
            return first + " \(Int(done * 100))%"
        case .failed(let problem): return "Couldn't get \(what): \(problem)"
        }
    }

    private func main(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

/// The API's view of the models and the speakers.
final class MacEngine: SpeechEngine {
    let neural = Neural.shared
    let speaker: SpeechPlayer

    init(speaker: SpeechPlayer) {
        self.speaker = speaker
    }

    var ttsState: ModelState { neural.voicesNow }
    var sttState: ModelState { neural.earsNow }

    func prepare(tts: Bool, stt: Bool) {
        if tts { _ = neural.voiceModel() }
        if stt { _ = neural.earModel() }
    }

    func speak(_ text: String, voice: Voice, speed: Double) async throws -> [Float] {
        try await neural.speak(text, voice: voice, speed: speed)
    }

    func write(_ samples: [Float]) async throws -> Recognized {
        try await neural.write(samples)
    }

    func open(_ url: URL) throws -> AudioReader {
        try FileAudioReader(url: url)
    }

    func say(_ text: String, voice: Voice, speed: Double) -> (id: String, queued: Int) {
        let id = UUID().uuidString
        var queued = 1
        DispatchQueue.main.sync {
            queued = speaker.enqueue(text, voice: voice, speed: speed)
        }
        return (id, queued)
    }

    func stopSaying() -> Int {
        var dropped = 0
        DispatchQueue.main.sync { dropped = speaker.stop() }
        return dropped
    }
}

/// Reads an audio file (anything Core Audio reads: wav, aiff, caf, mp3, m4a, flac, a video's sound)
/// as 16 kHz mono, a piece at a time.
final class FileAudioReader: AudioReader {
    private let file: AVAudioFile
    private let resampler: Resampler
    private let chunk: AVAudioFrameCount = 16_384
    private var pending: [Float] = []

    init(url: URL) throws {
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioError.unreadable(error.localizedDescription)
        }
        resampler = Resampler(from: file.processingFormat)
    }

    var duration: Double { Double(file.length) / file.processingFormat.sampleRate }

    func read(maxFrames: Int) throws -> [Float] {
        // Compressed files (mp3, aac) report a length a little past their real end, and reading
        // there throws: stop at the length, and take a failed read after the start as the end.
        while pending.count < maxFrames, file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
            do {
                try file.read(into: buffer, frameCount: min(chunk, AVAudioFrameCount(file.length - file.framePosition)))
            } catch {
                if file.framePosition > 0 { break }
                throw AudioError.unreadable(error.localizedDescription)
            }
            if buffer.frameLength == 0 { break }
            pending += resampler.convert(buffer)
        }
        let take = min(maxFrames, pending.count)
        defer { pending.removeFirst(take) }
        return Array(pending[..<take])
    }
}

/// Turns any audio into the 16 kHz mono the recognizer takes. Keeps its state from one buffer to
/// the next, so a stream of buffers converts without clicks at the joins.
final class Resampler {
    static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(PCM.listenRate),
                                      channels: 1, interleaved: false)!
    private let converter: AVAudioConverter?

    init(from format: AVAudioFormat) {
        converter = AVAudioConverter(from: format, to: Self.target)
        converter?.downmix = true
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let converter, buffer.frameLength > 0 else { return [] }
        let ratio = Self.target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity) else { return [] }
        var given = false
        var error: NSError?
        _ = converter.convert(to: out, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    }
}
