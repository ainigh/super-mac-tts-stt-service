import Foundation

/// A request's body: nothing, in memory, or (when it's big) in a file of its own, deleted when the
/// last copy of the body goes.
public enum HTTPBody {
    case empty
    case data(Data)
    case file(TempFile)

    /// The bytes. A file is mapped, not read in.
    public func data() throws -> Data {
        switch self {
        case .empty: return Data()
        case .data(let d): return d
        case .file(let f): return try Data(contentsOf: f.url, options: .alwaysMapped)
        }
    }

    public var count: Int {
        switch self {
        case .empty: return 0
        case .data(let d): return d.count
        case .file(let f): return f.size
        }
    }
}

/// A file that's removed when this goes away.
public final class TempFile {
    public let url: URL
    public internal(set) var size: Int

    public init(url: URL, size: Int = 0) {
        self.url = url
        self.size = size
    }

    /// A new, empty file in `directory`.
    public static func make(in directory: URL = FileManager.default.temporaryDirectory, suffix: String = "") throws -> TempFile {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("supervoice-\(UUID().uuidString)\(suffix)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw HTTPError(status: 500, code: "failed", message: "couldn't make a temporary file")
        }
        return TempFile(url: url)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

public struct HTTPRequest {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names lowercased; repeated headers joined with ", ".
    public var headers: [String: String]
    public var body: HTTPBody
    /// The caller is on this machine.
    public var fromLoopback: Bool

    public init(method: String, target: String, headers: [String: String] = [:], body: HTTPBody = .empty,
                fromLoopback: Bool = true) {
        self.method = method.uppercased()
        var lowered: [String: String] = [:]
        for (k, v) in headers { lowered[k.lowercased()] = v }
        self.headers = lowered
        self.body = body
        self.fromLoopback = fromLoopback
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = parts.first.map(String.init) ?? "/"
        path = rawPath.removingPercentEncoding ?? rawPath
        query = parts.count > 1 ? Self.form(String(parts[1])) : [:]
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// The media type, lowercased, without parameters ("application/json").
    public var contentType: String {
        (header("content-type") ?? "").split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? ""
    }

    /// a=1&b=two%20words → ["a": "1", "b": "two words"]
    public static func form(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let decode = { (x: Substring) in String(x).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(x) }
            guard let k = kv.first else { continue }
            out[decode(k)] = kv.count > 1 ? decode(kv[1]) : ""
        }
        return out
    }
}

public struct HTTPError: Error, Equatable {
    public var status: Int
    public var code: String
    public var message: String
    /// model_loading: how far the download has got (0 to 1).
    public var progress: Double?
    /// 405: the method the route takes.
    public var allow: String?

    public init(status: Int, code: String, message: String, progress: Double? = nil, allow: String? = nil) {
        self.status = status
        self.code = code
        self.message = message
        self.progress = progress
        self.allow = allow
    }
}

/// Where a body goes while it arrives: memory, then a file once it's past `memoryLimit`.
final class BodySink {
    private let memoryLimit: Int
    private let directory: URL
    private var memory = Data()
    private var file: TempFile?
    private var handle: FileHandle?
    private(set) var count = 0

    init(memoryLimit: Int, directory: URL) {
        self.memoryLimit = memoryLimit
        self.directory = directory
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        count += data.count
        if handle == nil, memory.count + data.count <= memoryLimit {
            memory.append(data)
            return
        }
        if handle == nil {
            let f = try TempFile.make(in: directory)
            handle = try FileHandle(forWritingTo: f.url)
            file = f
            try handle?.write(contentsOf: memory)
            memory = Data()
        }
        try handle?.write(contentsOf: data)
    }

    func finish() throws -> HTTPBody {
        if let handle, let file {
            try handle.close()
            file.size = count
            return .file(file)
        }
        return memory.isEmpty ? .empty : .data(memory)
    }
}

/// Reads one HTTP/1.1 request from bytes as they arrive.
public struct HTTPParser {
    public enum Outcome {
        /// More bytes are needed. `sendContinue`: the client asked to hear "100 Continue" before
        /// sending its body; say it once now.
        case more(sendContinue: Bool)
        case done(HTTPRequest)
    }

    public var maxHead = 64 * 1024
    public var maxBody = 2 * 1024 * 1024 * 1024
    public var memoryLimit = 16 * 1024 * 1024
    public var directory = FileManager.default.temporaryDirectory
    public var fromLoopback = true

    private enum Stage {
        case head
        case sized(remaining: Int)
        case chunkSize
        case chunkData(remaining: Int)
        case chunkEnd
        case trailers
        case done
    }

    private var stage = Stage.head
    private var buffer = Data()
    private var method = ""
    private var target = ""
    private var headers: [String: String] = [:]
    private var sink: BodySink?

    public init() {}

    public mutating func feed(_ data: Data) throws -> Outcome {
        buffer.append(data)
        var sendContinue = false
        if case .head = stage {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > maxHead { throw HTTPError(status: 431, code: "bad_request", message: "headers too large") }
                return .more(sendContinue: false)
            }
            try parseHead(Data(buffer[buffer.startIndex..<end.lowerBound]))
            buffer = Data(buffer[end.upperBound...])
            sink = BodySink(memoryLimit: memoryLimit, directory: directory)
            if (headers["transfer-encoding"] ?? "").lowercased().contains("chunked") {
                stage = .chunkSize
            } else if let length = headers["content-length"] {
                guard let n = Int(length.trimmingCharacters(in: .whitespaces)), n >= 0 else {
                    throw HTTPError(status: 400, code: "bad_request", message: "bad Content-Length")
                }
                guard n <= maxBody else { throw HTTPError(status: 413, code: "too_large", message: "the body is over 2 GB") }
                stage = .sized(remaining: n)
            } else {
                stage = .sized(remaining: 0)
            }
            sendContinue = (headers["expect"] ?? "").lowercased() == "100-continue"
        }
        try advance()
        if case .done = stage {
            let request = HTTPRequest(method: method, target: target, headers: headers,
                                      body: try sink?.finish() ?? .empty, fromLoopback: fromLoopback)
            sink = nil              // the body's file belongs to the request now
            return .done(request)
        }
        return .more(sendContinue: sendContinue)
    }

    private mutating func parseHead(_ head: Data) throws {
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else {
            throw HTTPError(status: 400, code: "bad_request", message: "unreadable request")
        }
        var lines = text.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { throw HTTPError(status: 400, code: "bad_request", message: "bad request line") }
        method = String(start[0]).uppercased()
        target = String(start[1])
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
    }

    private mutating func advance() throws {
        guard let sink else { return }
        while true {
            switch stage {
            case .head, .done:
                return
            case .sized(let remaining):
                let take = min(remaining, buffer.count)
                if take > 0 {
                    try sink.write(Data(buffer.prefix(take)))
                    buffer = Data(buffer.dropFirst(take))
                }
                if remaining - take == 0 {
                    stage = .done
                } else {
                    stage = .sized(remaining: remaining - take)
                    return
                }
            case .chunkSize:
                guard let line = takeLine() else { return }
                let hex = line.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard let size = Int(hex, radix: 16), size >= 0 else {
                    throw HTTPError(status: 400, code: "bad_request", message: "bad chunk")
                }
                guard sink.count + size <= maxBody else {
                    throw HTTPError(status: 413, code: "too_large", message: "the body is over 2 GB")
                }
                stage = size == 0 ? .trailers : .chunkData(remaining: size)
            case .chunkData(let remaining):
                let take = min(remaining, buffer.count)
                if take > 0 {
                    try sink.write(Data(buffer.prefix(take)))
                    buffer = Data(buffer.dropFirst(take))
                }
                if remaining - take == 0 {
                    stage = .chunkEnd
                } else {
                    stage = .chunkData(remaining: remaining - take)
                    return
                }
            case .chunkEnd:
                guard takeLine() != nil else { return }
                stage = .chunkSize
            case .trailers:
                guard let line = takeLine() else { return }
                if line.isEmpty { stage = .done }
            }
        }
    }

    /// The next line (without its CRLF), if a whole one has arrived.
    private mutating func takeLine() -> String? {
        guard let end = buffer.range(of: Data("\r\n".utf8)) else { return nil }
        let line = String(data: Data(buffer[buffer.startIndex..<end.lowerBound]), encoding: .utf8) ?? ""
        buffer = Data(buffer[end.upperBound...])
        return line
    }
}

/// Where a streamed response's bytes go. `write` throws once the client has gone, which ends the
/// work making them.
public protocol ResponseWriter: AnyObject {
    func write(_ data: Data) async throws
}

public struct HTTPResponse {
    public enum Body {
        case data(Data)
        /// Sent as it's made (chunked).
        case stream((ResponseWriter) async throws -> Void)
    }

    public var status: Int
    public var headers: [(String, String)]
    public var body: Body

    public init(status: Int = 200, headers: [(String, String)] = [], body: Body = .data(Data())) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public init(status: Int = 200, contentType: String, data: Data, headers: [(String, String)] = []) {
        self.init(status: status, headers: [("Content-Type", contentType)] + headers, body: .data(data))
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }

    public var bodyData: Data? {
        if case .data(let d) = body { return d }
        return nil
    }

    /// The status line and headers (with Content-Length, or chunked for a stream). Every response
    /// closes the connection after it.
    public func head() -> Data {
        var lines = ["HTTP/1.1 \(status) \(Self.reason(status))"]
        for (k, v) in headers { lines.append("\(k): \(v)") }
        switch body {
        case .data(let d): lines.append("Content-Length: \(d.count)")
        case .stream: lines.append("Transfer-Encoding: chunked")
        }
        lines.append("Connection: close")
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// One piece of a chunked body.
    public static func chunk(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        return Data((String(data.count, radix: 16) + "\r\n").utf8) + data + Data("\r\n".utf8)
    }

    public static let lastChunk = Data("0\r\n\r\n".utf8)

    public static let continueLine = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)

    static func reason(_ status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}
