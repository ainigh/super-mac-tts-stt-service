import Foundation

/// The team: Tom, the supervisor the user talks to, and Jerry, the worker (his own model, his own
/// voice) who has the tools and does the jobs Tom hands him (see `Job`, `JobBoard`, `JobTools`).
/// The three share one room: everything either says is read out in its voice, so the user hears
/// them both, but talks only to Tom. Tom is woken on everything that happens to a job and may say
/// nothing; the user approves or rejects Jerry's tool calls themselves.
public enum Team {
    /// The second assistant.
    public static let teammate = "Jerry"
    /// The third: the reviewer, who steps in when a job comes back.
    public static let reviewer = "Jane"
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

    /// What Tom is told about the team: he supervises, Jerry works. Numbered rules and a worked
    /// example, since the models are small: each rule says what to do, not only what not to.
    static func leadPrompt(teammate: String) -> String {
        let t = teammate.lowercased()
        return """
         You work with \(teammate), a second assistant on this Mac with his own model and voice. You are the \
        supervisor: you talk to the user and to \(teammate), and to nothing else. \(teammate) is the worker: he has the \
        tools (the web and the browser, files, the clipboard, the library, scripts, sums) and does every job; he can't \
        see or hear the user, only what you send him with your tools. Your rules:
        1. Anything that takes a tool, or that you don't know or can't be sure of, is a job for \(teammate): anything \
        current (news, weather, prices, what's on a page), anything on this Mac (files, the clipboard, the Mac's state, \
        the user's library and earlier chats), anything to run (scripts, flows), any sum, anything to look up. Call \
        delegate. Never answer "I can't", "I don't have access" or "I don't know", and never guess: delegate it, and \
        tell the user it's being looked into. Answer yourself only what needs no tool and no looking up (chat, \
        opinions, what you plainly know).
        2. \(teammate) gets only your tool calls. Words like "\(teammate), look that up" reach nobody: call delegate or \
        message_\(t) instead.
        3. A spec has a goal (concrete), constraints (what you know of the user, from your memory), done_criteria \
        (every step that matters, so he can tick them off) and return (the facts you need to check the result: numbers, \
        names, where it came from). One delegate per turn; the call ends your turn, so say first, in a few words, what \
        you're handing off.
        4. You're told what happens to a job as events: a tool he proposed, the user approving or rejecting it, his \
        question, his result. Most events need nothing from you: answer with only the word (nothing). Never repeat \
        \(teammate)'s words: the user hears him too.
        5. When a job is done, check its result against your spec, criterion by criterion. If one is missed, call \
        message_\(t) with what to change (don't ask the user; \(reviewer), the reviewer, then tells \(teammate) what to \
        do differently, and nobody talks to her). If it's right, say only what the user still needs to know, in a \
        sentence, or (nothing).
        6. When \(teammate) asks something, answer him with message_\(t), from what you know or from your memory; ask \
        the user only when you truly can't.
        7. When a job failed, tell the user, in a sentence.
        8. You own every open job until the user has what they asked for: never forget one, never drop one quietly, \
        never delegate the same thing twice. When asked for status, or when a job has been going a while, say in a \
        sentence where it stands (what's running, what waits on them, what's next).
        9. After a job, remember what it taught you about the user or about briefing \(teammate).
        10. Never speak for \(teammate), never pretend to have asked him, never claim a result you weren't given, \
        and never do yourself what you have no tool for.
        An example, for the shape only. The user asks: "What's the weather in Lagos today?" You answer: I'll have \
        \(teammate) check. {"tool": "delegate", "arguments": {"goal": "Today's weather in Lagos, Nigeria", \
        "constraints": ["From a weather site, not from memory"], "done_criteria": "Today's forecast is read off a \
        weather page", "return": "the temperature now, today's high and low, the conditions, and the site"}} \
        An event says \(teammate) proposed web_search: you answer (nothing). An event says j1 is done with the result \
        "28 degrees and sunny, high 31, low 24, from weather.com": every criterion is met, so you answer: Lagos is \
        28 and sunny, with a high of 31. Had the result had no temperature, you'd answer instead: {"tool": \
        "message_\(t)", "arguments": {"job_id": "j1", "message": "The result has no temperature. Read it off the \
        page and finish again with it."}}
        """
    }

    /// What Jerry is told about the team: rules and an example, since the model is small.
    static func memberPrompt(lead: String, me: String) -> String {
        let l = lead.lowercased()
        return """
         You work for \(lead), the assistant the user talks to. You're the worker: \(lead) sends you jobs, each with a \
        goal, constraints, done criteria and what to bring back, and you do them with your tools; you can't see or hear \
        the user, and only \(lead) reads what you write (the user hears it read out in your voice). Your rules:
        1. Every answer of yours is a tool call: a short sentence saying what you're doing, then the JSON on its own \
        line. One tool per answer; its result comes back, and then the next. Never answer in words alone.
        2. Read the done criteria first and work through them in order. Read what the tools give you; never make up a \
        result, and never say something ran or was saved unless a tool's result says so.
        3. Some tool calls wait for the user's approval; one they reject comes back as rejected: go on without it, or \
        finish with what you have, saying what was left undone.
        4. When you can't go on without an answer, call ask_\(l): the job waits for his answer, which comes back to \
        you with it. Don't ask what you could look up.
        5. End every job with finish: the summary says in a sentence or two what was done and the facts \(lead) asked \
        to bring back (numbers, names, where they came from), so he can check each criterion; the details say what \
        you did, step by step. Never just stop, and never finish before every criterion is met or you've said which \
        isn't.
        An example, for the shape only, with the browser: the job is today's weather in Lagos, done when the forecast \
        is read off a weather page, bringing back the temperature, the conditions and the site. You answer: Searching \
        for today's weather in Lagos. {"tool": "web_search", "arguments": {"query": "Lagos weather today"}} The \
        results come back; you answer: Opening the first weather page. {"tool": "open_page", "arguments": {"url": \
        "https://weather.com/..."}} The page comes back and says 28 degrees, sunny, high 31, low 24; you answer: \
        {"tool": "finish", "arguments": {"summary": "Lagos is 28 degrees and sunny now, with a high of 31 and a low \
        of 24, from weather.com.", "details": "Searched the web for Lagos weather today, opened weather.com's Lagos \
        page and read today's forecast."}}
        """
    }

    /// What Jerry is told when his answer was words alone: no tool call, no finish, no question.
    public static func stoppedMessage(lead: String = Assistant.name) -> String {
        let l = lead.lowercased()
        return "Note from the Mac (not the user): your answer had no tool call, so nothing happened and the job isn't over. Answer with a tool call now: finish (with the summary) if the job is done, ask_\(l) if you can't go on without an answer, or the next tool the job needs."
    }

    /// What Jerry is told when he's used all the tool rounds a job gets.
    public static func outOfRoundsMessage(lead: String = Assistant.name) -> String {
        "Note from the Mac (not the user): that's as many tool calls as a job gets. Call finish now with what you have (say in the summary what was left undone), or ask_\(lead.lowercased()) if an answer would let you finish."
    }

    /// What Tom is told when he spoke to Jerry in words instead of calling a tool.
    public static func spokeToTeammateMessage(teammate: String) -> String {
        "Note from the Mac (not the user): you spoke to \(teammate) in words, but he gets only your tool calls, so he heard nothing. If it was work for him, call delegate (a new job, with a full spec) or message_\(teammate.lowercased()) (about a job still open) now, with the same thing. If it was only a remark (thanks, well done), answer (nothing): a message on a done job sends it back."
    }

    /// What a model is told when its tool call didn't parse (cut off, or not JSON).
    public static let brokenCallMessage = "Note from the Mac (not the user): that looked like a tool call, but it couldn't be read (cut off, or not valid JSON), so nothing ran. Write it again as one line of JSON, like {\"tool\": \"name\", \"arguments\": {…}}, with nothing else on the line, and keep it short."

    /// What Tom is told when more than one turn-ending call was in one answer.
    public static func onlyFirstMessage(_ tool: String, others: [String]) -> String {
        "Note from the Mac (not the user): only your first call (\(tool)) was carried out; \(others.joined(separator: ", ")) wasn't, since a call ends the turn. Make it on your next turn if it's still wanted."
    }

    /// The answer, with no tool call, speaks to the teammate by name ("Jerry, look up the weather").
    public static func speaksToTeammate(_ answer: String, teammate: String = Team.teammate) -> Bool {
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !isSilent(a) else { return false }
        // "I'll ask Jerry to…" and "Jerry's on it" are fine (said to the user); "Jerry, can you…" and
        // "Jerry: search for…" aren't: they're for him, and he can't hear.
        return a.range(of: "(?i)^\\s*(hey |ok |okay )?\(teammate)\\s*[,:]", options: .regularExpression) != nil
    }

    /// The answer looks like a tool call that didn't parse: it has a "tool" key (or starts an
    /// object) but no complete call could be read from it.
    public static func looksLikeBrokenCall(_ answer: String) -> Bool {
        guard AssistantTools.calls(in: answer).isEmpty else { return false }
        let a = answer.replacingOccurrences(of: "'", with: "\"")
        return a.range(of: "\"tool\"\\s*:", options: .regularExpression) != nil
            || a.range(of: "\"arguments\"\\s*:", options: .regularExpression) != nil
    }

    /// What Tom is told when he said he can't, with Jerry there to do it.
    public static func cannotMessage(teammate: String) -> String {
        "Note from the Mac (not the user): you said you can't, don't know, or have no access, but \(teammate) has the tools for that. Delegate it now with delegate (a full spec), telling the user in a few words that it's being looked into; or, if it truly needs no tool and can't be known, say so plainly without mentioning tools."
    }

    /// The answer says it can't, doesn't know, or has no access ("I don't have access to the
    /// weather", "I can't check that", "I'm not able to browse").
    public static func claimsInability(_ answer: String) -> Bool {
        let a = answer.lowercased().replacingOccurrences(of: "’", with: "'")
        return a.range(of: #"\b(i (can't|cannot|can not|don't|do not|couldn't|won't be able to|am not able to|am unable to|'m not able to|'m unable to|have no|don't have|do not have)( currently| really| actually)? (access|browse|search|check|look|see|open|read|run|know|tell|find|get|reach|verify|confirm|fetch|retrieve|provide|do)|no (way|access|ability) to (check|browse|search|look|see|open|read|run|know|tell|find|get|reach|verify)|i don't know\b|i'm not sure\b|i have no (way|idea|access|information)|not (able|possible) (for me )?to (check|browse|search|look|see|open|read|run|know|tell|find|get|access)|as an ai\b|i lack (access|the ability)|i'm (just|only) (a|an) (voice|ai|language|assistant)|real[- ]time (data|information|access))"#,
                       options: .regularExpression) != nil
    }

    /// What Jane is told: she reviews one job that came back, and tells Jerry what to do differently.
    public static func reviewerPrompt(me: String = Team.reviewer, lead: String = Assistant.name, worker: String = Team.teammate) -> String {
        """
        You are \(me), the reviewer. \(lead), the supervisor, handed \(worker), the worker, a job; \(worker)'s result \
        didn't satisfy \(lead), who sent it back and escalated to you. You see only the job: what the user asked \
        just before, \(lead)'s spec and messages, what \(worker) said as he worked, which tools he used, and what \
        he brought back. Be suspicious of how intelligent and systematic the two of them are being: did \(worker) \
        read the spec, or guess? Did he check his result against the done criteria before finishing, or stop too \
        early? Did he use the right tools, in the right order, and read what they gave him? Did he assume what he \
        should have looked up or asked? Is \(lead)'s spec itself vague, and what should \(worker) take it to mean? \
        Then instruct \(worker): concretely, what to do differently this time, step by step, and what to check \
        before he finishes. A short paragraph, plain words, no markdown: it's read out loud in your voice and the \
        user hears it. You don't do the work yourself (you have no tools), you don't talk to the user, and you don't \
        praise: find the flaw. Then you leave.
        """
    }

    /// When nothing's been said for a while, what Tom is asked before the app stands down.
    public static func idleQuestion(minutes: String, openJobs: String) -> String {
        "Nothing from the user for \(minutes). Open jobs: \(openJobs). Is anything still owed to the user (a job not delivered, something you said you'd do, a question of theirs unanswered)? If so, answer with the word (hold) and then a sentence of status for them; else answer (nothing) and the app stands down."
    }

    /// Tom's answer says to hold on (work is pending): "(hold) The search is still running."
    public static func isHold(_ answer: String) -> Bool {
        answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .range(of: #"^[\(\[]?\s*hold(ing)?(\s+on)?\s*[\)\]:,.]?"#, options: .regularExpression) != nil
    }

    /// Tom's answer without its "(hold)" marker: what's read to the user.
    public static func withoutHold(_ answer: String) -> String {
        answer.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^[\(\[]?\s*hold(ing)?(\s+on)?\s*[\)\]:,.]?\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
    }

    /// A message from a teammate, as the model gets it (not the user).
    static func message(_ text: String, from: String, toWorker: Bool = false) -> String {
        toWorker ? "Message from \(from), your teammate (the user heard it read out too; work it with your tools, and end with finish or ask_\(from.lowercased())):\n\(text)"
            : "Message from \(from), your teammate (the user heard it read out too; answer him, or the user):\n\(text)"
    }

    /// Something said between the others, as the model gets it: context, no answer wanted.
    static func overheard(_ text: String, from: String, to: String) -> String {
        "(Overheard, no answer wanted: \(from) said to \(to): “\(text)”)"
    }

    /// The answer says nothing is to be said: "(nothing)", "nothing.", "[silence]".
    public static func isSilent(_ answer: String) -> Bool {
        answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .range(of: #"^[\(\[]?\s*(nothing|silence|silent|no reply|no answer|no response|none|no action( needed| required)?|nothing (to (say|add|do|report))|nothing needed)\s*[\)\]]?[.!]?$"#, options: .regularExpression) != nil
    }
}
