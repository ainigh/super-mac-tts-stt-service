import XCTest
@testable import VoiceCore

final class FixesTests: XCTestCase {
    var engine: FakeEngine!
    var settings = ServiceSettings()
    var api: VoiceAPI!

    override func setUp() {
        engine = FakeEngine()
        settings = ServiceSettings()
        api = VoiceAPI(engine: engine, version: "0.1.0") { [unowned self] in self.settings }
    }

    func testTranscribeRawPCM() async {
        let pcm = PCM.pcm16(speechLike(seconds: 2))
        let (r, body) = await api.send("POST", "/api/transcribe?format=pcm&rate=16000", body: pcm)
        XCTAssertEqual(r.status, 200, String(decoding: body, as: UTF8.self))
    }

    func testPlainTextBrace() async {
        let (r, body) = await api.send("POST", "/api/tts", body: Data("{laughs} Hello there.".utf8),
                                       headers: ["Content-Type": "text/plain"])
        XCTAssertEqual(r.status, 200, String(decoding: body, as: UTF8.self))
    }

    func testChunkEndMustBeCRLF() throws {
        var p = HTTPParser()
        let raw = "POST /api/tts HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabcdef\r\n0\r\n\r\n"
        XCTAssertThrowsError(try p.feed(Data(raw.utf8))) { e in
            XCTAssertEqual((e as? HTTPError)?.status, 400)
        }
    }

    func testChunkSizeLineUnbounded() throws {
        var p = HTTPParser()
        _ = try p.feed(Data("POST /api/tts HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
        let junk = Data(repeating: UInt8(ascii: "a"), count: 1 << 20)
        var threw = false
        for _ in 0..<8 { do { _ = try p.feed(junk) } catch { threw = true; break } }
        XCTAssertTrue(threw, "8 MB of chunk-size line buffered without error")
    }

    func testMultipartFilenameSemicolon() throws {
        let body = Multipart.encode([.init(name: "file", filename: "a;b.m4a", contentType: "audio/mp4", data: Data([1, 2]))], boundary: "XX")
        let m = try Multipart(body, boundary: "XX")
        XCTAssertEqual(m.part("file")?.filename, "a;b.m4a")
    }

    func testSpokenMath() {
        XCTAssertEqual(Assistant.spoken("2*3 is 6"), "2*3 is 6")
        XCTAssertEqual(Assistant.spoken("I like C# a lot"), "I like C# a lot")
    }

    func testNoSentence() {
        XCTAssertEqual(SpokenText.sentences("Are you coming? No. I am busy."), ["Are you coming?", "No.", "I am busy."])
        XCTAssertEqual(SpokenText.sentences("See No. 5 on the list."), ["See No. 5 on the list."])
        XCTAssertEqual(SpokenText.sentences("Solve for x. Then check."), ["Solve for x.", "Then check."])
    }

    func testNumberVoice() async {
        let (r, _) = await api.send("POST", "/api/tts", body: Data(#"{"text":"hi","voice":7}"#.utf8), headers: ["Content-Type": "application/json"])
        XCTAssertEqual(r.status, 400)
    }

    func testPlainSpaces() {
        XCTAssertEqual(Captions.plain([TimedText(start: 0, end: 1, text: "a  "), TimedText(start: 1, end: 2, text: " b")]), "a b")
    }
}
