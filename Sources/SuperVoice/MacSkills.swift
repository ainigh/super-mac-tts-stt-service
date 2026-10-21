import AppKit
import Foundation
import IOKit.ps
import PDFKit
import VoiceCore

/// What the model's skills need from the Mac: the clipboard, how it's doing, Spotlight, reading
/// documents, and the default browser (AppleScript, through osascript). Everything only looks,
/// but for opening pages in the browser.
final class MacSkills: MacHost {
    static let shared = MacSkills()

    func clipboard() async -> String? {
        await MainActor.run { NSPasteboard.general.string(forType: .string) }
    }

    func status() async -> [String: Any] {
        let apps = await MainActor.run { () -> (front: String?, open: [String], dark: Bool) in
            let ws = NSWorkspace.shared
            return (ws.frontmostApplication?.localizedName,
                    ws.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName),
                    NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        }
        var o: [String: Any] = ["apps_open": apps.open, "dark_mode": apps.dark]
        if let front = apps.front { o["front_app"] = front }
        let p = ProcessInfo.processInfo
        o["macos"] = p.operatingSystemVersionString
        o["memory"] = String(format: "%.0f GB", Double(p.physicalMemory) / 1_073_741_824)
        o["up_for"] = Self.duration(p.systemUptime)
        o["time_zone"] = TimeZone.current.identifier
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            if let free = v.volumeAvailableCapacityForImportantUsage { o["disk_free"] = String(format: "%.0f GB", Double(free) / 1e9) }
            if let total = v.volumeTotalCapacity { o["disk_size"] = String(format: "%.0f GB", Double(total) / 1e9) }
        }
        if let battery = Self.battery() { o["battery"] = battery }
        return o
    }

    /// "80%, charging", or nil without a battery.
    static func battery() -> String? {
        guard let infoRef = IOPSCopyPowerSourcesInfo() else { return nil }
        let info = infoRef.takeRetainedValue()
        guard let listRef = IOPSCopyPowerSourcesList(info) else { return nil }
        let list = listRef.takeRetainedValue() as NSArray
        for source in list {
            guard let dRef = IOPSGetPowerSourceDescription(info, source as CFTypeRef) else { continue }
            let d = dRef.takeUnretainedValue() as NSDictionary
            guard let now = d["Current Capacity"] as? Int, let max = d["Max Capacity"] as? Int, max > 0 else { continue }
            var s = "\(now * 100 / max)%"
            if d["Is Charging"] as? Bool == true {
                s += ", charging"
            } else if d["Power Source State"] as? String == "AC Power" {
                s += ", plugged in"
            }
            return s
        }
        return nil
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        if m < 60 { return "\(m) minutes" }
        if m < 60 * 48 { return "\(m / 60) hours" }
        return "\(m / 60 / 24) days"
    }

    func spotlight(_ query: String, limit: Int) async -> [String] {
        let out = await Self.run("/usr/bin/mdfind", ["-onlyin", NSHomeDirectory(), query], timeout: 8)
        return Array(out.output.split(separator: "\n").map(String.init).prefix(limit))
    }

    func documentText(_ url: URL) async -> String? {
        if url.pathExtension.lowercased() == "pdf" { return PDFDocument(url: url)?.string }
        // Word, RTF, HTML: AppKit reads them (HTML only on the main thread).
        return await MainActor.run { () -> String? in
            (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        }
    }

    func defaultBrowser() async -> (id: String, name: String)? {
        await MainActor.run { () -> (id: String, name: String)? in
            guard let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!),
                  let id = Bundle(url: app)?.bundleIdentifier else { return nil }
            return (id, FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""))
        }
    }

    func open(_ url: URL) async -> Bool {
        await MainActor.run { NSWorkspace.shared.open(url) }
    }

    func appleScript(_ source: String) async -> Result<String, HostError> {
        let out = await Self.run("/usr/bin/osascript", ["-"], input: source, timeout: 20)
        if out.status == 0 { return .success(out.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let why = out.error.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(HostError(why.isEmpty ? "the browser didn't answer" : why))
    }

    func fetch(_ url: URL) async -> (status: Int, body: String)? {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        return await withCheckedContinuation { k in
            URLSession.shared.dataTask(with: req) { data, response, _ in
                guard let data else { return k.resume(returning: nil) }
                let body = String(data: data.prefix(3_000_000), encoding: .utf8) ?? String(decoding: data.prefix(3_000_000), as: UTF8.self)
                k.resume(returning: ((response as? HTTPURLResponse)?.statusCode ?? 0, body))
            }.resume()
        }
    }

    /// Runs a program, off the main thread: its exit status, output and errors (stopped after `timeout`).
    static func run(_ path: String, _ arguments: [String], input: String? = nil, timeout: TimeInterval) async -> (status: Int32, output: String, error: String) {
        await withCheckedContinuation { k in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = arguments
                let out = Pipe(), err = Pipe(), inp = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = inp
                do {
                    try p.run()
                } catch {
                    return k.resume(returning: (-1, "", error.localizedDescription))
                }
                if let input { inp.fileHandleForWriting.write(Data(input.utf8)) }
                try? inp.fileHandleForWriting.close()
                let stop = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
                // Errors are read alongside, so neither pipe fills up and stalls it.
                let errors = Collected()
                let reading = DispatchGroup()
                reading.enter()
                DispatchQueue.global().async {
                    errors.data = err.fileHandleForReading.readDataToEndOfFile()
                    reading.leave()
                }
                let output = out.fileHandleForReading.readDataToEndOfFile()
                reading.wait()
                p.waitUntilExit()
                stop.cancel()
                k.resume(returning: (p.terminationStatus, String(decoding: output, as: UTF8.self), String(decoding: errors.data, as: UTF8.self)))
            }
        }
    }
}

/// What one thread reads for another to pick up once it's done.
private final class Collected: @unchecked Sendable {
    var data = Data()
}
