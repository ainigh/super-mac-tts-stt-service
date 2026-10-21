import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Tool Mac Tool Run's HTTP API (http://127.0.0.1:8768): the person's scripts and flows, run on
/// their say-so (every run waits for a click on Run, on the Mac). The assistant gets tools over it.
public protocol ScriptRunner: AnyObject {
    /// Sends a request and returns the status and the JSON answered (an empty object when it
    /// isn't JSON). Throws only when nothing answers.
    func call(_ method: String, _ path: String, body: [String: Any]?) async throws -> (status: Int, json: [String: Any])
}

public enum ToolRunError: Error, LocalizedError, Equatable {
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let url): return "Tool Mac Tool Run isn't answering at \(url). Is it running, with its API on?"
        }
    }
}

public final class ToolRunClient: ScriptRunner {
    public let baseURL: URL
    /// A run waits for the click (two minutes at most), then for the script to end.
    public var runTimeout: TimeInterval = 15 * 60
    public var timeout: TimeInterval = 15
    /// Shown on the Mac: "Super Voice wants to run a script".
    public var client = "Super Voice"

    public static let defaultURL = "http://127.0.0.1:8768"

    public init(baseURL: String = ToolRunClient.defaultURL) {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = Self.defaultURL }
        if !s.lowercased().hasPrefix("http") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        self.baseURL = URL(string: s) ?? URL(string: Self.defaultURL)!
    }

    public func call(_ method: String, _ path: String, body: [String: Any]?) async throws -> (status: Int, json: [String: Any]) {
        let long = path == "/api/run" || path == "/api/compose"
        var req = URLRequest(url: URL(string: baseURL.absoluteString + path)!, timeoutInterval: long ? runTimeout : timeout)
        req.httpMethod = method
        req.setValue(client, forHTTPHeaderField: "X-Client")
        if var body {
            if body["client"] == nil { body["client"] = client }
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = JSON.data(body)
        }
        let result: (Data, URLResponse?)
        do {
            result = try await withCheckedThrowingContinuation { (k: CheckedContinuation<(Data, URLResponse?), Error>) in
                URLSession.shared.dataTask(with: req) { data, response, error in
                    if let error { k.resume(throwing: error) } else { k.resume(returning: (data ?? Data(), response)) }
                }.resume()
            }
        } catch {
            throw ToolRunError.unreachable(baseURL.absoluteString)
        }
        let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        return (status, JSON.object(result.0) ?? [:])
    }
}

/// The tools over Tool Mac Tool Run, as the model is told them and as they're run.
public enum ToolRunTools {
    public static let maxOutput = 12_000

    public static let tools: [AssistantTools.Tool] = [
        AssistantTools.Tool(name: "list_scripts", description: "Lists the user's scripts in Tool Mac Tool Run (name, language, what each does, and what it looks like it does that can't be undone). Use it before running one, to find the right name."),
        AssistantTools.Tool(name: "run_script", description: "Runs one of the user's scripts and gives back whether it succeeded and everything it printed. Nothing runs until the user clicks Run on their Mac, so tell them it's waiting for that; it may take a while.",
                            arguments: [("script", "string: its name from list_scripts"), ("args", "list of strings, optional: its arguments"), ("stdin", "string, optional: text handed to it as input")]),
        AssistantTools.Tool(name: "list_flows", description: "Lists the user's flows (scripts composed in the Flow language) in Tool Mac Tool Run."),
        AssistantTools.Tool(name: "run_flow", description: "Runs one of the user's flows, once the user clicks Run on their Mac. Gives back how it went, what it printed, and each step.",
                            arguments: [("flow", "string: its name from list_flows"), ("args", "list of strings, optional: its arguments")]),
        AssistantTools.Tool(name: "run_flow_code", description: "Runs Flow code you write (it can run the user's scripts by name: run \"hello.sh\" []), once the user clicks Run on their Mac, where the code is shown in full.",
                            arguments: [("source", "string: the Flow code"), ("name", "string, optional: what to call the run")]),
        AssistantTools.Tool(name: "check_flow", description: "Checks Flow code for mistakes without running anything (nothing is asked of the user).",
                            arguments: [("source", "string: the Flow code")]),
        AssistantTools.Tool(name: "list_runs", description: "Lists the latest runs in Tool Mac Tool Run, newest first, without their output.",
                            arguments: [("limit", "integer, optional: how many, default 10")]),
        AssistantTools.Tool(name: "read_run", description: "Reads one run in full, with its output.", arguments: [("id", "string: the run's id")]),
        AssistantTools.Tool(name: "stop_run", description: "Stops a run that's still going.", arguments: [("id", "string: the run's id")]),
    ]

    public static var names: [String] { tools.map(\.name) }

    /// Runs one of these tools; nil when `name` isn't one of them. The answer is text for the model.
    public static func run(_ name: String, _ arguments: [String: Any], via runner: ScriptRunner) async -> String? {
        guard names.contains(name) else { return nil }
        do {
            switch name {
            case "list_scripts":
                let (status, json) = try await runner.call("GET", "/api/scripts", body: nil)
                if let trouble = trouble(status, json) { return trouble }
                let scripts = (json["scripts"] as? [[String: Any]]) ?? []
                guard !scripts.isEmpty else { return "There are no scripts in the folder (\((json["folder"] as? String) ?? "no folder"))." }
                return text(scripts.map { s in
                    var o: [String: Any] = ["name": s["name"] ?? "", "language": s["language_name"] ?? s["language"] ?? ""]
                    if let d = s["summary"] as? String, !d.isEmpty { o["does"] = d }
                    if let d = s["dangers"] as? [String], !d.isEmpty { o["cannot_be_undone"] = d }
                    if s["asks_for_input"] as? Bool == true { o["asks_for_input"] = true }
                    return o
                })
            case "run_script":
                guard let script = string(arguments["script"] ?? arguments["name"]) else { return "Say which script: its name from list_scripts." }
                var body: [String: Any] = ["script": script]
                if let args = list(arguments["args"] ?? arguments["arguments"]) { body["args"] = args }
                if let stdin = string(arguments["stdin"] ?? arguments["input"]) { body["stdin"] = stdin }
                let (status, json) = try await runner.call("POST", "/api/run", body: body)
                if let trouble = trouble(status, json) { return trouble }
                return outcome(json)
            case "list_flows":
                let (status, json) = try await runner.call("GET", "/api/flows", body: nil)
                if let trouble = trouble(status, json) { return trouble }
                let flows = (json["flows"] as? [[String: Any]]) ?? []
                guard !flows.isEmpty else { return "There are no flows." }
                return text(flows.map { f in
                    var o: [String: Any] = ["name": f["name"] ?? ""]
                    if let d = f["summary"] as? String, !d.isEmpty { o["does"] = d }
                    return o
                })
            case "run_flow":
                guard let flow = string(arguments["flow"] ?? arguments["name"]) else { return "Say which flow: its name from list_flows." }
                var body: [String: Any] = ["flow": flow]
                if let args = list(arguments["args"] ?? arguments["arguments"]) { body["args"] = args }
                let (status, json) = try await runner.call("POST", "/api/compose", body: body)
                if let trouble = trouble(status, json) { return trouble }
                return outcome(json)
            case "run_flow_code":
                guard let source = string(arguments["source"] ?? arguments["code"]) else { return "Give the Flow code as source." }
                var body: [String: Any] = ["source": source]
                if let n = string(arguments["name"]) { body["name"] = n }
                let (status, json) = try await runner.call("POST", "/api/compose", body: body)
                if let trouble = trouble(status, json) { return trouble }
                return outcome(json)
            case "check_flow":
                guard let source = string(arguments["source"] ?? arguments["code"]) else { return "Give the Flow code as source." }
                let (status, json) = try await runner.call("POST", "/api/check", body: ["source": source])
                if json["ok"] as? Bool == true {
                    let bindings = ((json["bindings"] as? [[String: Any]]) ?? []).map { "\(($0["name"] as? String) ?? "?"): \(($0["type"] as? String) ?? "?")" }
                    return "The code is fine." + (bindings.isEmpty ? "" : " It defines " + bindings.joined(separator: ", ") + ".")
                }
                if let trouble = trouble(status, json) { return trouble }
                return mistake(json)
            case "list_runs":
                let limit = min(max((arguments["limit"] as? Int) ?? Int((arguments["limit"] as? Double) ?? 10), 1), 100)
                let (status, json) = try await runner.call("GET", "/api/runs?limit=\(limit)", body: nil)
                if let trouble = trouble(status, json) { return trouble }
                let runs = (json["runs"] as? [[String: Any]]) ?? []
                guard !runs.isEmpty else { return "There are no runs yet." }
                return text(runs.map { r in
                    var o: [String: Any] = ["id": r["id"] ?? "", "name": r["name"] ?? "", "state": r["state"] ?? ""]
                    if let s = r["started"] { o["started"] = s }
                    if let s = r["seconds"] { o["seconds"] = s }
                    if let s = r["requested_by"] { o["requested_by"] = s }
                    return o
                })
            case "read_run":
                guard let id = string(arguments["id"] ?? arguments["run"]) else { return "Give the run's id." }
                let (status, json) = try await runner.call("GET", "/api/runs/\(id)", body: nil)
                if let trouble = trouble(status, json) { return trouble }
                return outcome(json)
            case "stop_run":
                guard let id = string(arguments["id"] ?? arguments["run"]) else { return "Give the run's id." }
                let (status, json) = try await runner.call("POST", "/api/runs/\(id)/stop", body: [:])
                if let trouble = trouble(status, json) { return trouble }
                return json["stopping"] as? Bool == true ? "Stopping it." : "It had already ended."
            default:
                return nil
            }
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "Tool Mac Tool Run couldn't be reached."
        }
    }

    /// How a run went, for the model: its state, exit code, time, and what it printed (cut short
    /// when long).
    static func outcome(_ r: [String: Any]) -> String {
        let name = (r["name"] as? String) ?? "the run"
        let state = (r["state"] as? String) ?? "unknown"
        var head = "\(name): \(state)"
        if let code = number(r["code"]) { head += " (exit code \(Int(code)))" }
        if let s = number(r["seconds"]) { head += ", \(JSON.round(s)) seconds" }
        if let id = r["id"] as? String { head += ", run id \(id)" }
        var lines = [head + "."]
        if let p = r["problem"] as? String, !p.isEmpty { lines.append("Problem: \(p)") }
        if let steps = r["steps"] as? [[String: Any]], !steps.isEmpty {
            lines.append("Steps: " + steps.map { "\(($0["name"] as? String) ?? "?") \(($0["state"] as? String) ?? "?")" }.joined(separator: "; ") + ".")
        }
        let output = ((r["output"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty {
            if state != "running" { lines.append("It printed nothing.") }
        } else {
            lines.append("It printed:\n" + (output.count > maxOutput ? "…" + String(output.suffix(maxOutput)) : output))
        }
        return lines.joined(separator: "\n")
    }

    static func mistake(_ json: [String: Any]) -> String {
        var s = "The Flow code has a mistake"
        if let line = json["line"] { s += " on line \(line)" }
        s += ": " + ((json["message"] as? String) ?? (json["error"] as? String) ?? "unknown") + "."
        if let fix = json["fix"] as? String, !fix.isEmpty { s += " Fix: \(fix)" }
        return s
    }

    /// What the model is told when the request didn't go through; nil when it did.
    static func trouble(_ status: Int, _ json: [String: Any]) -> String? {
        if (200..<300).contains(status) { return nil }
        let code = (json["code"] as? String) ?? ""
        let error = (json["error"] as? String) ?? "status \(status)"
        switch code {
        case "denied": return "It didn't run: the user clicked Don't Run on their Mac."
        case "not_answered": return "It didn't run: no one clicked Run on the Mac within two minutes."
        case "endpoint_off": return "That's turned off in Tool Mac Tool Run on this Mac (\(error))."
        case "no_folder": return "Tool Mac Tool Run has no scripts folder chosen yet; the user picks one in its panel."
        case "unknown_script", "unknown_flow", "unknown_run": return error
        case "flow_mistake": return mistake(json)
        default: return "Tool Mac Tool Run said \(status): \(error)"
        }
    }

    static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    static func list(_ v: Any?) -> [String]? {
        if let a = v as? [Any] { return a.compactMap { string($0) } }
        if let s = v as? String, !s.isEmpty { return [s] }
        return nil
    }

    static func text(_ object: Any) -> String {
        String(decoding: JSON.data(object), as: UTF8.self)
    }
}
