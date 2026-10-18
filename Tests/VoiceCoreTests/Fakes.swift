import Foundation
@testable import VoiceCore

/// Stands in for the models: "speaks" a tenth of a second per word, and "hears" each piece as
/// "Piece one." "Piece two." … with a word timing per word.
final class FakeEngine: SpeechEngine {
    var ttsState = ModelState.ready
    var sttState = ModelState.ready
    var spoken: [(String, Voice, Double)] = []
    var written: [Int] = []          // samples per piece
    var said: [String] = []
    var failWrite: Error?
    private let numbers = ["one", "two", "three", "four", "five", "six", "seven", "eight"]

    func prepare(tts: Bool, stt: Bool) {}

    func speak(_ text: String, voice: Voice, speed: Double) async throws -> [Float] {
        spoken.append((text, voice, speed))
        let words = text.split(separator: " ").count
        return [Float](repeating: 0.25, count: words * PCM.speakRate / 10)
    }

    func write(_ samples: [Float]) async throws -> Recognized {
        if let failWrite { throw failWrite }
        written.append(samples.count)
        let n = numbers[(written.count - 1) % numbers.count]
        return Recognized(text: "Piece \(n).", words: [TimedWord(word: "Piece", start: 0.5, end: 0.9),
                                                       TimedWord(word: "\(n).", start: 1.0, end: 1.4)])
    }

    func open(_ url: URL) throws -> AudioReader {
        guard let wav = PCM.readWAV(try Data(contentsOf: url)) else { throw AudioError.unreadable("not a WAV") }
        return SampleReader(samples: wav.samples, rate: wav.rate)
    }

    func say(_ text: String, voice: Voice, speed: Double) -> (id: String, queued: Int) {
        said.append(text)
        return ("id-\(said.count)", said.count)
    }

    func stopSaying() -> Int {
        defer { said = [] }
        return said.count
    }
}

/// Collects a streamed response.
final class Collector: ResponseWriter {
    var data = Data()
    var failAfter: Int?

    func write(_ chunk: Data) async throws {
        if let failAfter, data.count >= failAfter { throw WriterGone() }
        data.append(chunk)
    }

    var lines: [[String: Any]] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { JSON.object(Data($0.utf8)) }
    }
}

/// Speech-like audio: `seconds` of a tone with a gap of silence every `every` seconds.
func speechLike(seconds: Double, rate: Int = 16_000, every: Double = 5) -> [Float] {
    (0..<Int(seconds * Double(rate))).map { i in
        let t = Double(i) / Double(rate)
        return t.truncatingRemainder(dividingBy: every) > every - 0.4 ? 0 : Float(sin(t * 2 * .pi * 220) * 0.5)
    }
}

extension VoiceAPI {
    /// Sends a request and returns the response, with a stream's body collected.
    func send(_ method: String, _ target: String, body: Data = Data(), headers: [String: String] = [:],
              fromLoopback: Bool = true) async -> (HTTPResponse, Data) {
        let req = HTTPRequest(method: method, target: target, headers: ["Host": "127.0.0.1:8767"].merging(headers) { _, b in b },
                              body: body.isEmpty ? .empty : .data(body), fromLoopback: fromLoopback)
        let r = await handle(req)
        switch r.body {
        case .data(let d): return (r, d)
        case .stream(let make):
            let c = Collector()
            try? await make(c)
            return (r, c.data)
        }
    }
}

func json(_ d: Data) -> [String: Any] { JSON.object(d) ?? [:] }
