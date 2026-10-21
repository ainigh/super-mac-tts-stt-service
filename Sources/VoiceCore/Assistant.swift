import Foundation

/// The assistant, Micky: a conversation with Ollama by voice. Said alone, a wake word ("micky",
/// "ollama") wakes it; said first, what follows is the first question. Awake, everything said goes
/// to the model and the answer is read back. A few words are commands instead ("stop", "new chat",
/// "goodbye"). The platform does the listening and speaking; this is what's said, and what's sent.
public enum Assistant {
    public static let name = "Micky"

    /// What wakes it, as the recognizer tends to write each (any of these, alone or first).
    public static let wakeWords: [[String]] = [["micky"], ["mickey"], ["mikey"], ["nicky"], ["vicky"],
                                               ["ollama"], ["o", "llama"], ["oh", "llama"], ["olama"], ["llama"], ["alama"]]
    /// "Hey micky", "okay ollama": these may come before the wake word.
    static let greetings: Set<String> = ["hey", "hi", "hello", "ok", "okay", "yo"]

    public enum Command: Equatable, Sendable {
        /// Stops reading the answer.
        case stop
        /// Forgets this conversation and starts another.
        case newChat
        /// Turns the assistant off.
        case off
    }

    static let commands: [([String], Command)] = [
        (["stop"], .stop), (["stop", "talking"], .stop), (["stop", "reading"], .stop), (["be", "quiet"], .stop),
        (["quiet"], .stop), (["shut", "up"], .stop), (["enough"], .stop), (["never", "mind"], .stop),
        (["new", "chat"], .newChat), (["new", "conversation"], .newChat), (["start", "over"], .newChat),
        (["start", "a", "new", "chat"], .newChat), (["forget", "that"], .newChat),
        (["goodbye"], .off), (["bye"], .off), (["that", "s", "all"], .off), (["that", "s", "it"], .off),
        (["go", "to", "sleep"], .off), (["turn", "off"], .off), (["stop", "listening"], .off), (["thanks", "bye"], .off),
        (["thank", "you", "bye"], .off),
    ]

    /// What an utterance is.
    public enum Heard: Equatable, Sendable {
        /// The wake word, alone.
        case wake
        /// The wake word first, then this.
        case wakeThen(String)
        /// A command (with or without the wake word first).
        case command(Command)
        /// Anything else, as it was said.
        case speech(String)
    }

    /// Reads an utterance. `awake`: without it, only the wake word and what follows it count, and
    /// anything else is `speech` for the caller to ignore.
    public static func hear(_ utterance: String, awake: Bool) -> Heard {
        let tokens = Self.tokens(utterance)
        var start = 0
        if tokens.count > 1, greetings.contains(tokens[0].word) { start = 1 }
        var woke = false
        if let n = wakeLength(tokens.map(\.word), from: start) {
            woke = true
            start += n
        } else {
            start = 0
        }
        let words = tokens[start...].map(\.word)
        if woke, words.isEmpty { return .wake }
        if woke || awake, let (_, command) = commands.first(where: { $0.0 == words }) { return .command(command) }
        let rest = woke ? text(utterance, from: tokens[start].range.lowerBound) : utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        return woke ? .wakeThen(rest) : .speech(rest)
    }

    /// How many words of a wake word start at `from`; nil when none does.
    static func wakeLength(_ words: [String], from: Int) -> Int? {
        for wake in wakeWords where words.count >= from + wake.count && Array(words[from..<from + wake.count]) == wake {
            return wake.count
        }
        return nil
    }

    struct Token {
        var word: String
        var range: Range<String.Index>
    }

    /// The words, lowercased, with where each is.
    static func tokens(_ s: String) -> [Token] {
        var out: [Token] = []
        var searchFrom = s.startIndex
        while let r = s.range(of: #"[\p{L}\p{N}]+"#, options: .regularExpression, range: searchFrom..<s.endIndex) {
            out.append(Token(word: s[r].lowercased(), range: r))
            searchFrom = r.upperBound
        }
        return out
    }

    /// The text from `index` on, trimmed, starting with a capital.
    static func text(_ s: String, from index: String.Index) -> String {
        var rest = String(s[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let c = rest.first, c.isLowercase { rest = c.uppercased() + rest.dropFirst() }
        return rest
    }

    // MARK: Reading an answer aloud

    /// An answer as it's read: markdown taken out (emphasis, headings, bullets, links, code), so
    /// the voice doesn't say "asterisk".
    public static func spoken(_ markdown: String) -> String {
        var text = markdown
        // Code blocks aren't read.
        text = text.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " (some code, left out) ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            line = line.replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^>\s?"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^[-*+•]\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^(\d+)[.)]\s+"#, with: "$1. ", options: .regularExpression)
            if line.range(of: #"^[-*_]{3,}$"#, options: .regularExpression) != nil { line = "" }
            if line.range(of: #"^\|.*\|$"#, options: .regularExpression) != nil {
                line = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
                if line.range(of: #"^[-:, ]*$"#, options: .regularExpression) != nil { line = "" }
            }
            lines.append(line)
        }
        text = lines.joined(separator: "\n")
        text = text.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"`([^`]*)`"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(\*\*|__)(.+?)\1"#, with: "$2", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<![\p{L}\p{N}])[*_](?=\S)(.+?)(?<=\S)[*_](?![\p{L}\p{N}])"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<![\p{L}\p{N}])[*#]+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: The chat as it's kept

    /// A chat written out, as it's kept in the AI library and read back: who said what.
    public static func transcript(_ turns: [ChatTurn]) -> String {
        turns.map { ($0.role == .user ? "You: " : name + ": ") + $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n\n")
    }

    /// A chat's title: its first question.
    public static func title(_ turns: [ChatTurn]) -> String {
        guard let first = turns.first(where: { $0.role == .user }) else { return "Chat" }
        return LibraryRecord.title(for: first.text, words: 8)
    }

    /// The library record for a chat (the chat's id is the record's, so saving again replaces it).
    public static func record(id: UUID, created: Date, turns: [ChatTurn], existing: LibraryRecord?) -> LibraryRecord {
        var r = existing ?? LibraryRecord(kind: .chat, text: "", created: created, id: id)
        r.turns = turns
        r.text = transcript(turns)
        r.title = title(turns)
        r.modified = turns.last?.time ?? created
        return r
    }
}

// MARK: - What the model can look up

/// The tools the model may call: the chats kept before this one, and the library's dictations,
/// transcripts and notes. It gets only what it asks for; a new chat starts knowing none of it.
///
/// Calls are hand-rolled, not Ollama's tool calling: the tools are described to the model in words,
/// it asks for one by answering with a line of JSON (`{"tool": "list_chats", "arguments": {…}}`),
/// the result goes back as the next message, and it answers. Any model can do it, tools or not.
public enum AssistantTools {
    public static let maxChars = 20_000

    /// A tool as the model is told about it.
    public struct Tool: Equatable, Sendable {
        public var name: String
        public var description: String
        /// Each argument: its name, and what it is ("integer, optional: how many").
        public var arguments: [(String, String)]

        public init(name: String, description: String, arguments: [(String, String)] = []) {
            self.name = name
            self.description = description
            self.arguments = arguments
        }

        public static func == (a: Tool, b: Tool) -> Bool {
            a.name == b.name && a.description == b.description && a.arguments.map(\.0) == b.arguments.map(\.0) && a.arguments.map(\.1) == b.arguments.map(\.1)
        }

        /// Its line in the manual.
        var manual: String {
            var line = "- \(name): \(description)"
            if !arguments.isEmpty {
                line += " Arguments: " + arguments.map { "\($0.0) (\($0.1))" }.joined(separator: "; ") + "."
            }
            return line
        }
    }

    /// The tools over the library.
    public static let library: [Tool] = [
        Tool(name: "list_chats", description: "Lists earlier conversations with the user (not this one), newest first, with their id, date, title and length. Use it when the user refers to something discussed before.",
             arguments: [("limit", "integer, optional: how many, default 20"), ("query", "string, optional: only chats whose text has all these words")]),
        Tool(name: "load_chats", description: "Reads earlier conversations in full. Use it with ids from list_chats when the user asks about them or you need what was said.",
             arguments: [("ids", "list of strings: the chats' ids (a unique prefix is enough)")]),
        Tool(name: "list_library", description: "Lists what the user kept in their library: dictations, transcripts of audio files, and notes, newest first, with id, kind, date, title and length. Use it when the user mentions something they recorded, transcribed or noted.",
             arguments: [("kind", "string, optional: dictation, transcript or note"), ("query", "string, optional: only items whose title or text has all these words"), ("limit", "integer, optional: how many, default 20")]),
        Tool(name: "read_library", description: "Reads library items in full. Use it with ids from list_library.",
             arguments: [("ids", "list of strings: the items' ids (a unique prefix is enough)")]),
    ]

    /// How the model is told to call a tool, and what the tools are.
    public static func manual(_ tools: [Tool]) -> String {
        guard !tools.isEmpty else { return "" }
        return """
        You have tools. To use one, answer with nothing but one line of JSON, like this: \
        {"tool": "list_chats", "arguments": {"query": "budget"}} \
        The result comes back as the next message, marked as a tool result (it's not the user talking), and then you \
        answer the user in words. One tool per answer; call another after if you need to. Never write that JSON unless \
        you mean to call the tool, never make up a result, and don't mention the tools or their names to the user. \
        The tools:
        \(tools.map(\.manual).joined(separator: "\n"))
        """
    }

    /// A tool call, as read out of the model's answer.
    public struct Call: Equatable, Sendable {
        public var name: String
        public var argumentsJSON: String

        public init(name: String, argumentsJSON: String = "{}") {
            self.name = name
            self.argumentsJSON = argumentsJSON
        }

        public var arguments: [String: Any] { JSON.object(Data(argumentsJSON.utf8)) ?? [:] }
    }

    /// The tool calls in an answer: each JSON object in it with a "tool" (or "name") key, in order,
    /// whether bare, in a code fence, or among other text. Anything else in the answer is said.
    public static func calls(in content: String) -> [Call] {
        var out: [Call] = []
        for object in objects(in: content) where isCall(object) {
            guard let name = (object["tool"] ?? object["name"] ?? object["function"]) as? String, !name.isEmpty else { continue }
            let args = object["arguments"] ?? object["args"] ?? object["parameters"] ?? object["input"]
            var json = "{}"
            if let a = args as? [String: Any] {
                json = String(decoding: JSON.data(a), as: UTF8.self)
            } else if let a = args as? String, let o = JSON.object(Data(a.utf8)) {
                json = String(decoding: JSON.data(o), as: UTF8.self)
            } else {
                // Arguments beside the name: {"tool": "list_chats", "query": "budget"}.
                let rest = object.filter { !["tool", "name", "function", "arguments", "args", "parameters", "input"].contains($0.key) }
                if !rest.isEmpty, JSONSerialization.isValidJSONObject(rest) { json = String(decoding: JSON.data(rest), as: UTF8.self) }
            }
            out.append(Call(name: name, argumentsJSON: json))
        }
        return out
    }

    /// Every JSON object in the text (the outermost ones), in order.
    static func objects(in text: String) -> [[String: Any]] {
        let chars = Array(text.utf8)
        var out: [[String: Any]] = []
        var i = 0
        while i < chars.count {
            guard chars[i] == UInt8(ascii: "{"), let end = objectEnd(chars, from: i) else { i += 1; continue }
            if let o = JSON.object(Data(chars[i...end])) { out.append(o) }
            i = end + 1
        }
        return out
    }

    /// Where the object starting at `from` ends (its closing brace), minding strings; nil when it
    /// never closes.
    static func objectEnd(_ chars: [UInt8], from i: Int) -> Int? {
        var depth = 0, inString = false, escaped = false
        var j = i
        while j < chars.count {
            let c = chars[j]
            if inString {
                if escaped { escaped = false } else if c == UInt8(ascii: "\\") { escaped = true } else if c == UInt8(ascii: "\"") { inString = false }
            } else if c == UInt8(ascii: "\"") {
                inString = true
            } else if c == UInt8(ascii: "{") {
                depth += 1
            } else if c == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 { return j }
            }
            j += 1
        }
        return nil
    }

    /// {"tool": …}, or {"name"/"function": …} with arguments beside it.
    static func isCall(_ o: [String: Any]) -> Bool {
        if o["tool"] is String { return true }
        return (o["name"] ?? o["function"]) is String && (o["arguments"] ?? o["args"] ?? o["parameters"] ?? o["input"]) != nil
    }

    /// A tool's "limit" argument, from 1 to 100; whatever number the model wrote.
    static func limit(_ arguments: [String: Any], default d: Int) -> Int {
        guard let n = ToolRunTools.number(arguments["limit"]), n.isFinite else { return d }
        return Int(min(max(n, 1), 100))
    }

    /// The answer without its tool calls (and the code fences around them): what's left to say.
    public static func stripped(_ content: String) -> String {
        let chars = Array(content.utf8)
        var kept: [UInt8] = []
        var i = 0
        while i < chars.count {
            if chars[i] == UInt8(ascii: "{"), let end = objectEnd(chars, from: i), let o = JSON.object(Data(chars[i...end])), isCall(o) {
                i = end + 1
                continue
            }
            kept.append(chars[i])
            i += 1
        }
        var text = String(decoding: kept, as: UTF8.self)
        text = text.replacingOccurrences(of: #"```[a-zA-Z]*\s*```"#, with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A tool's result as the model gets it (a message from the Mac, not the user).
    public static func resultMessage(_ name: String, _ result: String) -> String {
        "Result of the tool \(name) (from the Mac, not the user; use it to answer them):\n\(result)"
    }

    /// Runs a library tool. `current`: this chat, which the model doesn't get to read back. The
    /// answer is text for the model (JSON for lists); nil when it isn't a library tool.
    public static func run(_ name: String, _ arguments: [String: Any], library: [LibraryRecord], current: UUID?) -> String? {
        let limit = Self.limit(arguments, default: 20)
        let query = (arguments["query"] as? String) ?? ""
        let ids = (arguments["ids"] as? [String]) ?? (arguments["ids"] as? String).map { [$0] } ?? (arguments["id"] as? String).map { [$0] } ?? []
        switch name {
        case "list_chats":
            let chats = library.filter { $0.kind == .chat && $0.id != current && $0.matches(query) }.prefix(limit)
            guard !chats.isEmpty else { return query.isEmpty ? "There are no earlier chats." : "No earlier chat has those words." }
            return json(chats.map { c -> [String: Any] in
                ["id": c.id.uuidString, "date": date(c.created), "title": c.title, "turns": c.turns?.count ?? 0]
            })
        case "load_chats":
            return read(ids, from: library.filter { $0.kind == .chat && $0.id != current }, what: "chat")
        case "list_library":
            let kind = (arguments["kind"] as? String).flatMap { LibraryRecord.Kind(rawValue: $0.lowercased()) }
            let items = library.filter { $0.kind != .chat && (kind == nil || $0.kind == kind) && $0.matches(query) }.prefix(limit)
            guard !items.isEmpty else { return query.isEmpty && kind == nil ? "The library is empty." : "Nothing in the library matches." }
            return json(items.map { r -> [String: Any] in
                var o: [String: Any] = ["id": r.id.uuidString, "kind": r.kind.rawValue, "date": date(r.created), "title": r.title, "words": r.wordCount]
                if let s = r.source { o["file"] = s }
                return o
            })
        case "read_library":
            return read(ids, from: library.filter { $0.kind != .chat }, what: "item")
        default:
            return nil
        }
    }

    /// What the model is told when it asks for a tool there isn't.
    public static func unknown(_ name: String, among tools: [Tool]) -> String {
        "There is no tool called \(name). The tools are: \(tools.map(\.name).joined(separator: ", "))."
    }

    static func read(_ ids: [String], from records: [LibraryRecord], what: String) -> String {
        guard !ids.isEmpty else { return "Give the ids to read." }
        var out: [String] = []
        var budget = maxChars
        for id in ids {
            let key = id.trimmingCharacters(in: .whitespaces).uppercased()
            let found = records.filter { $0.id.uuidString.hasPrefix(key) }
            guard found.count == 1, let r = found.first else {
                out.append(found.isEmpty ? "No \(what) has the id \(id)." : "The id \(id) matches more than one \(what); give more of it.")
                continue
            }
            var text = r.text
            if text.count > budget { text = String(text.prefix(max(budget, 0))) + "… (cut short)" }
            budget -= text.count
            out.append("## \(r.title) (\(r.kind.title.lowercased()), \(date(r.created)))\n\(text)")
            if budget <= 0 {
                out.append("(the rest left out: too long)")
                break
            }
        }
        return out.joined(separator: "\n\n")
    }

    static func json(_ object: Any) -> String {
        String(decoding: JSON.data(object), as: UTF8.self)
    }

    static let dates: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    public static func date(_ d: Date) -> String { dates.string(from: d) }

    static let longDates: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .long
        return f
    }()

    /// The date and time written out in full, as the model is told it: "Tuesday, October 21, 2026
    /// at 3:04:05 PM PDT".
    public static func longDate(_ d: Date) -> String { longDates.string(from: d) }

    static let longDays: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        return f
    }()

    /// The day written out in full: "Tuesday, October 21, 2026".
    public static func longDay(_ d: Date) -> String { longDays.string(from: d) }
}

// MARK: - The conversation

/// A language model that chats: Ollama, or a stand-in for tests.
public protocol LanguageModel: AnyObject {
    /// Sends the messages (Ollama's shape: role, content) and returns the answer's text.
    func chat(model: String, messages: [[String: Any]]) async throws -> String
}

public enum AssistantError: Error, LocalizedError, Equatable {
    /// Ollama isn't there.
    case unreachable(String)
    /// Ollama answered with an error.
    case server(Int, String)
    /// No model to talk to.
    case noModel
    case badReply

    public var errorDescription: String? {
        switch self {
        case .unreachable(let url): return "Ollama isn't answering at \(url). Is it running? (ollama serve)"
        case .server(let status, let message): return "Ollama said \(status): \(message)"
        case .noModel: return "Ollama has no model to talk to. Pull one first (ollama pull llama3.2) and pick it in AI Listen."
        case .badReply: return "Ollama's answer couldn't be read."
        }
    }
}

/// One chat with the model: its turns, and the messages as the model has them. Each question goes
/// with the whole chat; the model may call the tools first (earlier chats, the library), a few
/// rounds at most, and the answer comes back to be read.
public final class Conversation {
    public let id: UUID
    public let created: Date
    public private(set) var turns: [ChatTurn] = []
    public var model: String
    public var llm: LanguageModel
    /// The library as it is now (for the tools).
    public var library: () -> [LibraryRecord]
    /// Tool Mac Tool Run, when the model may run the user's scripts and flows through it.
    public var runner: ScriptRunner?
    /// Answer quickly: the shortest answer that does it, no working it out first (thinking off).
    public var quick = true
    /// Rounds of tool calls per question.
    public var maxToolRounds = 6
    /// Every tool call made, for the window to show.
    public private(set) var toolCalls: [String] = []
    private var wire: [[String: Any]] = []

    public init(llm: LanguageModel, model: String, library: @escaping () -> [LibraryRecord], id: UUID = UUID(), created: Date = Date()) {
        self.llm = llm
        self.model = model
        self.library = library
        self.id = id
        self.created = created
    }

    public var isEmpty: Bool { turns.isEmpty }

    /// The chat as it is now, apart from this one: a question still running here doesn't touch it.
    public func copy() -> Conversation {
        let c = Conversation(llm: llm, model: model, library: library, id: id, created: created)
        c.turns = turns
        c.wire = wire
        c.toolCalls = toolCalls
        c.runner = runner
        c.maxToolRounds = maxToolRounds
        return c
    }

    /// The tools the model may call.
    public var tools: [AssistantTools.Tool] { AssistantTools.library + (runner == nil ? [] : ToolRunTools.tools) }

    /// What the model is told before anything else.
    public func systemPrompt(now: Date = Date()) -> String {
        var p = """
        You are \(Assistant.name), a voice assistant on the user's Mac. The user is talking to you out loud and your \
        answers are read aloud by a voice, so answer the way a person speaks: short, plain sentences; no markdown, \
        no headings, no bullet lists, no code, no emoji. Keep it brief (a sentence or two unless more is really \
        asked for) and warm. What you hear was written down by speech recognition, so names and words may be \
        slightly off: take the likely meaning, and ask when it's unclear.
        """
        if quick {
            p += """
             Speed matters more than polish: answer straight away, without working it out step by step or thinking \
            out loud. Give the shortest answer that fully does what was asked, usually one sentence; no preamble, no \
            restating the question, no offers of more help.
            """
        }
        let tools = self.tools
        if !tools.isEmpty {
            p += """
             You remember only this conversation. The user's earlier chats with you and their library (dictations, \
            transcripts of audio files, and notes) are on this Mac, and you can look them up with the tools. Don't look \
            anything up unless it's needed; never make up what a chat or an item says.
            """
            if runner != nil {
                p += """
                 The user also has Tool Mac Tool Run on this Mac, which runs their scripts and flows: when they ask \
                you to run one, find its name with list_scripts or list_flows, then run it. Every run shows a card on \
                their Mac and waits for them to click Run (or Don't Run), so it may take a while; tell them how it \
                went and what it printed, in a sentence or two. Never run anything they didn't ask for.
                """
            }
            p += "\n\n" + AssistantTools.manual(tools)
        }
        // Last, and only the day: what comes before stays the same from one question to the next, so
        // Ollama reuses what it already read of it (the exact time is on each message).
        p += "\n\nToday is \(AssistantTools.longDay(now)); each message from the user says when it was said, to the second."
        return p
    }

    /// Asks the model `text`; the answer, to be read. The question and answer join the chat.
    public func ask(_ text: String, now: Date = Date()) async throws -> String {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        turns.append(ChatTurn(role: .user, text: question, time: now))
        wire.append(["role": "user", "content": Self.stamped(question, now: now)])
        let before = wire.count - 1
        do {
            var content = ""
            var round = 0
            while true {
                let reply = try await send(now: now)
                let calls = AssistantTools.calls(in: reply)
                if calls.isEmpty || round >= maxToolRounds {
                    content = calls.isEmpty ? reply : AssistantTools.stripped(reply)
                    break
                }
                round += 1
                wire.append(["role": "assistant", "content": reply])
                let records = library()
                for call in calls {
                    toolCalls.append(call.name)
                    let result = await run(call, library: records)
                    wire.append(["role": "user", "content": AssistantTools.resultMessage(call.name, result)])
                }
            }
            var answer = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if answer.isEmpty { answer = "I don't have an answer to that." }
            turns.append(ChatTurn(role: .assistant, text: answer, time: Date()))
            wire.append(["role": "assistant", "content": answer])
            return answer
        } catch {
            // The question didn't take: it isn't part of the chat.
            wire.removeSubrange(before...)
            turns.removeLast()
            throw error
        }
    }

    /// Runs one tool call.
    func run(_ call: AssistantTools.Call, library records: [LibraryRecord]) async -> String {
        if let result = AssistantTools.run(call.name, call.arguments, library: records, current: id) { return result }
        if let runner, let result = await ToolRunTools.run(call.name, call.arguments, via: runner) { return result }
        return AssistantTools.unknown(call.name, among: tools)
    }

    /// A question as the model gets it: with the date and time it was said, written out in full.
    public static func stamped(_ question: String, now: Date) -> String {
        "\(question)\n\n(said on \(AssistantTools.longDate(now)))"
    }

    private func send(now: Date) async throws -> String {
        guard !model.isEmpty else { throw AssistantError.noModel }
        let messages = [["role": "system", "content": systemPrompt(now: now)]] + wire
        return try await llm.chat(model: model, messages: messages)
    }

    /// This chat, for the AI library.
    public func record(existing: LibraryRecord?) -> LibraryRecord {
        Assistant.record(id: id, created: created, turns: turns, existing: existing)
    }
}

// MARK: - Ollama

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Ollama's HTTP API (http://127.0.0.1:11434 unless it's elsewhere).
public final class OllamaClient: LanguageModel {
    public let baseURL: URL
    public var timeout: TimeInterval = 120

    public static let defaultURL = "http://127.0.0.1:11434"

    public init(baseURL: String = OllamaClient.defaultURL) {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = Self.defaultURL }
        if !s.lowercased().hasPrefix("http") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        self.baseURL = URL(string: s) ?? URL(string: Self.defaultURL)!
    }

    /// Let the model think before it answers (slower; off by default). Off, thinking is turned
    /// off as far as Ollama and the model allow (see `think(model:on:)`).
    public var thinking = false
    /// How long Ollama keeps the model loaded after a question, so the next one doesn't wait for it.
    public var keepAlive = "30m"
    /// The longest answer with thinking off, in tokens: a safety net, the prompt asks for short.
    public static let quickAnswerTokens = 400
    /// The last answer came with thinking although it was turned off (an older Ollama, or a
    /// model that can't stop): see `ThinkingAdvice`.
    public private(set) var thoughtAnyway = false

    /// The request body for /api/chat: plain messages, no tools (calls are hand-rolled), and
    /// whether to think (`think`: nil leaves the field out, for an Ollama that refuses it).
    public static func chatBody(model: String, messages: [[String: Any]], thinking: Bool = false, sendThink: Bool = true,
                                keepAlive: String = "30m") -> [String: Any] {
        var body: [String: Any] = ["model": model, "messages": messages, "stream": false, "keep_alive": keepAlive]
        if !thinking { body["options"] = ["num_predict": quickAnswerTokens] }
        if sendThink { body["think"] = think(model: model, on: thinking) }
        if !thinking, noThinkTag(model), var last = messages.last, last["role"] as? String == "user",
           let content = last["content"] as? String {
            // Qwen 3 also takes "/no_think" in what's said, which works even where `think` doesn't.
            last["content"] = content + " /no_think"
            body["messages"] = Array(messages.dropLast()) + [last]
        }
        return body
    }

    /// Ollama's `think`: true or false, except gpt-oss, which always thinks and takes a level
    /// ("low" is as little as it goes).
    public static func think(model: String, on: Bool) -> Any {
        if model.lowercased().contains("gpt-oss") { return on ? "medium" : "low" }
        return on
    }

    /// Models that also understand "/no_think" in the message.
    static func noThinkTag(_ model: String) -> Bool { model.lowercased().contains("qwen3") }

    /// Reads /api/chat's answer: the message's text (any <think>…</think> taken out).
    public static func reply(_ data: Data) throws -> String {
        try answer(data).text
    }

    /// The answer's text, and whether it came with thinking (Ollama's `thinking`, or <think> in it).
    public static func answer(_ data: Data) throws -> (text: String, thought: Bool) {
        guard let o = JSON.object(data), let message = o["message"] as? [String: Any] else { throw AssistantError.badReply }
        let content = (message["content"] as? String) ?? ""
        let thinking = (message["thinking"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleaned = content.replacingOccurrences(of: #"<think>[\s\S]*?(</think>|$)"#, with: "", options: .regularExpression)
        let thought = !thinking.isEmpty || cleaned != content
        return (thought ? cleaned.trimmingCharacters(in: .whitespacesAndNewlines) : content, thought)
    }

    public func chat(model: String, messages: [[String: Any]]) async throws -> String {
        let on = thinking
        let data: Data
        do {
            data = try await post("/api/chat", Self.chatBody(model: model, messages: messages, thinking: on, keepAlive: keepAlive))
        } catch AssistantError.server(let status, let message) where status == 400 && message.lowercased().contains("think") {
            // This model (or this Ollama) doesn't take `think`: ask without it.
            data = try await post("/api/chat", Self.chatBody(model: model, messages: messages, thinking: on, sendThink: false, keepAlive: keepAlive))
        }
        let a = try Self.answer(data)
        thoughtAnyway = !on && a.thought
        return a.text
    }

    /// Loads `model` (a request with no prompt), so the first question doesn't wait for it.
    public func warm(_ model: String) async {
        guard !model.isEmpty else { return }
        _ = try? await post("/api/generate", ["model": model, "keep_alive": keepAlive])
    }

    /// Ollama's version ("0.12.3").
    public func version() async throws -> String {
        let data = try await get("/api/version")
        guard let v = JSON.object(data)?["version"] as? String else { throw AssistantError.badReply }
        return v
    }

    /// The models Ollama has, as named there ("llama3.2:latest").
    public func models() async throws -> [String] {
        let data = try await get("/api/tags")
        guard let o = JSON.object(data), let models = o["models"] as? [[String: Any]] else { throw AssistantError.badReply }
        return models.compactMap { $0["name"] as? String }
    }

    private func get(_ path: String) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 10)
        req.httpMethod = "GET"
        return try await send(req)
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = JSON.data(body)
        return try await send(req)
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let result: (Data, URLResponse?)
        do {
            result = try await withCheckedThrowingContinuation { (k: CheckedContinuation<(Data, URLResponse?), Error>) in
                URLSession.shared.dataTask(with: req) { data, response, error in
                    if let error { k.resume(throwing: error) } else { k.resume(returning: (data ?? Data(), response)) }
                }.resume()
            }
        } catch {
            throw AssistantError.unreachable(baseURL.absoluteString)
        }
        let (data, response) = result
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (JSON.object(data)?["error"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw AssistantError.server(status, message)
        }
        return data
    }
}

/// What to tell the user when thinking is off but can't be turned off all the way, with the
/// command that does the rest (nil: nothing to do).
public enum ThinkingAdvice {
    /// Ollama turns thinking off (`think: false`) from 0.9.0 on.
    public static let firstVersion = [0, 9, 0]

    public static func advice(model: String, version: String?, thoughtAnyway: Bool) -> (text: String, command: String?)? {
        if let version, isOlder(version, than: firstVersion) {
            return ("Ollama \(version) can't turn thinking off; 0.9 or newer can. Update it, then start it again:",
                    "brew upgrade ollama || curl -fsSL https://ollama.com/install.sh | sh")
        }
        if model.lowercased().contains("gpt-oss") {
            return ("\(model) always thinks a little (it's set to as little as it goes). For no thinking at all, use another model:",
                    "ollama pull llama3.2")
        }
        if thoughtAnyway {
            return ("\(model) thought anyway (what it thought isn't read out). Updating Ollama usually fixes it:",
                    "brew upgrade ollama || curl -fsSL https://ollama.com/install.sh | sh")
        }
        return nil
    }

    /// "0.6.8" against [0, 9, 0] (anything after the numbers, like "-rc1", is ignored).
    public static func isOlder(_ version: String, than other: [Int]) -> Bool {
        let parts = version.split(whereSeparator: { !$0.isNumber && $0 != "." }).first.map {
            $0.split(separator: ".").map { Int($0) ?? 0 }
        } ?? []
        guard !parts.isEmpty else { return false }
        for i in 0..<max(parts.count, other.count) {
            let a = i < parts.count ? parts[i] : 0, b = i < other.count ? other[i] : 0
            if a != b { return a < b }
        }
        return false
    }
}
