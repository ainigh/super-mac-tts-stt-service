import Foundation

/// Reads audio as 16 kHz mono samples, a piece at a time, so a long file is never all in memory.
public protocol AudioReader: AnyObject {
    /// The whole audio's length in seconds.
    var duration: Double { get }
    /// Up to `maxFrames` more samples (16 kHz mono); empty at the end.
    func read(maxFrames: Int) throws -> [Float]
}

/// Audio already in memory, at any rate: hands it out at 16 kHz.
public final class SampleReader: AudioReader {
    private let samples: [Float]
    private var position = 0

    public init(samples: [Float], rate: Double) {
        self.samples = rate == Double(PCM.listenRate) ? samples : PCM.resample(samples, from: rate, to: Double(PCM.listenRate))
    }

    public var duration: Double { Double(samples.count) / Double(PCM.listenRate) }

    public func read(maxFrames: Int) throws -> [Float] {
        guard position < samples.count, maxFrames > 0 else { return [] }
        let end = min(samples.count, position + maxFrames)
        defer { position = end }
        return Array(samples[position..<end])
    }
}

public enum AudioError: Error, Equatable {
    /// What couldn't be read, for the caller.
    case unreadable(String)
}

/// WAV in and out, raw PCM, and converting rates.
public enum PCM {
    /// What the voices make.
    public static let speakRate = 24_000
    /// What the recognizer takes.
    public static let listenRate = 16_000

    /// 16-bit little-endian PCM of `samples` (clipped to -1…1).
    public static func pcm16(_ samples: [Float]) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt8.self)
            for (i, s) in samples.enumerated() {
                let v = Int16(max(-1, min(1, s)) * 32767)
                let u = UInt16(bitPattern: v)
                out[i * 2] = UInt8(u & 0xff)
                out[i * 2 + 1] = UInt8(u >> 8)
            }
        }
        return data
    }

    /// A WAV header for 16-bit mono PCM. `frames` nil: a stream of unknown length (the length
    /// fields are set to the maximum, which players take to mean "until it ends").
    public static func wavHeader(rate: Int, frames: Int?) -> Data {
        let dataBytes: UInt32 = frames.map { UInt32(clamping: $0 * 2) } ?? 0xFFFF_FFFF
        let riffBytes: UInt32 = frames == nil ? 0xFFFF_FFFF : dataBytes &+ 36
        var h = Data()
        h.append(contentsOf: Array("RIFF".utf8))
        h.append(le: riffBytes)
        h.append(contentsOf: Array("WAVEfmt ".utf8))
        h.append(le: UInt32(16))
        h.append(le: UInt16(1))               // PCM
        h.append(le: UInt16(1))               // mono
        h.append(le: UInt32(rate))
        h.append(le: UInt32(rate * 2))        // bytes per second
        h.append(le: UInt16(2))               // bytes per frame
        h.append(le: UInt16(16))              // bits
        h.append(contentsOf: Array("data".utf8))
        h.append(le: dataBytes)
        return h
    }

    public static func wav(_ samples: [Float], rate: Int) -> Data {
        wavHeader(rate: rate, frames: samples.count) + pcm16(samples)
    }

    /// Reads a WAV (16-bit, 24-bit or 32-bit integer PCM, or 32-bit float; any rate; channels mixed
    /// down): its samples and rate. nil when it isn't a WAV this understands.
    public static func readWAV(_ data: Data) -> (samples: [Float], rate: Double)? {
        let b = [UInt8](data)
        guard b.count >= 12, String(bytes: b[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: b[8..<12], encoding: .ascii) == "WAVE" else { return nil }
        var format = 0, channels = 0, rate = 0, bits = 0
        var i = 12
        while i + 8 <= b.count {
            let id = String(bytes: b[i..<(i + 4)], encoding: .ascii) ?? ""
            var size = Int(u32(b, i + 4))
            let start = i + 8
            if id == "fmt ", start + 16 <= b.count {
                format = Int(u16(b, start))
                channels = Int(u16(b, start + 2))
                rate = Int(u32(b, start + 4))
                bits = Int(u16(b, start + 14))
                if format == 0xFFFE, start + 26 <= b.count { format = Int(u16(b, start + 24)) }  // extensible
            } else if id == "data" {
                guard channels > 0, rate > 0, bits > 0 else { return nil }
                if size == 0xFFFF_FFFF || start + size > b.count { size = b.count - start }  // a stream
                let width = bits / 8
                let frame = width * channels
                guard frame > 0 else { return nil }
                let frames = size / frame
                var out = [Float](repeating: 0, count: frames)
                for f in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels {
                        let p = start + f * frame + c * width
                        switch (format, bits) {
                        case (1, 16): sum += Float(Int16(bitPattern: u16(b, p))) / 32768
                        case (1, 24):
                            let v = Int32(b[p]) | Int32(b[p + 1]) << 8 | Int32(Int8(bitPattern: b[p + 2])) << 16
                            sum += Float(v) / 8_388_608
                        case (1, 32): sum += Float(Int32(bitPattern: u32(b, p))) / 2_147_483_648
                        case (1, 8): sum += (Float(b[p]) - 128) / 128
                        case (3, 32): sum += Float(bitPattern: u32(b, p))
                        default: return nil
                        }
                    }
                    out[f] = sum / Float(channels)
                }
                return (out, Double(rate))
            }
            i = start + size + (size & 1)
        }
        return nil
    }

    /// Raw 16-bit little-endian PCM, `channels` interleaved, mixed down to mono.
    public static func readPCM16(_ data: Data, channels: Int) -> [Float] {
        let b = [UInt8](data)
        let ch = max(1, channels)
        let frames = b.count / (2 * ch)
        var out = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var sum: Float = 0
            for c in 0..<ch { sum += Float(Int16(bitPattern: u16(b, (f * ch + c) * 2))) / 32768 }
            out[f] = sum / Float(ch)
        }
        return out
    }

    /// Linear-interpolated change of rate (good enough for speech going to a recognizer).
    public static func resample(_ samples: [Float], from: Double, to: Double) -> [Float] {
        guard from > 0, to > 0, from != to, !samples.isEmpty else { return samples }
        let count = Int((Double(samples.count) * to / from).rounded())
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        let step = from / to
        for i in 0..<count {
            let x = Double(i) * step
            let j = Int(x)
            let t = Float(x - Double(j))
            let a = samples[min(j, samples.count - 1)]
            let b = samples[min(j + 1, samples.count - 1)]
            out[i] = a + (b - a) * t
        }
        return out
    }

    /// The loudest sample's size, 0 to 1.
    public static func peak(_ samples: ArraySlice<Float>) -> Float {
        var p: Float = 0
        for s in samples { p = max(p, abs(s)) }
        return p
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        guard i + 1 < b.count else { return 0 }
        return UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 3 < b.count else { return 0 }
        return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}

extension Data {
    mutating func append<T: FixedWidthInteger>(le value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

extension PCM {
    /// The file extension the first bytes of an audio file say it has ("wav", "mp3", "m4a"…), so
    /// the platform's reader knows what it's opening; "" when they don't say.
    public static func sniffExtension(_ head: Data) -> String {
        let b = [UInt8](head.prefix(16))
        func text(_ from: Int, _ count: Int) -> String {
            guard b.count >= from + count else { return "" }
            return String(bytes: b[from..<(from + count)], encoding: .ascii) ?? ""
        }
        if text(0, 4) == "RIFF" { return "wav" }
        if text(0, 4) == "FORM" { return text(8, 4) == "AIFC" ? "aifc" : "aiff" }
        if text(0, 4) == "caff" { return "caf" }
        if text(0, 4) == "fLaC" { return "flac" }
        if text(0, 4) == "OggS" { return "ogg" }
        if text(4, 4) == "ftyp" {
            let brand = text(8, 4).lowercased()
            return brand.hasPrefix("qt") ? "mov" : brand.hasPrefix("m4a") || brand.hasPrefix("m4b") ? "m4a" : "mp4"
        }
        if text(0, 3) == "ID3" { return "mp3" }
        if b.count >= 2, b[0] == 0xFF, b[1] & 0xE0 == 0xE0 {
            return b[1] & 0x06 == 0 ? "aac" : "mp3"       // ADTS AAC has layer bits 00
        }
        return ""
    }
}
