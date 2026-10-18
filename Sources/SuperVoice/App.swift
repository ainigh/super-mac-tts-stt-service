import AppKit
import Combine
import SwiftUI
import VoiceCore

@main
enum Main {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)          // a menu bar app: no Dock icon
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var panel: MenuPanel!
    private var outsideClicks: Any?
    private var watching: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        panel = MenuPanel(content: PanelView(close: { [weak self] in self?.hide() }))
        Service.shared.launch()
        Updater.shared.start()
        // The icon says what's going on.
        Service.shared.objectWillChange
            .merge(with: Recorder.shared.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in DispatchQueue.main.async { self?.refreshIcon() } }
            .store(in: &watching)
        refreshIcon()
    }

    private func refreshIcon() {
        let symbol: String
        if Recorder.shared.on {
            symbol = "record.circle"
        } else if Service.shared.isServing {
            symbol = "waveform"
        } else {
            symbol = "waveform.slash"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Super Voice")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = Service.shared.isServing ? "Super Voice: serving at \(Service.shared.baseURL)" : "Super Voice: not serving"
    }

    @objc private func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        guard let button = item.button, let window = button.window else { return }
        let spot = window.convertToScreen(button.convert(button.bounds, to: nil))
        panel.present(below: spot)
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        panel.orderOut(nil)
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        Service.shared.stopServingForQuit()
    }
}

extension Service {
    /// Quitting: stop listening without forgetting that it was serving.
    func stopServingForQuit() {
        let was = wantsServing
        stopServing()
        UserDefaults.standard.set(was, forKey: "serving")
    }
}

/// The panel that drops down from the menu bar icon: glass, rounded, with a shadow; it floats
/// above other windows and takes clicks without taking the focus from the app you're in.
final class MenuPanel: NSPanel {
    private let hosting: NSHostingView<AnyView>

    init<V: View>(content: V) {
        hosting = NSHostingView(rootView: AnyView(content.environmentObject(Service.shared)))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 600),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let glass = NSVisualEffectView()
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 16
        glass.layer?.masksToBounds = true
        hosting.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: glass.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        contentView = glass
    }

    override var canBecomeKey: Bool { true }

    /// Shows it under `spot` (the icon, in screen coordinates), kept on that screen.
    func present(below spot: NSRect) {
        let size = hosting.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(spot.origin) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = spot.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        let y = spot.minY - size.height - 6
        setFrame(NSRect(x: x, y: max(screen.minY + 8, y), width: size.width, height: size.height), display: true)
        makeKeyAndOrderFront(nil)
    }

    /// Escape closes it.
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
