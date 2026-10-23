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
        guard let url = URL(string: baseURL.absoluteString + path) else { throw ToolRunError.unreachable(baseURL.absoluteString + path) }
        var req = URLRequest(url: url, timeoutInterval: long ? runTimeout : timeout)
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
        AssistantTools.Tool(name: "run_script", description: "Runs one of the user's scripts. A card on their Mac asks them first (you can't click); the call waits for their click and then for the script, and comes back with how it went and what it printed (or that they didn't click Run). If it comes back with only a request id, use check_request with it.",
                            arguments: [("script", "string: its name from list_scripts"), ("args", "list of strings, optional: its arguments"), ("stdin", "string, optional: text handed to it as input"),
                                        ("why", "string: why the user wants this, in their words; shown on the card they click")]),
        AssistantTools.Tool(name: "list_flows", description: "Lists the user's flows (scripts composed in the Flow language) in Tool Mac Tool Run."),
        AssistantTools.Tool(name: "run_flow", description: "Runs one of the user's flows, once they click Run on their Mac; the call waits and comes back with how it went and what it printed.",
                            arguments: [("flow", "string: its name from list_flows"), ("args", "list of strings, optional: its arguments"), ("why", "string: why the user wants this, in their words; shown on the card")]),
        AssistantTools.Tool(name: "run_flow_code", description: "Runs Flow code you write (it can run the user's scripts by name: run \"hello.sh\" []), once the user clicks Run on their Mac, where the code is shown in full; the call waits and comes back with how it went. Check it with check_flow first.",
                            arguments: [("source", "string: the Flow code"), ("name", "string, optional: what to call the run"), ("why", "string: why the user wants this, in their words; shown on the card")]),
        AssistantTools.Tool(name: "check_request", description: "Where a run request is: waiting for the user to click Run, denied, running (with what it's printed so far), or how it ended, with what it printed. Use the request id run_script, run_flow or run_flow_code gave you.",
                            arguments: [("id", "string: the request id")]),
        AssistantTools.Tool(name: "check_flow", description: "Checks Flow code for mistakes without running anything (nothing is asked of the user).",
                            arguments: [("source", "string: the Flow code")]),
        AssistantTools.Tool(name: "list_runs", description: "Lists the latest runs in Tool Mac Tool Run, newest first, without their output.",
                            arguments: [("limit", "integer, optional: how many, default 10")]),
        AssistantTools.Tool(name: "read_run", description: "Reads one run in full, with its output.", arguments: [("id", "string: the run's id")]),
        AssistantTools.Tool(name: "stop_run", description: "Stops a run that's still going.", arguments: [("id", "string: the run's id")]),
    ]

    public static var names: [String] { tools.map(\.name) }
    /// The tools that put a card on the Mac: the click there is their approval (the app asks nothing
    /// of its own). The call waits for the click and the run (a request id comes back only from an
    /// older Tool Mac Tool Run, and is then followed).
    public static let gated: Set<String> = ["run_script", "run_flow", "run_flow_code"]

    /// What Tool Mac Tool Run has: the scripts and flows, fetched once as AI Listen starts (and on
    /// request), so the models are told what there is without a round of list_scripts.
    public struct Catalog: Equatable, Sendable {
        public struct Script: Equatable, Sendable, Identifiable {
            public var name: String
            public var group: String
            public var language: String
            public var does: String
            public var dangers: [String]
            public var id: String { name }
        }
        public struct Flow: Equatable, Sendable, Identifiable {
            public var name: String
            public var does: String
            public var id: String { name }
        }
        public var folder: String
        public var scripts: [Script]
        public var flows: [Flow]
        public var fetched: Date

        public init(folder: String = "", scripts: [Script] = [], flows: [Flow] = [], fetched: Date = Date()) {
            self.folder = folder
            self.scripts = scripts
            self.flows = flows
            self.fetched = fetched
        }

        public var isEmpty: Bool { scripts.isEmpty && flows.isEmpty }

        /// Read from /api/scripts and /api/flows.
        public static func read(scripts: [String: Any], flows: [String: Any], now: Date = Date()) -> Catalog {
            let s = ((scripts["scripts"] as? [[String: Any]]) ?? []).compactMap { o -> Script? in
                guard let name = o["name"] as? String, !name.isEmpty else { return nil }
                return Script(name: name, group: (o["group"] as? String) ?? "scripts", language: (o["language_name"] as? String) ?? (o["language"] as? String) ?? "",
                              does: (o["summary"] as? String) ?? "", dangers: (o["dangers"] as? [String]) ?? [])
            }
            let f = ((flows["flows"] as? [[String: Any]]) ?? []).compactMap { o -> Flow? in
                guard let name = o["name"] as? String, !name.isEmpty else { return nil }
                return Flow(name: name, does: (o["summary"] as? String) ?? "")
            }
            return Catalog(folder: (scripts["folder"] as? String) ?? "", scripts: s, flows: f, fetched: now)
        }

        /// For Jerry: every script and flow, with what it does, so he runs them by name.
        public var prompt: String {
            guard !isEmpty else { return "" }
            var p = "\n\nThe scripts Tool Mac Tool Run has now (run_script by name; what each does, in its own words):"
            for s in scripts {
                p += "\n- \(s.name)" + (s.language.isEmpty ? "" : " (\(s.language))") + (s.does.isEmpty ? "" : ": \(s.does)")
                if !s.dangers.isEmpty { p += " [can't be undone: \(s.dangers.joined(separator: ", "))]" }
            }
            if !flows.isEmpty {
                p += "\nThe flows (run_flow by name):"
                for f in flows { p += "\n- \(f.name)" + (f.does.isEmpty ? "" : ": \(f.does)") }
            }
            return p
        }

        /// For Tom: what Jerry can run, in a line, so his specs name what there is.
        public var summary: String {
            guard !isEmpty else { return "" }
            let names = scripts.map { $0.does.isEmpty ? $0.name : "\($0.name) (\($0.does))" } + flows.map { $0.does.isEmpty ? $0.name : "\($0.name) (\($0.does))" }
            return " The scripts \(Team.teammate) can run on this Mac: " + names.joined(separator: "; ") + "."
        }
    }

    /// Fetches the catalog; nil when Tool Mac Tool Run doesn't answer (or has no folder yet).
    public static func catalog(via runner: ScriptRunner, now: Date = Date()) async -> Catalog? {
        guard let (status, scripts) = try? await runner.call("GET", "/api/scripts", body: nil), (200..<300).contains(status) else { return nil }
        let flows = (try? await runner.call("GET", "/api/flows", body: nil)).flatMap { (200..<300).contains($0.status) ? $0.json : nil } ?? [:]
        return Catalog.read(scripts: scripts, flows: flows, now: now)
    }

    /// The request id in what a run tool answered ("Request id 2A7C…"), for the app to follow.
    public static func requestID(in result: String) -> String? {
        guard let r = result.range(of: #"Request id ([A-Za-z0-9-]+)"#, options: .regularExpression) else { return nil }
        return String(result[r].dropFirst("Request id ".count))
    }

    /// A run request as the app follows it: its state, the run's id once it has one, whether it's
    /// over, and the words for it (the model's, and the user's).
    public struct RequestState: Equatable, Sendable {
        public var state: String
        public var runID: String?
        public var ok: Bool?
        public var text: String
        /// It won't change any more (`ok` is there, or the request is gone).
        public var over: Bool { ok != nil || state == "gone" || state == "unknown_request" }
    }

    /// Asks Tool Mac Tool Run where a request is.
    public static func status(of id: String, via runner: ScriptRunner) async -> RequestState {
        do {
            let (status, json) = try await runner.call("GET", "/api/requests/\(escaped(id))", body: nil)
            if status == 404, (json["code"] as? String) == "unknown_request" {
                return RequestState(state: "unknown_request", runID: nil, ok: false, text: "The request is gone: Tool Mac Tool Run started again since. Its runs (list_runs) may still show what happened.")
            }
            if let trouble = trouble(status, json) { return RequestState(state: "trouble", runID: nil, ok: nil, text: trouble) }
            return requestState(json)
        } catch {
            return RequestState(state: "unreachable", runID: nil, ok: nil, text: (error as? LocalizedError)?.errorDescription ?? "Tool Mac Tool Run couldn't be reached.")
        }
    }

    /// A request's answer, read for the model.
    static func requestState(_ json: [String: Any]) -> RequestState {
        let state = (json["state"] as? String) ?? "unknown"
        let runID = json["run_id"] as? String ?? (json["run"] as? [String: Any])?["id"] as? String
        let ok = json["ok"] as? Bool
        let text: String
        switch state {
        case "waiting": text = "Still waiting for the user to click Run on their Mac."
        case "denied": text = "It didn't run: the user clicked Don't Run. Don't send it again unless they ask."
        case "not_answered": text = "It didn't run: no one clicked Run within two minutes. Ask the user before sending it again."
        case "automated": text = "Allowed: it's tagged to run by itself now."
        case "gone": text = "It ran, but the run has been cleared from Tool Mac Tool Run's history, so its output is gone."
        default:
            if let run = json["run"] as? [String: Any] { text = outcome(run) }
            else { text = "\(state): \((json["error"] as? String) ?? "")" }
        }
        return RequestState(state: state, runID: runID, ok: ok, text: text)
    }

    /// What a run tool answered: the request id to follow, or (an older Tool Mac Tool Run that ran
    /// it there and then) how it went.
    static func sent(_ json: [String: Any]) -> String {
        if let id = json["request"] as? String, (json["state"] as? String) == "waiting" || json["run"] == nil && json["output"] == nil {
            return "Sent. It's on the user's Mac waiting for them to click Run; nothing has run yet. Request id \(id): use check_request with it to see whether they clicked, and how it went."
        }
        var text = outcome(json)
        if let id = json["request"] as? String { text += "\nRequest id \(id)." }
        return text
    }

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
                if let why = string(arguments["why"] ?? arguments["reason"]) { body["why"] = why }
                let (status, json) = try await runner.call("POST", "/api/run", body: body)
                if let trouble = trouble(status, json) { return trouble }
                return sent(json)
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
                if let why = string(arguments["why"] ?? arguments["reason"]) { body["why"] = why }
                let (status, json) = try await runner.call("POST", "/api/compose", body: body)
                if let trouble = trouble(status, json) { return trouble }
                return sent(json)
            case "run_flow_code":
                guard let source = string(arguments["source"] ?? arguments["code"]) else { return "Give the Flow code as source." }
                var body: [String: Any] = ["source": source]
                if let n = string(arguments["name"]) { body["name"] = n }
                if let why = string(arguments["why"] ?? arguments["reason"]) { body["why"] = why }
                let (status, json) = try await runner.call("POST", "/api/compose", body: body)
                if let trouble = trouble(status, json) { return trouble }
                return sent(json)
            case "check_request":
                guard let id = string(arguments["id"] ?? arguments["request"] ?? arguments["request_id"]) else { return "Give the request id." }
                return await status(of: id, via: runner).text
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
                let limit = AssistantTools.limit(arguments, default: 10)
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
                let (status, json) = try await runner.call("GET", "/api/runs/\(ToolRunTools.escaped(id))", body: nil)
                if let trouble = trouble(status, json) { return trouble }
                return outcome(json)
            case "stop_run":
                guard let id = string(arguments["id"] ?? arguments["run"]) else { return "Give the run's id." }
                let (status, json) = try await runner.call("POST", "/api/runs/\(ToolRunTools.escaped(id))/stop", body: [:])
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
        if let code = number(r["code"]), let c = Int(exactly: code.rounded()) { head += " (exit code \(c))" }
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
        case "unknown_script", "unknown_flow", "unknown_run", "unknown_request": return error
        case "flow_mistake": return mistake(json)
        default: return "Tool Mac Tool Run said \(status): \(error)"
        }
    }

    /// A run id the model wrote, as one path segment.
    static func escaped(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? ""
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
