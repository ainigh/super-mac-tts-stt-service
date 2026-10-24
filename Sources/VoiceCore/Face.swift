import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Super Face (github.com/ainigh/JUST-super-mac-tts-ONLY-service), the mouth and the face: a 3D
/// avatar on the desktop that says what it's given, with lip-sync, expressions and gestures. Super
/// Voice is the ears and the model; what it says goes through the face when the face is running
/// (its own Kokoro voice is kept for when it isn't). And because the face knows exactly what it
/// said and when, it's asked about each phrase heard: was that me?
public final class FaceClient {
    public static let defaultURL = "http://127.0.0.1:8769"
    /// What Super Voice's utterances are tagged with, so a stop stops only its own.
    public static let source = "supervoice"

    public let baseURL: URL

    public init(baseURL: String = FaceClient.defaultURL) {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = Self.defaultURL }
        if !s.lowercased().hasPrefix("http") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        self.baseURL = URL(string: s) ?? URL(string: Self.defaultURL)!
    }

    public enum Problem: Error, Equatable {
        /// Not running (or not answering).
        case unreachable
        /// Its voice is still downloading, the first time.
        case loading(Double)
        /// It answered with an error.
        case failed(String)
    }

    /// How it said it: all of it, or it was stopped first.
    public enum Outcome: Equatable {
        case said, stopped
    }

    // MARK: What's sent, and what comes back (pure, so they're tested)

    public static func speakBody(_ text: String, voice: String, speed: Double, who: String?) -> [String: Any] {
        var body: [String: Any] = ["text": text, "voice": voice, "speed": speed, "wait": true, "source": source]
        if let who, !who.isEmpty { body["who"] = who }
        return body
    }

    /// The answer to a speak that waited.
    public static func outcome(status: Int, _ data: Data) throws -> Outcome {
        let o = JSON.object(data) ?? [:]
        if status == 503, o["code"] as? String == "model_loading" {
            throw Problem.loading((o["progress"] as? Double) ?? 0)
        }
        guard (200..<300).contains(status) else {
            throw Problem.failed((o["error"] as? String) ?? "Super Face answered \(status)")
        }
        switch o["state"] as? String {
        case "done": return .said
        case "stopped": return .stopped
        case "failed": throw Problem.failed((o["error"] as? String) ?? "it couldn't say it")
        default: return .said
        }
    }

    /// The answer to "was that me?": nil when it can't tell (an answer that isn't one).
    public static func echo(_ data: Data) -> (echo: Bool, rest: String)? {
        guard let o = JSON.object(data), let echo = o["echo"] as? Bool else { return nil }
        return (echo, (o["rest"] as? String) ?? "")
    }

    // MARK: Calls

    /// Its health says it can speak: the avatar loaded and the voice ready. Answering isn't
    /// enough: a face whose avatar didn't load would take what's said and never say it.
    public static func ready(status: Int, _ data: Data) -> Bool {
        guard status == 200, let o = JSON.object(data), o["service"] as? String == "superface" else { return false }
        return o["ready"] as? Bool == true
    }

    /// Running, and ready to speak.
    public func isUp() async -> Bool {
        guard let (status, data) = try? await send("GET", "/api/health", timeout: 2) else { return false }
        return Self.ready(status: status, data)
    }

    /// Says `text` (the face shows itself) and returns once it's been said, or stopped.
    public func speak(_ text: String, voice: String, speed: Double, who: String? = nil) async throws -> Outcome {
        let (status, data) = try await send("POST", "/api/speak", Self.speakBody(text, voice: voice, speed: speed, who: who), timeout: 600)
        return try Self.outcome(status: status, data)
    }

    /// Stops what Super Voice asked it to say (not what other apps did).
    public func stop() async {
        _ = try? await send("POST", "/api/stop", ["source": Self.source], timeout: 2)
    }

    /// Was `heard` (a phrase `seconds` long, just heard) the face's own voice coming back? nil
    /// when the face can't be asked.
    public func echo(_ heard: String, seconds: Double) async -> (echo: Bool, rest: String)? {
        guard let (status, data) = try? await send("POST", "/api/echo", ["text": heard, "seconds": max(1, seconds)], timeout: 1.5),
              status == 200 else { return nil }
        return Self.echo(data)
    }

    private func send(_ method: String, _ path: String, _ body: [String: Any]? = nil, timeout: TimeInterval) async throws -> (Int, Data) {
        var req = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = JSON.data(body)
        }
        do {
            return try await withCheckedThrowingContinuation { (k: CheckedContinuation<(Int, Data), Error>) in
                URLSession.shared.dataTask(with: req) { data, response, error in
                    if let error { k.resume(throwing: error) } else {
                        k.resume(returning: ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()))
                    }
                }.resume()
            }
        } catch {
            throw Problem.unreachable
        }
    }
}
