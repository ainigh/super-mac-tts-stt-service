import Foundation

/// The board: what's said while always listening (or typed) becomes a pending entry, filed under
/// a voice command when its first word is one ("notes buy milk" → "notes": "buy milk"), else under
/// "note". Earlier entries are searched with it, and it waits for one of the options: add it, open
/// the best match, drop it, or copy the best match.
public enum Board {
    /// Said alone, it opens or closes the panel.
    public static let wakeWord = "mouse"
    /// What an entry is filed under when it doesn't start with a command.
    public static let defaultTag = "note"
    public static let defaultCommands = ["notes"]

    public enum Option: String, CaseIterable, Sendable {
        case add, open, no, copy

        /// Other words that mean it.
        static let synonyms: [String: Option] = ["cancel": .no, "nope": .no, "save": .add]
    }

    /// An utterance, read: the command it started with (if any), what it's filed under, and the rest.
    public struct Heard: Equatable, Sendable {
        public var command: String?
        public var tag: String
        public var text: String

        public init(command: String?, tag: String, text: String) {
            self.command = command
            self.tag = tag
            self.text = text
        }
    }

    /// "Notes, buy milk." → ["notes", "buy", "milk"]: lowercased, punctuation dropped.
    public static func words(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// The same word, or its plural: "note" and "notes".
    public static func sameWord(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        return x == y || x + "s" == y || y + "s" == x || x + "es" == y || y + "es" == x
    }

    /// "Mouse." said alone.
    public static func isWake(_ utterance: String) -> Bool {
        words(utterance) == [wakeWord]
    }

    /// An option said alone ("Add.", "copy", "no").
    public static func option(_ utterance: String) -> Option? {
        let w = words(utterance)
        guard w.count == 1 else { return nil }
        return Option(rawValue: w[0]) ?? Option.synonyms[w[0]]
    }

    /// Reads an utterance against the voice commands.
    public static func parse(_ utterance: String, commands: [String]) -> Heard {
        let said = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        // The first word, as it's written, and where it ends.
        guard let first = said.range(of: #"^[\p{L}\p{N}'’-]+"#, options: .regularExpression),
              let command = commands.first(where: { sameWord($0, words(String(said[first])).joined()) }) else {
            return Heard(command: nil, tag: defaultTag, text: said)
        }
        var rest = String(said[first.upperBound...])
        // The punctuation after the command goes; the sentence's own stays.
        let lead = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.:;-–—!?"))
        rest = String(rest.drop { $0.unicodeScalars.allSatisfy(lead.contains) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let c = rest.first, c.isLowercase { rest = c.uppercased() + rest.dropFirst() }
        return Heard(command: command, tag: command, text: rest)
    }

    /// Short words that don't help find anything.
    static let stopWords: Set<String> = ["a", "an", "the", "and", "or", "of", "to", "in", "on", "at", "for", "is", "it",
                                         "i", "my", "me", "be", "was", "are", "this", "that", "with", "by", "as", "so"]

    /// The words of `query` worth searching with.
    public static func keywords(_ query: String) -> [String] {
        var seen = Set<String>()
        return words(query).filter { !stopWords.contains($0) && seen.insert($0).inserted }
    }

    /// `records` filed under `tag` (any, when nil) that share words with `query`, best first (the
    /// most words in common, then the whole query appearing as it is, then the newest). With no
    /// words to search with, all of them, newest first.
    public static func rank(_ records: [LibraryRecord], query: String, tag: String?) -> [LibraryRecord] {
        let pool = records.filter { r in
            guard let t = r.tag else { return false }
            return tag.map { sameWord($0, t) } ?? true
        }
        let keys = keywords(query)
        guard !keys.isEmpty else { return pool.sorted { $0.created > $1.created } }
        let phrase = words(query).joined(separator: " ")
        let scored: [(LibraryRecord, Int, Bool)] = pool.compactMap { r in
            let have = words(r.title + " " + r.text)
            let score = keys.filter { k in have.contains { $0.hasPrefix(k) || sameWord($0, k) } }.count
            guard score > 0 else { return nil }
            return (r, score, words(r.text).joined(separator: " ").contains(phrase))
        }
        return scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if a.2 != b.2 { return a.2 }
            return a.0.created > b.0.created
        }.map(\.0)
    }

    /// What opening an entry does.
    public enum Action: Equatable, Sendable {
        /// Calls it: "GET https://…" or "POST https://… {body}".
        case http(method: String, url: URL, body: String?)
        /// A link: opens in the browser.
        case browse(URL)
        /// Anything else: shown in full.
        case show
    }

    public static func action(for text: String) -> Action {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = t.split(maxSplits: 2, whereSeparator: \.isWhitespace).map(String.init)
        if parts.count >= 2, ["GET", "POST"].contains(parts[0].uppercased()), let url = webURL(parts[1]) {
            let body = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines) : nil
            return .http(method: parts[0].uppercased(), url: url, body: body?.isEmpty == false ? body : nil)
        }
        if parts.count == 1, let url = webURL(parts[0]) { return .browse(url) }
        return .show
    }

    /// http(s) links, and "example.com/…" taken as https.
    static func webURL(_ s: String) -> URL? {
        let lower = s.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: s), url.host?.isEmpty == false else { return nil }
            return url
        }
        // A bare domain: letters, a dot, letters (www.example.com, example.com/path).
        guard s.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}(/\S*)?$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "https://" + s)
    }
}
