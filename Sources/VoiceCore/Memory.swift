import Foundation

/// What Tom has learned: a few short notes, in three sections, read into his prompt at the start
/// of every turn and written by him with `remember` and `forget` as jobs finish. Plain text,
/// bounded (so he prunes rather than piles up), shown to the user, and theirs to edit. It also
/// holds the standing instructions for each assistant (the user's additions to the system prompts).
public struct Memory: Codable, Equatable, Sendable {
    /// One section of notes.
    public struct Section: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        /// What goes in it, as Tom is told.
        public var about: String
        public var notes: [String]

        public init(id: String, title: String, about: String, notes: [String] = []) {
            self.id = id
            self.title = title
            self.about = about
            self.notes = notes
        }
    }

    public var sections: [Section]
    /// Standing instructions for Tom, the user's own words, after his system prompt.
    public var tomInstructions = ""
    /// Standing instructions for Jerry.
    public var jerryInstructions = ""

    /// Notes in all, at most: at the cap, Tom must forget before he remembers.
    public static let maxNotes = 60
    /// A note longer than this is cut (they're read into every prompt).
    public static let maxNoteLength = 200

    public static let userPrefs = "user_prefs"
    public static let playbook = "jerry_playbook"
    public static let failures = "failures"

    public init() {
        sections = [
            Section(id: Self.userPrefs, title: "User preferences", about: "what the user likes, uses and wants (services, limits, habits, how they like things done)"),
            Section(id: Self.playbook, title: "Jerry playbook", about: "what Jerry tends to misread, what phrasing in a spec works, what to put in done_criteria"),
            Section(id: Self.failures, title: "Failures", about: "jobs that went wrong and why, so the same spec mistake isn't made twice"),
        ]
    }

    public var isEmpty: Bool { sections.allSatisfy(\.notes.isEmpty) && tomInstructions.isEmpty && jerryInstructions.isEmpty }
    public var noteCount: Int { sections.reduce(0) { $0 + $1.notes.count } }

    /// The section a name means: its id, its title, or a near miss ("preferences", "playbook",
    /// "mistakes"); nil for anything else.
    public func section(named name: String) -> Int? {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        if let i = sections.firstIndex(where: { $0.id == n || $0.title.lowercased().replacingOccurrences(of: " ", with: "_") == n }) { return i }
        let aliases: [String: String] = [
            "prefs": Self.userPrefs, "preferences": Self.userPrefs, "user": Self.userPrefs, "user_preferences": Self.userPrefs, "preference": Self.userPrefs,
            "playbook": Self.playbook, "jerry": Self.playbook, "jerry_notes": Self.playbook, "worker": Self.playbook,
            "failure": Self.failures, "mistakes": Self.failures, "mistake": Self.failures, "errors": Self.failures, "lessons": Self.failures,
        ]
        guard let id = aliases[n] else { return nil }
        return sections.firstIndex { $0.id == id }
    }

    /// Adds a note to a section: what Tom is told.
    public mutating func remember(section name: String, note: String) -> String {
        guard let i = section(named: name) else { return "No section called \(name). The sections are: \(sections.map(\.id).joined(separator: ", "))." }
        var line = note.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !line.isEmpty else { return "Give the note to remember." }
        if line.count > Self.maxNoteLength { line = String(line.prefix(Self.maxNoteLength - 1)) + "…" }
        if sections[i].notes.contains(where: { $0.caseInsensitiveCompare(line) == .orderedSame }) { return "Already noted in \(sections[i].id)." }
        guard noteCount < Self.maxNotes else { return "Your memory is full (\(Self.maxNotes) notes). Forget something first, then remember this." }
        sections[i].notes.append(line)
        return "Noted in \(sections[i].id) (\(noteCount) of \(Self.maxNotes) notes)."
    }

    /// Takes a note out of a section (the one that says `note`, or has it in it): what Tom is told.
    public mutating func forget(section name: String, note: String) -> String {
        guard let i = section(named: name) else { return "No section called \(name). The sections are: \(sections.map(\.id).joined(separator: ", "))." }
        let key = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return "Say which note to forget (its words, or enough of them)." }
        if let j = sections[i].notes.firstIndex(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
            sections[i].notes.remove(at: j)
            return "Forgotten."
        }
        let matching = sections[i].notes.indices.filter { sections[i].notes[$0].range(of: key, options: .caseInsensitive) != nil }
        guard matching.count == 1, let j = matching.first else {
            return matching.isEmpty ? "No note in \(sections[i].id) says that." : "More than one note in \(sections[i].id) has those words; give more of the one to forget."
        }
        sections[i].notes.remove(at: j)
        return "Forgotten."
    }

    /// The notes as Tom reads them at the start of every turn.
    public func prompt() -> String {
        var p = "\n\nYour memory (what you've learned so far; \(noteCount) of \(Self.maxNotes) notes). Read it before you act; add to it with remember when a job teaches you something about the user or about how to brief Jerry, and prune it with forget when a note is wrong or stale."
        for s in sections {
            p += "\n\(s.id) (\(s.about)):"
            p += s.notes.isEmpty ? " (empty)" : "\n" + s.notes.map { "- " + $0 }.joined(separator: "\n")
        }
        return p
    }

    /// The notes as plain text, for the window, and to copy.
    public var text: String {
        sections.map { s in
            "# \(s.title)\n" + (s.notes.isEmpty ? "(nothing yet)" : s.notes.map { "- " + $0 }.joined(separator: "\n"))
        }.joined(separator: "\n\n")
    }

    /// The tools Tom keeps his memory with.
    public static let tools: [AssistantTools.Tool] = [
        AssistantTools.Tool(name: "remember", description: "Adds a line to your memory, which you read at the start of every turn and which the user can see and edit. Use it after a job for what you learned: a preference of the user's (user_prefs), how to brief Jerry so it goes right (jerry_playbook), or what went wrong and why (failures). One short line; nothing you already have.",
                            arguments: [("section", "string: user_prefs, jerry_playbook or failures"), ("note", "string: the line, short")]),
        AssistantTools.Tool(name: "forget", description: "Takes a line out of your memory, when it's wrong, stale, or the memory is full.",
                            arguments: [("section", "string: user_prefs, jerry_playbook or failures"), ("note", "string: the line, or enough of it to tell it apart")]),
    ]

    static let aliases: [String: String] = [
        "memorize": "remember", "memorise": "remember", "add_memory": "remember", "save_memory": "remember", "remember_note": "remember",
        "note_to_self": "remember", "learn": "remember", "write_memory": "remember", "update_memory": "remember",
        "remove_memory": "forget", "delete_memory": "forget", "forget_note": "forget", "unlearn": "forget",
    ]

    /// Runs a memory tool on `memory`: what Tom is told; nil when it isn't one.
    public static func run(_ name: String, _ arguments: [String: Any], on memory: inout Memory) -> String? {
        let section = ToolRunTools.string(arguments["section"] ?? arguments["category"] ?? arguments["kind"]) ?? Memory.userPrefs
        let note = ToolRunTools.string(arguments["note"] ?? arguments["text"] ?? arguments["line"] ?? arguments["content"]) ?? ""
        switch name {
        case "remember": return memory.remember(section: section, note: note)
        case "forget": return memory.forget(section: section, note: note)
        default: return nil
        }
    }
}

/// Tom's memory on disk: one JSON file.
public final class MemoryStore {
    public let url: URL
    public private(set) var memory: Memory

    public init(url: URL) {
        self.url = url
        memory = (try? Data(contentsOf: url)).flatMap { try? LibraryStore.decoder.decode(Memory.self, from: $0) } ?? Memory()
    }

    public func save(_ memory: Memory) throws {
        self.memory = memory
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LibraryStore.encoder.encode(memory).write(to: url, options: .atomic)
    }
}
