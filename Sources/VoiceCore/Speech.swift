import Foundation

/// Text as the voices read it: one sentence at a time.
public enum SpokenText {
    /// Splits text into sentences: at . ! ? … followed by a space (not after a short abbreviation
    /// like "e.g." or "Dr."), and at every line break. Pieces with no letter or digit are dropped.
    public static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var current = ""
            let chars = Array(line)
            var i = 0
            while i < chars.count {
                let c = chars[i]
                current.append(c)
                if ".!?…".contains(c) {
                    // Closing quotes and brackets belong to the sentence.
                    while i + 1 < chars.count, "\"'”’)]".contains(chars[i + 1]) {
                        i += 1
                        current.append(chars[i])
                    }
                    let atEnd = i + 1 >= chars.count
                    let spaceNext = !atEnd && chars[i + 1].isWhitespace
                    let nextWord = String(chars[(i + 1)...].drop(while: \.isWhitespace).prefix { !$0.isWhitespace })
                    if (spaceNext || atEnd) && !(c == "." && endsWithAbbreviation(current, next: nextWord)) {
                        push(&out, current)
                        current = ""
                    }
                }
                i += 1
            }
            push(&out, current)
        }
        return out
    }

    private static let abbreviations: Set<String> = ["e.g.", "i.e.", "etc.", "vs.", "mr.", "mrs.", "ms.", "dr.",
                                                     "st.", "no.", "approx.", "fig.", "p.m.", "a.m."]

    private static func endsWithAbbreviation(_ s: String, next: String) -> Bool {
        guard let last = s.split(whereSeparator: \.isWhitespace).last else { return false }
        let original = last.trimmingCharacters(in: CharacterSet(charactersIn: "(\"'"))
        let word = original.lowercased()
        // "No. 5" is a number; "No. I'm busy." is an answer.
        if word == "no." { return next.first?.isNumber == true }
        if abbreviations.contains(word) { return true }
        // A single capital and a dot ("J. Smith") is an initial.
        return original.count == 2 && original.first!.isUppercase
    }

    private static func push(_ out: inout [String], _ s: String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.contains(where: { $0.isLetter || $0.isNumber }) { out.append(t) }
    }

    /// The word being said `fraction` (0 to 1) of the way through saying `text`, when the time is
    /// spread over the words by their length. A UTF-16 range, as NSString counts.
    public static func wordRange(in text: String, at fraction: Double) -> NSRange? {
        var words: [NSRange] = []
        var start: String.Index?
        for i in text.indices {
            let inWord = text[i].isLetter || text[i].isNumber || ((text[i] == "'" || text[i] == "’") && start != nil)
            if inWord, start == nil { start = i }
            if !inWord, let s = start {
                words.append(NSRange(s..<i, in: text))
                start = nil
            }
        }
        if let s = start { words.append(NSRange(s..<text.endIndex, in: text)) }
        guard !words.isEmpty else { return nil }
        let total = words.reduce(0) { $0 + $1.length + 1 }
        var target = Double(total) * min(max(fraction, 0), 1)
        for w in words {
            target -= Double(w.length + 1)
            if target < 0 { return w }
        }
        return words.last
    }
}

/// A piece of a transcript: what was said, and when (seconds from the start).
public struct TimedText: Equatable, Codable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    public var json: [String: Any] {
        ["start": JSON.round(start), "end": JSON.round(end), "text": text]
    }
}

/// A word the recognizer heard, and when (seconds).
public struct TimedWord: Equatable, Sendable {
    public var word: String
    public var start: Double
    public var end: Double

    public init(word: String, start: Double, end: Double) {
        self.word = word
        self.start = start
        self.end = end
    }
}

/// Transcripts as files: plain text, SubRip (.srt) and WebVTT (.vtt) subtitles.
public enum Captions {
    public static func plain(_ segments: [TimedText]) -> String {
        segments.map(\.text).joined(separator: " ")
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func srt(_ segments: [TimedText]) -> String {
        segments.enumerated().map { i, s in
            "\(i + 1)\n\(stamp(s.start, comma: true)) --> \(stamp(s.end, comma: true))\n\(s.text)\n"
        }.joined(separator: "\n")
    }

    public static func vtt(_ segments: [TimedText]) -> String {
        "WEBVTT\n\n" + segments.map { s in
            "\(stamp(s.start, comma: false)) --> \(stamp(s.end, comma: false))\n\(s.text)\n"
        }.joined(separator: "\n")
    }

    /// 01:02:03,456 (SRT) or 01:02:03.456 (VTT).
    public static func stamp(_ seconds: Double, comma: Bool) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        let h = ms / 3_600_000, m = ms / 60_000 % 60, s = ms / 1000 % 60, f = ms % 1000
        return pad(h) + ":" + pad(m) + ":" + pad(s) + (comma ? "," : ".") + pad(f, 3)
    }

    /// 0:42, 12:05, 1:02:03: a time for people to read.
    public static func clock(_ seconds: Double) -> String {
        let t = Int(max(0, seconds))
        let h = t / 3600, m = t / 60 % 60, s = t % 60
        return h > 0 ? "\(h):\(pad(m)):\(pad(s))" : "\(m):\(pad(s))"
    }

    private static func pad(_ n: Int, _ width: Int = 2) -> String {
        let s = String(n)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    /// `text` (what was recognized) cut into sentences, each timed by its first and last word.
    /// Without word timings, the whole text is one piece spanning `offset` to `offset + length`.
    public static func sentences(_ text: String, words: [TimedWord], offset: Double, length: Double) -> [TimedText] {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return [] }
        guard !words.isEmpty else { return [TimedText(start: offset, end: offset + length, text: said)] }
        var out: [TimedText] = []
        var i = 0
        for sentence in SpokenText.sentences(said) {
            let count = max(1, sentence.split(whereSeparator: \.isWhitespace).count)
            let first = words[min(i, words.count - 1)]
            let last = words[min(i + count - 1, words.count - 1)]
            out.append(TimedText(start: offset + first.start, end: offset + last.end, text: sentence))
            i += count
        }
        return out
    }
}

/// Where to cut long audio into pieces a recognizer takes one at a time: at the quietest moment
/// near the end of each piece, so a word is rarely cut in half.
public enum QuietCut {
    /// `levels` is the loudness of consecutive short frames of one piece; the cut is the quietest
    /// frame at or after `from` (the last one if several are equally quiet, so pieces stay long).
    /// With nothing to search, the piece is kept whole.
    public static func cut(levels: [Float], from: Int) -> Int {
        let start = max(0, min(from, levels.count))
        guard start < levels.count else { return levels.count }
        var best = start
        for i in start..<levels.count where levels[i] <= levels[best] { best = i }
        return best
    }
}

/// Cuts live microphone audio (16 kHz mono) into phrases at the pauses, so each one can be written
/// down whole. Once someone speaks, every sample ends up in exactly one phrase; only quiet before
/// speech is dropped, all but a little of it (so the first word's start isn't clipped). A phrase
/// that runs on is cut at its quietest moment before it gets too long.
public struct PhraseCutter {
    public static let rate = 16_000
    /// Loudness is judged on frames this long (20 ms).
    static let frame = 320

    /// How long a pause ends a phrase.
    public var pause: Double
    /// The longest a phrase may get (the recognizer takes about 15 s at a time; longer is cut).
    public var longest: Double
    /// Quiet kept in front of speech.
    public var lead: Double = 0.3

    /// The open phrase so far.
    public private(set) var open: [Float] = []
    /// Someone spoke in the open phrase.
    public private(set) var spoke = false
    private var quietFrames = 0
    private var levels: [Float] = []        // per frame of `open`
    private var carry: [Float] = []         // samples short of a whole frame
    /// The background's loudness, followed slowly; speech is well above it.
    private var floor: Float = 0.003

    public init(pause: Double, longest: Double = 14) {
        self.pause = pause
        self.longest = longest
    }

    /// A finished phrase: its audio, and whether a pause ended it (rather than its length).
    public struct Phrase: Equatable {
        public var samples: [Float]
        public var paused: Bool
    }

    /// Adds what the microphone heard; returns the phrases it finished, oldest first.
    public mutating func add(_ samples: [Float]) -> [Phrase] {
        var done: [Phrase] = []
        carry += samples
        var i = 0
        while i + Self.frame <= carry.count {
            let chunk = Array(carry[i..<(i + Self.frame)])
            i += Self.frame
            if let phrase = addFrame(chunk) { done.append(phrase) }
        }
        carry.removeFirst(i)
        return done
    }

    /// Ends the open phrase now (listening stopped): it, if anything was said.
    public mutating func flush() -> [Float]? {
        open += carry
        carry = []
        defer { reset() }
        return spoke ? open : nil
    }

    /// Forgets the open phrase.
    public mutating func reset() {
        carry = []
        startOver()
    }

    private mutating func startOver() {
        open = []
        levels = []
        spoke = false
        quietFrames = 0
    }

    public static func rms(_ frame: ArraySlice<Float>) -> Float {
        guard !frame.isEmpty else { return 0 }
        var sum: Float = 0
        for x in frame { sum += x * x }
        return (sum / Float(frame.count)).squareRoot()
    }

    /// Louder than this counts as speech.
    var threshold: Float { max(0.006, floor * 3.5) }

    private mutating func addFrame(_ chunk: [Float]) -> Phrase? {
        let level = Self.rms(chunk[...])
        let loud = level > threshold
        // The floor drops quickly to quiet and rises slowly with steady background noise; speech
        // doesn't move it.
        if level < floor {
            floor = floor * 0.9 + level * 0.1
        } else if !loud {
            floor = min(0.015, floor * 0.99 + level * 0.01)
        }
        open += chunk
        levels.append(level)
        if loud {
            spoke = true
            quietFrames = 0
        } else {
            quietFrames += 1
        }
        let frameSeconds = Double(Self.frame) / Double(Self.rate)
        if !spoke {
            // Only quiet so far: keep just the lead.
            let keep = max(1, Int((lead / frameSeconds).rounded()))
            if levels.count > keep {
                let drop = levels.count - keep
                levels.removeFirst(drop)
                open.removeFirst(drop * Self.frame)
            }
            return nil
        }
        if Double(quietFrames) * frameSeconds >= pause {
            // The pause ends it (and stays in it: a soft word in it isn't lost).
            let phrase = Phrase(samples: open, paused: true)
            startOver()
            return phrase
        }
        if Double(levels.count) * frameSeconds >= longest {
            // Too long: cut at the quietest frame of its last third; the rest starts the next one.
            let from = levels.count * 2 / 3
            let cut = QuietCut.cut(levels: levels, from: from) + 1
            let phrase = Phrase(samples: Array(open[..<(cut * Self.frame)]), paused: false)
            open.removeFirst(cut * Self.frame)
            levels.removeFirst(cut)
            spoke = levels.contains { $0 > threshold }
            quietFrames = 0
            return phrase
        }
        return nil
    }
}
