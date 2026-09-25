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
    /// An AC. Its state is its mode ("cool", "dry", "off"), not on/off.
    public var isAC: Bool { domain == "climate" }
    /// An AC that is running: reporting, and not off.
    public var acOn: Bool { isAC && !isBad && state != "off" }

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

    /// Room sections named for what they are, not Home Assistant's domains
    /// ("Binary Sensor", "Alarm Control Panel"). Mirrors SECTION_TITLE in app.js.
    public static let sectionTitles: [(domain: String, title: String)] = [
        ("light", "Lights"), ("switch", "Switches"), ("fan", "Fans"), ("input_boolean", "Toggles"),
        ("climate", "Air conditioning"), ("media_player", "TVs & speakers"), ("remote", "Remotes"),
        ("camera", "Cameras"), ("alarm_control_panel", "Alarm"), ("binary_sensor", "Detectors"),
        ("sensor", "Readings"), ("device_tracker", "Presence"),
    ]
    public static func sectionTitle(_ d: String) -> String {
        sectionTitles.first { $0.domain == d }?.title ?? humanDomain(d).capitalized
    }
    /// Settings rather than things to look at (a switch's power-on behaviour,
    /// an AC's timer, a firmware notice): left out of room and system pages
    /// unless searched for. Mirrors SETTING_DOMAINS in app.js.
    public static let settingDomains: Set<String> = ["select", "input_select", "number", "input_number", "time", "date",
                                                     "datetime", "button", "input_button", "image", "text", "input_text",
                                                     "update", "event"]
    /// A diagnostic reading ("Goats Debug (station)"): the bridge does not
    /// export Home Assistant's entity category, so the name is what says it.
    public var isDiagnostic: Bool { name.range(of: #"\bdebug\b"#, options: [.regularExpression, .caseInsensitive]) != nil }
    /// Left out of room and system pages unless searched for.
    public var isBackstage: Bool { Entity.settingDomains.contains(domain) || isDiagnostic }

    /// Search haystack, matching app.js `matches()`.
    public func matches(_ query: String, areaName: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return true }
        return "\(name) \(entityId) \(state ?? "") \(areaName)".lowercased().contains(q)
    }
}

/* ---- devices ---- */

/// The farm thinks in devices — "the printer is off" — while Home Assistant
/// reports entities, dozens per device. Mirrors byDevice() in app.js.
public struct DeviceGroup: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let area: String
    public let entities: [Entity]

    public init(id: String, name: String, area: String, entities: [Entity]) {
        self.id = id; self.name = name; self.area = area; self.entities = entities
    }

    /// Nothing on it is reporting.
    public var isOffline: Bool { entities.allSatisfy(\.isBad) }
    /// Anything on it is on, open or running.
    public var isActive: Bool { entities.contains(where: \.isOn) }
    public var badCount: Int { entities.filter(\.isBad).count }
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

    /// Entities grouped into their devices. An entity without a device id (an
    /// older bridge) stands alone.
    public static func byDevice(_ ents: [Entity], names: [String: String]) -> [DeviceGroup] {
        var order: [String] = []
        var groups: [String: [Entity]] = [:]
        for e in ents {
            let id = e.device ?? e.key
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(e)
        }
        return order.map { id in
            let list = groups[id]!
            let first = list[0]
            return DeviceGroup(id: id, name: first.device.flatMap { names[$0] } ?? first.name,
                               area: first.area, entities: list)
        }
    }

    /// Devices with anything not reporting: fully offline first, then most
    /// entities down, then by name.
    public static func troubledDevices(_ devices: [DeviceGroup], limit: Int = 8) -> [DeviceGroup] {
        devices.filter { $0.badCount > 0 }.sorted { a, b in
            if a.isOffline != b.isOffline { return a.isOffline }
            if a.badCount != b.badCount { return a.badCount > b.badCount }
            return natural(a.name, b.name)
        }.prefix(limit).map { $0 }
    }

    /// Areas by name.
    public static func groupByArea(_ ents: [Entity], name: (String) -> String) -> [(id: String, entities: [Entity])] {
        let grouped = Dictionary(grouping: ents, by: \.area)
        return grouped.map { (id: $0.key, entities: $0.value) }.sorted { natural(name($0.id), name($1.id)) }
    }

    /// Operable domains first: the reason to open a room is usually to do something.
    public static func domainsForArea(_ ents: [Entity]) -> [(domain: String, entities: [Entity])] {
        let rank = { (d: String) in Entity.sectionTitles.firstIndex { $0.domain == d } ?? 99 }
        return Dictionary(grouping: ents, by: \.domain)
            .map { (domain: $0.key, entities: $0.value.sorted(by: byName)) }
            .sorted { a, b in
                // Operable first, the ACs with them (mirrors areaView in app.js).
                let ca = Farm.controllable.contains(a.domain) || a.domain == "climate" ? 0 : 1
                let cb = Farm.controllable.contains(b.domain) || b.domain == "climate" ? 0 : 1
                if ca != cb { return ca < cb }
                return (rank(a.domain), a.domain) < (rank(b.domain), b.domain)
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

public enum Capability: Sendable { case control, irrigation, irrigationControl }

public struct Gate: Equatable, Sendable {
    public let ok: Bool
    public let why: String
    /// Closed because the bridge is quiet: two such gates are said once.
    public var bridge = false
    public static let open = Gate(ok: true, why: "")
    /// Reads and valve control both down for the same quiet bridge, in one line.
    public static let bridgeDownBoth = "The bridge is not reporting in, so the controller cannot be read or sent a Run or Stop."
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
                                cloudIrrigationControl: Bool? = nil,
                                reportsTransport: String? = nil,
                                nowMs: Double, skewMs: Double) -> Gate {
        // Valve control run by the Cloud Function does not go through the
        // NUC, so it does not need a live bridge: its own switch decides.
        if capability == .irrigationControl, cloudIrrigationControl == true {
            return .open
        }
        let reads = capability == .irrigation
        if reads {
            if reportsEnabled == false { return Gate(ok: false, why: "Irrigation reports are switched off for now.") }
            // Controller reads go through the NUC's relay until the function
            // has a static egress IP (docs/dcon-off-the-nuc.md): with the bridge
            // quiet, a Refresh would only time out. No field yet means relay.
            if reportsTransport == "direct" { return .open }
        }
        // Valve control is spoken of as valve control: the owner thinks of the
        // Mobitech side as its own thing, not as "the bridge".
        let valves = capability == .irrigationControl
        guard let hb, let last = hb.lastSeen else {
            return Gate(ok: false, why: valves ? "Valve control has not checked in yet."
                        : reads ? "The bridge has not checked in yet, so the controller cannot be read."
                        : "The bridge has not checked in yet, so a press would not reach the farm.", bridge: true)
        }
        let age = (nowMs + skewMs - last) / 1000
        if hb.status == "offline" || age > (hb.heartbeatSeconds ?? 30) * Farm.staleFactor {
            return Gate(ok: false, why: valves ? "Valve control is not answering right now, so a Run or Stop would not reach the controller."
                        : reads ? "The bridge is not reporting in, so the controller cannot be read right now."
                        : "The bridge is not reporting in, so a press would not reach the farm.", bridge: true)
        }
        switch capability {
        case .control where hb.control == false:
            return Gate(ok: false, why: "Switching from the app is turned off at the farm.")
        case .irrigationControl where hb.irrigationControl != true:
            return Gate(ok: false, why: "Valve control is switched off at the farm.")
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
    /// An AC's set temperature, °C.
    public let temperature: Double?
    /// An AC's hvac_mode, fan_mode or preset_mode: one key at most.
    public let words: [String: String]

    init(entityId: String, domain: String, service: String, brightness: Int? = nil, percentage: Int? = nil,
         temperature: Double? = nil, words: [String: String] = [:]) {
        self.entityId = entityId; self.domain = domain; self.service = service
        self.brightness = brightness; self.percentage = percentage
        self.temperature = temperature; self.words = words
    }

    static let services: Set<String> = ["turn_on", "turn_off", "toggle", "set_percentage"]

    /// Home Assistant's own modes; fan and preset names are the AC's, held to
    /// a plain token. The same fences as the RTDB rules and commands.py.
    static let hvacModes: Set<String> = ["off", "heat", "cool", "heat_cool", "auto", "dry", "fan_only"]
    static func isToken(_ s: String) -> Bool { s.range(of: #"^[a-z0-9_]{1,32}$"#, options: .regularExpression) != nil }

    /// An AC's power (owner, 2026-09-25).
    public static func acPower(_ e: Entity, on: Bool) -> Command? {
        guard e.isAC, valid(e) else { return nil }
        return Command(entityId: e.entityId, domain: e.domain, service: on ? "turn_on" : "turn_off")
    }

    public static func acTemperature(_ e: Entity, _ t: Double) -> Command? {
        guard e.isAC, valid(e), t >= 10, t <= 35 else { return nil }
        return Command(entityId: e.entityId, domain: e.domain, service: "set_temperature", temperature: t)
    }

    /// field: "hvac_mode", "fan_mode" or "preset_mode".
    public static func acMode(_ e: Entity, field: String, value: String) -> Command? {
        guard e.isAC, valid(e) else { return nil }
        switch field {
        case "hvac_mode": guard hvacModes.contains(value) else { return nil }
        case "fan_mode", "preset_mode": guard isToken(value) else { return nil }
        default: return nil
        }
        return Command(entityId: e.entityId, domain: e.domain, service: "set_\(field)", words: [field: value])
    }

    static func valid(_ e: Entity) -> Bool {
        e.entityId.hasPrefix(e.domain + ".") && e.entityId.count <= 128 &&
            e.entityId.range(of: #"^[a-z_]+\.[a-z0-9_]+$"#, options: .regularExpression) != nil
    }

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

    /// Everything under `data`, numbers and words alike, as the backend writes it.
    public var dataJSON: [String: Any] {
        var d: [String: Any] = dataPayload
        if let temperature { d["temperature"] = temperature }
        for (k, v) in words { d[k] = v }
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
        .init(type: "live_readings", label: "Power and pressure reading", needsRange: false, combined: true),
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

/* ---- the farm pulse: one sentence a person would say ----
 * Mirrors pulsePanel() in dashboard/public/app.js; keep the wording in step.
 * Honest before reassuring: a bridge gone quiet outranks everything, and
 * "most areas are running normally" is only said when it is true. */
public enum Pulse {
    static let wordsTable = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight",
                             "nine", "ten", "eleven", "twelve"]
    public static func words(_ n: Int) -> String { n >= 0 && n <= 12 ? wordsTable[n] : "\(n)" }
    static func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
    static func plural(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? one : many }

    /// ["Cold Store", "East Orchard", "Barn"] -> "Cold Store, East Orchard and 1 other".
    public static func list(_ items: [String], max: Int = 2) -> String {
        if items.count <= max {
            return items.count > 1 ? items.dropLast().joined(separator: ", ") + " and " + items.last! : (items.first ?? "")
        }
        let rest = items.count - max
        return items.prefix(max).joined(separator: ", ") + " and \(rest) " + plural(rest, "other", "others")
    }

    /// Rooms with a device fully offline, worst first.
    public static func troubledAreas(_ devices: [DeviceGroup], name: (String) -> String) -> [String] {
        var tally: [String: Int] = [:]
        for d in devices where d.isOffline { tally[d.area, default: 0] += 1 }
        return tally.sorted { a, b in
            a.value != b.value ? a.value > b.value : Sorting.natural(name(a.key), name(b.key))
        }.map(\.key)
    }

    public static func summary(devices: [DeviceGroup], areaCount: Int, bridge: BridgeStatus,
                               areaName: (String) -> String) -> (title: String, body: String, quiet: Bool) {
        let n = devices.count
        let bad = devices.filter(\.isOffline).count
        let on = devices.filter(\.isActive).count
        let whereText = list(troubledAreas(devices, name: areaName).map(areaName))
        switch bridge {
        case .offline:
            return ("The bridge has gone quiet.",
                    "The farm bridge reported itself offline. What you see is the last state it sent.", true)
        case .stale(let age):
            return ("The bridge has gone quiet.",
                    "Nothing has arrived from the farm for \(Format.age(age)). What you see may be out of date.", true)
        default: break
        }
        if n == 0 {
            return ("Waiting for the first devices.",
                    "Assign devices to rooms in Home Assistant and they will appear here.", false)
        }
        if bad == 0 {
            let tail = on > 0 ? ", and \(words(on)) \(plural(on, "is", "are")) on right now." : "."
            return ("Everything is reporting.",
                    "All \(n) \(plural(n, "device", "devices")) across \(areaCount) \(plural(areaCount, "area", "areas")) are answering" + tail, false)
        }
        let ratio = Double(bad) / Double(n)
        if ratio <= 0.25 {
            return ("Most areas are running normally.",
                    "\(n - bad) of \(n) devices are reporting. \(cap(words(bad))) \(plural(bad, "needs", "need")) a closer look in \(whereText).", false)
        }
        if ratio <= 0.5 {
            return ("A few devices need a look.",
                    "\(n - bad) of \(n) devices are reporting. \(cap(words(bad))) are offline, in \(whereText).", false)
        }
        return ("Much of the farm is quiet.",
                "Only \(n - bad) of \(n) devices are reporting. \(cap(words(bad))) are offline, most of them in \(whereText).", false)
    }
}

public enum Format {
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sept", "Oct", "Nov", "Dec"]

    /// "2026-09-24", "2026-09-25" -> "24–25 Sept"; across months
    /// "30 Sept – 1 Oct"; the year only when it is not this one. The raw ISO
    /// pair read like a database row. Mirrors dayRange() in app.js.
    public static func dayRange(_ from: String, _ to: String?, now: Date = Date()) -> String {
        func parse(_ d: String) -> (y: Int, m: Int, d: Int)? {
            let p = d.split(separator: "-").compactMap { Int($0) }
            guard d.count == 10, p.count == 3, (1...12).contains(p[1]) else { return nil }
            return (p[0], p[1] - 1, p[2])
        }
        guard let a = parse(from), let b = parse(to ?? from) else { return [from, to].compactMap { $0 }.joined(separator: " – ") }
        let thisYear = Calendar(identifier: .gregorian).component(.year, from: now)
        func yr(_ x: (y: Int, m: Int, d: Int)) -> String { x.y != thisYear ? " \(x.y)" : "" }
        if a.y == b.y, a.m == b.m {
            return a.d == b.d ? "\(a.d) \(months[a.m])\(yr(a))" : "\(a.d)–\(b.d) \(months[a.m])\(yr(a))"
        }
        return "\(a.d) \(months[a.m])\(a.y != b.y ? yr(a) : "") – \(b.d) \(months[b.m])\(yr(b))"
    }

    /// "3h" since an ISO-8601 timestamp (Home Assistant's, with microseconds),
    /// "4 days" past two days, nil if unparseable or in the future.
    public static func since(_ iso: String?, now: Date = Date()) -> String? {
        guard var s = iso, !s.isEmpty else { return nil }
        // ISO8601DateFormatter will not take six fractional digits; drop them.
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) { s.removeSubrange(r) }
        guard let date = ISO8601DateFormatter().date(from: s) else { return nil }
        let sec = now.timeIntervalSince(date)
        guard sec >= 0 else { return nil }
        if sec >= 172_800 { return "\(Int((sec / 86_400).rounded())) days" }
        return age(sec)
    }

    public static func age(_ sec: Double) -> String {
        if sec < 90 { return "\(Int(sec.rounded()))s" }
        if sec < 5400 { return "\(Int((sec / 60).rounded()))m" }
        if sec < 172_800 { return "\(Int((sec / 3600).rounded()))h" }
        return "\(Int((sec / 86400).rounded()))d"
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


/* ---- irrigation control ---- */

/// What the app may ask the controller to do. The same limits as the
/// `irrigation_commands` rule and bridge/irrigation_control.py — this is the
/// fourth refusal, not a replacement for any of the three.
public struct IrrigationCommand: Equatable, Sendable {
    public static let maxValves = 5
    public static let maxMinutes = 60

    public let action: String
    /// "12,15" — valve numbers, as the rule's regex wants them.
    public let valves: String?
    public let minutes: Int?

    public static let stop = IrrigationCommand(action: "stop", valves: nil, minutes: nil)

    public static func run(valves: [Int], minutes: Int, cap: Int = maxMinutes) -> IrrigationCommand? {
        guard (1...maxValves).contains(valves.count), Set(valves).count == valves.count,
              valves.allSatisfy({ (1...99).contains($0) }),
              (1...min(cap, maxMinutes)).contains(minutes) else { return nil }
        return IrrigationCommand(action: "run", valves: valves.map(String.init).joined(separator: ","),
                                 minutes: minutes)
    }

    public var payload: [String: Any] {
        var p: [String: Any] = ["action": action]
        if let valves { p["valves"] = valves }
        if let minutes { p["minutes"] = minutes }
        return p
    }
}

public struct IrrigationValve: Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
}

extension Irrigation {
    /// The valves a manual run may open: Irrigation ones only, never the
    /// tank, booster pump or backwash valve. The bridge checks again against
    /// the controller's own registry.
    public static func operableValves(_ c: IrrigationCache) -> [IrrigationValve] {
        let rows = c.valveNames.isEmpty ? c.valves : c.valveNames
        return rows.compactMap { r -> IrrigationValve? in
            guard (r["type"] ?? "").lowercased() == "irrigation", let id = r["id"].flatMap(Int.init) else { return nil }
            return IrrigationValve(id: id, name: r["name"] ?? "Valve \(id)")
        }
        .sorted { $0.id < $1.id }
    }
}

extension CurrentProgram {
    /// A Manual Mode run — the only thing the app may stop.
    public var isManual: Bool { kind == "Manual" || name == "Manual Mode" }
}
