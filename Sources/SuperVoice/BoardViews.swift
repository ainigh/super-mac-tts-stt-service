import AppKit
import SwiftUI
import VoiceCore

/// Column 2: the voice commands. A first word that's one of these files what follows under it;
/// click one to see what's filed under it.
struct CommandsColumn: View {
    @ObservedObject var board = BoardModel.shared
    @State private var newWord = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Voice commands")
            Text("Start with one of these to file what you say under it. Anything else goes under #note.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                TextField("Add a word", text: $newWord)
                    .textFieldStyle(.plain)
                    .onSubmit(addWord)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                Button(action: addWord) { Image(systemName: "plus.circle.fill").font(.system(size: 16)) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Palette.violet)
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(board.commands, id: \.self) { word in
                        CommandRow(word: word, count: board.count(word), active: isActive(word),
                                   select: { board.selectedTag = board.selectedTag == word ? nil : word },
                                   remove: { board.removeCommand(word) })
                    }
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 5) {
                SectionTitle("Always there")
                Hint(word: Board.wakeWord, does: "opens or closes this panel")
                Hint(word: "add · open · no · copy", does: "answer what's pending")
            }
            Toggle("Sounds", isOn: $board.sounds).toggleStyle(.checkbox).font(.system(size: 11))
        }
        .padding(16)
    }

    private func isActive(_ word: String) -> Bool {
        if let p = board.pending { return p.command == word }
        return board.selectedTag == word
    }

    private func addWord() {
        board.addCommand(newWord)
        newWord = ""
    }
}

private struct CommandRow: View {
    var word: String
    var count: Int
    var active: Bool
    var select: () -> Void
    var remove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble.fill").font(.system(size: 11)).foregroundStyle(active ? .white : Palette.violet)
            Text(word).font(.system(size: 13, weight: .semibold)).foregroundStyle(active ? .white : .primary)
            Spacer()
            if hover && !active {
                Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove “\(word)” (what's filed under it stays)")
            } else {
                Text("\(count)").font(.system(size: 11, design: .rounded)).foregroundStyle(active ? .white.opacity(0.85) : .secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(active ? Palette.violet : Color.primary.opacity(hover ? 0.08 : 0.04)))
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

/// Column 3: the pending entry on top (said or typed; edit it before adding), then the entries,
/// searched with it.
struct EntriesColumn: View {
    @ObservedObject var board = BoardModel.shared
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title)
                Spacer()
                if let tag = board.selectedTag, board.pending == nil {
                    Button { board.selectedTag = nil } label: {
                        HStack(spacing: 3) { Text("#\(tag)"); Image(systemName: "xmark") }
                    }
                    .buttonStyle(Chip(selected: true, tint: Palette.violet))
                }
            }
            pendingCard
            if board.listening, !board.hearing.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "waveform").foregroundStyle(Palette.pink)
                        .symbolEffect(.variableColor.iterative, isActive: true)
                    Text(board.hearing).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if let notice = board.notice {
                Text(notice).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.green)
            }
            let results = board.results
            if results.isEmpty {
                Text(board.pending == nil ? "Nothing here yet. Say something, or type it above." : "Nothing matches yet.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 6)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(results.prefix(200).enumerated()), id: \.element.id) { i, r in
                        EntryRow(record: r, top: board.pending != nil && i == 0,
                                 open: { board.open(r) }, copy: { board.copyText(r.text) }, delete: { board.delete(r) })
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var title: String {
        if board.pending != nil { return "Matches" }
        return board.selectedTag == nil ? "Entries" : "Filed under"
    }

    /// The pending entry: a field you can type in (what's said lands here too).
    private var pendingCard: some View {
        let p = board.pending
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("#\(p?.tag ?? Board.defaultTag)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(p == nil ? Color.secondary.opacity(0.5) : Palette.violet))
                Text(p == nil ? (board.listening ? "Listening: say something, or type" : "Type a new entry")
                              : "Not added yet: add, open, no or copy")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
            }
            TextField("New entry", text: $board.entry, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1...5)
                .focused($typing)
                .onSubmit { board.add() }
                .onExitCommand { board.no() }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Palette.violet.opacity(p == nil ? 0.04 : 0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Palette.violet.opacity(p == nil ? 0.2 : 0.7), style: StrokeStyle(lineWidth: 1.5, dash: p == nil ? [5, 4] : [])))
    }
}

private struct EntryRow: View {
    var record: LibraryRecord
    var top: Bool
    var open: () -> Void
    var copy: () -> Void
    var delete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let tag = record.tag {
                        Text("#\(tag)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.violet)
                    }
                    if top { Text("TOP MATCH").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.green) }
                    kindBadge
                    Spacer()
                    Text(record.created, style: .relative).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Text(record.text).font(.system(size: 13)).lineLimit(3)
            }
            if hover {
                VStack(spacing: 6) {
                    Button(action: copy) { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy")
                    Button(action: delete) { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete")
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(top ? Palette.green.opacity(0.1) : Color.primary.opacity(hover ? 0.08 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(top ? Palette.green.opacity(0.6) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hover = $0 }
        .help(help)
    }

    @ViewBuilder private var kindBadge: some View {
        switch Board.action(for: record.text) {
        case .browse: Image(systemName: "link").font(.system(size: 9)).foregroundStyle(Palette.blue)
        case .http(let method, _, _): Text(method).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(Palette.orange)
        case .show: EmptyView()
        }
    }

    private var help: String {
        switch Board.action(for: record.text) {
        case .browse: return "Click to open in your browser"
        case .http(let method, let url, _): return "Click to call \(method) \(url.absoluteString)"
        case .show: return "Click to open"
        }
    }
}

/// Column 4: the options for the pending entry, or what was opened.
struct OptionsColumn: View {
    @ObservedObject var board = BoardModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let p = board.pending {
                options(p)
            } else if let opened = board.opened {
                OpenedView(opened: opened)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func options(_ p: Board.Heard) -> some View {
        let top = board.top
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle("What now?")
            OptionButton(option: .add, title: "Add", detail: p.text.isEmpty ? "Say something after “\(p.tag)”" : "As a new entry under #\(p.tag)",
                         symbol: "plus.circle.fill", tint: Palette.violet, enabled: !p.text.isEmpty)
            OptionButton(option: .open, title: "Open", detail: top.map { describe($0) } ?? "Nothing matches",
                         symbol: "arrow.up.forward.app.fill", tint: Palette.blue, enabled: top != nil)
            OptionButton(option: .no, title: "No", detail: "Drop it", symbol: "xmark.circle.fill",
                         tint: .secondary, enabled: true)
            OptionButton(option: .copy, title: "Copy", detail: top.map { "The top match: \(String($0.text.prefix(60)))" } ?? "What you said",
                         symbol: "doc.on.doc.fill", tint: Palette.teal, enabled: true)
            Text(board.listening ? "Say the option, or click it." : "Click an option.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func describe(_ r: LibraryRecord) -> String {
        switch Board.action(for: r.text) {
        case .browse(let url): return "Open \(url.host ?? "the link") in your browser"
        case .http(let method, let url, _): return "Call \(method) \(url.host ?? "")\(url.path)"
        case .show: return "The top match: \(String(r.text.prefix(60)))"
        }
    }
}

private struct OptionButton: View {
    @ObservedObject var board = BoardModel.shared
    var option: Board.Option
    var title: String
    var detail: String
    var symbol: String
    var tint: Color
    var enabled: Bool
    @State private var hover = false

    var body: some View {
        Button { board.choose(option) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 14, weight: .semibold))
                        Text("say “\(option.rawValue)”").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(hover ? 0.16 : 0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hover = $0 }
    }
}

/// An opened entry (with Copy), or the answer to a GET / POST.
private struct OpenedView: View {
    @ObservedObject var board = BoardModel.shared
    @EnvironmentObject var service: Service
    var opened: BoardModel.Opened

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(heading)
                Spacer()
                Button { board.opened = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            switch opened {
            case .record(let r):
                if let tag = r.tag { Text("#\(tag)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.violet) }
                ScrollView {
                    Text(r.text).font(.system(size: 14)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    Button("Copy") { board.copyText(r.text) }.buttonStyle(PillButton(tint: Palette.teal, filled: true))
                    Button("Read aloud") { service.reader.say(r.text, voice: service.voice, speed: service.settings.speed) }
                        .buttonStyle(PillButton(tint: .secondary, filled: false))
                    Spacer()
                    Button { board.delete(r) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete")
                }
            case .http(let call):
                Text(call.request).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(3)
                HStack(spacing: 6) {
                    if call.running {
                        ProgressView().controlSize(.small)
                        Text("Calling…").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else if let error = call.error {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.red)
                        Text(error).font(.system(size: 12))
                    } else if let status = call.status {
                        Circle().fill((200..<300).contains(status) ? Palette.green : Palette.orange).frame(width: 8, height: 8)
                        Text("HTTP \(status)").font(.system(size: 12, weight: .semibold))
                    }
                }
                ScrollView {
                    Text(call.response.isEmpty && !call.running ? "(no body)" : call.response)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 8) {
                    Button("Copy") { board.copyText(call.response) }
                        .buttonStyle(PillButton(tint: Palette.teal, filled: true))
                        .disabled(call.response.isEmpty)
                    Spacer()
                }
            }
        }
    }

    private var heading: String {
        switch opened {
        case .record: return "Opened"
        case .http(let call): return call.method
        }
    }
}
