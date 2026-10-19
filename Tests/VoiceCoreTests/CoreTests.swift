import XCTest
@testable import VoiceCore

final class VoiceTests: XCTestCase {
    func testResolvesIdsNamesAndShortNames() {
        let d = Voice.named("am_michael")
        XCTAssertEqual(Voice.resolve("af_heart", default: d)?.name, "Heart")
        XCTAssertEqual(Voice.resolve("Bella", default: d)?.id, "af_bella")
        XCTAssertEqual(Voice.resolve("F3", default: d)?.id, "bf_emma")
        XCTAssertEqual(Voice.resolve("m3", default: d)?.id, "am_puck")
        XCTAssertEqual(Voice.resolve("female", default: d)?.id, "af_heart")
        XCTAssertEqual(Voice.resolve("male", default: d)?.id, "am_michael")
        XCTAssertEqual(Voice.resolve("UK", default: d)?.id, "bf_emma")
        XCTAssertEqual(Voice.resolve("us", default: d)?.id, "af_heart")
        XCTAssertEqual(Voice.resolve(nil, default: d)?.id, "am_michael")
        XCTAssertEqual(Voice.resolve(" ", default: d)?.id, "am_michael")
        XCTAssertNil(Voice.resolve("alloy", default: d))
        XCTAssertEqual(Voice.named("nope").id, "af_heart")
    }
}

final class HTTPParserTests: XCTestCase {
    func testAGetInPieces() throws {
        var p = HTTPParser()
        guard case .more = try p.feed(Data("GET /api/transcribe?format=srt&x=a%20b HTTP/1.1\r\nHo".utf8)) else { return XCTFail() }
        guard case .done(let r) = try p.feed(Data("st: localhost\r\nX-A: 1\r\nx-a: 2\r\n\r\n".utf8)) else { return XCTFail() }
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/api/transcribe")
        XCTAssertEqual(r.query, ["format": "srt", "x": "a b"])
        XCTAssertEqual(r.header("HOST"), "localhost")
        XCTAssertEqual(r.header("x-a"), "1, 2")
    }

    func testABodyByLengthAndTheContinueItAskedFor() throws {
        var p = HTTPParser()
        let head = "POST /api/tts HTTP/1.1\r\nContent-Length: 11\r\nExpect: 100-continue\r\n\r\n"
        guard case .more(let sendContinue) = try p.feed(Data(head.utf8)) else { return XCTFail() }
        XCTAssertTrue(sendContinue)
        guard case .more(false) = try p.feed(Data("hello ".utf8)) else { return XCTFail() }
        guard case .done(let r) = try p.feed(Data("world".utf8)) else { return XCTFail() }
        XCTAssertEqual(String(decoding: try r.body.data(), as: UTF8.self), "hello world")
    }

    func testAChunkedBody() throws {
        var p = HTTPParser()
        let raw = "POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\nTrailer: x\r\n\r\n"
        var result: HTTPRequest?
        for byte in Data(raw.utf8) {        // a byte at a time
            if case .done(let r) = try p.feed(Data([byte])) { result = r }
        }
        XCTAssertEqual(String(decoding: try result!.body.data(), as: UTF8.self), "hello world")
    }

    func testABigBodyGoesToAFileThatsRemovedAfter() throws {
        var p = HTTPParser()
        p.memoryLimit = 10
        var url: URL?
        do {
            _ = try p.feed(Data("POST /x HTTP/1.1\r\nContent-Length: 30\r\n\r\n".utf8))
            guard case .done(let r) = try p.feed(Data(repeating: 65, count: 30)) else { return XCTFail() }
            guard case .file(let f) = r.body else { return XCTFail("not spilled") }
            url = f.url
            XCTAssertEqual(r.body.count, 30)
            XCTAssertEqual(try r.body.data(), Data(repeating: 65, count: 30))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url!.path))
    }

    func testRefusesTooBigAndNonsense() {
        var p = HTTPParser()
        p.maxBody = 100
        XCTAssertThrowsError(try p.feed(Data("POST /x HTTP/1.1\r\nContent-Length: 101\r\n\r\n".utf8))) {
            XCTAssertEqual(($0 as? HTTPError)?.status, 413)
        }
        var q = HTTPParser()
        XCTAssertThrowsError(try q.feed(Data("NONSENSE\r\n\r\n".utf8)))
    }

    func testResponseFraming() {
        let r = HTTPResponse(status: 503, contentType: "application/json", data: Data("{}".utf8))
        XCTAssertEqual(String(decoding: r.head(), as: UTF8.self),
                       "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n")
        XCTAssertEqual(String(decoding: HTTPResponse.chunk(Data(repeating: 66, count: 26)), as: UTF8.self),
                       "1a\r\n" + String(repeating: "B", count: 26) + "\r\n")
        let s = HTTPResponse(body: .stream { _ in })
        XCTAssertTrue(String(decoding: s.head(), as: UTF8.self).contains("Transfer-Encoding: chunked"))
    }
}

final class MultipartTests: XCTestCase {
    func testRoundTrip() throws {
        let file = Data([0, 1, 2, 13, 10, 45, 45, 255])        // CR LF -- inside the data
        let body = Multipart.encode([.init(name: "model", data: Data("whisper-1".utf8)),
                                     .init(name: "file", filename: "a b.m4a", contentType: "audio/mp4", data: file)],
                                    boundary: "----abc")
        let m = try Multipart(body, boundary: "----abc")
        XCTAssertEqual(m.field("model"), "whisper-1")
        XCTAssertEqual(m.part("file")?.filename, "a b.m4a")
        XCTAssertEqual(m.part("file")?.contentType, "audio/mp4")
        XCTAssertEqual(m.part("file")?.data, file)
        XCTAssertEqual(Multipart.boundary("multipart/form-data; boundary=\"----abc\""), "----abc")
        XCTAssertNil(Multipart.boundary("application/json"))
    }
}

final class AudioTests: XCTestCase {
    func testWAVRoundTrip() {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1]
        let wav = PCM.wav(samples, rate: 24_000)
        XCTAssertEqual(wav.count, 44 + 10)
        let back = PCM.readWAV(wav)
        XCTAssertEqual(back?.rate, 24_000)
        for (a, b) in zip(back!.samples, samples) { XCTAssertEqual(a, b, accuracy: 0.001) }
    }

    func testStereoFloatWAVIsMixedDown() {
        var d = Data("RIFF".utf8)
        d.append(le: UInt32(36 + 16))
        d.append(Data("WAVEfmt ".utf8))
        d.append(le: UInt32(16)); d.append(le: UInt16(3)); d.append(le: UInt16(2))
        d.append(le: UInt32(8000)); d.append(le: UInt32(64_000)); d.append(le: UInt16(8)); d.append(le: UInt16(32))
        d.append(Data("data".utf8)); d.append(le: UInt32(16))
        for f: Float in [1, 0, 0.5, 0.5] { d.append(le: f.bitPattern) }
        XCTAssertEqual(PCM.readWAV(d)?.samples, [0.5, 0.5])
        XCTAssertEqual(PCM.readWAV(d)?.rate, 8000)
    }

    func testResampleAndSniff() {
        XCTAssertEqual(PCM.resample([Float](repeating: 0.1, count: 24_000), from: 24_000, to: 16_000).count, 16_000)
        XCTAssertEqual(PCM.sniffExtension(PCM.wav([0], rate: 16_000)), "wav")
        XCTAssertEqual(PCM.sniffExtension(Data("ID3\u{3}".utf8)), "mp3")
        XCTAssertEqual(PCM.sniffExtension(Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8)), "m4a")
        XCTAssertEqual(PCM.sniffExtension(Data([0, 0, 0, 0x20]) + Data("ftypisom".utf8)), "mp4")
        XCTAssertEqual(PCM.sniffExtension(Data("fLaC".utf8)), "flac")
        XCTAssertEqual(PCM.sniffExtension(Data("#!AMR\n".utf8)), "amr")
        XCTAssertEqual(PCM.sniffExtension(Data([0, 0, 0, 0x18]) + Data("ftyp3gp4".utf8)), "3gp")
        XCTAssertEqual(PCM.sniffExtension(Data("hello".utf8)), "")
    }

    func testStreamedWAVHeaderSaysUnknownLength() {
        let h = PCM.wavHeader(rate: 24_000, frames: nil)
        XCTAssertEqual(h.count, 44)
        XCTAssertEqual(Array(h[4..<8]), [0xFF, 0xFF, 0xFF, 0xFF])
        // And it still reads, as the stream so far.
        XCTAssertEqual(PCM.readWAV(h + PCM.pcm16([0.5, 0.5]))?.samples.count, 2)
    }
}

final class CaptionTests: XCTestCase {
    let segments = [TimedText(start: 0.5, end: 2, text: "Hello."), TimedText(start: 3661.25, end: 3662, text: "Later.")]

    func testFormats() {
        XCTAssertEqual(Captions.srt(segments), "1\n00:00:00,500 --> 00:00:02,000\nHello.\n\n2\n01:01:01,250 --> 01:01:02,000\nLater.\n")
        XCTAssertEqual(Captions.vtt(segments), "WEBVTT\n\n00:00:00.500 --> 00:00:02.000\nHello.\n\n01:01:01.250 --> 01:01:02.000\nLater.\n")
        XCTAssertEqual(Captions.plain(segments), "Hello. Later.")
        XCTAssertEqual(Captions.clock(3725), "1:02:05")
        XCTAssertEqual(Captions.clock(65), "1:05")
    }

    func testSentencesAreTimedByTheirWords() {
        let words = ["Hi", "there.", "Bye."].enumerated().map { TimedWord(word: $1, start: Double($0), end: Double($0) + 0.5) }
        XCTAssertEqual(Captions.sentences("Hi there. Bye.", words: words, offset: 10, length: 5),
                       [TimedText(start: 10, end: 11.5, text: "Hi there."), TimedText(start: 12, end: 12.5, text: "Bye.")])
        XCTAssertEqual(Captions.sentences("No timings", words: [], offset: 2, length: 3), [TimedText(start: 2, end: 5, text: "No timings")])
        XCTAssertEqual(Captions.sentences("  ", words: words, offset: 0, length: 1), [])
    }

    func testSentenceSplitting() {
        XCTAssertEqual(SpokenText.sentences("Dr. Smith said hi. Then e.g. this! Done?\nNew line"),
                       ["Dr. Smith said hi.", "Then e.g. this!", "Done?", "New line"])
        XCTAssertEqual(SpokenText.sentences("... --- !!!"), [])
    }
}

final class AccessTests: XCTestCase {
    func testLoopbackHosts() {
        for h in ["localhost", "localhost:8767", "127.0.0.1:8767", "[::1]:8767", "127.0.0.2"] {
            XCTAssertTrue(Access.isLoopbackHost(h), h)
        }
        for h in ["example.com", "192.168.1.5:8767", "127.0.0.1.evil.com"] {
            XCTAssertFalse(Access.isLoopbackHost(h), h)
        }
    }

    func testGlobs() {
        XCTAssertTrue(Access.glob("*", matches: "https://x"))
        XCTAssertTrue(Access.glob("https://*.example.com", matches: "https://app.example.com"))
        XCTAssertFalse(Access.glob("https://*.example.com", matches: "https://example.org"))
        XCTAssertTrue(Access.glob("http://10.0.0.5:*", matches: "http://10.0.0.5:3000"))
    }
}

final class TranscriberTests: XCTestCase {
    func testCutsLongAudioAtQuietMomentsAndKeepsEverySample() async throws {
        let engine = FakeEngine()
        let audio = speechLike(seconds: 130)
        var events: [LongTranscriber.Event] = []
        let segments = try await LongTranscriber().run(SampleReader(samples: audio, rate: 16_000), engine: engine) { events.append($0) }
        XCTAssertEqual(engine.written.reduce(0, +), audio.count)
        XCTAssertEqual(engine.written.count, 3)
        // Each cut falls in a quiet gap (the gaps are 4.6 to 5 s into every 5 s).
        for n in engine.written.dropLast() {
            let at = Double(n) / 16_000
            XCTAssertGreaterThan(at.truncatingRemainder(dividingBy: 5), 4.5)
        }
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[1].start, Double(engine.written[0]) / 16_000 + 0.5, accuracy: 0.001)
        guard case .progress(let done, let total) = events.last else { return XCTFail() }
        XCTAssertEqual(done, 130)
        XCTAssertEqual(total, 130)
    }
}
