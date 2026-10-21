import Foundation

/// The team: Tom, the assistant the user talks to, and Jerry, a second assistant (his own model,
/// his own voice) Tom brings in when the user asks. The three share one room: everything either
/// says is read out, the user hears it all and can cut in, and the two can go back and forth.
/// Tom talks to Jerry with a tool (`tell_jerry`), which ends his turn: what he says is read in
/// his voice first, and only once it's been heard does it reach Jerry, so the user can intercept.
/// Jerry's answers come back to Tom the same way. The user can talk to Jerry directly too, by name.
public enum Team {
    /// The second assistant.
    public static let teammate = "Jerry"
    /// His name as the recognizer tends to write it.
    public static let teammateWords: [[String]] = [["jerry"], ["gerry"], ["jeri"], ["jerri"], ["jerrie"]]

    /// How many times in a row the two may message each other with nothing from the user, before
    /// Tom is made to come back to the user.
    public static let maxHops = 6

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

    /// The tool Tom talks to Jerry with.
    public static func tools(teammate: String = Team.teammate) -> [AssistantTools.Tool] {
        let t = teammate.lowercased()
        return [AssistantTools.Tool(name: "tell_\(t)",
                                    description: "Says something to \(teammate), your teammate (another assistant, with his own model and voice), and hands him the floor: your message is read out loud (the user hears it), then \(teammate) works on it and his answer comes back to you as a message from him, which the user hears too. Use it only when the user asks you to involve \(teammate) (ask \(teammate), hand it to \(teammate), see what \(teammate) thinks, have \(teammate) do it, talk it over with \(teammate)). Anything you write before the call is read to the user first. Calling it ends your turn.",
                                    arguments: [("message", "string: what to say to \(teammate), in full, with everything he needs to know")])]
    }

    /// The tool names a model may use for `tell_jerry`.
    static func aliases(teammate: String = Team.teammate) -> [String: String] {
        let t = teammate.lowercased()
        return ["ask_\(t)": "tell_\(t)", t: "tell_\(t)", "message_\(t)": "tell_\(t)", "call_\(t)": "tell_\(t)", "hand_to_\(t)": "tell_\(t)",
                "send_to_\(t)": "tell_\(t)", "talk_to_\(t)": "tell_\(t)", "say_to_\(t)": "tell_\(t)", "\(t)_tell": "tell_\(t)",
                "delegate_to_\(t)": "tell_\(t)", "ask_teammate": "tell_\(t)", "tell_teammate": "tell_\(t)"]
    }

    /// What Tom is told about the team.
    static func leadPrompt(teammate: String) -> String {
        let t = teammate.lowercased()
        return """
         You work with \(teammate), a second assistant on this Mac with his own model and voice, as a team of two in one \
        room with the user: everyone hears everything that's said. The user talks to you. When they ask you to bring \
        \(teammate) in (ask \(teammate), hand it to \(teammate), see what \(teammate) thinks, have \(teammate) do it), \
        use tell_\(t) with everything he needs, and nothing else in that answer but what the user should hear first. \
        His answers come to you as messages marked from \(teammate) (the user heard them read out): then say what's \
        needed to the user, or carry on with \(teammate) through tell_\(t) if the user asked for that, or, if \
        \(teammate)'s answer already did the job, answer with only the word (nothing) and the user hears nothing more. \
        Never repeat what \(teammate) just said, never speak for him, never pretend to have asked him, and don't involve \
        him unless the user asks. Something marked overheard was said between the user and \(teammate): no answer is \
        wanted; it's for context.
        """
    }

    /// What Jerry is told about the team.
    static func memberPrompt(lead: String, me: String) -> String {
        """
         You work with \(lead), the assistant the user mostly talks to, as a team of two in one room with the user: \
        everything you say is read out loud in your own voice, and the user hears it. Messages come to you from \
        \(lead) (marked so) or from the user directly; answer whoever asked, and address \(lead) by name when you \
        answer him. Do what \(lead) hands you with your tools, then report what you found or did, briefly: a few \
        sentences at most, since it's all read out. Don't ask \(lead) to do things; if something's missing, say so and \
        do the rest. The user may cut in at any time. Something marked overheard was said between the user and \
        \(lead): no answer is wanted; it's for context.
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

    /// What Tom is told when he's gone back and forth with Jerry enough.
    static func tooManyHops(teammate: String, hops: Int) -> String {
        "Not now: you and \(teammate) have gone back and forth \(hops) times with nothing from the user. Tell the user where things stand, in a few words; message \(teammate) again only when they ask."
    }

    /// The answer says nothing is to be said: "(nothing)", "nothing.", "[silence]".
    public static func isSilent(_ answer: String) -> Bool {
        answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .range(of: #"^[\(\[]?\s*(nothing|silence|silent|no reply|no answer|no response|none)\s*[\)\]]?\.?$"#, options: .regularExpression) != nil
    }
}
