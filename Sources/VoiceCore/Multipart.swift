import Foundation

/// multipart/form-data: what a browser's form or an OpenAI SDK uploads.
public struct Multipart {
    public struct Part {
        public var name: String
        public var filename: String?
        public var contentType: String?
        public var data: Data

        public var text: String { String(data: data, encoding: .utf8) ?? "" }
    }

    public var parts: [Part]

    public func part(_ name: String) -> Part? { parts.first { $0.name == name } }

    /// The text of a field, trimmed; nil when it isn't there or is blank.
    public func field(_ name: String) -> String? {
        guard let t = part(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// The boundary named in a Content-Type header, if it's multipart/form-data.
    public static func boundary(_ contentType: String?) -> String? {
        guard let contentType, contentType.lowercased().hasPrefix("multipart/form-data") else { return nil }
        for param in contentType.split(separator: ";").dropFirst() {
            let kv = param.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "boundary" else { continue }
            return kv[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    public init(parts: [Part]) {
        self.parts = parts
    }

    /// Splits a body at `boundary`. Throws when it isn't multipart at all.
    public init(_ body: Data, boundary: String) throws {
        let delimiter = Data("--\(boundary)".utf8)
        let crlf = Data("\r\n".utf8)
        let blank = Data("\r\n\r\n".utf8)
        var parts: [Part] = []
        guard var cursor = body.range(of: delimiter)?.upperBound else {
            throw HTTPError(status: 400, code: "bad_request", message: "the multipart body has no parts")
        }
        while cursor < body.endIndex {
            // "--" after a delimiter ends the body.
            if body[cursor...].starts(with: Data("--".utf8)) { break }
            guard let headStart = body.range(of: crlf, in: cursor..<body.endIndex)?.upperBound,
                  let headEnd = body.range(of: blank, in: (headStart - 2)..<body.endIndex) else { break }
            let head = String(data: body[headStart..<max(headStart, headEnd.lowerBound)], encoding: .utf8) ?? ""
            guard let next = body.range(of: crlf + delimiter, in: headEnd.upperBound..<body.endIndex) else { break }
            var part = Part(name: "", filename: nil, contentType: nil, data: Data(body[headEnd.upperBound..<next.lowerBound]))
            for line in head.components(separatedBy: "\r\n") {
                let lower = line.lowercased()
                if lower.hasPrefix("content-disposition:") {
                    part.name = Self.param("name", in: line) ?? ""
                    part.filename = Self.param("filename", in: line)
                } else if lower.hasPrefix("content-type:") {
                    part.contentType = line.dropFirst("content-type:".count).trimmingCharacters(in: .whitespaces)
                }
            }
            parts.append(part)
            cursor = next.upperBound
        }
        self.parts = parts
    }

    /// name="file" from a Content-Disposition line.
    static func param(_ key: String, in line: String) -> String? {
        for piece in line.split(separator: ";") {
            let kv = piece.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == key else { continue }
            return kv[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    /// A body to send (for tests and clients).
    public static func encode(_ parts: [Part], boundary: String) -> Data {
        var out = Data()
        for p in parts {
            out.append(Data("--\(boundary)\r\n".utf8))
            var disposition = "Content-Disposition: form-data; name=\"\(p.name)\""
            if let f = p.filename { disposition += "; filename=\"\(f)\"" }
            out.append(Data((disposition + "\r\n").utf8))
            if let t = p.contentType { out.append(Data("Content-Type: \(t)\r\n".utf8)) }
            out.append(Data("\r\n".utf8))
            out.append(p.data)
            out.append(Data("\r\n".utf8))
        }
        out.append(Data("--\(boundary)--\r\n".utf8))
        return out
    }
}
