import Foundation

/// Turns audio of any length into timed text. It goes to the recognizer in pieces of under a
/// minute, each cut at the quietest moment near its end; silent pieces are skipped.
public struct LongTranscriber {
    public enum Event {
        /// Seconds written down so far, and in all.
        case progress(done: Double, total: Double)
        case segment(TimedText)
    }

    /// Seconds per piece, and how far back from a piece's end to look for a quiet place to cut.
    public var piece = 50.0
    public var search = 12.0
    /// A piece no louder than this is silence.
    public var silence: Float = 0.02

    public init() {}

    /// Writes down everything `reader` gives, telling `onEvent` as it goes (it may throw to stop).
    /// Returns every segment, in order.
    @discardableResult
    public func run(_ reader: AudioReader, engine: SpeechEngine,
                    onEvent: (Event) async throws -> Void = { _ in }) async throws -> [TimedText] {
        let rate = PCM.listenRate
        let pieceFrames = Int(piece * Double(rate))
        let total = reader.duration
        var segments: [TimedText] = []
        var buffer: [Float] = []
        var atEnd = false
        var offset = 0.0
        try await onEvent(.progress(done: 0, total: JSON.round(total)))
        while true {
            try Task.checkCancellation()
            while buffer.count < pieceFrames, !atEnd {
                let more = try reader.read(maxFrames: pieceFrames - buffer.count)
                if more.isEmpty { atEnd = true } else { buffer += more }
            }
            if buffer.isEmpty { break }
            let cut = atEnd && buffer.count <= pieceFrames ? buffer.count : Self.cutPoint(buffer, rate: rate, search: search)
            let piece = Array(buffer[..<cut])
            buffer.removeFirst(cut)
            let length = Double(piece.count) / Double(rate)
            if PCM.peak(piece[...]) > silence {
                let heard = try await engine.write(piece)
                for s in Captions.sentences(heard.text, words: heard.words, offset: offset, length: length) {
                    segments.append(s)
                    try await onEvent(.segment(s))
                }
            }
            offset += length
            try await onEvent(.progress(done: JSON.round(offset), total: JSON.round(max(total, offset))))
        }
        return segments
    }

    /// Where to end a piece that isn't the last: the quietest tenth of a second in its last
    /// `search` seconds.
    static func cutPoint(_ samples: [Float], rate: Int, search: Double) -> Int {
        let frame = max(1, rate / 10)
        let n = samples.count
        var levels: [Float] = []
        var start = 0
        while start + frame <= n {
            var sum: Float = 0
            for i in start..<(start + frame) { sum += samples[i] * samples[i] }
            levels.append(sum / Float(frame))
            start += frame
        }
        let from = max(0, levels.count - Int(search * 10))
        let cut = QuietCut.cut(levels: levels, from: from)
        return max(frame, min(n, cut * frame + frame / 2))
    }
}
