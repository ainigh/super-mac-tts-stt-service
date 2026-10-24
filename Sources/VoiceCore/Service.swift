import Foundation

/// How a model is doing.
public enum ModelState: Equatable, Sendable {
    /// Loads on first use.
    case notLoaded
    /// The first time: downloading, how far when it's known (0 to 1).
    case downloading(Double?)
    case loading
    case ready
    case failed(String)

    public var name: String {
        switch self {
        case .notLoaded: return "not_loaded"
        case .downloading: return "downloading"
        case .loading: return "loading"
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }

    public var isReady: Bool { self == .ready }
}

/// What the recognizer heard in a piece of audio.
public struct Recognized: Sendable {
    public var text: String
    public var words: [TimedWord]

    public init(text: String, words: [TimedWord] = []) {
        self.text = text
        self.words = words
    }
}

/// The speech models, and the Mac's speakers: what the API needs from the platform.
public protocol SpeechEngine: AnyObject {
    var ttsState: ModelState { get }
    var sttState: ModelState { get }
    /// Starts getting a model (downloading it the first time), without waiting for it.
    func prepare(tts: Bool, stt: Bool)
    /// Reads `text` (a sentence or so) in `voice`: 24 kHz mono samples. Waits for the model.
    func speak(_ text: String, voice: Voice, speed: Double) async throws -> [Float]
    /// Writes down 16 kHz mono audio (up to a minute or so). Waits for the model.
    func write(_ samples: [Float]) async throws -> Recognized
    /// Opens an audio file of any format the platform reads.
    func open(_ url: URL) throws -> AudioReader
    /// Says `text` on this machine's speakers, after what's already queued: an id for it, and
    /// how many are queued (counting it).
    func say(_ text: String, voice: Voice, speed: Double) -> (id: String, queued: Int)
    /// Stops speaking and empties the queue: how many were dropped.
    func stopSaying() -> Int
}

/// The endpoint groups, each of which can be turned off.
public enum Endpoint: String, CaseIterable, Codable, Sendable {
    case tts, stt, transcribe, say, openai, model

    public var title: String {
        switch self {
        case .tts: return "Text to speech"
        case .stt: return "Speech to text"
        case .transcribe: return "Transcribe files"
        case .say: return "Speak on this Mac"
        case .openai: return "OpenAI-compatible"
        case .model: return "The model, for other apps"
        }
    }

    public var routes: String {
        switch self {
        case .tts: return "/api/tts"
        case .stt: return "/api/stt"
        case .transcribe: return "/api/transcribe"
        case .say: return "/api/say"
        case .openai: return "/v1/audio/*"
        case .model: return "/api/model/chat"
        }
    }
}

/// What the user has set that the API answers by.
public struct ServiceSettings: Equatable, Codable, Sendable {
    public var off: Set<Endpoint> = []
    public var voice: String = Voice.fallback.id
    public var speed: Double = 1
    /// Listen on every interface, not just this Mac (callers from elsewhere need the token).
    public var allowNetwork = false
    public var token = ""
    /// Browser origins allowed besides this machine's pages ("https://app.example.com", globs).
    public var origins: [String] = []
    public var port = ServiceSettings.defaultPort
    /// Super Face (the mouth and the face): where it is, and whether what's said goes through it.
    public var face = FaceClient.defaultURL
    public var speakThroughFace = true

    public static let defaultPort = 8767

    public init() {}

    // Settings saved before a field existed still load, taking its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ServiceSettings()
        off = try c.decodeIfPresent(Set<Endpoint>.self, forKey: .off) ?? d.off
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? d.voice
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? d.speed
        allowNetwork = try c.decodeIfPresent(Bool.self, forKey: .allowNetwork) ?? d.allowNetwork
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? d.token
        origins = try c.decodeIfPresent([String].self, forKey: .origins) ?? d.origins
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        face = try c.decodeIfPresent(String.self, forKey: .face) ?? d.face
        speakThroughFace = try c.decodeIfPresent(Bool.self, forKey: .speakThroughFace) ?? d.speakThroughFace
    }

    public func isOn(_ e: Endpoint) -> Bool { !off.contains(e) }

    public var defaultVoice: Voice { Voice.named(voice) }

    /// A fresh token for sharing on the network.
    public static func newToken() -> String {
        let chars = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<32).map { _ in chars.randomElement()! })
    }
}

public enum JSON {
    /// Two decimals: 2.8134 → 2.81.
    public static func round(_ x: Double) -> Double {
        (x * 100).rounded() / 100
    }

    public static func data(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    public static func response(_ object: Any, status: Int = 200, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/json", data: data(object), headers: headers)
    }

    /// One NDJSON line.
    public static func line(_ object: Any) -> Data {
        data(object) + Data("\n".utf8)
    }

    public static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
