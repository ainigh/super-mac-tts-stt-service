import Foundation

/// A skill: something the model can do besides talk, as a few tools. Each is switched on or off on
/// the panel's Skills board, and the model is told only about the ones that are on. All but two
/// only look: library editing changes the library (never a chat, and nothing is deleted), and
/// scripts run through Tool Mac Tool Run (each run waits for a click on the Mac).
public struct Skill: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var summary: String
    /// An SF Symbol.
    public var symbol: String
    /// It only looks: nothing on the Mac is changed.
    public var readOnly: Bool

    public init(id: String, title: String, summary: String, symbol: String, readOnly: Bool = true) {
        self.id = id
        self.title = title
        self.summary = summary
        self.symbol = symbol
        self.readOnly = readOnly
    }
}

public enum Skills {
    public static let library = Skill(id: "library", title: "Library", summary: "Looks up earlier chats, and the dictations, transcripts and notes in the library", symbol: "books.vertical.fill")
    public static let editing = Skill(id: "edit", title: "Library editing", summary: "Adds notes to the library and changes dictations, transcripts and notes when you ask (never chats; nothing is deleted)", symbol: "square.and.pencil", readOnly: false)
    public static let browser = Skill(id: "browser", title: "Browser", summary: "Opens pages and searches in your default browser, reads what's open there, and finds text on the page", symbol: "safari.fill")
    public static let files = Skill(id: "files", title: "Files", summary: "Finds files with Spotlight, lists folders, and reads text, PDF, RTF and Word files (hidden files and ~/Library stay out)", symbol: "folder.fill")
    public static let clipboard = Skill(id: "clipboard", title: "Clipboard", summary: "Reads what you last copied", symbol: "doc.on.clipboard.fill")
    public static let mac = Skill(id: "mac", title: "This Mac", summary: "The app in front, the apps open, battery, free disk space, memory, macOS", symbol: "laptopcomputer")
    public static let math = Skill(id: "math", title: "Calculator", summary: "Works sums out exactly instead of guessing", symbol: "function")
    public static let scripts = Skill(id: "scripts", title: "Scripts", summary: "Runs your scripts and flows through Tool Mac Tool Run (each run waits for you to click Run)", symbol: "terminal.fill", readOnly: false)

    public static let all: [Skill] = [library, editing, browser, files, clipboard, mac, math, scripts]
    public static var ids: [String] { all.map(\.id) }

    /// The tools of a skill (the browser's include the user's sites).
    public static func tools(_ id: String, sites: [Site] = []) -> [AssistantTools.Tool] {
        switch id {
        case library.id: return AssistantTools.library
        case editing.id: return AssistantTools.editing
        case browser.id: return BrowserSkill.tools(sites: sites)
        case files.id: return FileSkill.tools
        case clipboard.id: return [AssistantTools.Tool(name: "read_clipboard", description: "Reads what the user last copied (its text).")]
        case mac.id: return [AssistantTools.Tool(name: "mac_status", description: "Tells about the Mac now: the app in front and its window, the apps open, battery, free disk space, memory, macOS version, and how long since it started.")]
        case math.id: return [AssistantTools.Tool(name: "calculate", description: "Works out arithmetic exactly: + - * / ^ %, parentheses, sqrt, sin, cos, tan, log, ln, abs, round, floor, ceil, pi, e. Use it for any sum instead of working it out yourself.",
                                                  arguments: [("expression", "string: the sum, like (12.5 * 3) / 4")])]
        case scripts.id: return ToolRunTools.tools
        default: return []
        }
    }

    /// The skill a tool belongs to.
    public static func skill(for tool: String) -> Skill? {
        all.first { s in tools(s.id, sites: []).contains { $0.name == tool } } ?? (tool == "search_site" ? browser : nil)
    }

    /// What the system prompt says about the skills that are on (the tools' manual comes after).
    static func prompt(_ on: [String]) -> String {
        var p = ""
        if on.contains(library.id) {
            p += """
             You remember only this conversation. The user's earlier chats with you and their library (dictations, \
            transcripts of audio files, and notes) are on this Mac, and you can look them up with the tools. Don't look \
            anything up unless it's needed; never make up what a chat or an item says.
            """
        }
        if on.contains(editing.id) {
            p += """
             You can add notes to their library and change what's in it (never chats), but only when they ask you to; \
            say in a few words what you changed.
            """
        }
        if on.contains(browser.id) {
            p += """
             You can use the user's own web browser: open pages, search the web, read the page they have open, and \
            find text on it. They see whatever you open. Use it for anything current or that you don't know, and say \
            where the answer came from.
            """
        }
        if on.contains(files.id) { p += " You can find and read the files on their Mac, only to look: you can't change them." }
        if on.contains(clipboard.id) || on.contains(mac.id) { p += " You can see what they copied, and how their Mac is doing, when it helps." }
        if on.contains(math.id) { p += " Work out any arithmetic with calculate rather than in your head." }
        if on.contains(scripts.id) {
            p += """
             The user also has Tool Mac Tool Run on this Mac, which runs their scripts and flows: when they ask \
            you to run one, find its name with list_scripts or list_flows, then run it. Every run shows a card on \
            their Mac and waits for them to click Run (or Don't Run), so it may take a while; tell them how it \
            went and what it printed, in a sentence or two. Never run anything they didn't ask for.
            """
        }
        return p
    }
}

/// What the skills need from the Mac. The app provides it; tests use a stand-in.
public protocol MacHost: AnyObject {
    /// The clipboard's text.
    func clipboard() async -> String?
    /// The Mac now, as facts ("front_app": "Safari", "battery": "80%, charging", …).
    func status() async -> [String: Any]
    /// Spotlight's paths for `query`, at most `limit`.
    func spotlight(_ query: String, limit: Int) async -> [String]
    /// The text of a document Foundation can't read alone (PDF, RTF, Word); nil when it isn't one.
    func documentText(_ url: URL) async -> String?
    /// The default browser: its bundle id and name.
    func defaultBrowser() async -> (id: String, name: String)?
    /// Opens a link in the default browser.
    func open(_ url: URL) async -> Bool
    /// Runs AppleScript: what it returned, or the error it gave.
    func appleScript(_ source: String) async -> Result<String, HostError>
    /// Gets a page directly (when the browser won't be read): its status and body.
    func fetch(_ url: URL) async -> (status: Int, body: String)?
}

public struct HostError: Error, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// The skills that need the Mac: the browser, files, the clipboard and the Mac's status. Keeps
/// the last page read, so a long one can be read part by part.
public final class SkillRunner {
    public let host: MacHost
    public var sites: [Site]
    /// The web search, with {query} where the words go.
    public var searchTemplate: String
    public var home: URL
    /// How long a page may take to load before it's read anyway.
    public var loadWait: TimeInterval = 10
    public var pollInterval: TimeInterval = 0.5
    var lastPage: BrowserSkill.Page?

    public static let defaultSearch = "https://www.google.com/search?q={query}"

    public init(host: MacHost, sites: [Site] = Site.defaults, searchTemplate: String = SkillRunner.defaultSearch,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.host = host
        self.sites = sites
        self.searchTemplate = searchTemplate
        self.home = home
    }

    /// Runs one of these tools; nil when `name` isn't one of them. The answer is text for the model.
    public func run(_ name: String, _ arguments: [String: Any]) async -> String? {
        switch name {
        case "read_clipboard":
            guard let text = await host.clipboard(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "The clipboard has no text." }
            return Snippets.cut(text, to: AssistantTools.maxChars)
        case "mac_status":
            return AssistantTools.json(await host.status())
        case "find_files", "list_folder", "read_file":
            return await FileSkill.run(name, arguments, home: home, host: host)
        case "open_page", "web_search", "search_site", "read_page", "find_on_page":
            return await BrowserSkill.run(name, arguments, runner: self)
        default:
            return nil
        }
    }
}

// MARK: - The user's sites

/// A site the model can search, in the browser: a name and its search address, with {query}
/// where the words go ("wikipedia https://en.wikipedia.org/w/index.php?search={query}").
public struct Site: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var name: String
    public var template: String
    public var id: String { name }

    public init(name: String, template: String) {
        self.name = name
        self.template = template
    }

    public static let defaults = [
        Site(name: "wikipedia", template: "https://en.wikipedia.org/w/index.php?search={query}"),
        Site(name: "youtube", template: "https://www.youtube.com/results?search_query={query}"),
    ]

    /// Its address for `query` (the words encoded), or nil when the template isn't a web address.
    public func url(for query: String) -> URL? {
        Self.fill(template, query)
    }

    public var host: String { URL(string: template.replacingOccurrences(of: "{query}", with: "x"))?.host ?? template }

    static func fill(_ template: String, _ query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#/")
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        var t = template.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("{query}") {
            t = t.replacingOccurrences(of: "{query}", with: q)
        } else if t.contains("{q}") {
            t = t.replacingOccurrences(of: "{q}", with: q)
        } else if t.contains("%s") {
            t = t.replacingOccurrences(of: "%s", with: q)
        } else {
            t += q
        }
        return FileSkill.webURL(t)
    }

    /// "wiki https://…{query}" (or "wiki: …") read as a site; nil when it isn't one word and an address.
    public static func parse(_ line: String) -> Site? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 2 else { return nil }
        let name = parts[0].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":,"))
        guard !name.isEmpty, name.range(of: #"^[\p{L}\p{N}_-]+$"#, options: .regularExpression) != nil else { return nil }
        let template = parts[1].trimmingCharacters(in: .whitespaces)
        guard fill(template, "test") != nil else { return nil }
        return Site(name: name, template: template)
    }
}

// MARK: - The browser

/// The default browser, driven by AppleScript: pages open there (the user sees them), and what's
/// on the page is read with a line of JavaScript in its front tab. Safari and the Chromium browsers
/// (Chrome, Brave, Edge, Arc, Vivaldi, Opera) can be read once "Allow JavaScript from Apple Events"
/// is on; any other browser (or that off), the page still opens there and is read by fetching it.
public enum BrowserSkill {
    /// How much of a page is read at a time.
    public static let partChars = 8_000

    public static func tools(sites: [Site]) -> [AssistantTools.Tool] {
        var t: [AssistantTools.Tool] = [
            .init(name: "web_search", description: "Searches the web in the user's default browser (the results open there, where they see them) and reads back the results, with their addresses. Use it for anything current or that you don't know; then open_page a result to read it.",
                  arguments: [("query", "string: what to search for")]),
            .init(name: "open_page", description: "Opens a web page in the user's default browser, where they see it, and reads it: its title, address and text. With find, the page is scrolled to that text and it's highlighted.",
                  arguments: [("url", "string: the address"), ("find", "string, optional: text to find on it")]),
            .init(name: "read_page", description: "Reads the page open in the user's browser now: its title, address and text. Long pages come in parts.",
                  arguments: [("part", "integer, optional: which part of a long page, 1 is the start")]),
            .init(name: "find_on_page", description: "Finds text on the page open in the user's browser: highlights the first place it's found, scrolled into view, and gives back each place, with the words around it.",
                  arguments: [("text", "string: what to find")]),
        ]
        if !sites.isEmpty {
            t.append(.init(name: "search_site", description: "Searches one of the user's sites in their browser and reads back the results. The sites: " + sites.map { "\($0.name) (\($0.host))" }.joined(separator: ", ") + ".",
                           arguments: [("site", "string: the site's name"), ("query", "string: what to search for")]))
        }
        return t
    }

    public enum Family: Equatable, Sendable { case safari, chromium }

    public static func family(_ bundleID: String) -> Family? {
        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview": return .safari
        case "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary", "com.brave.Browser",
             "com.brave.Browser.beta", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "org.chromium.Chromium",
             "company.thebrowser.Browser", "com.operasoftware.Opera":
            return .chromium
        default: return nil
        }
    }

    /// AppleScript that runs `js` in the browser's front tab and returns what it gives.
    public static func script(running js: String, in bundleID: String) -> String? {
        let code = quoted(js)
        switch family(bundleID) {
        case .safari?: return "tell application id \"\(bundleID)\" to do JavaScript \(code) in current tab of front window"
        case .chromium?: return "tell application id \"\(bundleID)\" to tell active tab of front window to execute javascript \(code)"
        case nil: return nil
        }
    }

    /// AppleScript that returns the front tab's address and title, a line each (no JavaScript needed).
    public static func tabScript(_ bundleID: String) -> String? {
        switch family(bundleID) {
        case .safari?: return "tell application id \"\(bundleID)\" to return (URL of current tab of front window) & linefeed & (name of current tab of front window)"
        case .chromium?: return "tell application id \"\(bundleID)\" to return (URL of active tab of front window) & linefeed & (title of active tab of front window)"
        case nil: return nil
        }
    }

    /// An AppleScript string literal.
    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") + "\""
    }

    /// A JavaScript string literal.
    static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    /// The page: title, address, whether it's loaded, its text, and the links that look like
    /// results (a search page's).
    static let pageJS = """
    (function(){var seen={},links=[];var add=function(a,t){if(!a||!a.href||seen[a.href]||a.href.indexOf('http')!==0)return;t=(t||a.innerText||'').trim();if(t.length<3)return;seen[a.href]=1;links.push({title:t.slice(0,200),url:a.href});};\
    document.querySelectorAll('a h3, h2 a, h3 a, a.result__a, [data-testid=result-title-a], #video-title').forEach(function(e){var a=e.tagName==='A'?e:e.closest('a');add(a,e.innerText);});\
    return JSON.stringify({title:document.title,url:location.href,ready:document.readyState,text:document.body?document.body.innerText:'',links:links.slice(0,12)});})()
    """

    /// Finds `text` on the page (from the top, highlighted and scrolled to), and gives the page's text.
    static func findJS(_ text: String) -> String {
        "(function(q){var s=window.getSelection();if(s)s.removeAllRanges();var found=window.find(q,false,false,true);"
            + "return JSON.stringify({found:found,title:document.title,url:location.href,ready:document.readyState,text:document.body?document.body.innerText:'',links:[]});})(\(jsString(text)))"
    }

    /// A page as it was read.
    struct Page: Equatable {
        var title: String
        var url: String
        var text: String
        var links: [(title: String, url: String)] = []
        /// Read by fetching it, not from the browser: why.
        var fetchedBecause: String?
        var found: Bool?
        /// document.readyState: loading, interactive, complete.
        var ready = "complete"

        static func == (a: Page, b: Page) -> Bool {
            a.title == b.title && a.url == b.url && a.text == b.text && a.fetchedBecause == b.fetchedBecause && a.found == b.found
                && a.links.map(\.url) == b.links.map(\.url)
        }

        init(title: String, url: String, text: String, links: [(title: String, url: String)] = [], fetchedBecause: String? = nil, found: Bool? = nil) {
            self.title = title
            self.url = url
            self.text = text
            self.links = links
            self.fetchedBecause = fetchedBecause
            self.found = found
        }

        init?(json: String) {
            guard let o = JSON.object(Data(json.utf8)) else { return nil }
            title = (o["title"] as? String) ?? ""
            url = (o["url"] as? String) ?? ""
            text = Snippets.tidy((o["text"] as? String) ?? "")
            links = ((o["links"] as? [[String: Any]]) ?? []).compactMap { l in
                guard let u = l["url"] as? String else { return nil }
                return ((l["title"] as? String) ?? "", u)
            }
            found = o["found"] as? Bool
            ready = (o["ready"] as? String) ?? ""
        }
    }

    static func run(_ name: String, _ arguments: [String: Any], runner: SkillRunner) async -> String {
        let host = runner.host
        switch name {
        case "web_search", "search_site":
            guard let query = ToolRunTools.string(arguments["query"] ?? arguments["q"] ?? arguments["text"]) else { return "Say what to search for." }
            var template = runner.searchTemplate
            if name == "search_site" {
                let wanted = (ToolRunTools.string(arguments["site"] ?? arguments["name"]) ?? "").lowercased()
                guard let site = runner.sites.first(where: { $0.name == wanted }) ?? runner.sites.first(where: { $0.name.hasPrefix(wanted) && !wanted.isEmpty }) else {
                    return "There's no site called \(wanted). The sites: \(runner.sites.map(\.name).joined(separator: ", "))."
                }
                template = site.template
            }
            guard let url = Site.fill(template, query) else { return "The search address isn't a web address: \(template)" }
            return await open(url, find: nil, runner: runner, searching: true)
        case "open_page":
            guard let raw = ToolRunTools.string(arguments["url"] ?? arguments["address"] ?? arguments["link"]), let url = FileSkill.webURL(raw) else {
                return "Give a web address (https://…) to open."
            }
            return await open(url, find: ToolRunTools.string(arguments["find"]), runner: runner, searching: false)
        case "read_page":
            let part = Int(ToolRunTools.number(arguments["part"]) ?? 1)
            if part > 1, let page = runner.lastPage { return describe(page, part: part, opened: false) }
            guard let page = await readFront(runner: runner) else { return "No page is open in the browser that can be read." }
            runner.lastPage = page
            return describe(page, part: part, opened: false)
        case "find_on_page":
            guard let text = ToolRunTools.string(arguments["text"] ?? arguments["query"] ?? arguments["find"]) else { return "Say what to find." }
            guard let browser = await host.defaultBrowser() else { return "There's no browser." }
            if let script = script(running: findJS(text), in: browser.id), case .success(let out) = await host.appleScript(script), let page = Page(json: out) {
                runner.lastPage = page
                return found(text, in: page)
            }
            // The browser can't be asked: find it in the page fetched, and open it there at the text.
            guard let page = await readFront(runner: runner) else { return "No page is open in the browser that can be read." }
            runner.lastPage = page
            if let url = URL(string: page.url), let at = fragment(url, text) { _ = await host.open(at) }
            return found(text, in: page)
        default:
            return "There is no tool called \(name)."
        }
    }

    /// Opens `url` in the default browser and reads it once it's loaded.
    static func open(_ url: URL, find: String?, runner: SkillRunner, searching: Bool) async -> String {
        let host = runner.host
        let target = find.flatMap { fragment(url, $0) } ?? url
        guard await host.open(target) else { return "The browser didn't open \(url.absoluteString)." }
        let browser = await host.defaultBrowser()
        var page: Page?
        var why: String?
        if let browser, let read = script(running: pageJS, in: browser.id) {
            let deadline = Date().addingTimeInterval(runner.loadWait)
            var last: Page?
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: UInt64(runner.pollInterval * 1_000_000_000))
                switch await host.appleScript(read) {
                case .success(let out):
                    // This page (not the one before it, still in front), and loaded.
                    guard let p = Page(json: out), sameSite(p.url, url) else { continue }
                    last = p
                    if p.ready == "complete", !p.text.isEmpty { page = p }
                case .failure(let e):
                    why = e.message
                }
                if page != nil || why != nil { break }
            }
            if page == nil, why == nil {
                if let last { page = last } else { why = "the page didn't load in \(Int(runner.loadWait)) seconds" }
            }
        } else {
            why = "\(browser?.name ?? "this browser") can't be read by other apps"
        }
        if page == nil { page = await fetched(url, because: why ?? "the browser couldn't be read", host: host) }
        guard var p = page else { return "Opened \(url.absoluteString) in the browser, but couldn't read it (\(why ?? "no answer"))." }
        if let find, p.fetchedBecause == nil, let browser, let s = script(running: findJS(find), in: browser.id),
           case .success(let out) = await host.appleScript(s), let f = Page(json: out) {
            p.found = f.found
        }
        runner.lastPage = p
        var out = describe(p, part: 1, opened: true, browser: browser?.name, searching: searching)
        if let find { out += "\n\n" + found(find, in: p) }
        return out
    }

    /// The front tab, read: in the browser if it lets, else fetched (its address from the browser,
    /// or the last page opened).
    static func readFront(runner: SkillRunner) async -> Page? {
        let host = runner.host
        guard let browser = await host.defaultBrowser() else { return nil }
        var why = "\(browser.name) can't be read by other apps"
        if let s = script(running: pageJS, in: browser.id) {
            switch await host.appleScript(s) {
            case .success(let out): if let p = Page(json: out) { return p }
            case .failure(let e): why = e.message
            }
        }
        var address = runner.lastPage?.url
        if let t = tabScript(browser.id), case .success(let out) = await host.appleScript(t),
           let line = out.components(separatedBy: .newlines).first, FileSkill.webURL(line) != nil {
            address = line
        }
        guard let address, let url = URL(string: address) else { return nil }
        return await fetched(url, because: why, host: host)
    }

    static func fetched(_ url: URL, because why: String, host: MacHost) async -> Page? {
        guard let (_, body) = await host.fetch(url) else { return nil }
        return Page(title: HTMLText.title(body), url: url.absoluteString, text: HTMLText.text(body), fetchedBecause: why)
    }

    /// The same site: a redirect from example.com to www.example.com still counts.
    static func sameSite(_ seen: String, _ wanted: URL) -> Bool {
        guard let a = URL(string: seen)?.host?.lowercased(), let b = wanted.host?.lowercased() else { return false }
        let strip = { (h: String) in h.hasPrefix("www.") ? String(h.dropFirst(4)) : h }
        let x = strip(a), y = strip(b)
        return x == y || x.hasSuffix("." + y) || y.hasSuffix("." + x)
    }

    /// The address with a text fragment, so the browser scrolls to the text and highlights it.
    static func fragment(_ url: URL, _ text: String) -> URL? {
        var allowed = CharacterSet.urlFragmentAllowed
        allowed.remove(charactersIn: "-&,#")
        guard let t = text.trimmingCharacters(in: .whitespacesAndNewlines).addingPercentEncoding(withAllowedCharacters: allowed), !t.isEmpty else { return nil }
        var s = url.absoluteString
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        return URL(string: s + "#:~:text=" + t)
    }

    static func describe(_ p: Page, part: Int, opened: Bool, browser: String? = nil, searching: Bool = false) -> String {
        var lines: [String] = []
        if opened { lines.append("Opened in \(browser ?? "the browser"), where the user sees it.") }
        lines.append("Title: \(p.title.isEmpty ? "(none)" : p.title)")
        lines.append("Address: \(p.url)")
        if let why = p.fetchedBecause {
            lines.append("(Read by fetching the page, since \(why). To let it read the browser itself: in Safari, Develop > Allow JavaScript from Apple Events; in Chrome, View > Developer > Allow JavaScript from Apple Events.)")
        }
        if searching, !p.links.isEmpty {
            lines.append("Results:")
            for (i, l) in p.links.enumerated() { lines.append("\(i + 1). \(l.title) — \(l.url)") }
        }
        let parts = max(1, Int((Double(p.text.count) / Double(partChars)).rounded(.up)))
        let n = min(max(part, 1), parts)
        let start = p.text.index(p.text.startIndex, offsetBy: min((n - 1) * partChars, p.text.count))
        let end = p.text.index(start, offsetBy: min(partChars, p.text.distance(from: start, to: p.text.endIndex)))
        let text = String(p.text[start..<end])
        lines.append(parts > 1 ? "Text (part \(n) of \(parts); read_page with part for more):" : "Text:")
        lines.append(text.isEmpty ? "(no text)" : text)
        return lines.joined(separator: "\n")
    }

    static func found(_ text: String, in p: Page) -> String {
        let places = Snippets.around(text, in: p.text)
        if places.isEmpty { return p.found == true ? "Found “\(text)” on the page (highlighted there)." : "“\(text)” isn't on the page." }
        let head = p.found == false ? "Found “\(text)” \(places.count) time\(places.count == 1 ? "" : "s") in the page's text:" : "Found “\(text)”, highlighted on the page; where it is:"
        return head + "\n" + places.enumerated().map { "\($0.offset + 1). …\($0.element)…" }.joined(separator: "\n")
    }
}

// MARK: - Text from pages

public enum HTMLText {
    /// The page's <title>.
    public static func title(_ html: String) -> String {
        guard let r = html.range(of: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.regularExpression, .caseInsensitive]) else { return "" }
        let inner = String(html[r]).replacingOccurrences(of: #"</?title[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        return decode(inner).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a page says: scripts, styles and tags taken out, entities read, blocks on lines of their own.
    public static func text(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: #"<(script|style|noscript|svg|head)\b[\s\S]*?</\1>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article|/header|/footer)\b[^>]*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return Snippets.tidy(decode(s))
    }

    static func decode(_ s: String) -> String {
        var out = s
        for (k, v) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…")] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        while let r = out.range(of: #"&#(x?)([0-9a-fA-F]+);"#, options: .regularExpression) {
            let body = out[r].dropFirst(2).dropLast()
            let hex = body.hasPrefix("x") || body.hasPrefix("X")
            let n = UInt32(hex ? String(body.dropFirst()) : String(body), radix: hex ? 16 : 10)
            out.replaceSubrange(r, with: n.flatMap { Unicode.Scalar($0) }.map { String(Character($0)) } ?? " ")
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}

public enum Snippets {
    /// Lines trimmed, runs of spaces and blank lines made one.
    public static func tidy(_ text: String) -> String {
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: #"[ \t\x{00A0}]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Each place `query` is in `text` (case and accents ignored), with the words around it.
    public static func around(_ query: String, in text: String, limit: Int = 8, radius: Int = 100) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var out: [String] = []
        var from = text.startIndex
        while out.count < limit, let r = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
            let start = text.index(r.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(r.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
            out.append(text[start..<end].replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces))
            from = r.upperBound
        }
        return out
    }

    /// At most `n` characters, saying so when cut.
    public static func cut(_ text: String, to n: Int) -> String {
        text.count > n ? String(text.prefix(n)) + "… (cut short)" : text
    }
}

// MARK: - Files

/// Files, only to look: Spotlight, folders, and what's in a file. Hidden files and folders, and
/// ~/Library (but for iCloud Drive), are off limits, and so is anything outside the home folder,
/// /Applications, /Users/Shared and /Volumes.
public enum FileSkill {
    public static let tools: [AssistantTools.Tool] = [
        .init(name: "find_files", description: "Finds files on the Mac with Spotlight, by name or by what's in them. Gives back their paths.",
              arguments: [("query", "string: words in the name or the file"), ("limit", "integer, optional: how many, default 20")]),
        .init(name: "list_folder", description: "Lists a folder's files and folders, with sizes and dates.",
              arguments: [("path", "string, optional: the folder; ~ is the home folder (the default), and Desktop, Documents, Downloads are in it")]),
        .init(name: "read_file", description: "Reads a file: text, Markdown, code, CSV, JSON, PDF, RTF or Word. Long files come in parts.",
              arguments: [("path", "string: the file's path, from find_files or list_folder"), ("part", "integer, optional: which part of a long file, 1 is the start")]),
    ]

    static let partChars = 12_000

    /// A path as the model wrote it, made whole: "~/Documents", "Documents/a.txt" (from home), "/Volumes/…".
    public static func resolve(_ path: String, home: URL) -> URL {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hasPrefix("file://"), let u = URL(string: p) { p = u.path }
        if p.isEmpty || p == "~" { return home }
        if p.hasPrefix("~/") { return home.appendingPathComponent(String(p.dropFirst(2))).standardizedFileURL }
        if p.hasPrefix("/") { return URL(fileURLWithPath: p).standardizedFileURL }
        return home.appendingPathComponent(p).standardizedFileURL
    }

    /// May it be looked at?
    public static func allowed(_ url: URL, home: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        let roots = [homePath, "/Applications", "/Users/Shared", "/Volumes"]
        guard let root = roots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return false }
        let rest = path.dropFirst(root.count).split(separator: "/")
        if rest.contains(where: { $0.hasPrefix(".") }) { return false }
        if root == homePath, rest.first == "Library" {
            return rest.count >= 2 && rest[1] == "Mobile Documents"
        }
        return true
    }

    static func run(_ name: String, _ arguments: [String: Any], home: URL, host: MacHost) async -> String {
        switch name {
        case "find_files":
            guard let query = ToolRunTools.string(arguments["query"] ?? arguments["name"]) else { return "Say what to look for." }
            let limit = AssistantTools.limit(arguments, default: 20)
            let paths = await host.spotlight(query, limit: limit * 3).filter { allowed(URL(fileURLWithPath: $0), home: home) }.prefix(limit)
            guard !paths.isEmpty else { return "Spotlight found nothing for “\(query)”." }
            return paths.map { $0.hasPrefix(home.path + "/") ? "~/" + $0.dropFirst(home.path.count + 1) : $0 }.joined(separator: "\n")
        case "list_folder":
            return list(resolve(ToolRunTools.string(arguments["path"] ?? arguments["folder"]) ?? "~", home: home), home: home)
        case "read_file":
            guard let p = ToolRunTools.string(arguments["path"] ?? arguments["file"]) else { return "Give the file's path." }
            let part = Int(ToolRunTools.number(arguments["part"]) ?? 1)
            return await read(resolve(p, home: home), part: part, home: home, host: host)
        default:
            return "There is no tool called \(name)."
        }
    }

    static func list(_ url: URL, home: URL) -> String {
        guard allowed(url, home: home) else { return "That folder is off limits (hidden, in ~/Library, or outside the home folder)." }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return "There's no folder at \(url.path)."
        }
        let rows = items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.prefix(200).map { u -> String in
            let v = try? u.resourceValues(forKeys: Set(keys))
            let date = v?.contentModificationDate.map(AssistantTools.date) ?? ""
            if v?.isDirectory == true { return "\(u.lastPathComponent)/  (folder, \(date))" }
            return "\(u.lastPathComponent)  (\(size(v?.fileSize ?? 0)), \(date))"
        }
        guard !rows.isEmpty else { return "\(url.path) is empty." }
        return "\(url.path):\n" + rows.joined(separator: "\n") + (items.count > 200 ? "\n(and \(items.count - 200) more)" : "")
    }

    static func read(_ url: URL, part: Int, home: URL, host: MacHost) async -> String {
        guard allowed(url, home: home) else { return "That file is off limits (hidden, in ~/Library, or outside the home folder)." }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return "There's no file at \(url.path)." }
        if isDir.boolValue { return list(url, home: home) }
        var text: String?
        if ["pdf", "rtf", "rtfd", "doc", "docx", "odt", "pages", "html", "htm", "webarchive"].contains(url.pathExtension.lowercased()) {
            text = await host.documentText(url)
        }
        if text == nil {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return "\(url.lastPathComponent) couldn't be read." }
            if data.prefix(8000).contains(0) { return "\(url.lastPathComponent) isn't text (\(size(data.count)))." }
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        }
        guard let all = text else { return "\(url.lastPathComponent) couldn't be read." }
        let parts = max(1, Int((Double(all.count) / Double(partChars)).rounded(.up)))
        let n = min(max(part, 1), parts)
        let start = all.index(all.startIndex, offsetBy: (n - 1) * partChars)
        let end = all.index(start, offsetBy: min(partChars, all.distance(from: start, to: all.endIndex)))
        let head = parts > 1 ? "\(url.lastPathComponent) (part \(n) of \(parts); read_file with part for more):\n" : "\(url.lastPathComponent):\n"
        return head + all[start..<end]
    }

    static func size(_ bytes: Int) -> String {
        if bytes < 1_000 { return "\(bytes) bytes" }
        if bytes < 1_000_000 { return "\(bytes / 1_000) KB" }
        if bytes < 1_000_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
        return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    /// http(s) links, and "example.com/…" taken as https.
    public static func webURL(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: t), url.host?.isEmpty == false else { return nil }
            return url
        }
        // A bare domain: letters, a dot, letters (www.example.com, example.com/path).
        guard t.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}(/\S*)?$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "https://" + t)
    }
}

// MARK: - The calculator

/// Arithmetic, worked out exactly: numbers, + - * / ^ % (remainder), parentheses, and a few functions.
public enum Calculator {
    public enum Failure: Error, Equatable { case bad(String) }

    public static func evaluate(_ expression: String) throws -> Double {
        var p = Parser(Array(expression.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: ",", with: "").lowercased()))
        let v = try p.sum()
        p.skip()
        guard p.i == p.c.count else { throw Failure.bad("didn't understand “\(String(p.c[p.i...]))”") }
        return v
    }

    /// The answer as it's told: "42", "3.1415926536", "1.5e+21".
    public static func format(_ x: Double) -> String {
        guard x.isFinite else { return x.isNaN ? "not a number" : (x > 0 ? "infinity" : "minus infinity") }
        if x == x.rounded(), abs(x) < 1e15 { return String(Int64(x)) }
        if abs(x) >= 1e15 || abs(x) < 1e-6 { return String(format: "%.10g", x) }
        var s = String(format: "%.10f", x)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    static func run(_ arguments: [String: Any]) -> String {
        guard let e = ToolRunTools.string(arguments["expression"] ?? arguments["sum"] ?? arguments["input"]) else { return "Give the expression." }
        do {
            return "\(e) = \(format(try evaluate(e)))"
        } catch Failure.bad(let why) {
            return "Couldn't work out \(e): \(why)."
        } catch {
            return "Couldn't work out \(e)."
        }
    }

    struct Parser {
        var c: [Character]
        var i = 0
        init(_ c: [Character]) { self.c = c }

        mutating func skip() { while i < c.count, c[i].isWhitespace { i += 1 } }
        mutating func eat(_ ch: Character) -> Bool {
            skip()
            if i < c.count, c[i] == ch { i += 1; return true }
            return false
        }

        mutating func sum() throws -> Double {
            var v = try product()
            while true {
                if eat("+") { v += try product() } else if eat("-") { v -= try product() } else { return v }
            }
        }

        mutating func product() throws -> Double {
            var v = try power()
            while true {
                if eat("*") { v *= try power() } else if eat("/") { v /= try power() } else if eat("%") { v = v.truncatingRemainder(dividingBy: try power()) } else { return v }
            }
        }

        mutating func power() throws -> Double {
            let base = try unary()
            if eat("^") { return pow(base, try power()) }
            skip()
            if i + 1 < c.count, c[i] == "*", c[i + 1] == "*" {
                i += 2
                return pow(base, try power())
            }
            return base
        }

        mutating func unary() throws -> Double {
            if eat("-") { return -(try unary()) }
            if eat("+") { return try unary() }
            return try atom()
        }

        mutating func atom() throws -> Double {
            skip()
            if eat("(") {
                let v = try sum()
                guard eat(")") else { throw Failure.bad("a bracket isn't closed") }
                return v
            }
            guard i < c.count else { throw Failure.bad("it ends too soon") }
            if c[i].isNumber || c[i] == "." {
                let s = i
                while i < c.count, c[i].isNumber || c[i] == "." { i += 1 }
                if i < c.count, c[i] == "e", i + 1 < c.count, c[i + 1].isNumber || c[i + 1] == "-" || c[i + 1] == "+" {
                    i += 2
                    while i < c.count, c[i].isNumber { i += 1 }
                }
                guard let v = Double(String(c[s..<i])) else { throw Failure.bad("“\(String(c[s..<i]))” isn't a number") }
                return v
            }
            if c[i].isLetter {
                let s = i
                while i < c.count, c[i].isLetter || c[i].isNumber { i += 1 }
                let name = String(c[s..<i])
                switch name {
                case "pi": return .pi
                case "e": return M_E
                default: break
                }
                let fns: [String: (Double) -> Double] = ["sqrt": { $0.squareRoot() }, "sin": sin, "cos": cos, "tan": tan, "log": log10, "ln": log,
                                                          "abs": { abs($0) }, "round": { $0.rounded() }, "floor": { $0.rounded(.down) }, "ceil": { $0.rounded(.up) },
                                                          "exp": exp, "asin": asin, "acos": acos, "atan": atan]
                guard let f = fns[name] else { throw Failure.bad("there's no \(name)") }
                return f(try atom())
            }
            throw Failure.bad("didn't understand “\(c[i])”")
        }
    }
}
