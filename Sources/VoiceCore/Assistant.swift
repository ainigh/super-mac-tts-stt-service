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
        text = text.replacingOccurrences(of: #"[*#]+"#, with: "", options: .regularExpression)
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
public enum AssistantTools {
    public static let maxChars = 20_000

    /// The tools as Ollama takes them.
    public static let definitions: [[String: Any]] = [
        tool("list_chats", "Lists earlier conversations with the user (not this one), newest first, with their id, date, title and length. Call it when the user refers to something discussed before.",
             ["limit": ["type": "integer", "description": "How many (default 20)"],
              "query": ["type": "string", "description": "Only chats whose text has all these words"]]),
        tool("load_chats", "Reads earlier conversations in full. Call it with ids from list_chats when the user asks about them or you need what was said.",
             ["ids": ["type": "array", "items": ["type": "string"], "description": "The chats' ids (a unique prefix is enough)"]], required: ["ids"]),
        tool("list_library", "Lists what the user kept in their library: dictations, transcripts of audio files, and notes, newest first, with id, kind, date, title and length. Call it when the user mentions something they recorded, transcribed or noted.",
             ["kind": ["type": "string", "enum": ["dictation", "transcript", "note"], "description": "Only this kind"],
              "query": ["type": "string", "description": "Only items whose title or text has all these words"],
              "limit": ["type": "integer", "description": "How many (default 20)"]]),
        tool("read_library", "Reads library items in full. Call it with ids from list_library.",
             ["ids": ["type": "array", "items": ["type": "string"], "description": "The items' ids (a unique prefix is enough)"]], required: ["ids"]),
    ]

    static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "function",
         "function": ["name": name, "description": description,
                      "parameters": ["type": "object", "properties": properties, "required": required]]]
    }

    /// Runs a tool call against the library. `current`: this chat, which the model doesn't get to
    /// read back. The answer is text for the model (JSON for lists).
    public static func run(_ name: String, _ arguments: [String: Any], library: [LibraryRecord], current: UUID?) -> String {
        let limit = min(max((arguments["limit"] as? Int) ?? Int((arguments["limit"] as? Double) ?? 20), 1), 100)
        let query = (arguments["query"] as? String) ?? ""
        let ids = (arguments["ids"] as? [String]) ?? (arguments["ids"] as? String).map { [$0] } ?? []
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
            return "There is no tool called \(name)."
        }
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
}

// MARK: - The conversation

/// What the model answered: text, and the tools it wants called first.
public struct ModelReply: Equatable, Sendable {
    public struct ToolCall: Equatable, Sendable {
        public var name: String
        public var argumentsJSON: String

        public init(name: String, argumentsJSON: String) {
            self.name = name
            self.argumentsJSON = argumentsJSON
        }

        public var arguments: [String: Any] { JSON.object(Data(argumentsJSON.utf8)) ?? [:] }
    }

    public var content: String
    public var toolCalls: [ToolCall]

    public init(content: String, toolCalls: [ToolCall] = []) {
        self.content = content
        self.toolCalls = toolCalls
    }
}

/// A language model that chats: Ollama, or a stand-in for tests.
public protocol LanguageModel: AnyObject {
    /// Sends the messages (Ollama's shape: role, content, tool_calls, tool_name) and the tools the
    /// model may call (none: nil), and returns its answer.
    func chat(model: String, messages: [[String: Any]], tools: [[String: Any]]?) async throws -> ModelReply
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

    /// The model can't take tools: talk without them.
    var isNoTools: Bool {
        if case .server(_, let m) = self { return m.lowercased().contains("does not support tools") }
        return false
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
    /// Rounds of tool calls per question.
    public var maxToolRounds = 6
    /// The model takes tools, as far as is known (the first refusal turns it off for the chat).
    public private(set) var toolsSupported = true
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

    /// What the model is told before anything else.
    public func systemPrompt(now: Date = Date()) -> String {
        var p = """
        You are \(Assistant.name), a voice assistant on the user's Mac. The user is talking to you out loud and your \
        answers are read aloud by a voice, so answer the way a person speaks: short, plain sentences; no markdown, \
        no headings, no bullet lists, no code, no emoji. Keep it brief (a sentence or two unless more is really \
        asked for) and warm. What you hear was written down by speech recognition, so names and words may be \
        slightly off: take the likely meaning, and ask when it's unclear. The date and time now is \
        \(AssistantTools.longDate(now)); each message from the user says when it was said.
        """
        if toolsSupported {
            p += """
             You remember only this conversation. The user's earlier chats with you and their library (dictations, \
            transcripts of audio files, and notes) are on this Mac, and you can look them up with the tools: use \
            list_chats and load_chats when the user refers to something discussed before, and list_library and \
            read_library when they mention something they recorded, transcribed or noted. Don't look anything up \
            unless it's needed; never make up what a chat or an item says.
            """
        }
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
                if reply.toolCalls.isEmpty || round >= maxToolRounds || !toolsSupported {
                    content = reply.content
                    break
                }
                round += 1
                let calls: [[String: Any]] = reply.toolCalls.map { c -> [String: Any] in
                    let function: [String: Any] = ["name": c.name, "arguments": c.arguments]
                    return ["function": function]
                }
                wire.append(["role": "assistant", "content": reply.content, "tool_calls": calls])
                let records = library()
                for call in reply.toolCalls {
                    toolCalls.append(call.name)
                    let result = AssistantTools.run(call.name, call.arguments, library: records, current: id)
                    wire.append(["role": "tool", "tool_name": call.name, "content": result])
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

    /// A question as the model gets it: with the date and time it was said, written out in full.
    public static func stamped(_ question: String, now: Date) -> String {
        "\(question)\n\n(said on \(AssistantTools.longDate(now)))"
    }

    private func send(now: Date) async throws -> ModelReply {
        guard !model.isEmpty else { throw AssistantError.noModel }
        let messages = [["role": "system", "content": systemPrompt(now: now)]] + wire
        do {
            return try await llm.chat(model: model, messages: messages, tools: toolsSupported ? AssistantTools.definitions : nil)
        } catch let e as AssistantError where e.isNoTools && toolsSupported {
            toolsSupported = false
            let plain = [["role": "system", "content": systemPrompt(now: now)]] + wire
            return try await llm.chat(model: model, messages: plain, tools: nil)
        }
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

    /// The request body for /api/chat.
    public static func chatBody(model: String, messages: [[String: Any]], tools: [[String: Any]]?) -> [String: Any] {
        var body: [String: Any] = ["model": model, "messages": messages, "stream": false]
        if let tools, !tools.isEmpty { body["tools"] = tools }
        return body
    }

    /// Reads /api/chat's answer.
    public static func reply(_ data: Data) throws -> ModelReply {
        guard let o = JSON.object(data), let message = o["message"] as? [String: Any] else { throw AssistantError.badReply }
        let content = (message["content"] as? String) ?? ""
        let calls = ((message["tool_calls"] as? [[String: Any]]) ?? []).compactMap { c -> ModelReply.ToolCall? in
            guard let f = c["function"] as? [String: Any], let name = f["name"] as? String else { return nil }
            let args: String
            if let s = f["arguments"] as? String {
                args = s
            } else if let a = f["arguments"], JSONSerialization.isValidJSONObject(a) {
                args = String(decoding: JSON.data(a), as: UTF8.self)
            } else {
                args = "{}"
            }
            return ModelReply.ToolCall(name: name, argumentsJSON: args)
        }
        return ModelReply(content: content, toolCalls: calls)
    }

    public func chat(model: String, messages: [[String: Any]], tools: [[String: Any]]?) async throws -> ModelReply {
        let data = try await post("/api/chat", Self.chatBody(model: model, messages: messages, tools: tools))
        return try Self.reply(data)
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
