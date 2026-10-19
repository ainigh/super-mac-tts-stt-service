import Foundation

/// One of the voices: Kokoro-82M's best three women's and three men's, by its own quality grades.
/// The short names (f1…f3, m1…m3) mean the same voices as in glassvoice and never change.
public struct Voice: Equatable, Sendable {
    public var id: String
    public var name: String
    public var female: Bool
    public var alias: String

    /// "us" or "uk", from the id's first letter.
    public var accent: String { id.hasPrefix("b") ? "uk" : "us" }
    public var gender: String { female ? "female" : "male" }

    public static let all: [Voice] = [
        Voice(id: "af_heart", name: "Heart", female: true, alias: "f1"),
        Voice(id: "af_bella", name: "Bella", female: true, alias: "f2"),
        Voice(id: "bf_emma", name: "Emma", female: true, alias: "f3"),
        Voice(id: "am_michael", name: "Michael", female: false, alias: "m1"),
        Voice(id: "am_fenrir", name: "Fenrir", female: false, alias: "m2"),
        Voice(id: "am_puck", name: "Puck", female: false, alias: "m3"),
    ]

    public static let fallback = all[0]

    /// The voice with this id, or Heart.
    public static func named(_ id: String?) -> Voice {
        all.first { $0.id == id } ?? fallback
    }

    /// What a caller asked for: an id ("af_heart"), a name ("Heart"), a short name ("f1", "m3"),
    /// "female" / "male", "uk" / "us". nil when it isn't one of them; nil or blank gives `default`.
    public static func resolve(_ asked: String?, default: Voice) -> Voice? {
        guard let asked, !asked.trimmingCharacters(in: .whitespaces).isEmpty else { return `default` }
        let key = asked.trimmingCharacters(in: .whitespaces).lowercased()
        switch key {
        case "female", "f", "woman": return all.first { $0.female }
        case "male", "m", "man": return all.first { !$0.female }
        case "uk", "british": return all.first { $0.accent == "uk" }
        case "us", "american": return all.first { $0.accent == "us" }
        default: return all.first { $0.id == key || $0.name.lowercased() == key || $0.alias == key }
        }
    }

    public var json: [String: Any] {
        ["id": id, "name": name, "gender": gender, "accent": accent, "alias": alias]
    }

    /// "Heart · woman": as a menu shows it.
    public var label: String { "\(name) · \(female ? "woman" : "man")\(accent == "uk" ? ", UK" : "")" }
}
