import AVFoundation
import Foundation

/// One audio engine for AI Listen's microphone and its voice, with Apple's voice processing on (the
/// one FaceTime uses): what the voice plays goes out through this engine, so its echo canceller
/// knows it and takes it back out of what the microphone hears. Kokoro talking doesn't reach the
/// recognizer; you talking over it does. Each side starts it when it needs it, and it stops when
/// neither does. When voice processing can't be had (some audio devices), it's a plain engine and
/// `cancelsEcho` says so. On the main thread.
final class EchoCancel {
    let engine = AVAudioEngine()
    /// Voice processing is on: the voice is taken out of what the microphone hears.
    private(set) var cancelsEcho = false
    private var users: Set<String> = []

    init() {
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            // Other apps' sound (music, a video) isn't turned down while it listens.
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: true, duckingLevel: .min)
            cancelsEcho = engine.inputNode.isVoiceProcessingEnabled
        } catch {
            cancelsEcho = false
        }
    }

    /// `user` ("mic", "voice") needs it running.
    func start(for user: String) throws {
        users.insert(user)
        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            users.remove(user)
            throw error
        }
    }

    /// `user` is done with it; it stops when nobody needs it.
    func stop(for user: String) {
        users.remove(user)
        if users.isEmpty, engine.isRunning { engine.stop() }
    }

    /// The device changed and the engine stopped: started again for whoever still needs it.
    func restart() throws {
        guard !users.isEmpty, !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }
}
