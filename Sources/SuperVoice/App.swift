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
    private var insideActivity: Any?
    private var watching: Set<AnyCancellable> = []
    /// The panel closes after this long with nothing happening.
    static let idleClose: TimeInterval = 20
    private var lastActivity = Date()
    private var idleTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading
        panel = MenuPanel(content: PanelRoot(close: { [weak self] in self?.hide() },
                                             resized: { [weak self] size in
                                                 DispatchQueue.main.async { self?.panel?.fit(size) }     // not mid-update
                                             }))
        panel.onCancel = { [weak self] in self?.hide() }
        panel.onMouseMoved = { [weak self] in self?.noteActivity() }
        Service.shared.launch()
        BoardModel.shared.launch()
        Updater.shared.start()
        // The icon says what's going on.
        Service.shared.objectWillChange
            .merge(with: Recorder.shared.objectWillChange, BoardModel.shared.objectWillChange, AssistantModel.shared.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in DispatchQueue.main.async { self?.refreshIcon() } }
            .store(in: &watching)
        refreshIcon()
        // Anything done in the panel counts as activity.
        insideActivity = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            if let self, event.window === self.panel { self.noteActivity() }
            return event
        }
    }

    private func refreshIcon() {
        let board = BoardModel.shared
        let symbol: String
        if Recorder.shared.on {
            symbol = "record.circle"
        } else if AssistantModel.shared.on {
            symbol = "sparkles"
        } else if board.listening {
            symbol = "ear"
        } else if Service.shared.isServing {
            symbol = "waveform"
        } else {
            symbol = "waveform.slash"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Super Voice")
        image?.isTemplate = true
        item.button?.image = image
        var tip = Service.shared.isServing ? "Super Voice: serving at \(Service.shared.baseURL)" : "Super Voice: not serving"
        if board.listening { tip += "\nAlways listening (say “mouse”, then talk: it goes in the board's note)" }
        if AssistantModel.shared.on { tip += "\nAI Listen is on (say “Micky” or “Ollama”, then talk)" }
        item.button?.toolTip = tip
    }

    @objc private func toggle() {
        panel.isVisible ? hide() : show()
    }

    /// The panel's open: what's said goes on the board.
    var panelShown: Bool { panel?.isVisible ?? false }

    /// "Mouse": opens it without taking the keyboard from the app you're in, or closes it.
    func togglePanel(byVoice: Bool) {
        panel.isVisible ? hide() : show(takeKeyboard: !byVoice)
    }

    func show(takeKeyboard: Bool = true) {
        guard let button = item.button, let window = button.window else { return }
        let spot = window.convertToScreen(button.convert(button.bounds, to: nil))
        panel.present(below: spot, takeKeyboard: takeKeyboard)
        if outsideClicks == nil {
            outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.hide()
            }
        }
        noteActivity()
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
        refreshIcon()
    }

    func hide() {
        panel.orderOut(nil)
        BoardModel.shared.panelClosed()
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        idleTimer?.invalidate()
        idleTimer = nil
        refreshIcon()
    }

    /// Something happened (in the panel, or said): the idle countdown starts again.
    func noteActivity() {
        lastActivity = Date()
    }

    private func checkIdle() {
        guard panel.isVisible else { return }
        if Date().timeIntervalSince(lastActivity) >= Self.idleClose { hide() }
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
        acceptsMouseMovedEvents = true
        // The panel sizes itself (fit) as columns come and go, top staying put; the hosting view
        // only says how big it wants to be.
        hosting.sizingOptions = [.intrinsicContentSize]
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let glass = Glass()
        glass.onMouseMoved = { [weak self] in self?.onMouseMoved?() }
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

    /// The mouse moved over it (even when it isn't the key window: opened by voice).
    var onMouseMoved: (() -> Void)?

    /// Escape (when nothing in it takes it).
    var onCancel: (() -> Void)?
    /// Where it hangs from: the icon's spot on the screen.
    private var anchor: NSRect = .zero

    /// Shows it under `spot` (the icon, in screen coordinates), its first column under the icon,
    /// kept on that screen.
    func present(below spot: NSRect, takeKeyboard: Bool) {
        anchor = spot
        fit(hosting.fittingSize)
        if takeKeyboard { makeKeyAndOrderFront(nil) } else { orderFrontRegardless() }
    }

    /// Takes `size` (columns came or went), its top staying where it is.
    func fit(_ size: CGSize) {
        guard size.width > 0, size.height > 0, anchor != .zero else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = anchor.midX - 190                    // the first column (380 wide) centred under the icon
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        let top = anchor.minY - 6
        let y = max(screen.minY + 8, top - size.height)
        let frame = NSRect(x: x, y: y, width: size.width, height: min(size.height, top - screen.minY - 8))
        if frame != self.frame { setFrame(frame, display: true) }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// The panel's glass, which also hears the mouse moving over it whether or not the panel has the
/// keyboard.
private final class Glass: NSVisualEffectView {
    var onMouseMoved: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .inVisibleRect, .mouseEnteredAndExited],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouseMoved?()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onMouseMoved?()
    }
}
