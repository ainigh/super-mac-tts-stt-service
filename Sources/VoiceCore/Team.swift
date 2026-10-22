import Foundation

/// The team: Tom, the supervisor the user talks to, and Jerry, the worker (his own model, his own
/// voice) who has the tools and does the jobs Tom hands him (see `Job`, `JobBoard`, `JobTools`).
/// The three share one room: everything either says is read out in its voice, so the user hears
/// them both, but talks only to Tom. Tom is woken on everything that happens to a job and may say
/// nothing; the user approves or rejects Jerry's tool calls themselves.
public enum Team {
    /// The second assistant.
    public static let teammate = "Jerry"
    /// His name as the recognizer tends to write it.
    public static let teammateWords: [[String]] = [["jerry"], ["gerry"], ["jeri"], ["jerri"], ["jerrie"]]

    /// Something said by name to Jerry ("Jerry, what do you think?"): whom, and what (empty when
    /// only the name was said). Nil when it isn't addressed to him. ("Tom, …" is handled by the
    /// wake word, which comes off before this.)
    public static func addressed(_ text: String) -> (to: String, rest: String)? {
        let tokens = Assistant.tokens(text)
        guard !tokens.isEmpty else { return nil }
        var start = 0
        if tokens.count > 1, Assistant.greetings.contains(tokens[0].word) { start = 1 }
        guard let n = length(of: teammateWords, in: tokens.map(\.word), from: start) else { return nil }
        start += n
        guard start < tokens.count else { return (teammate, "") }
        // "Jerry what…" without a comma: the name is a word in a sentence only if it's the subject
        // of a verb we can't tell apart, so by name first always counts.
        return (teammate, Assistant.text(text, from: tokens[start].range.lowerBound))
    }

    static func length(of names: [[String]], in words: [String], from: Int) -> Int? {
        for name in names where words.count >= from + name.count && Array(words[from..<from + name.count]) == name {
            return name.count
        }
        return nil
    }

    /// Tom's tools over the team: the job tools (see `JobTools`).
    public static func tools(teammate: String = Team.teammate) -> [AssistantTools.Tool] {
        JobTools.supervisor(teammate: teammate)
    }

    /// What Tom is told about the team: he supervises, Jerry works.
    static func leadPrompt(teammate: String) -> String {
        let t = teammate.lowercased()
        return """
         You work with \(teammate), a second assistant on this Mac with his own model and voice. You are the \
        supervisor: you talk to the user and to \(teammate), and to nothing else. \(teammate) is the worker: he has the \
        tools (the web and the browser, files, the clipboard, the library, scripts, sums) and does every job; he can't \
        see or hear the user, only what you send him. Anything that takes a tool is a job for him: delegate it with a \
        full spec (goal, constraints from what you know of the user, done_criteria naming every step that matters, and \
        what to return so you can check it), say in a few words what you're handing off, and the call ends your turn. \
        You're told of everything that happens to a job as events: a tool he proposed, the user approving or \
        rejecting it, his question, his result. Most events need nothing from you: answer with only the word \
        (nothing). Speak to the user only when a job is done (compare the result with your spec: if it misses, \
        message_\(t) to send it back with what to change, without asking the user; if it's right, say what matters in \
        a sentence, and never repeat his report, which the user already heard read out), when it failed, when \
        \(teammate) asked something only the user can answer (answer from what you know first), or to correct course. \
        The user hears \(teammate) too, and approves or rejects his tool calls themselves. After a job, remember what \
        it taught you about the user or about briefing \(teammate). Never speak for \(teammate), never pretend to \
        have asked him, never claim a result you weren't given, and never do yourself what you have no tool for.
        """
    }

    /// What Jerry is told about the team.
    static func memberPrompt(lead: String, me: String) -> String {
        let l = lead.lowercased()
        return """
         You work for \(lead), the assistant the user talks to. You're the worker: \(lead) sends you jobs, each with a \
        goal, constraints, done criteria and what to bring back, and you do them with your tools; you can't see or hear \
        the user. Everything you write is read out loud in your own voice and the user hears it, so say briefly what \
        you're doing as you go (a short sentence with each tool call), and nothing more. Some tool calls wait for the \
        user to approve them; one they reject comes back as rejected: go on without it, or finish with what you have. \
        Meet every done criterion; when you can't go on without an answer, ask_\(l) (the job waits for his answer, \
        which comes back to you with it). Always end a job with finish: a summary in a sentence or two that says what \
        \(lead) needs to check it against the done criteria, and details for the user. Never make up a result.
        """
    }

    /// A message from a teammate, as the model gets it (not the user).
    static func message(_ text: String, from: String) -> String {
        "Message from \(from), your teammate (the user heard it read out too; answer him, or the user):\n\(text)"
    }

    /// Something said between the others, as the model gets it: context, no answer wanted.
    static func overheard(_ text: String, from: String, to: String) -> String {
        "(Overheard, no answer wanted: \(from) said to \(to): “\(text)”)"
    }

    /// The answer says nothing is to be said: "(nothing)", "nothing.", "[silence]".
    public static func isSilent(_ answer: String) -> Bool {
        answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .range(of: #"^[\(\[]?\s*(nothing|silence|silent|no reply|no answer|no response|none)\s*[\)\]]?\.?$"#, options: .regularExpression) != nil
    }
}
