import Foundation

/// The board: one note, in sections, each under a subtitle. Whatever's said to it (after "mouse")
/// or typed goes in the note: under its first word when that's a voice command ("note, buy milk"
/// → "Buy milk" under "note"), else under "search", as it was said. Everything is kept; a search
/// then also surfaces the note's sentences that match it, and "open" shows the note there.
public enum Board {
    /// Said alone, it opens or closes the panel; said first ("mouse, note buy milk"), it opens it
    /// and what follows is taken.
    public static let wakeWord = "mouse"
    /// What's said without a voice command first goes under this, and is searched with.
    public static let searchSubtitle = "search"
    public static let defaultCommands = ["note"]
    /// The library record that holds the note has this tag.
    public static let noteTag = "board"
    public static let noteTitle = "Board"

    public enum Option: String, CaseIterable, Sendable {
        case open, copy, no

        /// Other words that mean it.
        static let synonyms: [String: Option] = ["cancel": .no, "nope": .no, "undo": .no]
    }

    /// An utterance, read: the command it started with (none: a search), the subtitle it goes
    /// under, and the text that goes there.
    public struct Heard: Equatable, Sendable {
        public var command: String?
        public var subtitle: String
        public var text: String

        public init(command: String?, subtitle: String, text: String) {
            self.command = command
            self.subtitle = subtitle
            self.text = text
        }

        public var isSearch: Bool { command == nil }
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

    /// "Mouse, note buy milk." → "Note buy milk.": what follows the wake word said first (nil when
    /// it isn't first, or nothing follows).
    public static func afterWake(_ utterance: String) -> String? {
        guard let (first, rest) = firstWord(utterance), first == wakeWord, !rest.isEmpty else { return nil }
        return rest
    }

    /// An option said alone ("Open.", "copy", "no").
    public static func option(_ utterance: String) -> Option? {
        let w = words(utterance)
        guard w.count == 1 else { return nil }
        return Option(rawValue: w[0]) ?? Option.synonyms[w[0]]
    }

    /// Reads an utterance against the voice commands. "Search" said first is taken as a search of
    /// what follows.
    public static func parse(_ utterance: String, commands: [String]) -> Heard {
        let said = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (first, rest) = firstWord(said) else { return Heard(command: nil, subtitle: searchSubtitle, text: said) }
        if let command = commands.first(where: { sameWord($0, first) }) {
            return Heard(command: command, subtitle: command, text: rest)
        }
        if first == searchSubtitle { return Heard(command: nil, subtitle: searchSubtitle, text: rest) }
        return Heard(command: nil, subtitle: searchSubtitle, text: said)
    }

    /// The first word (lowercased, punctuation dropped), and the rest: the punctuation after the
    /// word goes, the sentence's own stays, and it starts with a capital.
    static func firstWord(_ utterance: String) -> (String, String)? {
        let said = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = said.range(of: #"^[\p{L}\p{N}'’-]+"#, options: .regularExpression) else { return nil }
        let lead = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.:;-–—!?"))
        var rest = String(String(said[first.upperBound...]).drop { $0.unicodeScalars.allSatisfy(lead.contains) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let c = rest.first, c.isLowercase { rest = c.uppercased() + rest.dropFirst() }
        return (words(String(said[first])).joined(), rest)
    }

    /// Short words that don't help find anything.
    static let stopWords: Set<String> = ["a", "an", "the", "and", "or", "of", "to", "in", "on", "at", "for", "is", "it",
                                         "i", "my", "me", "be", "was", "are", "this", "that", "with", "by", "as", "so"]

    /// The words of `query` worth searching with.
    public static func keywords(_ query: String) -> [String] {
        var seen = Set<String>()
        return words(query).filter { !stopWords.contains($0) && seen.insert($0).inserted }
    }

    /// "Buy milk. Call Sam!" → ["Buy milk.", "Call Sam!"]
    public static func sentences(_ line: String) -> [String] {
        var out: [String] = [], current = ""
        var chars = line.makeIterator()
        var next = chars.next()
        while let c = next {
            current.append(c)
            next = chars.next()
            if ".!?…".contains(c), next?.isWhitespace ?? true {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        out.append(current.trimmingCharacters(in: .whitespaces))
        return out.filter { !$0.isEmpty }
    }

    /// The board's note, as it's written: "## note" starts the section under "note"; each line
    /// under it is one thing said. Lines before any subtitle (edited in by hand) are kept as they are.
    public struct Note: Equatable, Sendable {
        public struct Section: Equatable, Sendable {
            public var subtitle: String
            public var lines: [String]

            public init(subtitle: String, lines: [String]) {
                self.subtitle = subtitle
                self.lines = lines
            }
        }

        /// A line's place: its section, and where it is in it.
        public struct Spot: Hashable, Sendable {
            public var section: Int
            public var line: Int

            public init(section: Int, line: Int) {
                self.section = section
                self.line = line
            }
        }

        public var sections: [Section]

        public init(sections: [Section] = []) {
            self.sections = sections
        }

        public init(text: String) {
            sections = []
            for raw in text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("## ") || line == "##" {
                    sections.append(Section(subtitle: line.dropFirst(2).trimmingCharacters(in: .whitespaces), lines: []))
                } else if !line.isEmpty {
                    if sections.isEmpty { sections.append(Section(subtitle: "", lines: [])) }
                    sections[sections.count - 1].lines.append(line)
                }
            }
        }

        public var text: String {
            sections.map { s in ((s.subtitle.isEmpty ? [] : ["## " + s.subtitle]) + s.lines).joined(separator: "\n") }
                .joined(separator: "\n\n")
        }

        public subscript(spot: Spot) -> String? {
            guard sections.indices.contains(spot.section), sections[spot.section].lines.indices.contains(spot.line) else { return nil }
            return sections[spot.section].lines[spot.line]
        }

        /// Adds `text` as a line at the end of the section under `subtitle` (a new section at the
        /// end when there's none yet), and says where it went.
        @discardableResult
        public mutating func append(_ text: String, under subtitle: String) -> Spot {
            var line = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            // It mustn't read back as a subtitle.
            while line.hasPrefix("#") { line = line.dropFirst().trimmingCharacters(in: .whitespaces) }
            if let i = sections.lastIndex(where: { !$0.subtitle.isEmpty && Board.sameWord($0.subtitle, subtitle) }) {
                sections[i].lines.append(line)
                return Spot(section: i, line: sections[i].lines.count - 1)
            }
            sections.append(Section(subtitle: subtitle, lines: [line]))
            return Spot(section: sections.count - 1, line: 0)
        }

        /// Takes a line out, if it's still there as `line` (a section left empty goes too).
        @discardableResult
        public mutating func remove(_ line: String, at spot: Spot) -> Bool {
            guard self[spot] == line else { return false }
            sections[spot.section].lines.remove(at: spot.line)
            if sections[spot.section].lines.isEmpty { sections.remove(at: spot.section) }
            return true
        }

        /// The lines under `subtitle` (all when nil), each as a hit on its whole line: section by
        /// section, the newest (last) line of each first.
        public func lines(under subtitle: String?) -> [Hit] {
            sections.enumerated().flatMap { s, section -> [Hit] in
                guard subtitle.map({ Board.sameWord($0, section.subtitle) }) ?? true else { return [] }
                return section.lines.indices.reversed().map { l in
                    Hit(spot: Spot(section: s, line: l), subtitle: section.subtitle, line: section.lines[l], sentence: section.lines[l])
                }
            }
        }

        /// The sentences that share words with `query`, best first: the most words in common, then
        /// the whole query appearing as it is, then the later in its section. `skipping`: a line
        /// left out (the search itself, just added). A sentence that only says the query again is
        /// left out too, and so is everything when the query has no words worth searching with.
        public func search(_ query: String, skipping: Spot? = nil) -> [Hit] {
            let keys = Board.keywords(query)
            guard !keys.isEmpty else { return [] }
            let said = Board.words(query)
            let phrase = said.joined(separator: " ")
            var scored: [(hit: Hit, score: Int, phrase: Bool)] = []
            for (s, section) in sections.enumerated() {
                for (l, line) in section.lines.enumerated() where Spot(section: s, line: l) != skipping {
                    for sentence in Board.sentences(line) {
                        let have = Board.words(sentence)
                        guard have != said else { continue }
                        let score = keys.filter { k in have.contains { $0.hasPrefix(k) || Board.sameWord($0, k) } }.count
                        guard score > 0 else { continue }
                        let hit = Hit(spot: Spot(section: s, line: l), subtitle: section.subtitle, line: line, sentence: sentence)
                        scored.append((hit, score, have.joined(separator: " ").contains(phrase)))
                    }
                }
            }
            return scored.sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                if a.phrase != b.phrase { return a.phrase }
                if a.hit.spot.line != b.hit.spot.line { return a.hit.spot.line > b.hit.spot.line }
                return a.hit.spot.section > b.hit.spot.section
            }.map(\.hit)
        }
    }

    /// A sentence found in the note: the line it's in, where that is, and its subtitle.
    public struct Hit: Equatable, Hashable, Sendable {
        public var spot: Note.Spot
        public var subtitle: String
        public var line: String
        public var sentence: String

        public init(spot: Note.Spot, subtitle: String, line: String, sentence: String) {
            self.spot = spot
            self.subtitle = subtitle
            self.line = line
            self.sentence = sentence
        }
    }

    /// What opening a line does.
    public enum Action: Equatable, Sendable {
        /// Calls it: "GET https://…" or "POST https://… {body}".
        case http(method: String, url: URL, body: String?)
        /// A link: opens in the browser.
        case browse(URL)
        /// Anything else: the note, shown there.
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
