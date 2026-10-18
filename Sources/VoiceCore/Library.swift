import Foundation

/// Something written down and kept: a dictation, a file's transcript, or text kept from Read aloud.
public struct LibraryRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case dictation, transcript, note

        public var title: String {
            switch self {
            case .dictation: return "Dictation"
            case .transcript: return "Transcript"
            case .note: return "Note"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    public var title: String
    public var text: String
    public var created: Date
    public var modified: Date
    /// Seconds of audio it came from.
    public var duration: Double?
    /// The audio file's name (transcripts).
    public var source: String?
    /// Timed lines (transcripts), for subtitles.
    public var segments: [TimedText]?
    public var starred: Bool

    public init(kind: Kind, text: String, title: String? = nil, created: Date = Date(), duration: Double? = nil,
                source: String? = nil, segments: [TimedText]? = nil) {
        id = UUID()
        self.kind = kind
        self.text = text
        self.title = title ?? Self.title(for: text)
        self.created = created
        modified = created
        self.duration = duration
        self.source = source
        self.segments = segments
        starred = false
    }

    /// A title from the text's first words: "Remind me to call Sam at four…".
    public static func title(for text: String, words: Int = 7) -> String {
        let all = text.split(whereSeparator: \.isWhitespace)
        guard !all.isEmpty else { return "Untitled" }
        let first = all.prefix(words).joined(separator: " ")
        let trimmed = first.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
        return all.count > words ? trimmed + "…" : trimmed
    }

    public var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }

    /// Matches every word of `query` in its title, text or source (case and accents ignored).
    public func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let hay = [title, text, source ?? ""].joined(separator: "\n")
        return words.allSatisfy { hay.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

/// The library on disk: one JSON file per item in a folder, so one bad file never loses the rest.
public final class LibraryStore {
    public let folder: URL
    public private(set) var items: [LibraryRecord] = []

    public init(folder: URL) {
        self.folder = folder
        load()
    }

    /// Reads every item, newest first.
    public func load() {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = Self.decoder
        items = files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(LibraryRecord.self, from: Data(contentsOf: $0)) }
        sort()
    }

    /// Adds or replaces an item (by id) and writes it.
    public func save(_ item: LibraryRecord) throws {
        let data = try Self.encoder.encode(item)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: url(item.id), options: .atomic)
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.append(item) }
        sort()
    }

    public func delete(_ id: UUID) throws {
        let u = url(id)
        if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
        items.removeAll { $0.id == id }
    }

    public func item(_ id: UUID) -> LibraryRecord? { items.first { $0.id == id } }

    /// The items of `kind` (all when nil) matching `query`, starred first when asked, newest first.
    public func filter(kind: LibraryRecord.Kind? = nil, query: String = "", starredOnly: Bool = false) -> [LibraryRecord] {
        items.filter { (kind == nil || $0.kind == kind) && (!starredOnly || $0.starred) && $0.matches(query) }
    }

    private func url(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).json") }

    private func sort() { items.sort { $0.created > $1.created } }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
