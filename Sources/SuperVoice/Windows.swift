import AppKit
import SwiftUI
import VoiceCore

/// The library, for views: the store, published. On the main thread.
final class Library: ObservableObject {
    static let shared = Library()

    /// ~/Library/Application Support/SuperVoice/Library
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SuperVoice/Library", isDirectory: true)
    }()

    private let store = LibraryStore(folder: Library.folder)
    @Published private(set) var items: [LibraryRecord] = []
    @Published var problem: String?

    private init() {
        items = store.items
    }

    @discardableResult
    func add(_ item: LibraryRecord) -> LibraryRecord {
        save(item)
        return item
    }

    func save(_ item: LibraryRecord) {
        do {
            var item = item
            if let old = store.item(item.id), old != item { item.modified = Date() }
            try store.save(item)
            items = store.items
        } catch {
            problem = "Couldn't save: \(error.localizedDescription)"
        }
    }

    func delete(_ id: UUID) {
        do {
            try store.delete(id)
            items = store.items
        } catch {
            problem = "Couldn't delete: \(error.localizedDescription)"
        }
    }

    func item(_ id: UUID) -> LibraryRecord? { items.first { $0.id == id } }

    func filter(kind: LibraryRecord.Kind?, query: String, starredOnly: Bool) -> [LibraryRecord] {
        store.filter(kind: kind, query: query, starredOnly: starredOnly)
    }
}

/// The tools' windows: one of each, brought forward when opened again.
enum Windows {
    enum Kind: String {
        case read, dictate, transcribe, library

        var title: String {
            switch self {
            case .read: return "Read Aloud"
            case .dictate: return "Dictate"
            case .transcribe: return "Transcribe"
            case .library: return "Library"
            }
        }

        var size: NSSize {
            switch self {
            case .read: return NSSize(width: 640, height: 520)
            case .dictate: return NSSize(width: 600, height: 520)
            case .transcribe: return NSSize(width: 680, height: 580)
            case .library: return NSSize(width: 980, height: 680)
            }
        }
    }

    private static var open: [Kind: NSWindow] = [:]
    private static let closer = Closer()

    static func show(_ kind: Kind) {
        NSApp.activate()
        if let w = open[kind] {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let view: AnyView
        switch kind {
        case .read: view = AnyView(ReadAloudView())
        case .dictate: view = AnyView(DictateView())
        case .transcribe: view = AnyView(TranscribeView())
        case .library: view = AnyView(LibraryView())
        }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: kind.size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = kind.title
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: view
            .environmentObject(Service.shared)
            .environmentObject(Library.shared))
        w.minSize = NSSize(width: 460, height: 380)
        w.setFrameAutosaveName("SuperVoice.\(kind.rawValue)")
        if !w.setFrameUsingName("SuperVoice.\(kind.rawValue)") { w.center() }
        w.delegate = closer
        open[kind] = w
        w.makeKeyAndOrderFront(nil)
    }

    /// Opens the library on one item.
    static func showItem(_ id: UUID) {
        LibraryView.Selection.shared.id = id
        show(.library)
    }

    private final class Closer: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            guard let w = notification.object as? NSWindow,
                  let kind = Windows.open.first(where: { $0.value === w })?.key else { return }
            Windows.open[kind] = nil
            // Back to being a menu bar app once its windows are gone.
            if Windows.open.isEmpty { DispatchQueue.main.async { NSApp.hide(nil) } }
        }
    }
}

/// A window's page: a header with its title and a line under it, then the content.
struct Page<Content: View>: View {
    var title: String
    var subtitle: String
    var symbol: String
    var colors: [Color]
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 18, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            content
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A line saying something's wrong or happening, in a soft colored box.
struct Notice: View {
    var text: String
    var tint: Color = .orange
    var symbol = "exclamationmark.triangle.fill"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.system(size: 12)).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The voice pills and speed chips every speaking tool shows; they set the app's default.
struct VoiceBar: View {
    @EnvironmentObject var service: Service

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VoicePicker(selected: service.settings.voice) { v in
                service.change { $0.voice = v.id }
            }
            .fixedSize()
            Spacer()
            HStack(spacing: 4) {
                ForEach([0.8, 1.0, 1.2, 1.5], id: \.self) { s in
                    Button(s == 1 ? "1×" : String(format: "%.1f×", s)) { service.change { $0.speed = s } }
                        .buttonStyle(Chip(selected: abs(service.settings.speed - s) < 0.01))
                }
            }
        }
    }
}

enum Files {
    /// Asks where to save `text` and writes it there.
    static func save(_ text: String, name: String, ext: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-") + "." + ext
        panel.canCreateDirectories = true
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    static let dated: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
