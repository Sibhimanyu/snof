import Foundation

/* The water chain: river motor (Livesky) -> the other farm's two motors
 * (Niagara) -> the main farm (Mobitech DCON). Read-only. The water Cloud
 * Functions write farms/<farm>/water and meta/water; this is their shape,
 * mirroring waterView() in dashboard/public/app.js. docs/water.md. */

public struct WaterMotor: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// livesky | niagara
    public var vendor: String
    /// main-farm | drip | "" (Niagara group role)
    public var role: String = ""
    public var group: String = ""
    /// The controller's own report. nil when it has not said.
    public var running: Bool?
    /// Livesky: a change the starter has not acknowledged ("-inprogress").
    public var pending = false
    /// Niagara: what its app last asked for; differs from `running` while a
    /// change is on its way. Not the motor's state.
    public var requested: Bool?
    public var connected: Bool?
    public var power = false
    public var supply = ""
    public var volts: [Double] = []
    public var amps: [Double] = []
    public var runMinutes: Int?
    public var stopMinutes: Int?
    public var autoStart: Bool?
    public var trips: [String] = []
    public var program: String?
    public var zone: Int?
    public var zoneLeft: String?
    public var pressureOut: Double?
    public var skippedZone: Int?
    public var event = ""
    public var eventCode = ""
    /// Controller report, and (zoned Niagara) the server's last live packet.
    public var reportedAt: Date?
    public var liveAt: Date?

    public init(id: String, name: String, vendor: String) {
        self.id = id; self.name = name; self.vendor = vendor
    }

    public var lastReport: Date? { liveAt ?? reportedAt }

    /// One line when a change is on its way, else nil.
    public var pendingText: String? {
        if vendor == "livesky" { return pending ? "A change is on its way to the starter." : nil }
        guard let req = requested, let run = running, req != run else { return nil }
        return req ? "Asked to start; the controller has not reported it running yet."
                   : "Asked to stop; the controller has not reported it off yet."
    }

    public var roleText: String {
        switch role {
        case "main-farm": return "For the main farm's water"
        case "drip": return "For this farm's own drip zones"
        default: return group
        }
    }
}

public struct VendorStatus: Hashable, Sendable {
    public var ok: Bool?
    public var error = ""
    public var at: Double?
    public init() {}
}

public struct LiveskySession: Hashable, Sendable {
    public var signedInAt: Double?
    public var expires: Double?
    public var mobileLast4 = ""
    public var status = VendorStatus()
    public init() {}

    public enum Kind: Equatable { case ok, none, expired, error }

    public func kind(nowMs: Double) -> Kind {
        if signedInAt == nil && expires == nil { return .none }
        if let e = expires, e <= nowMs { return .expired }
        if status.ok == false, !status.error.isEmpty { return .error }
        return .ok
    }
}

public struct WaterState: Hashable, Sendable {
    public var river: WaterMotor?
    /// The main-farm supply first, then the rest by name.
    public var motors: [WaterMotor] = []
    public var pulledAt: Double?
    /// meta/water.enabled: only an explicit true opens it (off by default).
    public var enabled = false
    public var livesky = LiveskySession()
    public var niagara = VendorStatus()
    public init() {}

    public var supply: [WaterMotor] { motors.filter { $0.role == "main-farm" } }

    /// Whether a motor's reading says what it is doing now: its vendor
    /// answered a recent pull and, for Livesky (the starter reports every few
    /// seconds), its own report is recent too. Niagara reports on change, so
    /// an hour-old "motor on" with no "off" since is still the state. A reading
    /// that is not current is drawn with its age, never as water flowing
    /// (2026-09-25: Home showed "River · Running" after the Livesky session
    /// ended). Mirrors waterCurrent() in app.js.
    public func isCurrent(_ m: WaterMotor?, now: Date) -> Bool {
        let nowMs = now.timeIntervalSince1970 * 1000
        guard let m else { return false }
        // A vendor's own `at` is stamped only when its read succeeded;
        // `pulledAt` is stamped on every pull, failed or not.
        if m.vendor == "livesky" {
            guard livesky.kind(nowMs: nowMs) == .ok, let read = livesky.status.at ?? pulledAt,
                  nowMs - read <= 10 * 60_000, let at = m.lastReport else { return false }
            return now.timeIntervalSince(at) < 15 * 60
        }
        guard let read = niagara.at ?? (niagara.ok != false ? pulledAt : nil) else { return false }
        return nowMs - read <= 10 * 60_000
    }

    /// When a reading that is not current was taken: the starter's own report
    /// for Livesky, Niagara's last good read (its reports only mark changes).
    public func readingDate(_ m: WaterMotor) -> Date? {
        m.vendor == "livesky" ? m.lastReport : (niagara.at ?? pulledAt).map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

extension Parse {
    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    static func numbers(_ v: Any?) -> [Double] {
        (v as? [Any] ?? []).compactMap { double($0) }
    }

    static func motor(id: String, _ v: Any?) -> WaterMotor? {
        guard let d = v as? [String: Any] else { return nil }
        var m = WaterMotor(id: id, name: string(d["name"]) ?? "Motor", vendor: string(d["vendor"]) ?? "")
        m.role = string(d["role"]) ?? ""
        m.group = string(d["group"]) ?? ""
        m.running = bool(d["running"])
        m.pending = bool(d["pending"]) ?? false
        m.requested = bool(d["requested"])
        m.connected = bool(d["connected"])
        m.power = bool(d["power"]) ?? false
        m.supply = string(d["supply"]) ?? ""
        m.volts = numbers(d["volts"])
        m.amps = numbers(d["amps"])
        m.runMinutes = double(d["runMinutes"]).map { Int($0) }
        m.stopMinutes = double(d["stopMinutes"]).map { Int($0) }
        m.autoStart = bool(d["autoStart"])
        m.trips = (d["trips"] as? [Any] ?? []).compactMap { string($0) }
        m.program = string(d["program"])
        m.zone = double(d["zone"]).map { Int($0) }
        m.zoneLeft = string(d["zoneLeft"])
        m.pressureOut = double(d["pressureOut"])
        m.skippedZone = double(d["skippedZone"]).map { Int($0) }
        m.event = string(d["event"]) ?? ""
        m.eventCode = string(d["eventCode"]) ?? ""
        m.reportedAt = string(d["reportedAt"]).flatMap { isoParser.date(from: $0) }
        m.liveAt = string(d["liveAt"]).flatMap { isoParser.date(from: $0) }
        return m
    }

    /// farms/<farm>/water + meta/water -> one state.
    public static func water(_ v: Any?, meta: Any?) -> WaterState {
        var w = WaterState()
        if let d = v as? [String: Any] {
            w.river = motor(id: "river", d["river"])
            w.pulledAt = double(d["pulledAt"])
            let ms = (d["motors"] as? [String: Any] ?? [:]).compactMap { motor(id: $0.key, $0.value) }
            w.motors = ms.sorted {
                ($0.role == "main-farm" ? 0 : 1, $0.name) < ($1.role == "main-farm" ? 0 : 1, $1.name)
            }
        }
        let m = (meta as? [String: Any])?["water"] as? [String: Any]
        w.enabled = bool(m?["enabled"]) == true
        func status(_ x: Any?) -> VendorStatus {
            var s = VendorStatus()
            let d = x as? [String: Any]
            s.ok = bool(d?["ok"]); s.error = string(d?["error"]) ?? ""; s.at = double(d?["at"])
            return s
        }
        let ls = m?["livesky"] as? [String: Any]
        w.livesky.signedInAt = double(ls?["signedInAt"])
        w.livesky.expires = double(ls?["expires"])
        w.livesky.mobileLast4 = string(ls?["mobileLast4"]) ?? ""
        w.livesky.status = status(ls)
        w.niagara = status(m?["niagara"])
        return w
    }
}

public enum WaterFormat {
    /// 196 -> "3 h 16 min"
    public static func minutes(_ m: Int) -> String {
        m < 60 ? "\(m) min" : "\(m / 60) h \(String(format: "%02d", m % 60)) min"
    }

    /// [451, 468, 458], "V" -> "451 · 468 · 458 V"
    public static func list(_ xs: [Double], _ unit: String) -> String? {
        guard !xs.isEmpty else { return nil }
        let parts = xs.map { $0 == $0.rounded() ? String(Int($0)) : String(format: "%.1f", $0) }
        return parts.joined(separator: " · ") + " " + unit
    }

    /// "00:32:31" -> "32:31", "01:04:28" -> "1:04:28"
    public static func hms(_ s: String) -> String {
        var t = s
        if t.hasPrefix("00:") { t.removeFirst(3) }
        if t.hasPrefix("0"), t.count > 4 { t.removeFirst() }
        return t
    }
}
