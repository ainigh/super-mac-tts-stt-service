import Foundation

/// A skill: something the model can do besides talk, as a few tools. Each is switched on or off on
/// the panel's column, and the model is told only about the ones that are on. The library skills
/// are the app's own; everything else on the Mac (the browser, files, the clipboard, the Mac's
/// state, sums, anything a script can do) comes from Tool Mac Tool Run, as the user's scripts and
/// flows, each run waiting for a click on the Mac.
public struct Skill: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var summary: String
    /// An SF Symbol.
    public var symbol: String
    /// It only looks: nothing on the Mac is changed.
    public var readOnly: Bool

    public init(id: String, title: String, summary: String, symbol: String, readOnly: Bool = true) {
        self.id = id
        self.title = title
        self.summary = summary
        self.symbol = symbol
        self.readOnly = readOnly
    }
}

public enum Skills {
    public static let library = Skill(id: "library", title: "Library", summary: "Looks up earlier chats, and the dictations, transcripts and notes in the library", symbol: "books.vertical.fill")
    public static let editing = Skill(id: "edit", title: "Library editing", summary: "Adds notes to the library and changes dictations, transcripts and notes when you ask (never chats; nothing is deleted)", symbol: "square.and.pencil", readOnly: false)
    public static let scripts = Skill(id: "scripts", title: "Scripts", summary: "Runs your scripts and flows through Tool Mac Tool Run: the browser, files, the clipboard, the Mac, sums, anything a script does (each run waits for you to click Run)", symbol: "terminal.fill", readOnly: false)
    /// The second assistant (see `Team`).
    public static let team = Skill(id: "team", title: Team.teammate, summary: "A second assistant, \(Team.teammate), with his own model and voice, who does the work: \(Assistant.name) hands him jobs and checks what comes back, and you hear them both (you talk to \(Assistant.name))", symbol: "person.2.fill")

    public static let all: [Skill] = [library, editing, scripts, team]
    public static var ids: [String] { all.map(\.id) }

    /// The tools of a skill.
    public static func tools(_ id: String, teammate: String = Team.teammate) -> [AssistantTools.Tool] {
        switch id {
        case team.id: return Team.tools(teammate: teammate)
        case library.id: return AssistantTools.library
        case editing.id: return AssistantTools.editing
        case scripts.id: return ToolRunTools.tools
        default: return []
        }
    }

    /// The skill a tool belongs to.
    public static func skill(for tool: String) -> Skill? {
        if JobTools.worker().contains(where: { $0.name == tool }) || JobTools.supervisor().contains(where: { $0.name == tool }) { return team }
        return all.first { s in tools(s.id).contains { $0.name == tool } }
    }

    /// What the system prompt says about the skills that are on (the tools' manual comes after).
    static func prompt(_ on: [String]) -> String {
        var p = ""
        if on.contains(library.id) {
            p += """
             You remember only this conversation. The user's earlier chats with you and their library (dictations, \
            transcripts of audio files, and notes) are on this Mac, and you can look them up with the tools. Don't look \
            anything up unless it's needed; never make up what a chat or an item says.
            """
        }
        if on.contains(editing.id) {
            p += """
             You can add notes to their library and change what's in it (never chats), but only when they ask you to; \
            say in a few words what you changed. Only a tool saves anything: never say something was added or \
            changed unless a tool's result says it was.
            """
        }
        if on.contains(scripts.id) {
            p += """
             The user also has Tool Mac Tool Run on this Mac, which runs their scripts and flows: that's how you reach \
            everything else on the Mac (the browser and the web, files, the clipboard, the Mac's state, sums): a \
            script for it is in the list you're given (or list_scripts); run it with run_script, with why (in the \
            user's words). A run comes back at once with a request id: nothing has run yet; a card on their Mac waits \
            for them to click Run (or Don't Run), and you can't click. Say it's waiting for their click; check_request \
            with the id tells you whether they clicked and how it went, and the Mac tells you too when it ends. Never \
            say it ran until a result says so, and never run anything they didn't ask for.
            """
        }
        return p
    }
}
