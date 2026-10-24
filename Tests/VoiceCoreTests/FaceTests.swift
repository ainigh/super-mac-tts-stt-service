import XCTest
@testable import VoiceCore

/// A model that answers what it's told to, and remembers what it was asked.
final class FakeModelAccess: ModelAccess {
    var modelName = "llama3.2:latest"
    var answer = #"{"sentences": [{"mood": "happy"}]}"#
    var error: Error?
    var asked: [(messages: [[String: Any]], format: Any?, temperature: Double?, think: Bool)] = []

    func chat(messages: [[String: Any]], format: Any?, temperature: Double?, think: Bool) async throws -> String {
        asked.append((messages, format, temperature, think))
        if let error { throw error }
        if modelName.isEmpty { throw AssistantError.noModel }
        return answer
    }
}

final class FaceTests: XCTestCase {
    var settings: ServiceSettings!
    var model: FakeModelAccess!
    var api: VoiceAPI!

    override func setUp() {
        settings = ServiceSettings()
        model = FakeModelAccess()
        api = VoiceAPI(engine: FakeEngine(), version: "0.1.0", model: model) { [unowned self] in self.settings }
    }

    func testTheModelAnswersOtherAppsWithAFormat() async {
        let body = #"{"messages": [{"role": "system", "content": "Direct."}, {"role": "user", "content": "1. Hi!"}], "format": {"type": "object"}, "temperature": 0}"#
        let (r, d) = await api.send("POST", "/api/model/chat", body: Data(body.utf8))
        XCTAssertEqual(r.status, 200)
        let o = json(d)
        XCTAssertEqual(o["model"] as? String, "llama3.2:latest")
        XCTAssertEqual((o["message"] as? [String: Any])?["content"] as? String, model.answer)
        XCTAssertNotNil(o["ms"] as? Int)
        XCTAssertEqual(model.asked.count, 1)
        XCTAssertEqual(model.asked[0].messages.count, 2)
        XCTAssertEqual(model.asked[0].temperature, 0)
        XCTAssertEqual(model.asked[0].think, false)
        XCTAssertEqual((model.asked[0].format as? [String: Any])?["type"] as? String, "object")
    }

    func testTheModelSaysWhichItIs() async {
        let (r, d) = await api.send("GET", "/api/model")
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(json(d)["model"] as? String, "llama3.2:latest")
        XCTAssertEqual(json(d)["ready"] as? Bool, true)
    }

    func testBadModelRequestsAreRefused() async {
        for body in [#"{}"#, #"{"messages": []}"#, #"{"messages": [{"role": "robot", "content": "x"}]}"#,
                     #"{"messages": [{"role": "user", "content": "x"}], "format": 3}"#] {
            let (r, d) = await api.send("POST", "/api/model/chat", body: Data(body.utf8))
            XCTAssertEqual(r.status, 400, body)
            XCTAssertEqual(json(d)["code"] as? String, "bad_request")
        }
        XCTAssertTrue(model.asked.isEmpty)
    }

    func testNoModelOrNoOllamaSaySo() async {
        let body = Data(#"{"messages": [{"role": "user", "content": "x"}]}"#.utf8)
        model.modelName = ""
        var (r, d) = await api.send("POST", "/api/model/chat", body: body)
        XCTAssertEqual(r.status, 503)
        XCTAssertEqual(json(d)["code"] as? String, "no_model")
        model.modelName = "qwen3:4b"
        model.error = AssistantError.unreachable("http://127.0.0.1:11434")
        (r, d) = await api.send("POST", "/api/model/chat", body: body)
        XCTAssertEqual(r.status, 502)
        XCTAssertEqual(json(d)["code"] as? String, "model_unreachable")
    }

    func testTheModelEndpointCanBeSwitchedOff() async {
        settings.off = [.model]
        let (r, d) = await api.send("POST", "/api/model/chat", body: Data(#"{"messages": [{"role": "user", "content": "x"}]}"#.utf8))
        XCTAssertEqual(r.status, 503)
        XCTAssertEqual(json(d)["code"] as? String, "endpoint_off")
        let (_, h) = await api.send("GET", "/api/health")
        XCTAssertEqual(json(h)["model"] as? Bool, false)
        XCTAssertEqual((json(h)["face"] as? [String: Any])?["url"] as? String, "http://127.0.0.1:8769")
    }

    func testWithoutModelAccessThereIsNoModel() async {
        let bare = VoiceAPI(engine: FakeEngine(), version: "0") { ServiceSettings() }
        let (r, _) = await bare.send("POST", "/api/model/chat", body: Data(#"{"messages": [{"role": "user", "content": "x"}]}"#.utf8))
        XCTAssertEqual(r.status, 503)
    }

    func testTheStructuredBodyKeepsToTheFormat() {
        let b = OllamaClient.structuredBody(model: "qwen3:4b", messages: [["role": "user", "content": "x"]],
                                            format: ["type": "object"], temperature: 0, think: false)
        XCTAssertEqual(b["stream"] as? Bool, false)
        XCTAssertEqual(b["think"] as? Bool, false)
        XCTAssertEqual((b["format"] as? [String: Any])?["type"] as? String, "object")
        XCTAssertEqual((b["options"] as? [String: Any])?["temperature"] as? Double, 0)
        XCTAssertNil(OllamaClient.structuredBody(model: "m", messages: [], format: nil, temperature: nil, think: false, sendThink: false)["think"])
    }

    func testSettingsSavedBeforeTheFaceStillLoad() throws {
        let old = Data(#"{"off": ["say"], "voice": "am_puck", "speed": 1.2, "allowNetwork": false, "token": "", "origins": [], "port": 9000}"#.utf8)
        let s = try JSONDecoder().decode(ServiceSettings.self, from: old)
        XCTAssertEqual(s.voice, "am_puck")
        XCTAssertEqual(s.port, 9000)
        XCTAssertEqual(s.off, [.say])
        XCTAssertEqual(s.face, FaceClient.defaultURL)
        XCTAssertTrue(s.speakThroughFace)
        let again = try JSONDecoder().decode(ServiceSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(again, s)
    }

    // MARK: Super Face's client

    func testWhatIsSentToTheFace() {
        let b = FaceClient.speakBody("Hello", voice: "am_fenrir", speed: 1.1, who: "Jerry")
        XCTAssertEqual(b["text"] as? String, "Hello")
        XCTAssertEqual(b["voice"] as? String, "am_fenrir")
        XCTAssertEqual(b["wait"] as? Bool, true)
        XCTAssertEqual(b["source"] as? String, "supervoice")
        XCTAssertEqual(b["who"] as? String, "Jerry")
        XCTAssertNil(FaceClient.speakBody("Hi", voice: "af_heart", speed: 1, who: nil)["who"])
    }

    func testWhatTheFaceAnswers() throws {
        XCTAssertEqual(try FaceClient.outcome(status: 200, Data(#"{"ok": true, "state": "done"}"#.utf8)), .said)
        XCTAssertEqual(try FaceClient.outcome(status: 200, Data(#"{"ok": false, "state": "stopped"}"#.utf8)), .stopped)
        XCTAssertThrowsError(try FaceClient.outcome(status: 503, Data(#"{"code": "model_loading", "progress": 0.3}"#.utf8))) { e in
            XCTAssertEqual(e as? FaceClient.Problem, .loading(0.3))
        }
        XCTAssertThrowsError(try FaceClient.outcome(status: 400, Data(#"{"error": "no voice named x"}"#.utf8))) { e in
            XCTAssertEqual(e as? FaceClient.Problem, .failed("no voice named x"))
        }
        XCTAssertThrowsError(try FaceClient.outcome(status: 200, Data(#"{"state": "failed", "error": "broke"}"#.utf8)))
        let echo = FaceClient.echo(Data(#"{"echo": false, "rest": "book a table", "matched": 0.4}"#.utf8))
        XCTAssertEqual(echo?.echo, false)
        XCTAssertEqual(echo?.rest, "book a table")
        XCTAssertNil(FaceClient.echo(Data("nope".utf8)))
    }

    func testOnlyAFaceThatCanSpeakIsUsed() {
        XCTAssertTrue(FaceClient.ready(status: 200, Data(#"{"service": "superface", "ready": true}"#.utf8)))
        // Its avatar didn't load, it's still starting, or it's a version that doesn't say.
        XCTAssertFalse(FaceClient.ready(status: 200, Data(#"{"service": "superface", "ready": false, "avatar": "failed"}"#.utf8)))
        XCTAssertFalse(FaceClient.ready(status: 200, Data(#"{"service": "superface", "avatar": "loading"}"#.utf8)))
        XCTAssertFalse(FaceClient.ready(status: 200, Data(#"{"service": "supervoice", "ready": true}"#.utf8)))
        XCTAssertFalse(FaceClient.ready(status: 503, Data()))
    }

    func testTheFaceAddressIsTidied() {
        XCTAssertEqual(FaceClient(baseURL: "127.0.0.1:8769/").baseURL.absoluteString, "http://127.0.0.1:8769")
        XCTAssertEqual(FaceClient(baseURL: "  ").baseURL.absoluteString, FaceClient.defaultURL)
    }

    func testAFaceThatIsNotRunningIsNotUp() async {
        let face = FaceClient(baseURL: "http://127.0.0.1:1")
        let up = await face.isUp()
        XCTAssertFalse(up)
        let echo = await face.echo("hello", seconds: 2)
        XCTAssertNil(echo)
        do {
            _ = try await face.speak("Hi", voice: "af_heart", speed: 1)
            XCTFail("it can't speak")
        } catch {
            XCTAssertEqual(error as? FaceClient.Problem, .unreachable)
        }
    }
}
