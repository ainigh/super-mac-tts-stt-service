import XCTest
@testable import VoiceCore

/// The phrase cutter and the lift: a quiet microphone (Apple's voice processing gives one) is
/// still heard, steady noise isn't taken for speech, and quiet audio reaches the models turned up.
final class CutterTests: XCTestCase {
    private let rate = PhraseCutter.rate

    private func tone(seconds: Double, amplitude: Float) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { Float(sin(Double($0) / Double(rate) * 2 * .pi * 220)) * amplitude }
    }

    /// Steady noise of about the given RMS (uniform, repeatable).
    private func noise(seconds: Double, rms: Float, seed: UInt32 = 1) -> [Float] {
        var x = seed
        return (0..<Int(seconds * Double(rate))).map { _ in
            x = x &* 1_664_525 &+ 1_013_904_223
            return (Float(x >> 8) / Float(1 << 24) * 2 - 1) * rms * 1.732
        }
    }

    private func phrases(_ audio: [Float], pause: Double = 0.8) -> [PhraseCutter.Phrase] {
        var cutter = PhraseCutter(pause: pause)
        var out: [PhraseCutter.Phrase] = []
        var i = 0
        while i < audio.count {
            out += cutter.add(Array(audio[i..<min(i + 1024, audio.count)]))
            i += 1024
        }
        return out
    }

    /// Speech far quieter than a normal microphone's (RMS about 0.004, -48 dB) still makes a phrase.
    func testQuietSpeechIsAPhrase() {
        let audio = noise(seconds: 1, rms: 0.0002) + tone(seconds: 1, amplitude: 0.006) + noise(seconds: 1.5, rms: 0.0002)
        let got = phrases(audio)
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].paused, true)
        // About the tone, the lead before it and the pause after it.
        XCTAssertGreaterThan(Double(got[0].samples.count) / Double(rate), 1.9)
        XCTAssertLessThan(Double(got[0].samples.count) / Double(rate), 2.5)
    }

    /// Steady noise above the quietest threshold soon counts as background: it doesn't go on
    /// making phrases, and speech over it is still cut out at its pauses.
    func testSteadyNoiseIsBackground() {
        let audio = noise(seconds: 20, rms: 0.004) + tone(seconds: 1, amplitude: 0.05) + noise(seconds: 1.5, rms: 0.004)
        let got = phrases(audio)
        // At most one phrase of noise as it settles, and the speech.
        XCTAssertLessThanOrEqual(got.count, 2)
        guard let last = got.last else { return XCTFail("the speech wasn't heard") }
        XCTAssertTrue(last.paused)
        XCTAssertLessThan(Double(last.samples.count) / Double(rate), 3)
        XCTAssertGreaterThan(Double(last.samples.count) / Double(rate), 1.9)
    }

    /// Silence makes nothing.
    func testSilenceIsNothing() {
        XCTAssertEqual(phrases([Float](repeating: 0, count: rate * 10)).count, 0)
        XCTAssertEqual(phrases(noise(seconds: 10, rms: 0.0005)).count, 0)
    }

    /// Long talking is still cut by length, not at a false pause as the floor creeps up.
    func testLongSpeechCutsByLength() {
        let got = phrases(tone(seconds: 20, amplitude: 0.05))
        XCTAssertEqual(got.count, 1)
        XCTAssertFalse(got[0].paused)
        XCTAssertGreaterThan(Double(got[0].samples.count) / Double(rate), 9)
    }

    func testLifted() {
        let quiet = tone(seconds: 0.1, amplitude: 0.02)
        let up = PCM.lifted(quiet)
        XCTAssertEqual(PCM.peak(up[...]), 0.5, accuracy: 0.01)
        // Loud enough already: untouched. Very quiet: turned up only 30 times. Silence: untouched.
        XCTAssertEqual(PCM.lifted(tone(seconds: 0.1, amplitude: 0.6)), tone(seconds: 0.1, amplitude: 0.6))
        XCTAssertEqual(PCM.peak(PCM.lifted(tone(seconds: 0.1, amplitude: 0.001))[...]), 0.03, accuracy: 0.001)
        XCTAssertEqual(PCM.lifted([0, 0, 0]), [0, 0, 0])
    }
}
