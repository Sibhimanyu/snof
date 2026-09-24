import Foundation

/* The rules the web dashboard (dashboard/public/app.js) applies, ported
 * one-for-one. Where the two could disagree, the web version is the reference
 * and this file should change to match it. */

public enum Farm {
    /// The RTDB farm slug. Same constant as `FARM` in app.js.
    public static let slug = "snof"

    /// Heartbeats missed before the bridge counts as stale.
    public static let staleFactor = 2.5
    /// How long an optimistic control waits for the farm to agree.
    public static let commandTimeout: Duration = .seconds(12)
    /// How long to watch for a report before saying it is late.
    public static let reportTimeout: Duration = .seconds(60)

    /* Domains the app offers controls for. cover, lock and alarm_control_panel
     * are excluded deliberately, here as in the RTDB rules and the bridge:
     * opening a gate or unlocking a door from a phone is a separate security
     * decision, not a config tweak. */
    public static let controllable: Set<String> = ["switch", "light", "fan", "input_boolean"]

    static let onStates: Set<String> = ["on", "open", "opening", "home", "playing", "unlocked", "detected"]
    static let offStates: Set<String> = ["off", "closed", "closing", "not_home", "idle", "standby", "locked"]
    static let badStates: Set<String> = ["unavailable", "unknown"]
}

public enum StateTone: Sendable { case on, off, unavailable, neutral }

extension Entity {
    public var isOn: Bool { state.map { Farm.onStates.contains($0) } ?? false }
    public var isBad: Bool {
        guard let s = state, !s.isEmpty else { return true }
        return Farm.badStates.contains(s)
    }
    public var isControllable: Bool { Farm.controllable.contains(domain) }

    public var tone: StateTone {
        if isBad { return .unavailable }
        if isOn { return .on }
        if let s = state, Farm.offStates.contains(s) { return .off }
        return .neutral
    }

    /// "34.2%", "31.4 °C", "ON".
    public var formattedState: String {
        guard let s = state, !s.isEmpty else { return "—" }
        if let unit = attrs.unit {
            return unit == "%" ? "\(s)%" : "\(s) \(unit)"
        }
        if s == "on" || s == "off" { return s.uppercased() }
        return s
    }

    /// Slider position in percent, or nil when the entity has no level to set.
    public var level: Int? {
        switch domain {
        case "fan": return attrs.percentage.map { Int($0.rounded()) }
        case "light": return attrs.brightness.map { Int(($0 / 255 * 100).rounded()) }
        default: return nil
        }
    }

    /// "moisture, 82% battery" — the extra context a row carries.
    public var subtitle: String {
        var bits: [String] = []
        if let dc = attrs.deviceClass { bits.append(dc) }
        if let b = attrs.batteryLevel { bits.append("\(Int(b.rounded()))% battery") }
        return bits.joined(separator: ", ")
    }

    public var humanDomain: String { Entity.humanDomain(domain) }
    public static func humanDomain(_ d: String) -> String { d.replacingOccurrences(of: "_", with: " ") }

    /// Search haystack, matching app.js `matches()`.
    public func matches(_ query: String, areaName: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return true }
        return "\(name) \(entityId) \(state ?? "") \(areaName)".lowercased().contains(q)
    }
}

/* ---- sorting and grouping ---- */

public enum Sorting {
    /// "Zone 2" before "Zone 10".
    public static func natural(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    public static func byName(_ a: Entity, _ b: Entity) -> Bool { natural(a.name, b.name) }

    /// Only entities in a real room exist in the app. The bridge already
    /// refuses to publish anything without an area; this is the second net, so
    /// a stale node or one whose room was just deleted never surfaces as an
    /// "Unassigned" pile or becomes pressable.
    public static func inRooms(_ ents: [Entity], areas: [String: Area]) -> [Entity] {
        ents.filter { $0.area != Area.unassigned && areas[$0.area] != nil }
    }

    /// Areas by name.
    public static func groupByArea(_ ents: [Entity], name: (String) -> String) -> [(id: String, entities: [Entity])] {
        let grouped = Dictionary(grouping: ents, by: \.area)
        return grouped.map { (id: $0.key, entities: $0.value) }.sorted { natural(name($0.id), name($1.id)) }
    }

    /// Operable domains first: the reason to open a room is usually to do something.
    public static func domainsForArea(_ ents: [Entity]) -> [(domain: String, entities: [Entity])] {
        Dictionary(grouping: ents, by: \.domain)
            .map { (domain: $0.key, entities: $0.value.sorted(by: byName)) }
            .sorted { a, b in
                let ca = Farm.controllable.contains(a.domain) ? 0 : 1
                let cb = Farm.controllable.contains(b.domain) ? 0 : 1
                return ca != cb ? ca < cb : a.domain < b.domain
            }
    }

    /* Quick controls: active first, then the rest, alphabetical within each.
     * Unavailable devices are excluded outright — with 15 active out of 698 the
     * slots otherwise filled with alphabetically-early dead switches (bug 4 in
     * docs/dashboard.md). */
    public static func quickControls(_ all: [Entity], limit: Int = 8) -> (shown: [Entity], operable: Int) {
        let operable = all.filter { $0.isControllable && !$0.isBad }.sorted(by: byName)
        let ordered = operable.filter(\.isOn) + operable.filter { !$0.isOn }
        return (Array(ordered.prefix(limit)), operable.count)
    }

    /// Not-reporting entities tallied by domain, largest first: which integration
    /// died, and how much of it.
    public static func offlineBreakdown(_ all: [Entity], limit: Int = 8) -> [(domain: String, count: Int)] {
        var tally: [String: Int] = [:]
        for e in all where e.isBad { tally[e.domain, default: 0] += 1 }
        return tally.map { (domain: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.domain < $1.domain }
            .prefix(limit).map { $0 }
    }

    /// The icon for a room is its most common domain; ties go to a controllable one.
    public static func dominantDomain(_ ents: [Entity]) -> String? {
        var tally: [String: Int] = [:]
        for e in ents { tally[e.domain, default: 0] += 1 }
        return tally.max { a, b in
            let sa = a.value * 2 + (Farm.controllable.contains(a.key) ? 1 : 0)
            let sb = b.value * 2 + (Farm.controllable.contains(b.key) ? 1 : 0)
            return sa != sb ? sa < sb : a.key > b.key
        }?.key
    }
}

/* ---- bridge liveness and the capability gate ---- */

public enum BridgeStatus: Equatable, Sendable {
    case unknown
    case offline
    case stale(ageSeconds: Double)
    case live

    public init(_ hb: BridgeMeta?, nowMs: Double, skewMs: Double) {
        guard let hb, let last = hb.lastSeen else { self = .unknown; return }
        if hb.status == "offline" { self = .offline; return }
        let age = (nowMs + skewMs - last) / 1000
        self = age > (hb.heartbeatSeconds ?? 30) * Farm.staleFactor ? .stale(ageSeconds: age) : .live
    }

    public var label: String {
        switch self {
        case .unknown: return "No bridge data"
        case .offline: return "Bridge offline"
        case .stale(let age): return "Stale \(Format.age(age))"
        case .live: return "Live"
        }
    }
}

public enum Capability: Sendable { case control, irrigation }

public struct Gate: Equatable, Sendable {
    public let ok: Bool
    public let why: String
    public static let open = Gate(ok: true, why: "")
}

extension Gate {
    /* Will anything act on this? Mirrors bridgeGate() and reportsGate() in
     * app.js. Device control goes through the NUC, so it needs a live bridge.
     * Irrigation reports run in a Cloud Function and do not: the only thing
     * that blocks them is the meta/reports.enabled kill switch.
     * A switched-off capability must read as switched off, not as broken
     * hardware: before the web version checked this, a toggle flipped, wrote a
     * command nothing was watching, and snapped back twelve seconds later.
     * A bridge too old to publish a field leaves it nil; only an explicit
     * false blocks. */
    public static func evaluate(_ capability: Capability, bridge hb: BridgeMeta?,
                                reportsEnabled: Bool? = nil,
                                nowMs: Double, skewMs: Double) -> Gate {
        if capability == .irrigation {
            return reportsEnabled == false
                ? Gate(ok: false, why: "Irrigation reports are switched off for now.")
                : .open
        }
        guard let hb, let last = hb.lastSeen else {
            return Gate(ok: false, why: "The bridge has not reported in yet, so nothing would act on that.")
        }
        let age = (nowMs + skewMs - last) / 1000
        if hb.status == "offline" || age > (hb.heartbeatSeconds ?? 30) * Farm.staleFactor {
            return Gate(ok: false, why: "The bridge is not reporting in, so nothing would act on that.")
        }
        switch capability {
        case .control where hb.control == false:
            return Gate(ok: false, why: "Device control is switched off on the bridge. Turn on allow_control in the add-on options to operate anything from here.")
        default:
            return .open
        }
    }
}

/* ---- commands ---- */

public struct Command: Equatable, Sendable {
    public let entityId: String
    public let domain: String
    public let service: String
    public let brightness: Int?
    public let percentage: Int?

    static let services: Set<String> = ["turn_on", "turn_off", "toggle", "set_percentage"]

    /// The only commands this app will ever build. RTDB rules and
    /// bridge/commands.py re-check all of this; this is the first of three
    /// refusals, not the only one.
    public static func toggle(_ e: Entity, on: Bool) -> Command? {
        make(e, service: on ? "turn_on" : "turn_off")
    }

    /// Slider positions arrive in percent; lights take HA's 0–255.
    public static func level(_ e: Entity, percent: Int) -> Command? {
        let pct = max(0, min(100, percent))
        switch e.domain {
        case "fan": return make(e, service: "set_percentage", percentage: pct)
        case "light": return make(e, service: "turn_on", brightness: Int((Double(pct) / 100 * 255).rounded()))
        default: return nil
        }
    }

    static func make(_ e: Entity, service: String, brightness: Int? = nil, percentage: Int? = nil) -> Command? {
        guard Farm.controllable.contains(e.domain), services.contains(service),
              e.entityId.hasPrefix(e.domain + "."), e.entityId.count <= 128,
              e.entityId.range(of: #"^[a-z_]+\.[a-z0-9_]+$"#, options: .regularExpression) != nil
        else { return nil }
        return Command(entityId: e.entityId, domain: e.domain, service: service,
                       brightness: brightness, percentage: percentage)
    }

    /// The RTDB payload minus `uid` and `at`, which the backend fills in
    /// (`at` must be the server timestamp placeholder).
    public var dataPayload: [String: Int] {
        var d: [String: Int] = [:]
        if let brightness { d["brightness"] = brightness }
        if let percentage { d["percentage"] = percentage }
        return d
    }
}

/* ---- irrigation ---- */

public struct IrrigationType: Identifiable, Hashable, Sendable {
    public let type: String
    public let label: String
    public let needsRange: Bool
    public let combined: Bool
    public var id: String { type }
}

public enum IrrigationTypes {
    /// Same order and labels as IRR_TYPES in app.js, and the same allow-list
    /// as the `irrigation_requests/type` rule.
    public static let all: [IrrigationType] = [
        .init(type: "live_readings", label: "Power and pressure now", needsRange: false, combined: true),
        .init(type: "session_log", label: "Irrigation session log", needsRange: true, combined: true),
        .init(type: "performance", label: "Valve runtime against pressure", needsRange: true, combined: true),
        .init(type: "controller", label: "Controller dashboard", needsRange: false, combined: false),
        .init(type: "electricity", label: "Electricity snapshot", needsRange: false, combined: false),
        .init(type: "pressure", label: "Pressure snapshot", needsRange: false, combined: false),
        .init(type: "valves", label: "Valve runtime", needsRange: true, combined: false),
        .init(type: "timer_log", label: "Timer log", needsRange: true, combined: false),
        .init(type: "motor_log", label: "Motor log", needsRange: true, combined: false),
        .init(type: "pressure_range", label: "Pressure range", needsRange: true, combined: false),
        .init(type: "pressure_hour", label: "Pressure, last hour", needsRange: false, combined: false),
        .init(type: "power_range", label: "Power over time", needsRange: true, combined: false),
    ]

    public static func find(_ type: String) -> IrrigationType? { all.first { $0.type == type } }
    public static func label(for type: String) -> String? { find(type)?.label }

    /// The bridge caps a range at 31 days; refusing here saves a round trip.
    public static let maxRangeDays = 31

    /// nil when valid, otherwise the reason in plain words.
    public static func validate(type: String, from: String, to: String) -> String? {
        guard let t = find(type) else { return "Unknown report type." }
        guard t.needsRange else { return nil }
        guard let f = Format.day(from), let e = Format.day(to) else { return "Pick a from and to date for this report." }
        if e < f { return "The to date is before the from date." }
        let days = Calendar(identifier: .gregorian).dateComponents([.day], from: f, to: e).day ?? 0
        if days > maxRangeDays { return "Pick a range of \(maxRangeDays) days or fewer." }
        return nil
    }
}

/* ---- access ---- */

public enum Role: String, Sendable {
    case viewer = "Viewer", controller = "Controller", admin = "Admin"
}

public enum Invites {
    /// RTDB keys cannot contain '.', so an invite is keyed by the lowercased
    /// email with '.' swapped for ','. database.rules.json does the same swap.
    public static func key(for email: String?) -> String? {
        guard let e = email?.trimmingCharacters(in: .whitespaces).lowercased(), !e.isEmpty else { return nil }
        return e.replacingOccurrences(of: ".", with: ",")
    }
}

/* ---- formatting ---- */

public enum Format {
    public static func age(_ sec: Double) -> String {
        if sec < 90 { return "\(Int(sec.rounded()))s" }
        if sec < 5400 { return "\(Int((sec / 60).rounded()))m" }
        return "\(Int((sec / 3600).rounded()))h"
    }

    /// "1h 20m", "45m".
    public static func minutes(_ m: Int) -> String {
        guard m >= 60 else { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }

    /// Pre-sections reports carry raw vendor runtime strings.
    public static func runtimeMinutes(_ s: String?) -> Int {
        let str = s ?? ""
        func grab(_ pattern: String) -> Int? {
            guard let r = str.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
            return Int(str[r].filter(\.isNumber))
        }
        let h = grab(#"\d+\s*h"#), m = grab(#"\d+\s*m"#)
        if h != nil || m != nil { return (h ?? 0) * 60 + (m ?? 0) }
        return Double(str).map { Int($0) } ?? 0
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Strict YYYY-MM-DD, as the rules require.
    public static func day(_ s: String) -> Date? {
        guard s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        return dayFormatter.date(from: s)
    }

    /// A calendar date in the device's time zone, as the bridge's YYYY-MM-DD.
    public static func dayString(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
