import Combine
import FluidAudio
import Foundation
import VoiceCore

/// Tells the voices from yours by how they sound. Each of Kokoro's voices AI Listen uses is
/// enrolled once (a sentence is made with it and turned into a speaker print, a CAM++ embedding),
/// and yours is learned from what you say while nobody's talking. A phrase heard while a voice
/// plays is turned into a print too and compared: closer to theirs than to yours, it's the voice
/// coming back through the microphone (what echo cancellation left of it), and it's dropped before
/// it's written down. Unsure, it's left to the words to decide (see `Echo`).
///
/// The model (CAM++, about 7 MB on the Neural Engine) downloads once, the first time. Prints are
/// kept under a lock; the work runs off the main thread.
final class VoicePrints: ObservableObject {
    static let shared = VoicePrints()

    @Published private(set) var state: ModelState = .notLoaded

    private var load: Task<CampPlusEmbedder, Error>?
    /// The model, once it's loaded (nothing waits for it: until then, nothing can be told).
    private var model: CampPlusEmbedder?
    private let lock = NSLock()
    /// Each voice's print, by its id.
    private var theirs: [String: [Float]] = [:]
    private var enrolling: Set<String> = []
    /// Yours: the mean of what's been heard of you, and how many pieces.
    private var mine: [Float]?
    private var mineCount = 0

    /// What each voice says to be enrolled.
    static let sample = "Hello there. This is how I sound when I talk to you. One, two, three, four, five, six, seven."
    /// A phrase shorter than this can't be told (seconds).
    static let minSeconds = 0.6
    /// At least this close to one of theirs to be theirs, and further from yours than that by `margin`.
    static let theirsAbove: Float = 0.5
    static let margin: Float = 0.08
    /// Below this to any of theirs, it's surely not them (and may be learned as yours).
    static let notTheirsBelow: Float = 0.35

    /// The model, loading it if it isn't yet. Any thread.
    private func embedder() -> Task<CampPlusEmbedder, Error> {
        lock.lock()
        defer { lock.unlock() }
        if let load { return load }
        main { self.state = .loading }
        let task = Task.detached(priority: .utility) { try await CampPlusEmbedder.load() }
        load = task
        Task.detached { [weak self] in
            let result = await task.result
            guard let self else { return }
            switch result {
            case .success(let model):
                self.lock.lock()
                self.model = model
                self.lock.unlock()
                self.main { self.state = .ready }
            case .failure(let error):
                self.lock.lock()
                self.load = nil
                self.lock.unlock()
                self.main { self.state = .failed(error.localizedDescription) }
            }
        }
        return task
    }

    /// The print of 16 kHz audio; nil when it's too short or the model isn't loaded yet (it never
    /// waits for it: a phrase mustn't wait on a download).
    private func embedding(of samples: [Float]) async -> [Float]? {
        guard Double(samples.count) >= Self.minSeconds * Double(PCM.listenRate) else { return nil }
        lock.lock()
        let model = self.model
        lock.unlock()
        guard let model else { return nil }
        return try? await model.embed(audio: samples)
    }

    /// Starts getting the model, if it isn't here yet.
    func prepare() {
        _ = embedder()
    }

    /// Enrolls `voice` (once): what it sounds like saying the sample. Main thread.
    func enroll(_ voice: Voice) {
        lock.lock()
        let known = theirs[voice.id] != nil || enrolling.contains(voice.id)
        if !known { enrolling.insert(voice.id) }
        lock.unlock()
        guard !known else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var print: [Float]?
            // Enrolling does wait for the model (it's the one thing that may).
            if let model = try? await self.embedder().value,
               let audio = try? await Neural.shared.speak(Self.sample, voice: voice, speed: 1) {
                let heard = PCM.resample(audio, from: Double(PCM.speakRate), to: Double(PCM.listenRate))
                print = try? await model.embed(audio: heard)
            }
            self.lock.lock()
            self.enrolling.remove(voice.id)
            if let print { self.theirs[voice.id] = print }
            self.lock.unlock()
        }
    }

    /// Whether a phrase heard while a voice played is one of theirs: true, theirs (drop it); false,
    /// not theirs; nil, can't tell (too short, no prints yet, or in between).
    func isTheirs(_ samples: [Float]) async -> Bool? {
        lock.lock()
        let prints = Array(theirs.values), me = mine
        lock.unlock()
        guard !prints.isEmpty, let p = await embedding(of: samples) else { return nil }
        let nearest = prints.map { Self.cosine($0, p) }.max() ?? -1
        if nearest < Self.notTheirsBelow { return false }
        guard nearest >= Self.theirsAbove else { return nil }
        if let me { return nearest > Self.cosine(me, p) + Self.margin }
        return true
    }

    /// Something said with nobody talking: it's you, and goes into your print (unless it sounds
    /// like one of them, which a stray bit of echo might).
    func learnUser(_ samples: [Float]) async {
        guard let p = await embedding(of: samples) else { return }
        lock.lock()
        defer { lock.unlock() }
        if let nearest = theirs.values.map({ Self.cosine($0, p) }).max(), nearest >= Self.theirsAbove { return }
        if var m = mine, mineCount > 0 {
            // A running mean, kept to unit length; the latest counts less as it settles (to 50).
            let n = Float(min(mineCount, 50))
            for i in 0..<min(m.count, p.count) { m[i] = (m[i] * n + p[i]) / (n + 1) }
            let norm = max(sqrt(m.reduce(0) { $0 + $1 * $1 }), 1e-9)
            mine = m.map { $0 / norm }
            mineCount += 1
        } else {
            mine = p
            mineCount = 1
        }
    }

    /// Cosine similarity of two unit prints.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
        return s
    }

    private func main(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
