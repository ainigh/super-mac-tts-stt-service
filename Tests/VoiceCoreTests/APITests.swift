import XCTest
@testable import VoiceCore

final class APITests: XCTestCase {
    var engine: FakeEngine!
    var settings: ServiceSettings!
    var api: VoiceAPI!

    override func setUp() {
        engine = FakeEngine()
        settings = ServiceSettings()
        api = VoiceAPI(engine: engine, version: "0.1.0") { [unowned self] in self.settings }
    }

    func testHealthSaysWhatsOnAndHowTheModelsAre() async {
        settings.off = [.say]
        engine.sttState = .downloading(0.4213)
        let (r, d) = await api.send("GET", "/api/health")
        XCTAssertEqual(r.status, 200)
        let h = json(d)
        XCTAssertEqual(h["ok"] as? Bool, true)
        XCTAssertEqual(h["tts"] as? Bool, true)
        XCTAssertEqual(h["say"] as? Bool, false)
        XCTAssertEqual(h["version"] as? String, "0.1.0")
        XCTAssertEqual(h["port"] as? Int, 8767)
        XCTAssertNotNil(h["uptime"] as? Int)
        let models = h["models"] as? [String: [String: Any]]
        XCTAssertEqual(models?["tts"]?["state"] as? String, "ready")
        XCTAssertEqual(models?["stt"]?["state"] as? String, "downloading")
        XCTAssertEqual(models?["stt"]?["progress"] as? Double, 0.42)
    }

    func testVoicesListsTheSixWithTheDefault() async {
        settings.voice = "am_fenrir"
        let (_, d) = await api.send("GET", "/api/voices")
        let v = json(d)
        XCTAssertEqual(v["default"] as? String, "am_fenrir")
        let voices = v["voices"] as? [[String: Any]]
        XCTAssertEqual(voices?.count, 6)
        XCTAssertEqual(voices?.map { $0["alias"] as? String }, ["f1", "f2", "f3", "m1", "m2", "m3"])
        XCTAssertEqual(voices?[2]["accent"] as? String, "uk")
    }

    func testTTSMakesAWAVSentenceBySentence() async {
        let (r, d) = await api.send("POST", "/api/tts", body: Data(#"{"text": "Hello there. How are you?", "voice": "m2", "speed": 1.5}"#.utf8))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.header("Content-Type"), "audio/wav")
        XCTAssertEqual(r.header("X-Voice"), "am_fenrir")
        XCTAssertEqual(r.header("X-Duration"), "0.5")
        XCTAssertEqual(engine.spoken.map(\.0), ["Hello there.", "How are you?"])
        XCTAssertEqual(engine.spoken.first?.2, 1.5)
        let wav = PCM.readWAV(d)
        XCTAssertEqual(wav?.rate, 24_000)
        XCTAssertEqual(wav?.samples.count, 5 * 2400)
    }

    func testTTSTakesPlainTextAndTheDefaults() async {
        settings.voice = "bf_emma"
        settings.speed = 0.8
        let (r, _) = await api.send("POST", "/api/tts", body: Data("Just this.".utf8),
                                    headers: ["Content-Type": "application/x-www-form-urlencoded"])
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(engine.spoken.first?.1.id, "bf_emma")
        XCTAssertEqual(engine.spoken.first?.2, 0.8)
    }

    func testTTSStreamsAHeaderThenEachSentence() async {
        let (r, d) = await api.send("POST", "/api/tts", body: Data(#"{"text": "One two. Three.", "stream": true}"#.utf8))
        XCTAssertEqual(r.status, 200)
        guard case .stream = r.body else { return XCTFail("not streamed") }
        XCTAssertEqual(d.count, 44 + (2 + 1) * 2400 * 2)
        XCTAssertEqual(Array(d[40..<44]), [0xFF, 0xFF, 0xFF, 0xFF])
    }

    func testTTSPCMHasNoHeader() async {
        let (r, d) = await api.send("POST", "/api/tts", body: Data(#"{"text": "Hi.", "format": "pcm"}"#.utf8))
        XCTAssertEqual(r.header("Content-Type"), "audio/pcm")
        XCTAssertEqual(d.count, 2400 * 2)
    }

    func testTTSSaysWhatsWrong() async {
        let cases: [(String, Int, String)] = [
            (#"{"text": "  "}"#, 400, "missing_text"),
            (#"{"voice": "f1"}"#, 400, "missing_text"),
            (#"{"text": "Hi", "voice": "alloy"}"#, 400, "unknown_voice"),
            (#"{"text": "Hi", "speed": 3}"#, 400, "bad_speed"),
            (#"{"text": "Hi", "speed": "fast"}"#, 400, "bad_speed"),
            (#"{"text": "Hi", "format": "mp3"}"#, 400, "bad_request"),
            (#"{"text": "Hi""#, 400, "bad_request"),
            ("{\"text\": \"\(String(repeating: "a", count: 20_001))\"}", 413, "too_large"),
        ]
        for (body, status, code) in cases {
            let (r, d) = await api.send("POST", "/api/tts", body: Data(body.utf8))
            XCTAssertEqual(r.status, status, body.prefix(40) + "")
            XCTAssertEqual(json(d)["code"] as? String, code, body.prefix(40) + "")
        }
    }

    func testAnEndpointTurnedOffSaysSo() async {
        settings.off = [.tts]
        let (r, d) = await api.send("POST", "/api/tts", body: Data("Hi.".utf8))
        XCTAssertEqual(r.status, 503)
        XCTAssertEqual(json(d)["code"] as? String, "endpoint_off")
        settings.off = [.openai]
        let (r2, d2) = await api.send("GET", "/v1/models")
        XCTAssertEqual(r2.status, 503)
        XCTAssertEqual((json(d2)["error"] as? [String: Any])?["code"] as? String, "endpoint_off")
    }

    func testAFirstDownloadAnswersModelLoading() async {
        engine.ttsState = .downloading(0.3)
        let (r, d) = await api.send("POST", "/api/tts", body: Data("Hi.".utf8))
        XCTAssertEqual(r.status, 503)
        XCTAssertEqual(r.header("Retry-After"), "5")
        XCTAssertEqual(json(d)["code"] as? String, "model_loading")
        XCTAssertEqual(json(d)["progress"] as? Double, 0.3)
    }

    func testSTTWritesDownAWAV() async {
        let wav = PCM.wav(speechLike(seconds: 3, rate: 24_000), rate: 24_000)
        let (r, d) = await api.send("POST", "/api/stt?lang=en", body: wav)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(json(d)["text"] as? String, "Piece one.")
        XCTAssertEqual(json(d)["duration"] as? Double, 3)
        XCTAssertEqual(engine.written, [48_000])
    }

    func testSTTTakesRawPCM() async {
        let pcm = PCM.pcm16(speechLike(seconds: 2, rate: 8000))
        let (r, d) = await api.send("POST", "/api/stt?format=pcm&rate=8000", body: pcm)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(json(d)["duration"] as? Double, 2)
        XCTAssertEqual(engine.written, [32_000])
    }

    func testSilenceIsNoTextNotAnError() async {
        let (r, d) = await api.send("POST", "/api/stt", body: PCM.wav([Float](repeating: 0, count: 16_000), rate: 16_000))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(json(d)["text"] as? String, "")
        XCTAssertEqual(engine.written, [])
    }

    func testSTTRefusesWhatIsntAudio() async {
        let (r, d) = await api.send("POST", "/api/stt", body: Data("not audio at all".utf8))
        XCTAssertEqual(r.status, 415)
        XCTAssertEqual(json(d)["code"] as? String, "unsupported_audio")
        let (r2, _) = await api.send("POST", "/api/stt")
        XCTAssertEqual(r2.status, 400)
    }

    func testTranscribeStreamsEvents() async {
        let wav = PCM.wav(speechLike(seconds: 120), rate: 16_000)
        let (r, d) = await api.send("POST", "/api/transcribe", body: wav)
        XCTAssertEqual(r.header("Content-Type"), "application/x-ndjson")
        let c = Collector()
        c.data = d
        let events = c.lines
        XCTAssertEqual(events.first?["type"] as? String, "info")
        XCTAssertEqual(events.first?["duration"] as? Double, 120)
        let segments = events.filter { $0["type"] as? String == "segment" }
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.map { $0["text"] as? String }, ["Piece one.", "Piece two.", "Piece three."])
        // The second piece starts where the first was cut (at a quiet moment before 50 s).
        let secondStart = segments[1]["start"] as? Double ?? 0
        XCTAssertGreaterThan(secondStart, 38.5)
        XCTAssertLessThan(secondStart, 51)
        let progress = events.filter { $0["type"] as? String == "progress" }
        XCTAssertEqual(progress.last?["done"] as? Double, 120)
        XCTAssertEqual(events.last?["type"] as? String, "done")
        XCTAssertEqual(events.last?["text"] as? String, "Piece one. Piece two. Piece three.")
        XCTAssertEqual(engine.written.reduce(0, +), 120 * 16_000)
    }

    func testTranscribeReportsAnErrorInTheStream() async {
        engine.failWrite = HTTPError(status: 500, code: "failed", message: "model broke")
        let (_, d) = await api.send("POST", "/api/transcribe", body: PCM.wav(speechLike(seconds: 2), rate: 16_000))
        let c = Collector()
        c.data = d
        XCTAssertEqual(c.lines.last?["type"] as? String, "error")
        XCTAssertEqual(c.lines.last?["message"] as? String, "model broke")
    }

    func testTranscribeAsSubtitlesAndJSON() async {
        let wav = PCM.wav(speechLike(seconds: 4), rate: 16_000)
        let (r, d) = await api.send("POST", "/api/transcribe?format=srt", body: wav)
        XCTAssertEqual(r.header("Content-Type"), "application/x-subrip; charset=utf-8")
        XCTAssertEqual(String(decoding: d, as: UTF8.self), "1\n00:00:00,500 --> 00:00:01,400\nPiece one.\n")
        let (_, j) = await api.send("POST", "/api/transcribe?format=json", body: wav)
        XCTAssertEqual((json(j)["segments"] as? [[String: Any]])?.first?["start"] as? Double, 0.5)
        let (_, t) = await api.send("POST", "/api/transcribe?format=txt", body: wav)
        XCTAssertEqual(String(decoding: t, as: UTF8.self), "Piece three.\n")      // the fake counts pieces
    }

    func testAMultipartUploadWorksOnTheNativeRoutes() async {
        let body = Multipart.encode([.init(name: "file", filename: "a.wav", contentType: "audio/wav",
                                           data: PCM.wav(speechLike(seconds: 1), rate: 16_000))], boundary: "XyZ")
        let (r, d) = await api.send("POST", "/api/stt", body: body, headers: ["Content-Type": "multipart/form-data; boundary=XyZ"])
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(json(d)["text"] as? String, "Piece one.")
    }

    func testSayQueuesAndStops() async {
        let (r, d) = await api.send("POST", "/api/say", body: Data(#"{"text": "Build finished"}"#.utf8))
        XCTAssertEqual(r.status, 202)
        XCTAssertEqual(json(d)["queued"] as? Int, 1)
        let (_, s) = await api.send("POST", "/api/say/stop")
        XCTAssertEqual(json(s)["stopped"] as? Int, 1)
    }

    func testOpenAISpeech() async {
        let (r, d) = await api.send("POST", "/v1/audio/speech",
                                    body: Data(#"{"model": "tts-1", "input": "Hello.", "voice": "alloy"}"#.utf8))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.header("Content-Type"), "audio/wav")       // mp3 is answered with WAV
        XCTAssertEqual(r.header("X-Voice"), "af_heart")             // unknown voices get the default
        XCTAssertNotNil(PCM.readWAV(d))
        let (r2, _) = await api.send("POST", "/v1/audio/speech",
                                     body: Data(#"{"input": "Hello.", "voice": "puck", "response_format": "pcm"}"#.utf8))
        XCTAssertEqual(r2.header("Content-Type"), "audio/pcm")
        XCTAssertEqual(r2.header("X-Voice"), "am_puck")
    }

    func testOpenAITranscription() async {
        let file = PCM.wav(speechLike(seconds: 2), rate: 16_000)
        func form(_ format: String?) -> Data {
            var parts: [Multipart.Part] = [.init(name: "model", data: Data("whisper-1".utf8)),
                                           .init(name: "file", filename: "note.wav", contentType: "audio/wav", data: file)]
            if let format { parts.append(.init(name: "response_format", data: Data(format.utf8))) }
            return Multipart.encode(parts, boundary: "b0und")
        }
        let headers = ["Content-Type": "multipart/form-data; boundary=b0und"]
        let (r, d) = await api.send("POST", "/v1/audio/transcriptions", body: form(nil), headers: headers)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(json(d) as NSDictionary, ["text": "Piece one."])
        let (_, v) = await api.send("POST", "/v1/audio/transcriptions", body: form("verbose_json"), headers: headers)
        XCTAssertEqual(json(v)["duration"] as? Double, 2)
        XCTAssertEqual((json(v)["segments"] as? [[String: Any]])?.first?["id"] as? Int, 0)
        let (_, t) = await api.send("POST", "/v1/audio/transcriptions", body: form("text"), headers: headers)
        XCTAssertEqual(String(decoding: t, as: UTF8.self), "Piece three.\n")
        let (bad, b) = await api.send("POST", "/v1/audio/transcriptions", body: Data("x".utf8))
        XCTAssertEqual(bad.status, 400)
        XCTAssertEqual((json(b)["error"] as? [String: Any])?["type"] as? String, "invalid_request_error")
    }

    func testModels() async {
        let (_, d) = await api.send("GET", "/v1/models")
        XCTAssertEqual((json(d)["data"] as? [[String: Any]])?.map { $0["id"] as? String }, ["kokoro", "parakeet"])
    }

    func testUnknownRoutesAndMethods() async {
        let (r, d) = await api.send("GET", "/api/nope")
        XCTAssertEqual(r.status, 404)
        XCTAssertTrue((json(d)["error"] as? String ?? "").contains("/api/tts"))
        let (r2, _) = await api.send("GET", "/api/tts")
        XCTAssertEqual(r2.status, 405)
        XCTAssertEqual(r2.header("Allow"), "POST")
        let (r3h, _) = await api.send("POST", "/api/health")
        XCTAssertEqual(r3h.header("Allow"), "GET, HEAD")
        let (r3, d3) = await api.send("GET", "/")
        XCTAssertEqual(r3.status, 200)
        XCTAssertTrue(String(decoding: d3, as: UTF8.self).contains("<title>Super Voice</title>"))
    }

    func testBrowsersFromThisMachineGetCORSAndOthersAreRefused() async {
        let (pre, _) = await api.send("OPTIONS", "/api/tts", headers: ["Origin": "http://localhost:3000"])
        XCTAssertEqual(pre.status, 204)
        XCTAssertEqual(pre.header("Access-Control-Allow-Origin"), "http://localhost:3000")
        let (r, _) = await api.send("GET", "/api/health", headers: ["Origin": "https://evil.example"])
        XCTAssertEqual(r.status, 403)
        settings.origins = ["https://*.example"]
        let (r2, _) = await api.send("GET", "/api/health", headers: ["Origin": "https://app.example"])
        XCTAssertEqual(r2.status, 200)
        XCTAssertEqual(r2.header("Access-Control-Allow-Origin"), "https://app.example")
    }

    func testOtherHostsAndMachinesAreRefusedUnlessShared() async {
        let (r, _) = await api.send("GET", "/api/health", headers: ["Host": "rebind.evil.example"])
        XCTAssertEqual(r.status, 403)
        let (r2, _) = await api.send("GET", "/api/health", fromLoopback: false)
        XCTAssertEqual(r2.status, 403)
        settings.allowNetwork = true
        settings.token = "secret"
        let (r3, d3) = await api.send("GET", "/api/health", headers: ["Host": "mac.local:8767"], fromLoopback: false)
        XCTAssertEqual(r3.status, 401)
        XCTAssertEqual(json(d3)["code"] as? String, "unauthorized")
        let (r4, _) = await api.send("GET", "/api/health", headers: ["Host": "mac.local:8767", "Authorization": "Bearer secret"],
                                     fromLoopback: false)
        XCTAssertEqual(r4.status, 200)
        let (r5, _) = await api.send("GET", "/api/health", headers: ["Host": "mac.local:8767"])
        XCTAssertEqual(r5.status, 200)              // this Mac needs no token
    }
}
