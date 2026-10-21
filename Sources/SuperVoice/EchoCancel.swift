import AVFoundation
import Foundation

/// One audio engine for AI Listen's microphone and its voice, with Apple's voice processing on (the
/// one FaceTime uses): what the voice plays goes out through this engine, so its echo canceller
/// knows it and takes it back out of what the microphone hears. Kokoro talking doesn't reach the
/// recognizer; you talking over it does.
///
/// Voice processing is only on while the engine runs (it's turned off as it stops, so it never
/// gets in the way of the other listeners, always listen's or dictation's), and it's given up for
/// good, the engine carrying on plain, if the microphone gives nothing but silence with it on.
/// `cancelsEcho` says whether it's on. On the main thread.
final class EchoCancel {
    let engine = AVAudioEngine()
    /// Voice processing is on now: the voice is taken out of what the microphone hears.
    private(set) var cancelsEcho = false
    /// Wanted (the setting), and not given up on.
    var wanted = true {
        didSet { if !wanted { turnOff() } }
    }
    /// It gave the microphone only silence: not tried again until the app starts again.
    private(set) var failed = false
    private var users: Set<String> = []
    /// Told when the engine is stopped from under its users (voice processing given up), so each
    /// can start again.
    private var stopped: [() -> Void] = []

    func whenStopped(_ what: @escaping () -> Void) {
        stopped.append(what)
    }

    /// Turns voice processing on, if it's wanted and the engine isn't running (it can't change
    /// while it runs). The microphone's format changes with it, so this comes before reading it.
    func prepare() {
        guard wanted, !failed, !engine.isRunning, !engine.inputNode.isVoiceProcessingEnabled else { return }
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            // Other apps' sound (music, a video) isn't turned down while it listens.
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: true, duckingLevel: .min)
        } catch {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
        }
        cancelsEcho = engine.inputNode.isVoiceProcessingEnabled
    }

    /// `user` ("mic", "voice") needs it running.
    func start(for user: String) throws {
        users.insert(user)
        guard !engine.isRunning else { return }
        prepare()
        engine.prepare()
        do {
            try engine.start()
        } catch {
            users.remove(user)
            turnOff()
            throw error
        }
    }

    /// `user` is done with it; it stops when nobody needs it, and voice processing goes off.
    func stop(for user: String) {
        users.remove(user)
        if users.isEmpty {
            if engine.isRunning { engine.stop() }
            turnOff()
        }
    }

    /// The microphone heard nothing at all with voice processing on: it's given up, and the engine
    /// stopped so it can start again plain.
    func giveUp() {
        failed = true
        if engine.isRunning { engine.stop() }
        turnOff()
        for what in stopped { what() }
    }

    private func turnOff() {
        guard !engine.isRunning, engine.inputNode.isVoiceProcessingEnabled else {
            cancelsEcho = engine.inputNode.isVoiceProcessingEnabled
            return
        }
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        cancelsEcho = false
    }
}
