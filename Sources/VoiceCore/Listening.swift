import Foundation

/// When what's being said is done. A pause ends it, unless what was said so far sounds like it's
/// going on ("…and", "…because the", "…to,"): then it waits a little longer for the rest, so a
/// breath mid-sentence doesn't send half a question.
public enum TurnEnd {
    /// How much longer it waits when it sounds unfinished, in seconds.
    public static let hold = 1.6

    /// Words a sentence doesn't end on: joining words, articles, prepositions, fillers.
    static let hanging: Set<String> = [
        "and", "or", "but", "so", "because", "cause", "if", "then", "than", "which", "who", "whose", "whom",
        "when", "where", "while", "whether", "although", "though", "unless", "until", "since", "nor",
        "the", "a", "an", "my", "your", "our", "their", "his", "its",
        "to", "of", "in", "on", "at", "for", "with", "without", "from", "into", "onto", "by", "between",
        "through", "over", "under", "after", "before", "per", "via", "versus",
        "is", "are", "was", "were", "i'm", "it's", "i", "we", "um", "uh", "er", "erm", "hmm", "also", "plus",
        "very", "really", "maybe",
    ]

    /// Said so far, does it sound like more is coming? A question mark or an exclamation ends it; a
    /// hanging word ends nothing (the recognizer puts a full stop after a pause whatever was said);
    /// a comma, a dash, a colon or no punctuation at all sounds unfinished.
    public static func unfinished(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last else { return false }
        if last == "?" || last == "!" { return false }
        let words = t.lowercased().replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        if let w = words.last, hanging.contains(w) { return true }
        if ",;:-–—…".contains(last) || t.hasSuffix("...") { return true }
        // A lone wake word or command is whole even without a full stop.
        if words.count <= 2 { return false }
        return !".!?\"”')".contains(last)
    }
}

/// While the answer is being read, the microphone stays open so the user can talk over it (barge
/// in). What comes back is then mostly the answer itself, heard through the speakers: this tells
/// that apart from the user.
public enum Echo {
    /// Words that stop it said first, even alone.
    static let bargeWords: Set<String> = ["stop", "wait", "mouse", "hold", "quiet", "pause", "enough"]
    /// Short words that tell nothing apart.
    static let stopWords: Set<String> = ["a", "an", "the", "and", "or", "of", "to", "in", "on", "at", "for", "is", "it",
                                         "i", "my", "me", "be", "was", "are", "this", "that", "with", "by", "as", "so", "s"]

    /// What was heard while `spoken` was being read: nil when it's only the answer coming back (or
    /// too little to tell); else what the user said, with the echo heard before it taken off.
    public static func interruption(_ heard: String, reading spoken: String) -> String? {
        let tokens = Assistant.tokens(heard)
        guard !tokens.isEmpty else { return nil }
        let echo = Set(Assistant.tokens(spoken).map(\.word))
        // "Stop", "wait, no": short and first, it's them, even when the answer has the word too.
        if tokens.count <= 2, bargeWords.contains(tokens[0].word) { return Assistant.text(heard, from: tokens[0].range.lowerBound) }
        // The echo before the user started.
        var start = 0
        while start < tokens.count, echo.contains(tokens[start].word) { start += 1 }
        guard start < tokens.count else { return nil }
        let rest = Array(tokens[start...])
        let said = Assistant.text(heard, from: rest[0].range.lowerBound)
        if bargeWords.contains(rest[0].word) { return said }
        let content = rest.filter { !stopWords.contains($0.word) }
        let fresh = content.filter { !echo.contains($0.word) }
        // Two new words at least, and most of what's left new: not the answer, misheard.
        guard fresh.count >= 2, Double(fresh.count) >= Double(max(content.count, 1)) * 0.5 else { return nil }
        return said
    }
}
