import AppKit
import Combine
import Foundation
import ServiceManagement
import VoiceCore

/// The service: its settings, the server, the models. What the panel shows and switches.
/// On the main thread.
final class Service: ObservableObject {
    static let shared = Service()

    @Published private(set) var settings: ServiceSettings
    @Published private(set) var server: APIServer.State = .stopped
    /// The user wants it serving (it's started at launch when so).
    @Published private(set) var wantsServing: Bool

    let speaker = SpeechPlayer()               // /api/say
    let reader = SpeechPlayer()                // Read aloud, and reading back from the library
    let neural = Neural.shared
    private(set) var engine: MacEngine!
    private(set) var api: VoiceAPI!
    private var http: APIServer!
    private let lock = NSLock()
    private var settingsNow: ServiceSettings
    /// The model other apps get (POST /api/model/chat): AI Listen's, kept here for the server's threads.
    private var modelNow = (url: OllamaClient.defaultURL, model: "")
    private var watching: Set<AnyCancellable> = []

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0-dev"
    /// "0.1" from "0.1.12" or "0.1-abc1234".
    static var versionBase: String {
        let parts = version.split(separator: "-")[0].split(separator: ".")
        return parts.prefix(2).joined(separator: ".")
    }

    private init() {
        let defaults = UserDefaults.standard
        var loaded = ServiceSettings()
        if let data = defaults.data(forKey: "serviceSettings"),
           let saved = try? JSONDecoder().decode(ServiceSettings.self, from: data) {
            loaded = saved
        }
        settings = loaded
        settingsNow = loaded
        wantsServing = defaults.object(forKey: "serving") as? Bool ?? true
        engine = MacEngine(speaker: speaker)
        speaker.throughFace = true
        let model = OllamaModelAccess { [weak self] in self?.currentModel ?? (url: OllamaClient.defaultURL, model: "") }
        api = VoiceAPI(engine: engine, version: Self.version,
                       directory: FileManager.default.temporaryDirectory.appendingPathComponent("SuperVoice", isDirectory: true),
                       model: model) { [weak self] in
            self?.currentSettings ?? ServiceSettings()
        }
        http = APIServer(api: api)
        http.onState = { [weak self] state in self?.server = state }
        // Panels and windows redraw when a model's state changes.
        neural.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &watching)
    }

    /// The settings, for the server's threads.
    private var currentSettings: ServiceSettings {
        lock.lock()
        defer { lock.unlock() }
        return settingsNow
    }

    /// The model AI Listen talks with, for the server's threads.
    private var currentModel: (url: String, model: String) {
        lock.lock()
        defer { lock.unlock() }
        return modelNow
    }

    /// AI Listen's model changed (or was first read): other apps get the same one.
    func useModel(url: String, model: String) {
        lock.lock()
        modelNow = (url: url, model: model)
        lock.unlock()
    }

    /// At launch: serve if it was serving, and get both models going so the first call is quick.
    func launch() {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("SuperVoice"))
        if wantsServing { startServing() }
        _ = neural.voiceModel()
        _ = neural.earModel()
    }

    var isServing: Bool {
        if case .running = server { return true }
        return false
    }

    var baseURL: String { "http://127.0.0.1:\(settings.port)" }

    func startServing() {
        wantsServing = true
        UserDefaults.standard.set(true, forKey: "serving")
        http.start(port: settings.port, network: settings.allowNetwork)
    }

    func stopServing() {
        wantsServing = false
        UserDefaults.standard.set(false, forKey: "serving")
        http.stop()
    }

    func change(_ edit: (inout ServiceSettings) -> Void) {
        var s = settings
        edit(&s)
        guard s != settings else { return }
        let restart = s.port != settings.port || s.allowNetwork != settings.allowNetwork
        if s.allowNetwork, s.token.isEmpty { s.token = ServiceSettings.newToken() }
        settings = s
        lock.lock()
        settingsNow = s
        lock.unlock()
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: "serviceSettings") }
        if restart, wantsServing { startServing() }
    }

    func setEndpoint(_ e: Endpoint, on: Bool) {
        change { s in
            if on { s.off.remove(e) } else { s.off.insert(e) }
        }
    }

    var voice: Voice { settings.defaultVoice }

    // MARK: Open at login

    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Open at login: \(error.localizedDescription)")
        }
        objectWillChange.send()
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
