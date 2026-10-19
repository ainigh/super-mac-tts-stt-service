import Foundation

/// Who may call: programs on this Mac always; browsers only from allowed origins; other machines
/// only when sharing on the network is on, and with the token.
public enum Access {
    /// Why a request is refused, or nil to let it through.
    public static func refusal(_ req: HTTPRequest, settings: ServiceSettings) -> HTTPError? {
        if !settings.allowNetwork, let host = req.header("host"), !isLoopbackHost(host) {
            // A website pointing its own name at 127.0.0.1 (DNS rebinding) says that name here.
            return HTTPError(status: 403, code: "forbidden", message: "requests for another host are refused")
        }
        if let origin = req.header("origin"), !originAllowed(origin, settings: settings) {
            return HTTPError(status: 403, code: "forbidden", message: "cross-site request refused (allow \(origin) in Super Voice's settings)")
        }
        if !req.fromLoopback {
            guard settings.allowNetwork, !settings.token.isEmpty else {
                return HTTPError(status: 403, code: "forbidden", message: "only this Mac may call")
            }
            if bearer(req) != settings.token {
                return HTTPError(status: 401, code: "unauthorized", message: "send Authorization: Bearer <token> (the token is in Super Voice's panel)")
            }
        }
        return nil
    }

    static func bearer(_ req: HTTPRequest) -> String? {
        guard let auth = req.header("authorization") else { return nil }
        let parts = auth.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return parts[1].trimmingCharacters(in: .whitespaces)
    }

    /// localhost, 127.0.0.1, [::1], with or without a port.
    public static func isLoopbackHost(_ host: String) -> Bool {
        var h = host.lowercased().trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("[") {
            h = String(h.dropFirst().prefix { $0 != "]" })
        } else if let colon = h.lastIndex(of: ":") {
            h = String(h[..<colon])
        }
        if h == "localhost" || h == "::1" || h.hasSuffix(".localhost") { return true }
        // 127.x.x.x, as an address (not a name like 127.0.0.1.example.com).
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { UInt8($0) != nil }
    }

    public static func originAllowed(_ origin: String, settings: ServiceSettings) -> Bool {
        if let url = URL(string: origin), url.scheme == "http", let host = url.host,
           isLoopbackHost(host.contains(":") ? "[\(host)]" : host) {
            return true
        }
        return settings.origins.contains { glob($0, matches: origin) }
    }

    /// `*` matches anything (including nothing).
    public static func glob(_ pattern: String, matches s: String) -> Bool {
        let p = Array(pattern.lowercased()), t = Array(s.lowercased())
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi
                mark = ti
                pi += 1
            } else if star >= 0 {
                pi = star + 1
                mark += 1
                ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// CORS headers for an allowed origin.
    public static func cors(_ req: HTTPRequest, settings: ServiceSettings) -> [(String, String)] {
        guard let origin = req.header("origin"), originAllowed(origin, settings: settings) else { return [] }
        return [
            ("Access-Control-Allow-Origin", origin),
            ("Vary", "Origin"),
            ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
            ("Access-Control-Allow-Headers", "Content-Type, Authorization"),
            ("Access-Control-Expose-Headers", "X-Voice, X-Sample-Rate, X-Duration"),
            ("Access-Control-Max-Age", "600"),
        ]
    }
}
