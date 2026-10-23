import AppKit
import Combine
import Foundation
import VoiceCore

/// The columns beside the panel, always out: the team, its jobs, the skills (each switched on or
/// off) and the scripts Tool Mac Tool Run has (column 2); what they used (column 3, newest first,
/// this session); and one of those opened in full (column 4). On the main thread.
final class SkillsModel: ObservableObject {
    static let shared = SkillsModel()

    /// The skills that are on.
    @Published private(set) var enabled: Set<String>
    /// What the model used, newest first.
    @Published private(set) var uses: [ToolUse] = []
    /// A skill clicked in column 2: column 3 shows only what it did.
    @Published var selected: String?
    /// What's open in column 4.
    @Published var opened: ToolUse?
    /// A line saying what just happened ("Copied").
    @Published private(set) var notice: String?

    private let defaults = UserDefaults.standard
    private var noticeClear: DispatchWorkItem?
    static let maxUses = 200

    private init() {
        let saved = UserDefaults.standard
        // Only the skills there still are (the browser, files and the rest went to Tool Mac Tool Run).
        var on = Set(saved.stringArray(forKey: "skillsOn") ?? Skills.ids).intersection(Skills.ids)
        // Jerry came after the skills were first saved: he's on once, until switched off.
        if !saved.bool(forKey: "skillTeamAdded") {
            on.insert(Skills.team.id)
            saved.set(true, forKey: "skillTeamAdded")
        }
        // Scripts are how Jerry reaches the Mac now: on once, until switched off.
        if !saved.bool(forKey: "skillScriptsMain") {
            on.insert(Skills.scripts.id)
            saved.set(true, forKey: "skillScriptsMain")
        }
        saved.set(Array(on).sorted(), forKey: "skillsOn")
        enabled = on
    }

    /// Columns 2 and 3 show: always.
    var showsColumns: Bool { true }
    /// Column 4 shows.
    var showsDetail: Bool { opened != nil }

    func isOn(_ skill: Skill) -> Bool { enabled.contains(skill.id) }

    func set(_ skill: Skill, on: Bool) {
        if on { enabled.insert(skill.id) } else { enabled.remove(skill.id) }
        defaults.set(Array(enabled).sorted(), forKey: "skillsOn")
        say(on ? "\(skill.title) on" : "\(skill.title) off: the model won't use it")
        AssistantModel.shared.skillsChanged()
    }

    /// Why a skill that's on can't be used yet, if it can't.
    func missing(_ skill: Skill) -> String? {
        switch skill.id {
        case Skills.scripts.id:
            if AssistantModel.shared.settings.toolRunURL.trimmingCharacters(in: .whitespaces).isEmpty {
                return "Set Tool Mac Tool Run's address in AI Listen's settings"
            }
            return AssistantModel.shared.catalogProblem
        default:
            return nil
        }
    }

    /// How many times the model used it this session.
    func count(_ skill: Skill) -> Int { uses.filter { $0.skill?.id == skill.id }.count }

    /// Column 3: what was used (by the skill clicked, when one is).
    var shown: [ToolUse] {
        guard let selected else { return uses }
        return uses.filter { $0.skill?.id == selected }
    }

    func record(_ use: ToolUse) {
        uses.insert(use, at: 0)
        if uses.count > Self.maxUses { uses.removeLast(uses.count - Self.maxUses) }
    }

    func clearUses() {
        uses = []
        opened = nil
    }

    // MARK: Options

    func copy(_ text: String) {
        Service.shared.copy(text)
        say("Copied")
    }

    func openLink(_ use: ToolUse) {
        guard let url = use.link else { return }
        NSWorkspace.shared.open(url)
        say("Opened \(url.host ?? url.absoluteString) in your browser")
    }

    private func say(_ s: String?) {
        noticeClear?.cancel()
        notice = s
        guard let s else { return }
        let clear = DispatchWorkItem { [weak self] in if self?.notice == s { self?.notice = nil } }
        noticeClear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: clear)
    }
}
