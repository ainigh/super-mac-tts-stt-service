import Foundation

/// A job: what Tom hands Jerry. Its record is the harness's (this struct, kept by the app), never
/// the models': its status changes only as a side effect of what the harness does (a tool
/// proposed, approved or run; Jerry's `finish` or `ask_tom`; Tom's `message_jerry` or `cancel_job`).
public struct Job: Codable, Equatable, Identifiable, Sendable {
    /// What Tom asked for.
    public struct Spec: Codable, Equatable, Sendable {
        public var goal: String
        public var constraints: [String]
        public var doneCriteria: String
        /// What to bring back (the shape of the result), so Tom can check it against done_criteria.
        public var returns: String

        public init(goal: String, constraints: [String] = [], doneCriteria: String = "", returns: String = "") {
            self.goal = goal
            self.constraints = constraints
            self.doneCriteria = doneCriteria
            self.returns = returns
        }

        /// The spec written out, as Jerry gets it and the window shows it.
        public var text: String {
            var lines = ["Goal: \(goal)"]
            if !constraints.isEmpty { lines.append("Constraints: " + constraints.joined(separator: "; ")) }
            if !doneCriteria.isEmpty { lines.append("Done when: \(doneCriteria)") }
            if !returns.isEmpty { lines.append("Bring back: \(returns)") }
            return lines.joined(separator: "\n")
        }
    }

    public enum Status: String, Codable, Sendable {
        case queued, running, awaitingApproval = "awaiting_approval", blocked, done, failed

        public var title: String {
            switch self {
            case .queued: return "Queued"
            case .running: return "Running"
            case .awaitingApproval: return "Waiting for your approval"
            case .blocked: return "Blocked: Jerry asked"
            case .done: return "Done"
            case .failed: return "Failed"
            }
        }

        /// Still to be done (not done or failed).
        public var isOpen: Bool { self != .done && self != .failed }
    }

    /// What Jerry brings back.
    public struct Result: Codable, Equatable, Sendable {
        /// For Tom and the user, a sentence or two.
        public var summary: String
        /// For the user to expand: what was done, step by step.
        public var details: String

        public init(summary: String, details: String = "") {
            self.summary = summary
            self.details = details
        }
    }

    /// Something that happened to the job, written by the harness.
    public struct Event: Codable, Equatable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable {
            /// The status changed (`text`: the new status, and why).
            case status
            /// Tom said something to Jerry about it (`text`: his message).
            case message
            /// Jerry said something while working (`text`: his words).
            case said
            /// Jerry asked Tom (`text`: the question).
            case question
            /// Tool traffic (L3: the harness alone writes it; Tom sees that it happened, not the result).
            case toolProposed = "tool_proposed", toolApproved = "tool_approved", toolRejected = "tool_rejected", toolResult = "tool_result"
            /// Jerry finished (`text`: the summary).
            case result
        }

        public var id: UUID
        public var time: Date
        public var kind: Kind
        public var text: String

        public init(kind: Kind, text: String, time: Date = Date(), id: UUID = UUID()) {
            self.id = id
            self.time = time
            self.kind = kind
            self.text = text
        }

        /// Tom hears of tool traffic as an event, not a result.
        public var isToolTraffic: Bool {
            [.toolProposed, .toolApproved, .toolRejected, .toolResult].contains(kind)
        }
    }

    /// "j17".
    public var id: String
    /// The chat (the AI library record) it was asked in.
    public var session: UUID
    public var spec: Spec
    public var status: Status
    /// Jerry's question, while it's blocked.
    public var blockedOn: String?
    public var events: [Event]
    public var result: Result?
    /// How many times Tom sent it back.
    public var revisions: Int
    /// Tom's messages Jerry hasn't seen yet (an answer to his question, or why it came back).
    public var inbox: [String]
    /// Every tool Jerry used on it (L3), in order.
    public var tools: [ToolUse]
    public var created: Date
    public var modified: Date

    public init(id: String, session: UUID, spec: Spec, created: Date = Date()) {
        self.id = id
        self.session = session
        self.spec = spec
        status = .queued
        events = []
        revisions = 0
        inbox = []
        tools = []
        self.created = created
        modified = created
    }

    /// Its number, for ordering: 17 of "j17".
    public var number: Int { Int(id.dropFirst()) ?? 0 }

    /// A line for the window and the logs: "j17 (revision 1): Done".
    public var headline: String {
        var s = id
        if revisions > 0 { s += " (revision \(revisions))" }
        return s + ": " + status.title
    }
}

/// The jobs, and what may happen to them. Pure: the app keeps one, calls these as things happen,
/// and saves it. Every change returns the event written, for the room's log and to wake Tom.
public struct JobBoard: Codable, Equatable, Sendable {
    public private(set) var jobs: [Job] = []
    private var nextNumber = 1

    /// A job may come back this many times; after that Tom is told to take it to the user.
    public static let maxRevisions = 3

    public init() {}

    public func job(_ id: String) -> Job? { jobs.first { $0.id == Self.normalize(id) } }

    /// "J17", "job 17", "17" → "j17".
    public static func normalize(_ id: String) -> String {
        let s = id.lowercased().trimmingCharacters(in: .whitespaces)
        if let n = Int(s) { return "j\(n)" }
        if let r = s.range(of: #"\d+"#, options: .regularExpression) { return "j" + s[r] }
        return s
    }

    /// The jobs still to be done, oldest first.
    public var open: [Job] { jobs.filter { $0.status.isOpen }.sorted { $0.number < $1.number } }

    /// The job Jerry is on, if any (running, or waiting for the user's approval).
    public var current: Job? { jobs.first { $0.status == .running || $0.status == .awaitingApproval } }

    /// The next job for Jerry: one sent back or unblocked goes first (the user is waiting on it),
    /// else the oldest queued. Nil while one is running (one at a time), or none is queued.
    public func nextQueued() -> Job? {
        guard current == nil else { return nil }
        let queued = jobs.filter { $0.status == .queued }
        if let again = queued.filter({ $0.revisions > 0 || !$0.inbox.isEmpty }).min(by: { $0.modified < $1.modified }) { return again }
        return queued.min { $0.number < $1.number }
    }

    // MARK: Tom's moves

    /// A new job, queued.
    @discardableResult
    public mutating func delegate(_ spec: Job.Spec, session: UUID, now: Date = Date()) -> Job {
        var job = Job(id: "j\(nextNumber)", session: session, spec: spec, created: now)
        nextNumber += 1
        job.events.append(Job.Event(kind: .status, text: "queued", time: now))
        jobs.append(job)
        return job
    }

    /// Tom's message to Jerry about a job: on a blocked job it answers him (queued again); on a done
    /// one it sends it back (queued, a revision); else it waits for him with the job. What Tom is
    /// told, and the job as it is now (nil: no such job, or it can't take it).
    public mutating func message(_ id: String, _ text: String, now: Date = Date()) -> (result: String, job: Job?) {
        guard let i = index(id) else { return ("No job called \(id). Open jobs: \(openList()).", nil) }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return ("Give the message for Jerry.", nil) }
        var job = jobs[i]
        var note: String
        switch job.status {
        case .failed:
            return ("\(job.id) failed; it can't be messaged. Delegate it again if it should be done.", nil)
        case .done:
            guard job.revisions < Self.maxRevisions else {
                return ("\(job.id) has come back \(job.revisions) times already. Tell the user where it stands instead; delegate a fresh job if they want it done differently.", nil)
            }
            job.revisions += 1
            job.status = .queued
            job.result = nil
            job.events.append(Job.Event(kind: .status, text: "sent back (revision \(job.revisions))", time: now))
            note = "\(job.id) sent back to Jerry (revision \(job.revisions)); he'll take it up again in turn."
        case .blocked:
            job.status = .queued
            job.blockedOn = nil
            job.events.append(Job.Event(kind: .status, text: "answered; queued again", time: now))
            note = "\(job.id) unblocked; Jerry gets your answer when he takes it up again."
        case .queued, .running, .awaitingApproval:
            note = "\(job.id) is \(job.status.rawValue); Jerry sees your message with it."
        }
        job.inbox.append(message)
        job.events.append(Job.Event(kind: .message, text: message, time: now))
        job.modified = now
        jobs[i] = job
        return (note, job)
    }

    /// Tom cancels a job: failed, out of the queue. What Tom is told, and the job (nil: no such job).
    public mutating func cancel(_ id: String, now: Date = Date()) -> (result: String, job: Job?) {
        guard let i = index(id) else { return ("No job called \(id). Open jobs: \(openList()).", nil) }
        guard jobs[i].status.isOpen else { return ("\(jobs[i].id) is already \(jobs[i].status.rawValue).", nil) }
        let wasRunning = jobs[i].status == .running || jobs[i].status == .awaitingApproval
        set(i, .failed, why: "cancelled by Tom", now: now)
        return ("\(jobs[i].id) cancelled" + (wasRunning ? " (Jerry stops as soon as he can)." : "."), jobs[i])
    }

    /// A job's standing, as Tom asks for it.
    public func status(_ id: String) -> String {
        guard let job = job(id) else { return "No job called \(id). Open jobs: \(openList())." }
        var lines = ["\(job.headline)"]
        lines.append(job.spec.text)
        if let q = job.blockedOn { lines.append("Jerry asks: \(q)") }
        let recent = job.events.suffix(6).map { "- " + Self.line($0) }
        if !recent.isEmpty { lines.append("Recent events:\n" + recent.joined(separator: "\n")) }
        if let r = job.result {
            lines.append("Result: \(r.summary)")
            if !r.details.isEmpty { lines.append("Details: \(r.details)") }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: The harness's moves, as Jerry works

    /// Jerry takes it up.
    @discardableResult
    public mutating func start(_ id: String, now: Date = Date()) -> Job? {
        guard let i = index(id), jobs[i].status == .queued else { return nil }
        set(i, .running, why: jobs[i].revisions > 0 ? "running (revision \(jobs[i].revisions))" : "running", now: now)
        return jobs[i]
    }

    /// Jerry said something while working on it.
    public mutating func said(_ id: String, _ text: String, now: Date = Date()) {
        guard let i = index(id) else { return }
        jobs[i].events.append(Job.Event(kind: .said, text: text, time: now))
        jobs[i].modified = now
    }

    /// Jerry proposed a tool call that needs the user's approval.
    @discardableResult
    public mutating func proposed(_ id: String, tool: String, arguments: String, now: Date = Date()) -> Job? {
        guard let i = index(id) else { return nil }
        jobs[i].events.append(Job.Event(kind: .toolProposed, text: Self.toolLine(tool, arguments), time: now))
        set(i, .awaitingApproval, why: "waiting for the user to approve \(tool)", now: now)
        return jobs[i]
    }

    /// The user approved (it runs now) or rejected it.
    @discardableResult
    public mutating func decided(_ id: String, tool: String, approved: Bool, now: Date = Date()) -> Job? {
        guard let i = index(id) else { return nil }
        jobs[i].events.append(Job.Event(kind: approved ? .toolApproved : .toolRejected, text: tool, time: now))
        if jobs[i].status == .awaitingApproval { set(i, .running, why: approved ? "running: \(tool) approved" : "running: \(tool) rejected", now: now) }
        return jobs[i]
    }

    /// A tool ran (approved, or one that needs no approval): its use, kept in full (L3).
    public mutating func ran(_ id: String, _ use: ToolUse) {
        guard let i = index(id) else { return }
        jobs[i].tools.append(use)
        jobs[i].events.append(Job.Event(kind: .toolResult, text: use.name, time: use.time))
        jobs[i].modified = use.time
    }

    /// Jerry asked Tom: blocked until Tom answers (`message`).
    @discardableResult
    public mutating func block(_ id: String, question: String, now: Date = Date()) -> Job? {
        guard let i = index(id), jobs[i].status.isOpen else { return nil }
        jobs[i].blockedOn = question
        jobs[i].events.append(Job.Event(kind: .question, text: question, time: now))
        set(i, .blocked, why: "blocked: Jerry asked Tom", now: now)
        return jobs[i]
    }

    /// Jerry finished it.
    @discardableResult
    public mutating func finish(_ id: String, _ result: Job.Result, now: Date = Date()) -> Job? {
        guard let i = index(id), jobs[i].status.isOpen else { return nil }
        jobs[i].result = result
        jobs[i].blockedOn = nil
        jobs[i].events.append(Job.Event(kind: .result, text: result.summary, time: now))
        set(i, .done, why: "done", now: now)
        return jobs[i]
    }

    /// It couldn't be done (the model failed, or the app stopped).
    @discardableResult
    public mutating func fail(_ id: String, why: String, now: Date = Date()) -> Job? {
        guard let i = index(id), jobs[i].status.isOpen else { return nil }
        set(i, .failed, why: "failed: \(why)", now: now)
        return jobs[i]
    }

    /// Jerry took the job's inbox (Tom's messages) with him: emptied.
    public mutating func took(_ id: String) -> [String] {
        guard let i = index(id) else { return [] }
        defer { jobs[i].inbox = [] }
        return jobs[i].inbox
    }

    /// A job left running when the app stopped is queued again at the next start (Jerry's chat is
    /// gone with the session; the record isn't).
    public mutating func recover(now: Date = Date()) {
        for i in jobs.indices where jobs[i].status == .running || jobs[i].status == .awaitingApproval {
            set(i, .queued, why: "queued again (the app started again)", now: now)
        }
    }

    /// Forgets the jobs that are over.
    public mutating func clearFinished() {
        jobs.removeAll { !$0.status.isOpen }
    }

    // MARK: For the prompts

    /// The open jobs, as Tom is told at the start of every turn ("" when there are none).
    public func prompt(session: UUID) -> String {
        let open = self.open
        guard !open.isEmpty else { return "" }
        var p = "\n\nOpen jobs (Jerry does one at a time, oldest first; one sent back or unblocked goes first):"
        for job in open {
            var line = "\n- \(job.headline)" + (job.session == session ? "" : " (from an earlier chat)") + ". \(job.spec.goal)"
            if let q = job.blockedOn { line += " Jerry asks: \(q)" }
            p += line
        }
        return p
    }

    /// A job as Jerry gets it when he takes it up: the spec, Tom's messages, and what he did on it
    /// before (when it's come back).
    public static func briefing(_ job: Job, messages: [String]) -> String {
        var lines = ["Job \(job.id) from Tom" + (job.revisions > 0 ? " (revision \(job.revisions): it came back; see his message)" : "") + ":"]
        lines.append(job.spec.text)
        if !messages.isEmpty { lines.append("Tom says: " + messages.joined(separator: " ")) }
        if !job.tools.isEmpty, job.revisions > 0 || job.inbox.isEmpty {
            lines.append("What you did on it before: " + job.tools.map(\.name).joined(separator: ", ") + ".")
        }
        if let r = job.result { lines.append("What you brought back before: \(r.summary)") }
        lines.append("Work it with your tools, say briefly what you're doing as you go, and end with finish (or ask_tom if you can't go on without an answer).")
        return lines.joined(separator: "\n")
    }

    /// An event in words, for the room's log and for Tom.
    public static func line(_ e: Job.Event) -> String {
        switch e.kind {
        case .status: return e.text
        case .message: return "Tom: \(e.text)"
        case .said: return "Jerry: \(e.text)"
        case .question: return "Jerry asks: \(e.text)"
        case .toolProposed: return "proposed \(e.text)"
        case .toolApproved: return "\(e.text) approved by the user"
        case .toolRejected: return "\(e.text) rejected by the user"
        case .toolResult: return "\(e.text) ran"
        case .result: return "result: \(e.text)"
        }
    }

    /// "web_search(query: cats)".
    static func toolLine(_ tool: String, _ arguments: String) -> String {
        let summary = ToolUse(name: tool, arguments: arguments, result: "").summary
        return summary.isEmpty ? tool : "\(tool)(\(summary))"
    }

    private func index(_ id: String) -> Int? {
        let key = Self.normalize(id)
        return jobs.firstIndex { $0.id == key }
    }

    private func openList() -> String {
        let o = open
        return o.isEmpty ? "none" : o.map(\.id).joined(separator: ", ")
    }

    private mutating func set(_ i: Int, _ status: Job.Status, why: String, now: Date) {
        jobs[i].status = status
        jobs[i].modified = now
        jobs[i].events.append(Job.Event(kind: .status, text: why, time: now))
    }
}

/// The job tools: Tom's (delegating and managing) and Jerry's (asking and finishing).
public enum JobTools {
    /// Tom's: delegate, message_jerry and cancel_job end his turn (the harness acts on them);
    /// job_status answers at once.
    public static func supervisor(teammate: String = Team.teammate) -> [AssistantTools.Tool] {
        let t = teammate.lowercased()
        return [
            AssistantTools.Tool(name: "delegate", description: "Hands \(teammate) a job. He has the tools (the web, files, the library, scripts, …); you don't, so anything that needs them is a job for him. Write the spec in full: he can't see or hear the user, only you. Returns the job's id. Calling it ends your turn: say first, in a few words, what you're handing off.",
                                arguments: [("goal", "string: what to achieve, concretely"), ("constraints", "list of strings, optional: limits and preferences (from your memory too)"),
                                            ("done_criteria", "string: how to tell it's done; name every step that matters"), ("return", "string: what to bring back, enough to check done_criteria")]),
            AssistantTools.Tool(name: "job_status", description: "A job's standing: status, what \(teammate) asked (if blocked), recent events, and the result once it's done.",
                                arguments: [("job_id", "string: like j17")]),
            AssistantTools.Tool(name: "message_\(t)", description: "Says something to \(teammate) about a job: answers his question (a blocked job goes on), or sends a done job back with what to change (a revision), or adds to a running one. Calling it ends your turn.",
                                arguments: [("job_id", "string"), ("message", "string: what to tell him, in full")]),
            AssistantTools.Tool(name: "cancel_job", description: "Stops a job: it's dropped. Calling it ends your turn.",
                                arguments: [("job_id", "string")]),
        ]
    }

    /// Jerry's: both end his turn on the job.
    public static func worker(lead: String = Assistant.name) -> [AssistantTools.Tool] {
        let l = lead.lowercased()
        return [
            AssistantTools.Tool(name: "ask_\(l)", description: "Asks \(lead) something you can't go on without (he can ask the user). The job waits for his answer; you get it with the job when it comes back to you. Calling it ends your turn.",
                                arguments: [("question", "string")]),
            AssistantTools.Tool(name: "finish", description: "Ends the job with what you found or did. Calling it ends your turn. Always finish; never just stop.",
                                arguments: [("summary", "string: a sentence or two, for \(lead) and the user, with what they need to check it went as asked"),
                                            ("details", "string, optional: what you did, step by step, for the user to read if they want")]),
        ]
    }

    /// Names models give these, taken as the tool they mean.
    public static func aliases(teammate: String = Team.teammate, lead: String = Assistant.name) -> [String: String] {
        let t = teammate.lowercased(), l = lead.lowercased()
        return ["create_job": "delegate", "new_job": "delegate", "assign": "delegate", "assign_job": "delegate", "delegate_job": "delegate", "hand_off": "delegate",
                "delegate_to_\(t)": "delegate", "tell_\(t)": "message_\(t)", "ask_\(t)": "message_\(t)", "reply_\(t)": "message_\(t)", "answer_\(t)": "message_\(t)",
                "send_back": "message_\(t)", "message_job": "message_\(t)", "\(t)": "message_\(t)",
                "get_status": "job_status", "status": "job_status", "check_job": "job_status", "job": "job_status", "get_job_status": "job_status",
                "cancel": "cancel_job", "stop_job": "cancel_job", "drop_job": "cancel_job",
                "question": "ask_\(l)", "ask": "ask_\(l)", "ask_lead": "ask_\(l)", "tell_\(l)": "ask_\(l)", "message_\(l)": "ask_\(l)",
                "done": "finish", "complete": "finish", "finish_job": "finish", "report": "finish", "submit": "finish", "result": "finish", "final_answer": "finish"]
    }

    /// The spec in a delegate call's arguments (nil: no goal).
    public static func spec(_ arguments: [String: Any]) -> Job.Spec? {
        guard let goal = ToolRunTools.string(arguments["goal"] ?? arguments["task"] ?? arguments["spec"] ?? arguments["message"] ?? arguments["job"]),
              !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var constraints: [String] = []
        if let list = arguments["constraints"] as? [Any] {
            constraints = list.compactMap { ToolRunTools.string($0) }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        } else if let one = ToolRunTools.string(arguments["constraints"]), !one.trimmingCharacters(in: .whitespaces).isEmpty {
            constraints = one.components(separatedBy: CharacterSet(charactersIn: ";\n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let done = ToolRunTools.string(arguments["done_criteria"] ?? arguments["done"] ?? arguments["doneCriteria"] ?? arguments["success"]) ?? ""
        let returns = ToolRunTools.string(arguments["return"] ?? arguments["returns"] ?? arguments["return_shape"] ?? arguments["output"]) ?? ""
        return Job.Spec(goal: goal.trimmingCharacters(in: .whitespacesAndNewlines), constraints: constraints,
                        doneCriteria: done.trimmingCharacters(in: .whitespacesAndNewlines), returns: returns.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The job id in a call's arguments.
    public static func jobID(_ arguments: [String: Any]) -> String? {
        let raw = arguments["job_id"] ?? arguments["id"] ?? arguments["job"] ?? arguments["jobId"]
        if let n = ToolRunTools.number(raw), n.isFinite, !(raw is String) { return "j\(Int(n))" }
        return ToolRunTools.string(raw)
    }

    /// The result in a finish call's arguments (a bare string is the summary).
    public static func result(_ arguments: [String: Any]) -> Job.Result? {
        let summary = ToolRunTools.string(arguments["summary"] ?? arguments["result"] ?? arguments["text"] ?? arguments["message"] ?? arguments["answer"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let details = ToolRunTools.string(arguments["details"] ?? arguments["detail"] ?? arguments["steps"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !summary.isEmpty || !details.isEmpty else { return nil }
        return Job.Result(summary: summary.isEmpty ? details : summary, details: details)
    }

    /// What the user says to approve a proposed tool call while one waits: true, false, or nil (not
    /// an answer: it's for Tom as usual).
    public static func approval(_ said: String) -> Bool? {
        let words = Assistant.tokens(said).map(\.word)
        guard !words.isEmpty, words.count <= 6 else { return nil }
        let yes: Set<String> = ["approve", "approved", "yes", "yeah", "yep", "ok", "okay", "sure", "go", "ahead", "allow", "proceed", "do", "it", "fine", "run", "please", "accept", "continue"]
        let no: Set<String> = ["reject", "rejected", "no", "nope", "don", "dont", "stop", "deny", "skip", "cancel", "never", "not", "refuse"]
        let meaningless: Set<String> = ["tom", "that", "this", "the", "and", "then", "just", "go", "ahead", "it", "do", "please", "so", "with", "on", "now", "them", "thanks", "thank", "you", "t"]
        let content = words.filter { !meaningless.contains($0) }
        if content.contains(where: { no.contains($0) }) { return false }
        if content.isEmpty { return words.contains("go") || words.contains("do") || words.contains("it") ? true : nil }
        if content.allSatisfy({ yes.contains($0) }) { return true }
        return nil
    }
}
