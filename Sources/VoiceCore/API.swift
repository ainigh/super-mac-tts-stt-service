import Foundation

/// The HTTP API (see API.md): requests in, responses out. The server around it only moves bytes.
public final class VoiceAPI {
    public let engine: SpeechEngine
    public let version: String
    private let settings: () -> ServiceSettings
    private let directory: URL

    public static let maxText = 20_000

    public init(engine: SpeechEngine, version: String, directory: URL = FileManager.default.temporaryDirectory,
                settings: @escaping () -> ServiceSettings) {
        self.engine = engine
        self.version = version
        self.directory = directory
        self.settings = settings
    }

    public func handle(_ req: HTTPRequest) async -> HTTPResponse {
        let s = settings()
        let openAI = req.path.hasPrefix("/v1/")
        if let refusal = Access.refusal(req, settings: s) { return failure(refusal, openAI: openAI) }
        let cors = Access.cors(req, settings: s)
        if req.method == "OPTIONS" { return HTTPResponse(status: 204, headers: cors) }
        var response: HTTPResponse
        do {
            response = try await route(req, s)
        } catch let e as HTTPError {
            response = failure(e, openAI: openAI)
        } catch is CancellationError {
            response = failure(HTTPError(status: 500, code: "failed", message: "stopped"), openAI: openAI)
        } catch {
            response = failure(HTTPError(status: 500, code: "failed", message: describe(error)), openAI: openAI)
        }
        response.headers += cors
        return response
    }

    private static let routes: [String: String] = [
        "/": "GET", "/index.html": "GET", "/favicon.ico": "GET", "/api/health": "GET", "/api/voices": "GET",
        "/api/tts": "POST", "/api/stt": "POST", "/api/transcribe": "POST", "/api/say": "POST",
        "/api/say/stop": "POST", "/v1/models": "GET", "/v1/audio/speech": "POST", "/v1/audio/transcriptions": "POST",
    ]

    private func route(_ req: HTTPRequest, _ s: ServiceSettings) async throws -> HTTPResponse {
        var path = req.path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard let method = Self.routes[path] else {
            throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.path) (see /api/health)")
        }
        guard req.method == method || (method == "GET" && req.method == "HEAD") else {
            throw HTTPError(status: 405, code: "bad_request", message: "\(path) takes \(method)")
        }
        switch path {
        case "/", "/index.html":
            return HTTPResponse(contentType: "text/html; charset=utf-8", data: Data(StatusPage.html.utf8))
        case "/favicon.ico":
            return HTTPResponse(status: 204)
        case "/api/health":
            return JSON.response(health(s))
        case "/api/voices":
            return JSON.response(["default": s.defaultVoice.id, "speed": s.speed, "voices": Voice.all.map(\.json)])
        case "/api/tts":
            try need(.tts, s)
            return try await tts(req, s)
        case "/api/stt":
            try need(.stt, s)
            return try await stt(req)
        case "/api/transcribe":
            try need(.transcribe, s)
            return try await transcribe(req)
        case "/api/say":
            try need(.say, s)
            return try say(req, s)
        case "/api/say/stop":
            try need(.say, s)
            return JSON.response(["ok": true, "stopped": engine.stopSaying()])
        case "/v1/models":
            try need(.openai, s)
            let created = 1_767_225_600
            return JSON.response(["object": "list", "data": [
                ["id": "kokoro", "object": "model", "created": created, "owned_by": "supervoice"],
                ["id": "parakeet", "object": "model", "created": created, "owned_by": "supervoice"],
            ]])
        case "/v1/audio/speech":
            try need(.openai, s)
            try need(.tts, s)
            return try await openAISpeech(req, s)
        case "/v1/audio/transcriptions":
            try need(.openai, s)
            try need(.stt, s)
            return try await openAITranscription(req)
        default:
            throw HTTPError(status: 404, code: "not_found", message: "no such route: \(req.path)")
        }
    }

    // MARK: Health

    private func health(_ s: ServiceSettings) -> [String: Any] {
        var out: [String: Any] = [
            "ok": true, "service": "supervoice", "version": version,
            "models": ["tts": model("kokoro-82m", engine.ttsState), "stt": model("parakeet-tdt-0.6b-v3", engine.sttState)],
        ]
        for e in Endpoint.allCases { out[e.rawValue] = s.isOn(e) }
        return out
    }

    private func model(_ name: String, _ state: ModelState) -> [String: Any] {
        var m: [String: Any] = ["name": name, "state": state.name]
        if case .downloading(let p) = state, let p { m["progress"] = JSON.round(p) }
        if case .failed(let message) = state { m["message"] = message }
        return m
    }

    // MARK: Speaking

    private func tts(_ req: HTTPRequest, _ s: ServiceSettings) async throws -> HTTPResponse {
        let fields = try textFields(req)
        let text = try textField(fields["text"])
        guard let voice = Voice.resolve(fields["voice"] as? String, default: s.defaultVoice) else {
            throw HTTPError(status: 400, code: "unknown_voice",
                            message: "no voice named \(fields["voice"] ?? ""); the voices: \(Voice.all.map(\.name).joined(separator: ", ")) (or f1-f3, m1-m3)")
        }
        let speed = try speedField(fields["speed"], default: s.speed)
        let format = (fields["format"] as? String ?? "wav").lowercased()
        guard format == "wav" || format == "pcm" else {
            throw HTTPError(status: 400, code: "bad_request", message: "format is wav or pcm")
        }
        let stream = fields["stream"] as? Bool ?? false
        return try await speech(text, voice: voice, speed: speed, wav: format == "wav", stream: stream)
    }

    private func speech(_ text: String, voice: Voice, speed: Double, wav: Bool, stream: Bool) async throws -> HTTPResponse {
        try ready(tts: true)
        let sentences = SpokenText.sentences(text)
        let headers = [("Content-Type", wav ? "audio/wav" : "audio/pcm"), ("X-Voice", voice.id),
                       ("X-Sample-Rate", String(PCM.speakRate))]
        let engine = self.engine
        if stream {
            return HTTPResponse(status: 200, headers: headers, body: .stream { out in
                if wav { try await out.write(PCM.wavHeader(rate: PCM.speakRate, frames: nil)) }
                // Each sentence is made while the one before it is sent.
                var next: Task<[Float], Error>? = sentences.first.map { first in
                    Task { try await engine.speak(first, voice: voice, speed: speed) }
                }
                defer { next?.cancel() }
                for i in sentences.indices {
                    guard let current = next else { break }
                    next = i + 1 < sentences.count ? Task { [sentence = sentences[i + 1]] in
                        try await engine.speak(sentence, voice: voice, speed: speed)
                    } : nil
                    try await out.write(PCM.pcm16(try await current.value))
                }
            })
        }
        var samples: [Float] = []
        for sentence in sentences {
            try Task.checkCancellation()
            samples += try await engine.speak(sentence, voice: voice, speed: speed)
        }
        let body = wav ? PCM.wav(samples, rate: PCM.speakRate) : PCM.pcm16(samples)
        return HTTPResponse(status: 200, headers: headers, body: .data(body))
    }

    private func say(_ req: HTTPRequest, _ s: ServiceSettings) throws -> HTTPResponse {
        let fields = try textFields(req)
        let text = try textField(fields["text"])
        guard let voice = Voice.resolve(fields["voice"] as? String, default: s.defaultVoice) else {
            throw HTTPError(status: 400, code: "unknown_voice", message: "no voice named \(fields["voice"] ?? "")")
        }
        let speed = try speedField(fields["speed"], default: s.speed)
        let (id, queued) = engine.say(text, voice: voice, speed: speed)
        return JSON.response(["ok": true, "id": id, "queued": queued], status: 202)
    }

    private func openAISpeech(_ req: HTTPRequest, _ s: ServiceSettings) async throws -> HTTPResponse {
        guard let fields = JSON.object(try req.body.data()) else {
            throw HTTPError(status: 400, code: "bad_request", message: "send JSON: {\"model\", \"input\", \"voice\"}")
        }
        let text = try textField(fields["input"])
        let voice = Voice.resolve(fields["voice"] as? String, default: s.defaultVoice) ?? s.defaultVoice
        let speed = try speedField(fields["speed"], default: s.speed)
        let pcm = (fields["response_format"] as? String)?.lowercased() == "pcm"
        return try await speech(text, voice: voice, speed: speed, wav: !pcm, stream: false)
    }

    // MARK: Listening

    private func stt(_ req: HTTPRequest) async throws -> HTTPResponse {
        let started = Date()
        let audio = try open(req)
        try ready(stt: true)
        let segments = try await LongTranscriber().run(audio.reader, engine: engine)
        return JSON.response(["text": Captions.plain(segments), "duration": JSON.round(audio.reader.duration),
                              "time": JSON.round(Date().timeIntervalSince(started))])
    }

    private func transcribe(_ req: HTTPRequest) async throws -> HTTPResponse {
        let format = req.query["format"]?.lowercased() ?? ""
        guard ["", "ndjson", "json", "txt", "text", "srt", "vtt"].contains(format) else {
            throw HTTPError(status: 400, code: "bad_request", message: "format is json, txt, srt or vtt (or leave it out for NDJSON)")
        }
        let audio = try open(req)
        try ready(stt: true)
        let engine = self.engine
        if format.isEmpty || format == "ndjson" {
            return HTTPResponse(status: 200, headers: [("Content-Type", "application/x-ndjson"), ("Cache-Control", "no-cache")],
                                body: .stream { out in
                try await out.write(JSON.line(["type": "info", "duration": JSON.round(audio.reader.duration)]))
                do {
                    let segments = try await LongTranscriber().run(audio.reader, engine: engine) { event in
                        switch event {
                        case .progress(let done, let total):
                            try await out.write(JSON.line(["type": "progress", "done": done, "total": total]))
                        case .segment(let s):
                            try await out.write(JSON.line(["type": "segment"].merging(s.json) { a, _ in a }))
                        }
                    }
                    try await out.write(JSON.line(["type": "done", "text": Captions.plain(segments)]))
                } catch let e as WriterGone {
                    throw e
                } catch {
                    try await out.write(JSON.line(["type": "error", "message": describe(error)]))
                }
            })
        }
        let segments = try await LongTranscriber().run(audio.reader, engine: engine)
        return captions(segments, duration: audio.reader.duration, format: format)
    }

    private func captions(_ segments: [TimedText], duration: Double, format: String) -> HTTPResponse {
        switch format {
        case "txt", "text":
            return HTTPResponse(contentType: "text/plain; charset=utf-8", data: Data((Captions.plain(segments) + "\n").utf8))
        case "srt":
            return HTTPResponse(contentType: "application/x-subrip; charset=utf-8", data: Data(Captions.srt(segments).utf8))
        case "vtt":
            return HTTPResponse(contentType: "text/vtt; charset=utf-8", data: Data(Captions.vtt(segments).utf8))
        default:
            return JSON.response(["text": Captions.plain(segments), "duration": JSON.round(duration),
                                  "segments": segments.map(\.json)])
        }
    }

    private func openAITranscription(_ req: HTTPRequest) async throws -> HTTPResponse {
        guard Multipart.boundary(req.header("content-type")) != nil else {
            throw HTTPError(status: 400, code: "bad_request", message: "send multipart/form-data with a file field")
        }
        let form = try Multipart(try req.body.data(), boundary: Multipart.boundary(req.header("content-type"))!)
        let format = form.field("response_format")?.lowercased() ?? "json"
        guard ["json", "text", "srt", "vtt", "verbose_json"].contains(format) else {
            throw HTTPError(status: 400, code: "bad_request", message: "response_format is json, text, srt, vtt or verbose_json")
        }
        let audio = try open(req, form: form)
        try ready(stt: true)
        let segments = try await LongTranscriber().run(audio.reader, engine: engine)
        switch format {
        case "json":
            return JSON.response(["text": Captions.plain(segments)])
        case "verbose_json":
            return JSON.response([
                "task": "transcribe", "language": "", "duration": JSON.round(audio.reader.duration),
                "text": Captions.plain(segments),
                "segments": segments.enumerated().map { i, s in s.json.merging(["id": i]) { a, _ in a } },
            ])
        default:
            return captions(segments, duration: audio.reader.duration, format: format)
        }
    }

    /// The audio a request carries, opened: a raw PCM body (format=pcm), a multipart upload's
    /// file, or the body itself as a file. `keep` holds the file the reader reads.
    private func open(_ req: HTTPRequest, form: Multipart? = nil) throws -> (reader: AudioReader, keep: AnyObject?) {
        if req.query["format"]?.lowercased() == "pcm" {
            let rate = Double(req.query["rate"] ?? "") ?? Double(PCM.listenRate)
            let channels = Int(req.query["channels"] ?? "") ?? 1
            let samples = PCM.readPCM16(try req.body.data(), channels: channels)
            return (SampleReader(samples: samples, rate: rate), nil)
        }
        var file: TempFile
        var form = form
        if form == nil, let boundary = Multipart.boundary(req.header("content-type")) {
            form = try Multipart(try req.body.data(), boundary: boundary)
        }
        if let form {
            guard let part = form.part("file") ?? form.parts.first(where: { $0.filename != nil }), !part.data.isEmpty else {
                throw HTTPError(status: 400, code: "bad_request", message: "the upload has no file field")
            }
            file = try write(part.data)
        } else {
            switch req.body {
            case .empty:
                throw HTTPError(status: 400, code: "bad_request", message: "send the audio as the request's body")
            case .data(let d):
                file = try write(d)
            case .file(let spilled):
                file = try named(spilled)
            }
        }
        do {
            return (try engine.open(file.url), file)
        } catch {
            throw HTTPError(status: 415, code: "unsupported_audio", message: "couldn't read that as audio: \(describe(error))")
        }
    }

    /// Audio bytes into a file named for what they are, for the platform's reader.
    private func write(_ data: Data) throws -> TempFile {
        let ext = PCM.sniffExtension(data)
        let file = try TempFile.make(in: directory, suffix: ext.isEmpty ? "" : "." + ext)
        try data.write(to: file.url)
        file.size = data.count
        return file
    }

    /// A body that arrived in a file, renamed to end in what it is.
    private func named(_ spilled: TempFile) throws -> TempFile {
        let handle = try FileHandle(forReadingFrom: spilled.url)
        let head = handle.readData(ofLength: 16)
        try? handle.close()
        let ext = PCM.sniffExtension(head)
        guard !ext.isEmpty else { return spilled }
        let url = spilled.url.appendingPathExtension(ext)
        try FileManager.default.moveItem(at: spilled.url, to: url)
        return TempFile(url: url, size: spilled.size)
    }

    // MARK: Helpers

    private func need(_ e: Endpoint, _ s: ServiceSettings) throws {
        guard s.isOn(e) else {
            throw HTTPError(status: 503, code: "endpoint_off", message: "\(e.rawValue) is turned off in Super Voice")
        }
    }

    /// Gets the model going; a first download answers model_loading rather than keeping the
    /// caller waiting for minutes. Once it's on disk, callers just wait for it to load.
    private func ready(tts: Bool = false, stt: Bool = false) throws {
        engine.prepare(tts: tts, stt: stt)
        let state = tts ? engine.ttsState : engine.sttState
        if case .downloading(let progress) = state {
            let what = tts ? "the voices" : "speech recognition"
            throw HTTPError(status: 503, code: "model_loading",
                            message: "getting \(what) ready (downloading, the first time only)", progress: progress ?? 0)
        }
    }

    /// A body of text: JSON (when it looks like JSON), else the text itself.
    private func textFields(_ req: HTTPRequest) throws -> [String: Any] {
        let data = try req.body.data()
        let text = String(data: data, encoding: .utf8) ?? ""
        if req.contentType == "application/json" || text.drop(while: \.isWhitespace).hasPrefix("{") {
            guard let object = JSON.object(data) else {
                throw HTTPError(status: 400, code: "bad_request", message: "the body isn't valid JSON")
            }
            return object
        }
        return ["text": text]
    }

    private func textField(_ value: Any?) throws -> String {
        guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HTTPError(status: 400, code: "missing_text", message: "missing text")
        }
        guard text.count <= Self.maxText else {
            throw HTTPError(status: 413, code: "too_large", message: "text is over \(Self.maxText) characters")
        }
        return text
    }

    private func speedField(_ value: Any?, default fallback: Double) throws -> Double {
        let speed: Double
        switch value {
        case nil, is NSNull: return fallback
        case let n as NSNumber: speed = n.doubleValue
        case let s as String:
            guard let d = Double(s) else { throw HTTPError(status: 400, code: "bad_speed", message: "speed must be a number") }
            speed = d
        default: throw HTTPError(status: 400, code: "bad_speed", message: "speed must be a number")
        }
        guard (0.5...2.0).contains(speed) else {
            throw HTTPError(status: 400, code: "bad_speed", message: "speed must be between 0.5 and 2")
        }
        return speed
    }

    private func failure(_ e: HTTPError, openAI: Bool) -> HTTPResponse {
        var headers: [(String, String)] = []
        if e.code == "model_loading" { headers.append(("Retry-After", "5")) }
        if openAI {
            let type = e.status >= 500 ? "server_error" : "invalid_request_error"
            return JSON.response(["error": ["message": e.message, "type": type, "code": e.code]], status: e.status, headers: headers)
        }
        var body: [String: Any] = ["error": e.message, "code": e.code]
        if let p = e.progress { body["progress"] = JSON.round(p) }
        return JSON.response(body, status: e.status, headers: headers)
    }
}

/// Thrown by a ResponseWriter once the client has gone.
public struct WriterGone: Error {
    public init() {}
}

func describe(_ error: Error) -> String {
    if let e = error as? HTTPError { return e.message }
    if let e = error as? AudioError, case .unreadable(let m) = e { return m }
    let ns = error as NSError
    return ns.localizedDescription.isEmpty ? String(describing: error) : ns.localizedDescription
}
