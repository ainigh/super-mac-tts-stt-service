import AppKit
import Combine
import Foundation
import VoiceCore

/// The Skills board beside the panel: what the model may use when you talk with it (column 2,
/// each switched on or off, and your sites to search), what it used (column 3, newest first, this
/// session), and one of those opened in full (column 4). It shows while AI Listen is on, or when
/// pinned (the rectangles button). On the main thread.
final class SkillsModel: ObservableObject {
    static let shared = SkillsModel()

    /// The skills that are on.
    @Published private(set) var enabled: Set<String>
    /// The sites the model can search, in the browser.
    @Published private(set) var sites: [Site]
    /// The web search, with {query} where the words go.
    @Published private(set) var searchTemplate: String
    /// The columns stay out even when AI Listen is off.
    @Published var pinned: Bool { didSet { defaults.set(pinned, forKey: "boardPinned") } }
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
    private var watching: Set<AnyCancellable> = []
    static let maxUses = 200

    private init() {
        let saved = UserDefaults.standard
        enabled = Set(saved.stringArray(forKey: "skillsOn") ?? Skills.ids)
        if let data = saved.data(forKey: "skillSites"), let s = try? JSONDecoder().decode([Site].self, from: data) {
            sites = s
        } else {
            sites = Site.defaults
        }
        searchTemplate = saved.string(forKey: "skillSearch") ?? SkillRunner.defaultSearch
        pinned = saved.bool(forKey: "boardPinned")
    }

    /// Columns 2 and 3 show.
    var showsColumns: Bool { pinned || AssistantModel.shared.on }
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
            return AssistantModel.shared.settings.toolRunURL.trimmingCharacters(in: .whitespaces).isEmpty
                ? "Set Tool Mac Tool Run's address in AI Listen's settings" : nil
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

    // MARK: Sites

    /// "wiki https://en.wikipedia.org/wiki/{query}": added, or why not.
    @discardableResult
    func addSite(_ line: String) -> Bool {
        guard let site = Site.parse(line) else {
            say("A site is one word, then its search address with {query} in it")
            return false
        }
        sites.removeAll { $0.name == site.name }
        sites.append(site)
        saveSites()
        say("Added \(site.name)")
        return true
    }

    func removeSite(_ site: Site) {
        sites.removeAll { $0 == site }
        saveSites()
    }

    func setSearch(_ template: String) {
        let t = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Site(name: "search", template: t).url(for: "test") != nil else {
            say("The search needs a web address, with {query} where the words go")
            return
        }
        searchTemplate = t
        defaults.set(t, forKey: "skillSearch")
        AssistantModel.shared.skillsChanged()
        say("Searches go to \(Site(name: "", template: t).host)")
    }

    private func saveSites() {
        if let data = try? JSONEncoder().encode(sites) { defaults.set(data, forKey: "skillSites") }
        AssistantModel.shared.skillsChanged()
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
