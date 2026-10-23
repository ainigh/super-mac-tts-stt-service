import AppKit
import SwiftUI
import VoiceCore

/// Column 2: the team (who's doing what), the jobs, the skills (each switched on or off; the
/// model is told only about those on), and the scripts Tool Mac Tool Run has, which are how Jerry
/// reaches the Mac. Click a skill to see what it did.
struct SkillsColumn: View {
    @ObservedObject var board = SkillsModel.shared
    @ObservedObject var assistant = AssistantModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    team
                    jobs
                    skills
                    scripts
                    hints
                }
            }
            if let notice = board.notice {
                Text(notice).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.green)
            }
        }
        .padding(16)
    }

    // MARK: The team

    private var team: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(assistant.teamOn ? "The team" : Assistant.name)
            MemberRow(name: Assistant.name, role: assistant.teamOn ? "The face: understands you, hands every request on, says where it stands" : "Talks with you, with the skills below",
                      state: assistant.thinking ? "Thinking" : (assistant.speaking == Assistant.name ? "Speaking" : nil),
                      model: assistant.modelName, tint: Palette.violet)
            if assistant.teamOn {
                MemberRow(name: Team.teammate, role: "The engine: runs your scripts (the browser, files, the Mac) and looks things up in the library",
                          state: assistant.board.current(for: Team.teammate).map { "On \($0.id): \($0.spec.goal)" } ?? (assistant.speaking == Team.teammate ? "Speaking" : nil),
                          model: assistant.jerryModelName, tint: Palette.teal)
                MemberRow(name: Team.reviewer, role: "The brain: answers what takes knowing or judging, and reviews a job sent back",
                          state: assistant.board.current(for: Team.reviewer).map { "On \($0.id): \($0.spec.goal)" } ?? (assistant.janeThinking ? "Reviewing" : (assistant.speaking == Team.reviewer ? "Speaking" : nil)),
                          model: assistant.janeModelName, tint: Palette.orange)
            }
        }
    }

    // MARK: The jobs

    @ViewBuilder private var jobs: some View {
        let open = assistant.board.open
        let done = assistant.board.jobs.filter { !$0.status.isOpen }.sorted { $0.number > $1.number }.prefix(3)
        if assistant.teamOn, !open.isEmpty || !done.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    SectionTitle("Jobs")
                    Spacer()
                    Text(open.isEmpty ? "none open" : "\(open.count) open").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Details") { Windows.show(.assistant) }.buttonStyle(.borderless).font(.system(size: 11))
                        .help("The jobs in full (spec, result, tools, log), in AI Listen's window")
                }
                ForEach(open) { JobLine(job: $0) }
                ForEach(Array(done)) { JobLine(job: $0) }
            }
        }
    }

    // MARK: The skills

    private var skills: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle("Skills")
            Text("What \(assistant.teamOn ? Team.teammate : Assistant.name) can use. Everything on the Mac goes through your scripts, each run waiting for your click. Click one to see what it did.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(Skills.all) { skill in
                SkillRow(skill: skill, on: board.isOn(skill), count: board.count(skill), selected: board.selected == skill.id,
                         missing: board.isOn(skill) ? board.missing(skill) : nil,
                         toggle: { board.set(skill, on: $0) },
                         select: { board.selected = board.selected == skill.id ? nil : skill.id })
            }
        }
    }

    // MARK: Tool Mac Tool Run's scripts

    @ViewBuilder private var scripts: some View {
        if board.isOn(Skills.scripts) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    SectionTitle("Scripts on this Mac")
                    Spacer()
                    if let c = assistant.catalog {
                        Text("\(c.scripts.count) scripts, \(c.flows.count) flows").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Button { assistant.refreshCatalog() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Ask Tool Mac Tool Run again what it has")
                }
                if let c = assistant.catalog, !c.isEmpty {
                    ForEach(c.scripts) { s in
                        CatalogRow(name: s.name, does: s.does, symbol: s.group == "browser" ? "safari" : s.group == "utilities" ? "wrench.adjustable" : "terminal",
                                   warning: s.dangers.isEmpty ? nil : s.dangers.joined(separator: ", "))
                    }
                    ForEach(c.flows) { f in CatalogRow(name: f.name, does: f.does, symbol: "arrow.triangle.branch", warning: nil) }
                } else {
                    Text(assistant.catalogProblem ?? "Asked as AI Listen starts.").font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var hints: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionTitle("Always there")
            Hint(word: Assistant.wakeWords[0][0], does: assistant.alwaysListen ? "starts it (always listening is on)" : "starts it, with Listen on")
            Hint(word: "stop · new chat · goodbye", does: "while it's on")
            Hint(word: "stop everything", does: "stops the voices, every job and every run")
            if assistant.settings.wave {
                Hint(word: "a wave", does: assistant.alwaysListen ? "at the camera starts it" : "starts it, with Listen on")
            }
            Text((assistant.settings.bargeIn ? "Talk over an answer to stop it. " : "") + "Off after \(AssistantModel.clock(assistant.settings.idleSeconds)) with nothing said.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One of the team: who, what they're for, what they're doing, their model.
private struct MemberRow: View {
    var name: String
    var role: String
    var state: String?
    var model: String
    var tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(state == nil ? tint.opacity(0.35) : tint).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 13, weight: .semibold))
                    Text(model).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Text(role).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let state {
                    Text(state).font(.system(size: 11, weight: .medium)).foregroundStyle(tint).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

/// A job in a line: its id, whose it is, where it stands, its goal.
private struct JobLine: View {
    var job: Job

    var body: some View {
        HStack(spacing: 6) {
            Text(job.id).font(.system(size: 11, weight: .semibold, design: .monospaced))
            Text(job.assignee).font(.system(size: 10)).foregroundStyle(job.spec.isQuestion ? Palette.orange : Palette.teal)
            Text(job.status.title).font(.system(size: 10)).foregroundStyle(color)
            Text(job.spec.goal).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .help(job.result.map { "\(job.spec.goal)\n\nResult: \($0.summary)" } ?? job.spec.text)
    }

    private var color: Color {
        switch job.status {
        case .queued: return .secondary
        case .running: return Palette.teal
        case .awaitingApproval, .blocked: return Palette.orange
        case .done: return Palette.green
        case .failed: return Palette.red
        }
    }
}

/// A script or flow Tool Mac Tool Run has.
private struct CatalogRow: View {
    var name: String
    var does: String
    var symbol: String
    var warning: String?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(Palette.blue).frame(width: 14).padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 11, weight: .semibold, design: .monospaced)).lineLimit(1)
                if !does.isEmpty { Text(does).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2) }
                if let warning { Text(warning).font(.system(size: 10)).foregroundStyle(Palette.red).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
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
        return "Nothing yet. Say “\(Assistant.wakeWords[0][0])”, then ask: “what page is open in my browser?”, “run my backup”, “what are the five senses?”, “note: call Sam at four”."
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
