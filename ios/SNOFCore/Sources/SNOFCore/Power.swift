import Foundation

/* Power: the farm's three EB lines (owner, 2026-09-25). Home and the sheds
 * are on a single-phase line with the GoodWe inverter; a three-phase line
 * with the V-Guard inverter (a FoxESS unit) charges the XEV 9e; and a second
 * three-phase line, free for agriculture, runs the main farm motor. Which
 * inverter is on which line is a fact about this farm that Home Assistant
 * does not hold, so it is written here. The inverters themselves are
 * recognised by what their integrations report, not by typed names.
 * Mirrors POWER_LINES / powerLines() / lineStatus() in
 * dashboard/public/app.js; keep the two in step. */

public enum InverterKind: String, Sendable { case goodwe, foxess }

public struct PowerLineSpec: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let phase: String
    public let short: String
    public let inverter: InverterKind?
    public let brand: String
    public let use: String
}

public struct InverterReading: Sendable {
    public var offline: Bool
    /// PV input in watts, as the old Solar card had it.
    public var watts: Double?
    public var kwh: Double?
    public var total: Double?
    public var grid: Double?
    public var temp: Double?
    public var mode: String?
}

public struct PowerLine: Sendable, Identifiable {
    public let spec: PowerLineSpec
    public var id: String { spec.id }
    public var device: DeviceGroup?
    public var inverter: InverterReading?
    public var supply: Supply?
    public var supplyToday: String?
    public var pumpToday: String?
    /// The controller's reading is under an hour old.
    public var current = true
}

public struct LineStatus: Sendable, Equatable {
    public enum State: String, Sendable { case on, rest, off, offline, bad }
    public var state: State
    public var figure: String
    public var unit: String
    public var sub: String
}

public enum Power {
    public static let lines: [PowerLineSpec] = [
        // Titles name the line, never an action: "EV charging" read as the
        // car charging right now (owner, 2026-09-25).
        .init(id: "home", title: "Home & sheds line", phase: "Single phase", short: "1-phase", inverter: .goodwe, brand: "GoodWe", use: "For the house and the sheds"),
        .init(id: "ev", title: "EV charger line", phase: "Three phase", short: "3-phase", inverter: .foxess, brand: "V-Guard", use: "For charging the XEV 9e"),
        .init(id: "farm", title: "Farm motor line", phase: "Three phase", short: "3-phase", inverter: nil, brand: "", use: "Free agricultural supply, for the Farm motor"),
    ]

    static func m(_ s: String, _ p: String) -> Bool { s.range(of: p, options: .regularExpression) != nil }

    /// From the entities the integration makes.
    public static func kind(_ d: DeviceGroup) -> InverterKind? {
        let has = { (p: String) in d.entities.contains { m($0.name.lowercased(), p) } }
        if has("on-grid l1 (voltage|power)$") { return .goodwe }
        if has("feed-in power$") && has("\\br power$") { return .foxess }
        return nil
    }

    public static func reading(_ d: DeviceGroup) -> InverterReading {
        func f(_ p: String) -> Entity? { d.entities.first { m($0.name.lowercased(), p) && !$0.isBad } }
        let pv = f("\\bpv power$") ?? f("solar power$")
        var w = Systems.number(pv)
        if let v = w, (pv?.attrs.unit ?? "").lowercased() == "kw" { w = v * 1000 }
        let offline = d.isOffline || w == nil
        return InverterReading(offline: offline, watts: offline ? nil : w,
                               kwh: Systems.number(f("(today's pv generation|energy generated today)$")),
                               total: Systems.number(f("(total pv generation|energy generated total)$")),
                               grid: Systems.number(f("(on-grid l1 voltage|\\br voltage)$")),
                               temp: Systems.number(f("inverter temperature$")),
                               mode: f("work mode$")?.state)
    }

    public static func build(systems: [FarmSystemID: FarmSystem], irrigation c: IrrigationCache, now: Date = Date()) -> [PowerLine] {
        let inverters = (systems[.solar]?.devices ?? []).map { ($0, kind($0)) }
        return lines.map { spec in
            if let want = spec.inverter {
                let hit = inverters.first { $0.1 == want }?.0
                return PowerLine(spec: spec, device: hit, inverter: hit.map(reading))
            }
            func val(_ p: String) -> String? { c.electricity.first { m(($0["label"] ?? "").lowercased(), p) }?["value"] }
            let checked = c.program?.at ?? c.lastUpdated ?? 0
            return PowerLine(spec: spec, supply: Irrigation.supply(c), supplyToday: val("^supply today"), pumpToday: val("^pump today"),
                             current: checked > 0 && now.timeIntervalSince1970 * 1000 - checked < 60 * 60_000)
        }
    }

    public static func kwh(_ k: Double) -> String { "\(Format.trim((k * 10).rounded() / 10)) kWh" }

    /// What the Home panel says about one line.
    public static func status(_ l: PowerLine) -> LineStatus {
        if l.spec.inverter != nil {
            guard let i = l.inverter else {
                return .init(state: .off, figure: "Not reporting", unit: "", sub: "\(l.spec.brand) inverter")
            }
            guard !i.offline, let w = i.watts else {
                return .init(state: .offline, figure: "Inverter offline", unit: "", sub: (i.kwh ?? 0) > 0 ? "\(kwh(i.kwh!)) today" : "")
            }
            let parts = Systems.power(w).split(separator: " ").map(String.init)
            return .init(state: w > 0 ? .on : .rest, figure: parts[0], unit: parts.count > 1 ? parts[1] : "",
                         sub: i.kwh.map { "\(kwh($0)) today" } ?? "solar")
        }
        guard let s = l.supply, s.hasVoltage else {
            return .init(state: .off, figure: "No reading", unit: "", sub: "from the irrigation controller")
        }
        // Free agricultural power comes and goes on the board's schedule, so a
        // line with no power is not a fault; a missing phase is. The reading is
        // from a moment ("at 08:16"), so it is said as one, never as now.
        let when = s.at.map { " at \($0)" } ?? ""
        if !s.powerOn {
            return .init(state: .rest, figure: "No power", unit: "", sub: (l.supplyToday.map { "\($0) supply today · " } ?? "") + "read" + (when.isEmpty ? " last" : when))
        }
        if s.missingPhase { return .init(state: .bad, figure: "\(s.livePhases) of 3", unit: "phases", sub: "a phase was missing" + when) }
        return .init(state: .on, figure: "3", unit: "phases", sub: "pump " + (s.pumpDrawing == true ? "on" : "off") + when)
    }
}
