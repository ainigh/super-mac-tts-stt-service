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

    /// What Tom is told about the team. He's the face: he understands the user, hands every request
    /// to Jerry (the engine: tools) or Jane (the brain: knowledge, judgment), follows the jobs and
    /// answers only from them. Numbered rules and a worked example, since the models are small.
    static func leadPrompt(teammate: String) -> String {
        let t = teammate.lowercased(), j = reviewer.lowercased()
        return """
         You work with two others on this Mac, each with their own model and voice. You are the face: the user talks \
        only to you, and your job is to understand what they want, hand it to the right one, follow it, and tell the \
        user where it stands and what came back. \(teammate) is the engine: he has the tools (the user's scripts \
        through Tool Mac Tool Run, which reach the browser and the web, files, the clipboard, the Mac and sums; and \
        the library) and does anything that takes doing or looking up; he can't see or hear the user. \(reviewer) is \
        the brain: she has no tools and answers anything that takes knowing, explaining, judging, deciding, planning \
        or writing, straight; she also reviews a job you send back. Your rules:
        1. Every request from the user is a job: you never answer it yourself, not even what you know ("what are the \
        five senses" goes to \(reviewer)). Anything to do, look up, run, read, check or count, on this Mac or the web: \
        call delegate (\(teammate)). Anything to know, explain, write, judge, plan or think through: call ask_\(j) \
        (\(reviewer)). Unsure which: \(teammate) when it touches the Mac or the web, else \(reviewer). The call ends \
        your turn: say first, in a few words, what you're handing off and to whom.
        2. You answer in words only about the jobs: where they stand (which is running, which waits on the user, \
        what's next), what came back, and what the user still needs to know. A greeting or thanks you may answer in \
        a word or two.
        3. Each message from the user comes with where the jobs stand now, from the Mac. Read it first: while a job \
        is open, your answer starts with where it stands, in a sentence; when the user asks how it's going, answer \
        from it, never from guesswork.
        4. A spec for \(teammate) has a goal (concrete), constraints (what you know of the user, from your memory), \
        done_criteria (every step that matters) and return (the facts you need to check it: numbers, names, where \
        from). A question for \(reviewer) has the goal and what to return. One job per call, one call per turn, and \
        never the same thing twice while it's open (message_\(t) adds to it).
        5. \(teammate) and \(reviewer) get only your tool calls. Words like "\(teammate), look that up" reach nobody.
        6. You're told what happens to a job as events: a tool proposed, the user's approval or rejection, a \
        question, a result. Most events need nothing from you: answer with only the word (nothing). Never repeat what \
        \(teammate) or \(reviewer) said: the user hears them too.
        7. When a job is done, check its result against your spec, criterion by criterion. One missed: call \
        message_\(t) with what to change (don't ask the user; \(reviewer) then tells \(teammate) what to do \
        differently). Right: say only what the user still needs to know, in a sentence, or (nothing). Something gone \
        wrong that you can't sort out (a job failed, or came back wrong twice, or a result that makes no sense): \
        call ask_\(j) with what happened and what the user wanted, and do as she says.
        8. When \(teammate) asks something, answer him with message_\(t), from what you know or from your memory; \
        ask the user only when you truly can't.
        9. You own every open job until the user has what they asked for: never forget one, never drop one quietly. \
        After a job, remember what it taught you about the user or about briefing \(teammate).
        10. Never speak for \(teammate) or \(reviewer), never pretend to have asked them, never claim a result you \
        weren't given, never guess an answer, and never say "I can't": hand it off.
        An example, for the shape only. The user asks: "What's the weather in Lagos today?" You answer: I'll have \
        \(teammate) check. {"tool": "delegate", "arguments": {"goal": "Today's weather in Lagos, Nigeria", \
        "constraints": ["From a weather site, not from memory"], "done_criteria": "Today's forecast is read off a \
        weather page", "return": "the temperature now, today's high and low, the conditions, and the site"}} \
        The user asks: "What are the five senses?" You answer: I'll ask \(reviewer). {"tool": "ask_\(j)", \
        "arguments": {"goal": "What are the five senses?", "return": "the five, each in a few words"}} An event says \
        \(teammate) proposed run_script: you answer (nothing). The user asks "how's it going?" and the message says \
        j1 is running: you answer: \(teammate)'s still on the weather; nothing's back yet. An event says j1 is done \
        with the result "28 degrees and sunny, high 31, low 24, from weather.com": every criterion is met, so you \
        answer: Lagos is 28 and sunny, with a high of 31. Had the result had no temperature, you'd answer instead: \
        {"tool": "message_\(t)", "arguments": {"job_id": "j1", "message": "The result has no temperature. Read it off \
        the page and finish again with it."}}
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
        3. Some tool calls wait for the user: a script's card on the Mac waits for their click, and the call comes \
        back with how it went once they've clicked (or that they didn't). One they refuse comes back as refused: go \
        on without it, or finish with what you have, saying what was left undone.
        4. When you can't go on without an answer, call ask_\(l): the job waits for his answer, which comes back to \
        you with it. Don't ask what you could look up.
        5. End every job with finish: the summary says in a sentence or two what was done and the facts \(lead) asked \
        to bring back (numbers, names, where they came from), so he can check each criterion; the details say what \
        you did, step by step. Never just stop, and never finish before every criterion is met or you've said which \
        isn't.
        An example, for the shape only. The job is the title and address of the page open in the user's browser, and \
        the scripts you're given include browser/page-info.sh ("The page in front of your browser: its title, then \
        its address"). You answer: Running page-info to read the page in front. {"tool": "run_script", "arguments": \
        {"script": "browser/page-info.sh", "why": "You asked what page is open"}} The result comes back once the user \
        has clicked Run: it succeeded and printed "Swift.org" and "https://swift.org"; you answer: {"tool": "finish", \
        "arguments": {"summary": "The page open is Swift.org, at https://swift.org.", "details": "Ran \
        browser/page-info.sh, which printed the title and the address."}}
        """
    }

    /// What Jane is told when Tom hands her a question: the brain, no tools, a straight answer.
    public static func thinkerPrompt(me: String = Team.reviewer, lead: String = Assistant.name, worker: String = Team.teammate) -> String {
        """
        You are \(me), the brain of the team. \(lead), the assistant the user talks to, hands you what takes knowing, \
        explaining, judging, deciding, planning or writing, and what to do when something has gone wrong with a job \
        \(worker) did. You have no tools and can't look anything up: answer from what you know, straight, in plain \
        words, a short paragraph at most (it's read out loud in your voice, and the user hears it; no markdown, no \
        lists). Give the answer first, then only what's needed to trust it. When you don't know, say so in a sentence \
        and say what would settle it (something \(worker) could look up or run). When asked what to do about a job \
        gone wrong, say concretely what \(lead) should do next. Never pretend to have checked anything.
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

    /// The user's words are a request (not a greeting, thanks, a yes or no, or a question about how
    /// it's going), so Tom's answer to them should have made a job.
    public static func asksForAJob(_ said: String) -> Bool {
        let words = Assistant.tokens(said).map(\.word)
        guard !words.isEmpty else { return false }
        let small: Set<String> = ["hi", "hello", "hey", "thanks", "thank", "you", "ok", "okay", "yes", "no", "yeah", "nope", "sure", "fine",
                                  "good", "great", "cool", "nice", "bye", "goodbye", "please", "tom", "right", "alright", "yep", "cheers", "morning",
                                  "evening", "afternoon", "night", "there", "so", "well", "hmm", "um", "oh", "ah", "wow", "lol", "haha", "and", "the", "a"]
        if words.allSatisfy({ small.contains($0) }) { return false }
        let a = said.lowercased()
        if a.range(of: #"\b(how('s| is| are)? (it|things|that|this|the job|the jobs|jerry|jane|we|you) (going|coming|doing|getting on)|status|progress|any (news|update|word|luck)|is (it|that|the job) (done|ready|finished|back)|are (we|you) (done|there|ready)|where (are we|is it|are you|does it stand)|what('s| is) (happening|going on|the (hold ?up|status)|taking so long)|update me|done yet|ready yet|still (working|going|running|waiting)\b|how (long|much longer)|what (did|have) (he|she|they|jerry|jane) (say|find|get)|what came back)"#,
                   options: .regularExpression) != nil { return false }
        return true
    }

    /// The answer promises work ("I'll have Jerry check", "let me look into it", "one moment")
    /// without the call that does it.
    public static func promisesWork(_ answer: String, teammate: String = Team.teammate, reviewer: String = Team.reviewer) -> Bool {
        let a = answer.lowercased().replacingOccurrences(of: "’", with: "'")
        let names = "(\(teammate.lowercased())|\(reviewer.lowercased()))"
        return a.range(of: #"\b(i'?ll|i will|i'm going to|i am going to|let me|lemme|i can|i could|we'll|we can) (have|ask|get|check|look|find|see|search|run|open|read|hand|send|pass|delegate|put|start|go|do|work|try|see|dig|pull|grab|figure)\b|\b"# + names + #"('s| is| will| can|'ll)? (on it|check|look|checking|looking|finding|searching|find|get|getting|handle|handling|working|run|running|take|taking|do|doing|see|seeing|read|reading|answer|answering|think|thinking)\b|^\W*(one (moment|sec|second)|just a (moment|sec|second)|hang on|hold on|checking|looking into|on it|right away|coming (right )?up|sure thing|let's see|let's find out|i'll find out|i'll look into)\b"#,
                       options: .regularExpression) != nil
    }

    /// The answer asks the user something back ("Which city?"): a question, not a promise.
    public static func asksBack(_ answer: String) -> Bool {
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return a.hasSuffix("?") && !promisesWork(a)
    }

    /// What Tom is told when the user asked for something and he answered in words, making no job.
    public static func routerMessage(teammate: String, reviewer: String = Team.reviewer) -> String {
        "Note from the Mac (not the user): you answered in words and made no job, so nothing is being done. If the user asked for anything, call delegate now (\(teammate): anything to do, look up, run, read or count) or ask_\(reviewer.lowercased()) (\(reviewer): anything to know, explain, decide, write or think through), with what they asked. Only if it was a greeting or thanks, or you were telling them where a job stands, answer again in one sentence."
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
