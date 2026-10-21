import AppKit
import SwiftUI
import VoiceCore

/// Column 2: the skills, each switched on or off (the model is told only about those on), your
/// sites to search, and the words that always work. Click a skill to see what it did.
struct SkillsColumn: View {
    @ObservedObject var board = SkillsModel.shared
    @ObservedObject var assistant = AssistantModel.shared
    @State private var newSite = ""
    @State private var search = SkillsModel.shared.searchTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Skills")
            Text("What \(Assistant.name) can use when you talk with it. All but editing and scripts only look. Click one to see what it did.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Skills.all) { skill in
                        SkillRow(skill: skill, on: board.isOn(skill), count: board.count(skill), selected: board.selected == skill.id,
                                 missing: board.isOn(skill) ? board.missing(skill) : nil,
                                 toggle: { board.set(skill, on: $0) },
                                 select: { board.selected = board.selected == skill.id ? nil : skill.id })
                    }
                    sitesSection.padding(.top, 8)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 5) {
                SectionTitle("Always there")
                Hint(word: Assistant.wakeWords[0][0], does: assistant.alwaysListen ? "starts it (always listening is on)" : "starts it, with Listen on")
                Hint(word: "stop · new chat · goodbye", does: "while it's on")
                Text("Talk over an answer to stop it. Off after \(AssistantModel.clock(assistant.settings.idleSeconds)) with nothing said.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let notice = board.notice {
                Text(notice).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.green)
            }
        }
        .padding(16)
    }

    /// The browser's search, and the sites it can search.
    private var sitesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Browser searches")
            HStack(spacing: 6) {
                TextField(SkillRunner.defaultSearch, text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit { board.setSearch(search) }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .help("Where web searches go, with {query} where the words go")
                Button("Set") { board.setSearch(search) }
                    .buttonStyle(.borderless)
                    .disabled(search == board.searchTemplate)
            }
            ForEach(board.sites) { site in
                SiteRow(site: site, remove: { board.removeSite(site) })
            }
            HStack(spacing: 6) {
                TextField("name https://…{query}", text: $newSite)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .onSubmit(addSite)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .help("A site the model can search in your browser: a name, then its search address with {query} where the words go")
                Button(action: addSite) { Image(systemName: "plus.circle.fill").font(.system(size: 15)) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Palette.violet)
                    .disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Pages open in your default browser. To let it read them in Safari, turn on Develop > Allow JavaScript from Apple Events (Chrome: View > Developer); otherwise it fetches the page to read it.")
                .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func addSite() {
        if board.addSite(newSite) { newSite = "" }
    }
}

private struct SkillRow: View {
    var skill: Skill
    var on: Bool
    var count: Int
    var selected: Bool
    var missing: String?
    var toggle: (Bool) -> Void
    var select: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: skill.symbol).font(.system(size: 12))
                .foregroundStyle(selected ? .white : (on ? Palette.violet : .secondary))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(skill.title).font(.system(size: 13, weight: .semibold))
                    if !skill.readOnly {
                        Text("CHANGES THINGS").font(.system(size: 8, weight: .bold))
                            .foregroundStyle(selected ? .white.opacity(0.85) : Palette.orange)
                    }
                    if count > 0 {
                        Text("\(count)").font(.system(size: 10, design: .rounded))
                            .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
                    }
                }
                Text(missing ?? skill.summary).font(.system(size: 10))
                    .foregroundStyle(selected ? .white.opacity(0.85) : (missing != nil ? Palette.orange : .secondary))
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(selected ? .white : (on ? .primary : .secondary))
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(get: { on }, set: toggle))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .help(on ? "On: the model may use it. Click to turn it off." : "Off: the model isn't told about it.")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(selected ? Palette.violet : Color.primary.opacity(hover ? 0.08 : 0.04)))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hover = $0 }
    }
}

private struct SiteRow: View {
    var site: Site
    var remove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Palette.blue)
            Text(site.name).font(.system(size: 12, weight: .semibold))
            Text(site.host).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if hover {
                Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove \(site.name)")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .onHover { hover = $0 }
        .help(site.template)
    }
}

private struct Hint: View {
    var word: String
    var does: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("“\(word)”").font(.system(size: 11, weight: .semibold))
            Text(does).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// Column 3: what the model used, newest first (only the skill clicked, when one is), and what
/// AI Listen is hearing.
struct ActivityColumn: View {
    @ObservedObject var board = SkillsModel.shared
    @ObservedObject var assistant = AssistantModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title)
                Spacer()
                if let id = board.selected, let skill = Skills.all.first(where: { $0.id == id }) {
                    Button { board.selected = nil } label: {
                        HStack(spacing: 3) { Text(skill.title); Image(systemName: "xmark") }
                    }
                    .buttonStyle(Chip(selected: true, tint: Palette.violet))
                } else if !board.uses.isEmpty {
                    Button("Clear") { board.clearUses() }.buttonStyle(.borderless).font(.system(size: 11))
                }
            }
            status
            let shown = board.shown
            if shown.isEmpty {
                Text(empty).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(shown.prefix(100)) { use in
                        UseRow(use: use, selected: board.opened?.id == use.id,
                               open: { board.opened = board.opened?.id == use.id ? nil : use },
                               copy: { board.copy(use.result) })
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var title: String { board.selected == nil ? "What it used" : "What it did" }

    private var empty: String {
        if board.selected != nil { return "Nothing with this skill yet." }
        return "Nothing yet. Say “\(Assistant.wakeWords[0][0])”, then ask: “search the web for tomorrow's weather”, “what's on my clipboard?”, “find my tax PDF”, “note: call Sam at four”."
    }

    /// AI Listen's state, and what it's hearing.
    @ViewBuilder private var status: some View {
        let hearing = assistant.on ? assistant.hearing : assistant.wakeHearing
        HStack(spacing: 6) {
            switch assistant.phase {
            case .off:
                Image(systemName: assistant.alwaysListen ? "ear" : "moon.zzz").foregroundStyle(.secondary)
                Text(assistant.alwaysListen ? "Listening for “\(Assistant.wakeWords[0][0])”" : "AI Listen is off").foregroundStyle(.secondary)
            case .listening:
                Image(systemName: "ear.fill").foregroundStyle(Palette.pink).symbolEffect(.pulse, isActive: true)
                Text("Listening…")
            case .thinking:
                ProgressView().controlSize(.small)
                Text("Thinking…")
            case .speaking:
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Palette.violet)
                    .symbolEffect(.variableColor.iterative, isActive: true)
                Text(assistant.settings.bargeIn ? "Speaking (talk over it to stop it)" : "Speaking…")
            }
            Spacer()
        }
        .font(.system(size: 12, weight: .medium))
        if !hearing.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "waveform").foregroundStyle(Palette.pink)
                    .symbolEffect(.variableColor.iterative, isActive: true)
                Text(hearing).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

private struct UseRow: View {
    var use: ToolUse
    var selected: Bool
    var open: () -> Void
    var copy: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: use.skill?.symbol ?? "wrench.and.screwdriver.fill").font(.system(size: 11))
                .foregroundStyle(Palette.violet).frame(width: 14).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(AssistantView.toolName(use.name).capitalizedFirst).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(Self.time.string(from: use.time)).font(.system(size: 10, design: .rounded)).foregroundStyle(.tertiary)
                }
                if !use.summary.isEmpty {
                    Text(use.summary).font(.system(size: 11)).foregroundStyle(Palette.violet).lineLimit(2)
                }
                Text(use.result).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
            }
            if hover {
                Button(action: copy) { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy what it got")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? Palette.violet.opacity(0.14) : Color.primary.opacity(hover ? 0.08 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? Palette.violet.opacity(0.6) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hover = $0 }
        .help("Click to see all of it")
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        f.dateStyle = .none
        return f
    }()
}

/// Column 4: one use in full: what was asked, and everything it got, to copy, open or hear.
struct UseDetailColumn: View {
    @ObservedObject var board = SkillsModel.shared
    @EnvironmentObject var service: Service

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let use = board.opened {
                HStack {
                    SectionTitle(AssistantView.toolName(use.name).capitalizedFirst)
                    Spacer()
                    Button { board.opened = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                if !use.summary.isEmpty {
                    Text(use.summary).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(4)
                }
                ScrollView {
                    Text(use.result.isEmpty ? "(nothing)" : use.result)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 8) {
                    Button("Copy") { board.copy(use.result) }
                        .buttonStyle(PillButton(tint: Palette.teal, filled: true))
                    if let link = use.link {
                        Button("Open \(link.host ?? "link")") { board.openLink(use) }
                            .buttonStyle(PillButton(tint: Palette.blue, filled: false))
                    }
                    Button("Read aloud") { service.reader.say(use.result, voice: service.voice, speed: service.settings.speed) }
                        .buttonStyle(PillButton(tint: .secondary, filled: false))
                    Spacer()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

extension String {
    /// "the library" → "The library".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
