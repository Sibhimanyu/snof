import Foundation

/* The owner's developer console: raw, read-only Mobitech requests sent through
 * the NUC (contract: .context/dev-console-contract.md). Everything here is pure
 * so it can be tested: the curl parser, the request builder, the client-side
 * refusal, and the JSON tree. The token never reaches the phone: requests carry
 * {{token}} placeholders and the NUC fills them in. */

public struct DevRequest: Equatable, Codable, Sendable {
    public var method: String        // GET | POST
    public var path: String          // /v1/http/
    public var query: String         // a=b&c=d, may be ""
    public var body: String          // may be ""
    public var bodyType: String      // form | json | none
    public var auth: Bool

    public init(method: String = "POST", path: String = "/v1/http/", query: String = "",
                body: String = "", bodyType: String = "form", auth: Bool = false) {
        self.method = method; self.path = path; self.query = query
        self.body = body; self.bodyType = bodyType; self.auth = auth
    }
}

public struct DevResult: Equatable, Sendable {
    public var status: Int
    public var ms: Int
    public var json: Bool
    public var body: String
    public var truncated: Bool
    public var error: String?
    public var size: Int { body.utf8.count }

    public init(status: Int, ms: Int, json: Bool, body: String, truncated: Bool, error: String? = nil) {
        self.status = status; self.ms = ms; self.json = json; self.body = body
        self.truncated = truncated; self.error = error
    }

    /// farms/<farm>/dev_results/<id>
    public static func parse(_ v: Any?) -> DevResult? {
        guard let d = v as? [String: Any] else { return nil }
        guard let status = Parse.double(d["status"]) else { return nil }
        return DevResult(status: Int(status), ms: Int(Parse.double(d["ms"]) ?? 0),
                         json: Parse.bool(d["json"]) ?? false, body: Parse.string(d["body"]) ?? "",
                         truncated: Parse.bool(d["truncated"]) ?? false, error: Parse.string(d["error"]))
    }
}

public enum DevConsole {
    public static let host = "dcon.mobitechwireless.com"
    public static let placeholders = ["{{token}}", "{{serial}}", "{{device_id}}"]
    public static let timeoutSeconds: Double = 30
    public static let historyLimit = 20

    // MARK: query rows

    public static func queryRows(_ q: String) -> [(key: String, value: String)] {
        q.split(separator: "&", omittingEmptySubsequences: true).map { part in
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(kv[0]), kv.count > 1 ? String(kv[1]) : "")
        }
    }

    public static func joinRows(_ rows: [(key: String, value: String)]) -> String {
        rows.filter { !$0.key.isEmpty }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }

    // MARK: refusal

    public static let readsOnly = "Only reads are allowed from the console"

    private static let reportsMethods: [String: (key: String, values: Set<String>?)] = [
        "dashboard": ("", nil), "dcon_node_details": ("type", ["get"]),
        "dcon_node": ("method", ["get_node", "get_all_valve"]),
        "dcon_timer": ("method", ["select"]),
        "logs": ("method", ["motor_log", "timer_log", "valve_log", "flow_log"]),
        "reports": ("", nil),
        "ferti": ("type", ["tank_get", "inj_get", "get", "tank_log_web"]),
        "fertiSett": ("type", ["get"]), "getWliData": ("", nil), "cmd_status": ("", nil),
    ]

    /// Form fields of a query/body, or nil when a key repeats.
    private static func fields(_ text: String, json: Bool) -> [String: String]? {
        var out: [String: String] = [:]
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if json || t.hasPrefix("{") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any] else { return t.isEmpty ? [:] : nil }
            for (k, v) in o { out[k] = (v as? String) ?? String(describing: v) }
            return out
        }
        for part in t.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let k = decoded(String(kv[0])), v = kv.count > 1 ? decoded(String(kv[1])) : ""
            if out[k] != nil { return nil }
            out[k] = v
        }
        return out
    }

    /// An allow-list mirroring the farm box: nil when the request is a permitted
    /// read, otherwise why not. Paths /v1/http/ and /v1/weather/cumulative/ only.
    public static func refusal(_ r: DevRequest) -> String? {
        guard r.method == "GET" || r.method == "POST" else { return "Only GET and POST." }
        if r.query.count > 2000 { return "The query is too long (2000 characters at most)." }
        if r.body.count > 8000 { return "The body is too long (8000 characters at most)." }
        guard r.path == "/v1/http/" || r.path == "/v1/weather/cumulative/" else { return readsOnly }
        guard let q = fields(r.query, json: false), let b = fields(r.body, json: r.bodyType == "json") else { return readsOnly }
        var f = q
        for (k, v) in b { if let old = f[k], old != v { return readsOnly }; f[k] = v }
        let low = f.mapValues { $0.lowercased() }
        if low["type"] == "otp" || low.values.contains(where: { $0.contains("/v1/command") }) { return readsOnly }
        if r.path == "/v1/weather/cumulative/" {
            return f["type"] == "rain" && f["action"] == nil ? nil : readsOnly
        }
        guard let action = f["action"], let rule = reportsMethods[action] else { return readsOnly }
        if let values = rule.values {
            guard let v = f[rule.key], values.contains(v) else { return readsOnly }
        }
        return nil
    }

    /// The same request with anything token-shaped replaced by {{token}}.
    public static func scrubbed(_ r: DevRequest) -> DevRequest {
        var c = r
        c.path = scrubTokens(r.path); c.query = scrubTokens(r.query); c.body = scrubTokens(r.body)
        return c
    }

    private static func decoded(_ s: String) -> String {
        let plus = s.replacingOccurrences(of: "+", with: " ")
        return plus.removingPercentEncoding ?? plus
    }

    // MARK: tokens

    /// Any value that looks like a Mobitech token (40+ characters ending @ios,
    /// or its URL-encoded %40ios form) becomes {{token}}.
    public static func scrubTokens(_ s: String) -> String {
        s.replacingOccurrences(of: "[^\\s\"'&=?,;]{34,}(@|%40)ios", with: "{{token}}", options: .regularExpression)
    }

    // MARK: build

    /// What goes to dev_requests (without `at`, which the server stamps).
    public static func node(_ r: DevRequest, uid: String) -> [String: Any] {
        ["uid": uid, "method": r.method, "path": r.path, "query": r.query, "body": r.body,
         "bodyType": r.body.isEmpty ? "none" : r.bodyType, "auth": r.auth]
    }

    public static func curl(_ r: DevRequest) -> String {
        var url = "https://\(host)\(r.path)"
        if !r.query.isEmpty { url += "?\(r.query)" }
        var parts = ["curl", "-X", r.method, shq(url)]
        if r.auth { parts += ["-H", shq("authorization: {{token}}")] }
        if !r.body.isEmpty {
            if r.bodyType == "json" { parts += ["-H", shq("content-type: application/json")] }
            parts += ["--data-raw", shq(r.body)]
        }
        return parts.joined(separator: " ")
    }

    private static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: curl parser

    public enum CurlError: Error, Equatable, LocalizedError {
        case notCurl, noURL, wrongHost(String)
        public var errorDescription: String? {
            switch self {
            case .notCurl: return "That does not look like a curl command."
            case .noURL: return "No URL found in that curl command."
            case .wrongHost(let h): return "Only \(DevConsole.host) is allowed (found \(h))."
            }
        }
    }

    public static func shellWords(_ text: String) -> [String] {
        var words: [String] = [], cur = "", has = false
        let chars = Array(text.replacingOccurrences(of: "\\\r\n", with: " ").replacingOccurrences(of: "\\\n", with: " "))
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "'" {
                has = true; i += 1
                while i < chars.count, chars[i] != "'" { cur.append(chars[i]); i += 1 }
            } else if c == "\"" {
                has = true; i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count, "\"\\$`".contains(chars[i + 1]) { i += 1 }
                    cur.append(chars[i]); i += 1
                }
            } else if c == "\\", i + 1 < chars.count {
                has = true; i += 1; cur.append(chars[i])
            } else if c == "$", i + 1 < chars.count, chars[i + 1] == "'" {
                // $'…' quoting: keep the text, honour \n \t \' \\
                has = true; i += 2
                while i < chars.count, chars[i] != "'" {
                    if chars[i] == "\\", i + 1 < chars.count {
                        i += 1
                        switch chars[i] { case "n": cur.append("\n"); case "t": cur.append("\t"); default: cur.append(chars[i]) }
                    } else { cur.append(chars[i]) }
                    i += 1
                }
            } else if c.isWhitespace {
                if has { words.append(cur); cur = ""; has = false }
            } else { cur.append(c); has = true }
            i += 1
        }
        if has { words.append(cur) }
        return words
    }

    public static func parseCurl(_ text: String) throws -> DevRequest {
        var w = shellWords(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let first = w.first, first == "curl" || first.hasSuffix("/curl") else { throw CurlError.notCurl }
        w.removeFirst()
        var method: String?, url: String?, data: [String] = [], authHeader = false, json = false, get = false
        let withArg: Set<String> = ["-o", "-A", "-e", "-b", "-u", "-m", "-w", "-x", "-c", "-K", "-T", "-F", "-Y", "-y",
                                    "--max-time", "--connect-timeout", "--user-agent", "--referer", "--cookie", "--proxy",
                                    "--output", "--user", "--retry", "--cacert", "--resolve", "--write-out"]
        let dataFlags: Set<String> = ["-d", "--data", "--data-raw", "--data-binary", "--data-ascii", "--data-urlencode"]
        var i = 0
        func take(_ attached: String?) -> String? {
            if let a = attached, !a.isEmpty { return a }
            i += 1; return i < w.count ? w[i] : nil
        }
        while i < w.count {
            let a = w[i]
            if a.hasPrefix("--") {
                let eq = a.firstIndex(of: "=")
                let name = eq.map { String(a[..<$0]) } ?? a
                let inline = eq.map { String(a[a.index(after: $0)...]) }
                switch name {
                case "--request": method = take(inline)?.uppercased()
                case "--header":
                    if let h = take(inline) { header(h, &authHeader, &json) }
                case "--url": url = take(inline)
                case "--get": get = true
                case _ where dataFlags.contains(name):
                    if let d = take(inline) { data.append(d) }
                case _ where withArg.contains(name): _ = take(inline)
                default: break
                }
            } else if a.hasPrefix("-"), a.count > 1 {
                let flag = String(a.prefix(2)), rest = String(a.dropFirst(2))
                switch flag {
                case "-X": method = take(rest)?.uppercased()
                case "-H": if let h = take(rest) { header(h, &authHeader, &json) }
                case "-G": get = true
                case "-d": if let d = take(rest) { data.append(d) }
                case _ where withArg.contains(flag): _ = take(rest)
                default: break   // -s -L -k -i -v -I …
                }
            } else if url == nil { url = a }
            i += 1
        }
        guard var u = url else { throw CurlError.noURL }
        if !u.contains("://") { u = "https://" + u }
        guard let comps = URLComponents(string: u), let h = comps.host else { throw CurlError.noURL }
        guard h.lowercased() == host else { throw CurlError.wrongHost(h) }
        var path = comps.percentEncodedPath.isEmpty ? "/" : comps.percentEncodedPath
        if path.count > 1, !path.hasSuffix("/") , path.hasPrefix("/v1/http") { path += "/" }
        var query = comps.percentEncodedQuery ?? ""
        var body = data.joined(separator: "&")
        if get, !body.isEmpty { query = query.isEmpty ? body : query + "&" + body; body = "" }
        let m = method ?? (body.isEmpty ? "GET" : "POST")
        var bodyType = "none"
        if !body.isEmpty {
            let looksJSON = (try? JSONSerialization.jsonObject(with: Data(body.utf8), options: [.fragmentsAllowed])) != nil
                && (body.hasPrefix("{") || body.hasPrefix("["))
            bodyType = (json || looksJSON) && looksJSON ? "json" : "form"
        }
        return DevRequest(method: m == "POST" ? "POST" : "GET", path: path, query: scrubTokens(query),
                          body: scrubTokens(body), bodyType: bodyType, auth: authHeader)
    }

    private static func header(_ h: String, _ auth: inout Bool, _ json: inout Bool) {
        let low = h.lowercased()
        if low.hasPrefix("authorization:") { auth = true }
        if low.hasPrefix("content-type:"), low.contains("json") { json = true }
    }

    // MARK: presets

    public struct Preset: Identifiable, Sendable {
        public let id: String
        public let request: DevRequest
    }

    private static func form(_ id: String, _ q: String) -> Preset {
        Preset(id: id, request: DevRequest(method: "GET", path: "/v1/http/", query: q, auth: false))
    }

    /// From docs/mobitech-app.md. serial_no is filled by the NUC.
    public static let presets: [Preset] = [
        form("dashboard", "action=dashboard&p=app&token_id={{token}}&serial_no={{serial}}&product=DCON"),
        form("dcon_node_details", "action=dcon_node_details&type=get&serial_no={{serial}}&token_id={{token}}"),
        form("get_node", "action=dcon_node&method=get_node&serial_no={{serial}}&token_id={{token}}"),
        form("get_all_valve (today)", "action=dcon_node&method=get_all_valve&from=YYYY-MM-DD&to=YYYY-MM-DD&serial_no={{serial}}&token_id={{token}}"),
        form("programs (dcon_timer select)", "action=dcon_timer&method=select&serial_no={{serial}}&token_id={{token}}"),
        form("timer_log", "action=logs&method=timer_log&serial_no={{serial}}&from=YYYY-MM-DD&to=YYYY-MM-DD&token_id={{token}}"),
        form("motor_log", "action=logs&method=motor_log&serial_no={{serial}}&from=YYYY-MM-DD&to=YYYY-MM-DD&token_id={{token}}"),
        form("electricity", "action=reports&type=electricity&serial_no={{serial}}&dt=YYYY-MM-DD HH:MM&product=DCON&token_id={{token}}"),
        form("electricity_day", "action=reports&type=electricity_day&serial_no={{serial}}&dt=YYYY-MM-DD&product=DCON&token_id={{token}}"),
        form("pressure_cond", "action=reports&type=pressure_cond&serial_no={{serial}}&dt=YYYY-MM-DD&product=DCON&token_id={{token}}"),
        form("pressure_day", "action=reports&type=pressure_day&serial_no={{serial}}&dt=YYYY-MM-DD&product=DCON&token_id={{token}}"),
        form("fertiSett", "action=fertiSett&type=get&serial_no={{serial}}&product=DCON&token_id={{token}}"),
        form("tank_get", "action=ferti&type=tank_get&serial_no={{serial}}&token_id={{token}}"),
        form("inj_get", "action=ferti&type=inj_get&serial_no={{serial}}&token_id={{token}}"),
        form("getWliData", "action=getWliData&serial_no={{serial}}&dt=&token_id={{token}}"),
        Preset(id: "rain", request: DevRequest(method: "GET", path: "/v1/weather/cumulative/",
                                               query: "device_id={{device_id}}&type=rain", auth: true)),
        form("cmd_status (random_no)", "action=cmd_status&random_no=&serial_no={{serial}}&token_id={{token}}"),
    ]

    // MARK: history

    public struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
        public var id: String
        public var at: Double            // ms since 1970
        public var request: DevRequest
        public var status: Int
        public var ms: Int
        public var json: Bool
        public var body: String
        public var truncated: Bool
        public var error: String?
        public init(id: String = UUID().uuidString, at: Double, request: DevRequest, result: DevResult) {
            self.id = id; self.at = at; self.request = request; self.status = result.status; self.ms = result.ms
            self.json = result.json; self.truncated = result.truncated; self.error = result.error
            self.body = String(result.body.prefix(40_000))
        }
        public var result: DevResult {
            DevResult(status: status, ms: ms, json: json, body: body, truncated: truncated, error: error)
        }
    }

    /// Newest first, deduplicated by id, capped.
    public static func pushHistory(_ list: [HistoryEntry], _ e: HistoryEntry) -> [HistoryEntry] {
        Array(([e] + list.filter { $0.id != e.id }).prefix(historyLimit))
    }
}

/* ---- JSON tree ---- */

public enum JSONTree {
    public enum Kind: Sendable { case object, array, string, number, bool, null }

    public struct Node: Identifiable, Sendable {
        public let id: String          // path, e.g. "$.packets.2[0]"
        public let key: String?
        public let kind: Kind
        public let text: String        // scalar text, or "" for containers
        public let children: [Node]
        public var isContainer: Bool { kind == .object || kind == .array }
        /// "{3}" / "[12]"
        public var summary: String { kind == .object ? "{\(children.count)}" : kind == .array ? "[\(children.count)]" : text }
    }

    public struct Row: Identifiable, Sendable {
        public let id: String
        public let depth: Int
        public let key: String?
        public let kind: Kind
        public let text: String
        public let isContainer: Bool
        public let isOpen: Bool
        public let count: Int
    }

    public static func parse(_ text: String) -> Node? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else { return nil }
        return node(obj, key: nil, path: "$")
    }

    private static func node(_ v: Any, key: String?, path: String) -> Node {
        if let d = v as? [String: Any] {
            let kids = d.keys.sorted().map { node(d[$0]!, key: $0, path: path + "." + $0) }
            return Node(id: path, key: key, kind: .object, text: "", children: kids)
        }
        if let a = v as? [Any] {
            let kids = a.enumerated().map { node($1, key: String($0), path: path + "[\($0)]") }
            return Node(id: path, key: key, kind: .array, text: "", children: kids)
        }
        if v is NSNull { return Node(id: path, key: key, kind: .null, text: "null", children: []) }
        if let n = v as? NSNumber {
            if String(cString: n.objCType) == "c" { return Node(id: path, key: key, kind: .bool, text: n.boolValue ? "true" : "false", children: []) }
            return Node(id: path, key: key, kind: .number, text: n.stringValue, children: [])
        }
        return Node(id: path, key: key, kind: .string, text: "\"\(v)\"", children: [])
    }

    /// Ids of every container: "expand all" is this set.
    public static func containerIDs(_ n: Node) -> Set<String> {
        var out = Set<String>()
        func walk(_ n: Node) { if n.isContainer { out.insert(n.id); n.children.forEach(walk) } }
        walk(n)
        return out
    }

    /// Root and its direct containers open: a sensible first view.
    public static func defaultOpen(_ n: Node) -> Set<String> {
        var s: Set<String> = n.isContainer ? [n.id] : []
        for c in n.children where c.isContainer { s.insert(c.id) }
        return s
    }

    public static func rows(_ n: Node, open: Set<String>) -> [Row] {
        var out: [Row] = []
        func walk(_ n: Node, depth: Int) {
            let isOpen = n.isContainer && open.contains(n.id)
            out.append(Row(id: n.id, depth: depth, key: n.key, kind: n.kind, text: n.summary,
                           isContainer: n.isContainer, isOpen: isOpen, count: n.children.count))
            if isOpen { n.children.forEach { walk($0, depth: depth + 1) } }
        }
        walk(n, depth: 0)
        return out
    }

    public static func pretty(_ text: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
