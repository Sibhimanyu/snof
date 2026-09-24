import Foundation

/* The farm, by system: devices sorted into what they are from their own
 * entities (an inverter reports PV power, a camera is a camera, an AC is a
 * climate entity), and each system knows whether being offline is a fault
 * (a camera, the inverter, a switch module) or only means it is switched off
 * at the wall (an AC, a TV, the 3D printer). Mirrors farmSystems() /
 * systemSummary() / attentionItems() in dashboard/public/app.js — keep the
 * rules in step. (Owner, 2026-09-25: most "offline" devices were ACs, TVs
 * and a printer that were simply off.) */

public enum FarmSystemID: String, CaseIterable, Sendable, Hashable, Identifiable {
    case security, solar, switches, climate, media, printer, other
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .security: return "Security"
        case .solar: return "Solar"
        case .switches: return "Lights & switches"
        case .climate: return "Climate"
        case .media: return "TVs"
        case .printer: return "3D printer"
        case .other: return "Other"
        }
    }

    public var symbol: String {
        switch self {
        case .security: return "shield.lefthalf.filled"
        case .solar: return "sun.max"
        case .switches: return "lightbulb"
        case .climate: return "air.conditioner.horizontal"
        case .media: return "tv"
        case .printer: return "printer"
        case .other: return "square.grid.2x2"
        }
    }

    /// Whether this system being offline deserves a look.
    public var offlineIsFault: Bool { [.security, .solar, .switches].contains(self) }
}

public struct FarmSystem: Identifiable, Sendable {
    public let id: FarmSystemID
    public var devices: [DeviceGroup]
    public var entities: [Entity] { devices.flatMap(\.entities) }
    public init(id: FarmSystemID, devices: [DeviceGroup]) { self.id = id; self.devices = devices }
}

public enum SystemState: String, Sendable { case on, rest, off, offline, warn, bad }

public struct SystemSummary: Sendable {
    public var state: SystemState
    public var line: String
    public var sub: String
    public var watts: Double? = nil
    public var kwh: Double? = nil
    public var armed = false
    public var camerasOnline = 0
    public var cameras = 0
    public var detecting = 0
}

public enum Systems {
    static func lname(_ e: Entity) -> String { e.name.lowercased() }
    /// "custom bypass" -> "Custom bypass" (the web's cap()).
    static func firstUpper(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
    static func number(_ e: Entity?) -> Double? {
        guard let e, !e.isBad, let s = e.state else { return nil }
        return Double(s)
    }
    static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    public static func classify(_ g: DeviceGroup) -> FarmSystemID {
        let e = g.entities
        let has = { (d: String) in e.contains { $0.domain == d } }
        if e.contains(where: { $0.domain == "sensor" && matches(lname($0), "(pv power|solar power|pv generation)") }) { return .solar }
        let printish = e.contains { matches(lname($0), "print") }
        if has("alarm_control_panel") || (has("camera") && !printish) { return .security }
        if e.contains(where: { matches(lname($0), "\\bprint (error|progress|status)|current stage") }) { return .printer }
        if has("climate") { return .climate }
        if has("media_player") { return .media }
        if e.contains(where: \.isControllable) { return .switches }
        return .other
    }

    /// Systems that have devices, keyed by id. A printer's add-ons (its AMS,
    /// the external spool) are named after it and join it, matched on Home
    /// Assistant's own names (`raw`) rather than the tidied display ones.
    public static func build(_ entities: [Entity], names: [String: String],
                             raw: [String: String] = [:]) -> [FarmSystemID: FarmSystem] {
        let groups = Sorting.byDevice(entities, names: names)
        var out: [FarmSystemID: FarmSystem] = [:]
        func put(_ id: FarmSystemID, _ g: DeviceGroup) {
            out[id, default: FarmSystem(id: id, devices: [])].devices.append(g)
        }
        func match(_ g: DeviceGroup) -> String { raw[g.id] ?? g.name }
        var printers: [String] = []
        var rest: [(FarmSystemID, DeviceGroup)] = []
        for g in groups {
            let id = classify(g)
            if id == .printer { printers.append(match(g)); put(.printer, g) } else { rest.append((id, g)) }
        }
        for (id, g) in rest { put(printers.contains { match(g).hasPrefix("\($0)_") } ? .printer : id, g) }
        return out
    }

    public static func power(_ w: Double) -> String {
        w >= 1000 ? String(format: "%.2f kW", w / 1000) : "\(Int(w.rounded())) W"
    }

    public static func summary(_ sys: FarmSystem) -> SystemSummary {
        let ents = sys.entities
        func find(_ test: (String, Entity) -> Bool) -> Entity? {
            ents.first { test(lname($0), $0) && !$0.isBad } ?? ents.first { test(lname($0), $0) }
        }
        let allOffline = sys.devices.allSatisfy(\.isOffline)
        switch sys.id {
        case .solar:
            let pv = find { n, e in e.domain == "sensor" && (n.hasSuffix("pv power") || n.hasSuffix("solar power")) }
            let today = find { n, e in e.domain == "sensor" && n.contains("today") && (n.contains("pv") || n.contains("solar")) }
            let mode = find { n, _ in n.hasSuffix("work mode") }
            var w = number(pv)
            if let v = w, (pv?.attrs.unit ?? "").lowercased() == "kw" { w = v * 1000 }
            let kwh = number(today)
            guard !allOffline, let watts = w else {
                return SystemSummary(state: .offline, line: "Inverter offline", sub: "", watts: nil, kwh: kwh)
            }
            let kwhText = kwh.map { "\(Format.trim($0)) kWh today" }
            if watts > 0 { return SystemSummary(state: .on, line: power(watts), sub: kwhText ?? "generating", watts: watts, kwh: kwh) }
            let resting = matches((mode?.state ?? "").lowercased(), "wait|standby|sleep")
            return SystemSummary(state: .rest, line: resting ? "Resting" : "0 W",
                                 sub: (kwh ?? 0) > 0 ? (kwhText ?? "") : (resting ? "No sun right now" : ""), watts: 0, kwh: kwh)
        case .security:
            let panels = ents.filter { $0.domain == "alarm_control_panel" && !$0.isBad }
            let cams = ents.filter { $0.domain == "camera" }
            let camsOn = cams.filter { !$0.isBad }.count
            let active = ents.filter { $0.domain == "binary_sensor" && $0.isOn && matches(lname($0), "(person|motion|pet) detected") }
            let p = panels.first { $0.state == "triggered" } ?? panels.first { ($0.state ?? "").hasPrefix("armed") } ?? panels.first
            let st = p?.state ?? ""
            let armed: String = p == nil ? "" : st == "triggered" ? "Alarm triggered" : st == "disarmed" ? "Disarmed"
                : st.hasPrefix("armed_") ? "Armed · " + firstUpper(st.dropFirst(6).replacingOccurrences(of: "_", with: " ")) : firstUpper(st)
            let camLine = cams.isEmpty ? "" : "\(camsOn) of \(cams.count) cameras online"
            let state: SystemState = st == "triggered" ? .bad : !active.isEmpty ? .on : camsOn < cams.count ? .warn : .rest
            return SystemSummary(state: state, line: armed.isEmpty ? (camLine.isEmpty ? "No alarm" : camLine) : armed,
                                 sub: !active.isEmpty ? "\(active.count) detecting now" : (armed.isEmpty ? "" : camLine),
                                 armed: st.hasPrefix("armed"), camerasOnline: camsOn, cameras: cams.count, detecting: active.count)
        case .switches:
            let ops = ents.filter(\.isControllable)
            let live = ops.filter { !$0.isBad }
            let on = live.filter(\.isOn).count
            return SystemSummary(state: on > 0 ? .on : live.isEmpty ? .offline : .rest,
                                 line: live.isEmpty ? "Offline" : on > 0 ? "\(on) on" : "All off",
                                 sub: "\(live.count) of \(ops.count) reachable")
        case .climate, .media:
            let main = ents.filter { $0.domain == (sys.id == .climate ? "climate" : "media_player") }
            let on = main.filter { !$0.isBad && !["off", "standby", "idle"].contains($0.state ?? "") }
            // A set-top box is not a TV: count screens as devices.
            let noun = sys.id == .climate ? (main.count == 1 ? "AC" : "ACs") : (main.count == 1 ? "device" : "devices")
            return SystemSummary(state: on.isEmpty ? .off : .on, line: on.isEmpty ? "All off" : "\(on.count) on", sub: "\(main.count) \(noun)")
        case .printer:
            if allOffline { return SystemSummary(state: .off, line: "Off", sub: "Switched off") }
            let prog = find { n, e in n.contains("progress") && e.attrs.unit == "%" }
            let stage = find { n, _ in matches(n, "current stage|print status") }
            let stageText = stage.flatMap { $0.isBad ? nil : firstUpper(($0.state ?? "").replacingOccurrences(of: "_", with: " ")) }
            if let pct = number(prog), pct > 0, pct < 100 {
                return SystemSummary(state: .on, line: "Printing \(Int(pct.rounded()))%", sub: stageText ?? "")
            }
            return SystemSummary(state: .rest, line: stageText ?? "Idle", sub: "")
        case .other:
            let on = sys.devices.filter(\.isActive).count
            return SystemSummary(state: on > 0 ? .on : .rest, line: on > 0 ? "\(on) active" : "Quiet",
                                 sub: "\(sys.devices.count) \(sys.devices.count == 1 ? "device" : "devices")")
        }
    }

    /// An entity's name without its device's name in front ("Storage Shed
    /// Smart Switch Switch 4" -> "Switch 4"), for places that show the room.
    public static func shortName(_ e: Entity, deviceName: String?) -> String {
        guard let d = deviceName, !d.isEmpty, e.name.hasPrefix(d + " ") else { return e.name }
        let rest = String(e.name.dropFirst(d.count + 1))
        return rest.isEmpty ? e.name : rest
    }
}

/* ---- watered, by crop ---- */

public struct ValveWater: Hashable, Sendable {
    public let name: String
    public let minutes: Int
}

public struct CropWater: Hashable, Sendable, Identifiable {
    public var id: String { key }
    public let key: String
    public let art: String?
    public let label: String
    public var minutes: Int
    public var cutShort: Int
    public var valves: [ValveWater]
    /// Valves of one crop can run in separate programs (Mango1, Mango2).
    public var sameMinutes: Bool { valves.allSatisfy { $0.minutes == valves.first?.minutes } }
}

extension Irrigation {
    static let cropLabels: [String: String] = [
        "veg": "Vegetables", "onion": "Onion", "kulam": "Kulam", "grass": "Grass", "house": "House",
        "mulberry": "Mulberry", "coconut": "Coconut", "guava": "Guava", "mango": "Mango", "amla": "Amla",
        "jamun": "Jamun", "pomegranate": "Pomegranate",
    ]

    /// "12 Coco 1" -> 12; also "valve 12", which a report writes when its
    /// name lookup failed.
    static func valveNumber(_ name: String) -> Int? {
        var t = name.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("valve ") { t = String(t.dropFirst(6)) }
        let digits = t.prefix { $0.isNumber }
        return digits.isEmpty || digits.count > 2 ? nil : Int(digits)
    }

    /// Room for backwash pauses, which stop the countdown (RUN_SLACK_MIN in reports.py).
    public static let runSlack: TimeInterval = 30 * 60

    /// When the run log was read: judged against this, not the phone's clock.
    public static func logReadAt(_ c: IrrigationCache, now: Date) -> Date {
        guard let ms = c.timerLogAt ?? c.lastUpdated else { return now }
        return min(now, Date(timeIntervalSince1970: ms / 1000))
    }

    /// Not known to have ended, so never "cut short": the function writes "so
    /// far" for a run it caught part-way, and an older log (which wrote every
    /// unfinished run as "stopped") is judged against when it was read. A run
    /// read 22 minutes into its hour is not cut short two hours later
    /// (2026-09-25). Mirrors mayStillRun() in app.js.
    public static func mayStillRun(_ r: ProgramRun, readAt: Date, zone: TimeZone) -> Bool {
        if r.finished { return false }
        if r.going { return true }
        guard let planned = r.plannedMin, let start = FarmTime.date(r.start, zone: zone) else { return false }
        return start.addingTimeInterval(Double(planned) * 60 + runSlack) > readAt
    }

    /// What follows a run's amount: "" (finished), " so far", ", cut short".
    public static func outcome(_ r: ProgramRun, readAt: Date, zone: TimeZone) -> String {
        r.finished ? "" : mayStillRun(r, readAt: readAt, zone: zone) ? " so far" : ", cut short"
    }

    /// What each crop got on one farm day, from the controller's run log.
    /// A crop got as long as its longest-watered valve; each valve keeps its
    /// own minutes; cut-short counts are per run. Also the irrigation valves
    /// that got nothing, and whether the cached log may be missing earlier
    /// runs of that day (it holds the newest runs only).
    public static func crops(_ c: IrrigationCache, day: String, now: Date = Date())
        -> (crops: [CropWater], dry: [String], runs: [ProgramRun], partial: Bool) {
        let zone = FarmTime.zone(c.timeZone)
        let rows = c.valveNames.isEmpty ? c.valves : c.valveNames
        var byNumber: [Int: String] = [:]
        for r in rows { if let id = r["id"].flatMap(Int.init), let n = r["name"] { byNumber[id] = n } }
        let dayRuns = runs(c).filter { $0.day == day && !$0.valves.isEmpty }
        let readAt = logReadAt(c, now: now)
        var valves: [String: (no: Int?, min: Int, cut: Set<String>)] = [:]
        var order: [String] = []
        for r in dayRuns {
            let cut = !r.finished && !mayStillRun(r, readAt: readAt, zone: zone)
            for raw in r.valves.components(separatedBy: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !raw.isEmpty {
                let no = valveNumber(raw)
                let name = no.flatMap { byNumber[$0] } ?? raw
                if valves[name] == nil { order.append(name) }
                var v = valves[name] ?? (no, 0, [])
                v.min += r.deliveredMin ?? 0
                if cut { v.cut.insert("\(r.start)|\(r.name)") }
                valves[name] = v
            }
        }
        var crops: [String: CropWater] = [:]
        var cutRuns: [String: Set<String>] = [:]
        var keys: [String] = []
        for n in order {
            guard let v = valves[n] else { continue }
            let art = ValveArt.key(name: n, type: "irrigation").flatMap { $0 == "backwash" ? nil : $0 }
            let key = art ?? "v:\(n)"
            let label = art.flatMap { cropLabels[$0] } ?? String(n.drop { $0.isNumber || $0 == " " })
            if crops[key] == nil { keys.append(key) }
            var cw = crops[key] ?? CropWater(key: key, art: art, label: label.isEmpty ? n : label, minutes: 0, cutShort: 0, valves: [])
            cw.minutes = max(cw.minutes, v.min)
            // Runs of one crop's valves, counted once each (Mango1 and Mango2
            // are separate programs, so their cuts add up).
            cutRuns[key, default: []].formUnion(v.cut)
            cw.cutShort = cutRuns[key]?.count ?? 0
            cw.valves.append(ValveWater(name: n, minutes: v.min))
            crops[key] = cw
        }
        let watered = Set(valves.values.compactMap(\.no))
        let dry = rows.filter { ($0["type"] ?? "").lowercased() == "irrigation" }
            .filter { r in (r["id"].flatMap(Int.init)).map { !watered.contains($0) } ?? false }
            .sorted { (Int($0["id"] ?? "") ?? 0) < (Int($1["id"] ?? "") ?? 0) }
            .compactMap { $0["name"] }
        let oldest = c.timerLog.compactMap { $0["at"] }.min() ?? ""
        // The function keeps 150 runs; at the cap, earlier runs may be missing.
        let partial = c.timerLog.count >= 150 && String(oldest.prefix(10)) >= day
        let sorted = keys.compactMap { crops[$0] }
            .sorted { $0.minutes != $1.minutes ? $0.minutes > $1.minutes : $0.label < $1.label }
        return (sorted, dry, dayRuns, partial)
    }
}

/* ---- needs a look ---- */

public struct AttentionItem: Hashable, Sendable, Identifiable {
    public enum Level: Int, Sendable { case bad = 0, warn = 1 }
    public enum Place: Hashable, Sendable { case home, irrigation, water, system(FarmSystemID) }
    public var id: String { "\(level.rawValue)|\(text)|\(sub)" }
    public let level: Level
    public let text: String
    public let sub: String
    public let place: Place
    public init(_ level: Level, _ text: String, _ sub: String = "", _ place: Place) {
        self.level = level; self.text = text; self.sub = sub; self.place = place
    }
}

extension Systems {
    /// An appliance (a fan, an AC, a TV, a remote) is "off at the wall" when
    /// unavailable, whatever system it sits in: a smart fan counted as a
    /// switch module was flagged every night (review, 2026-09-25).
    public static func isAppliance(_ g: DeviceGroup) -> Bool {
        g.entities.contains { ["fan", "climate", "media_player", "remote"].contains($0.domain) }
    }

    /// Whether this device being offline deserves a look.
    public static func offlineIsFault(_ g: DeviceGroup, system: FarmSystemID?) -> Bool {
        (system ?? .other).offlineIsFault && !isAppliance(g)
    }
}

public enum Attention {
    public struct Input: Sendable {
        public var bridgeDown = false
        public var bridgeQuietFor: String = ""
        public var irrigation = IrrigationCache()
        /// The controller's own running state, counted down (WaterNow).
        public var programRunning = false
        public var now = Date()
        public var mobitechSignInNeeded = false
        /// Only a missing or ended session: an outage is not a sign-in problem.
        public var liveskySignInNeeded = false
        public var water = WaterState()
        public var systems: [FarmSystemID: FarmSystem] = [:]
        public var areaName: [String: String] = [:]
        public init() {}
    }

    public static func items(_ i: Input) -> [AttentionItem] {
        var out: [AttentionItem] = []
        let room = { (id: String) in i.areaName[id] ?? "" }
        if i.bridgeDown {
            // "Bridge", as the pill, the account sheet and the gates say it.
            out.append(.init(.bad, "Bridge not reporting",
                             "Switches and controller reads are paused" + (i.bridgeQuietFor.isEmpty ? "" : " · quiet for \(i.bridgeQuietFor)"), .home))
        }
        let c = i.irrigation
        let zone = FarmTime.zone(c.timeZone)
        // Only what the controller said recently: an hours-old "no signal"
        // or "no power" must not read as a present problem.
        let checked = c.program?.at ?? c.lastUpdated ?? 0
        let recent = i.now.timeIntervalSince1970 * 1000 - checked < 60 * 60_000
        if i.programRunning, let p = c.program { for f in p.faults { out.append(.init(.bad, "Valve \(f)", "during the running program", .irrigation)) } }
        if recent, let s = Irrigation.supply(c), s.hasVoltage {
            if !s.powerOn { out.append(.init(.warn, "No power at the pump", s.at.map { "as of \($0)" } ?? "", .irrigation)) }
            else if s.missingPhase {
                out.append(.init(.bad, "A power phase is missing", "\(s.livePhases) of 3 phases live" + (s.at.map { " · \($0)" } ?? ""), .irrigation))
            }
        }
        let since = i.now.addingTimeInterval(-86_400)
        let readAt = Irrigation.logReadAt(c, now: i.now)
        // Programs with no valves assigned end at 0m by design; not faults.
        let cut = Irrigation.runs(c).filter { r in
            !r.finished && r.plannedMin != nil && !r.valves.isEmpty && !Irrigation.mayStillRun(r, readAt: readAt, zone: zone)
                && (FarmTime.date(r.start, zone: zone).map { $0 >= since } ?? false)
        }
        if !cut.isEmpty {
            out.append(.init(.warn, "\(cut.count) \(cut.count == 1 ? "run" : "runs") cut short in the last 24 h",
                             cut.prefix(2).map { "\($0.name) \($0.amount ?? "")" }.joined(separator: " · "), .irrigation))
        }
        if let err = c.lastError, !err.isEmpty {
            let short = err.replacingOccurrences(of: "^DCON [a-z_]+: ", with: "", options: .regularExpression)
            out.append(.init(.warn, "Could not reach the controller", String(short.prefix(80)), .irrigation))
        }
        if i.mobitechSignInNeeded {
            out.append(.init(.warn, "Mobitech sign-in needed", "sign in so valve commands keep working", .irrigation))
        }
        let w = i.water
        for m in ([w.river] + w.motors.map { Optional($0) }).compactMap({ $0 }) {
            if !m.trips.isEmpty { out.append(.init(.bad, "\(m.name) tripped", m.trips.joined(separator: ", "), .water)) }
            if let z = m.skippedZone { out.append(.init(.warn, "\(m.name): zone \(z) skipped", "no valve feedback", .water)) }
        }
        if w.enabled {
            if i.liveskySignInNeeded { out.append(.init(.warn, "Livesky sign-in needed", "the river motor is not being read", .water)) }
            else if w.livesky.status.ok == false, !w.livesky.status.error.isEmpty {
                out.append(.init(.warn, "River motor not read", w.livesky.status.error, .water))
            }
            if w.niagara.ok == false, !w.niagara.error.isEmpty { out.append(.init(.warn, "Other farm not read", w.niagara.error, .water)) }
            if let t = w.pulledAt, i.now.timeIntervalSince1970 * 1000 - t > 30 * 60_000 {
                out.append(.init(.warn, "Water readings are old",
                                 "last read \(Format.age(max(0, i.now.timeIntervalSince1970 - t / 1000))) ago", .water))
            }
        }
        if let sec = i.systems[.security] {
            if Systems.summary(sec).state == .bad { out.append(.init(.bad, "Alarm triggered", "", .system(.security))) }
            let panels = sec.entities.filter { $0.domain == "alarm_control_panel" }
            if !panels.isEmpty, panels.allSatisfy(\.isBad) {
                out.append(.init(.warn, "Alarm station offline", "the alarm state is unknown", .system(.security)))
            }
            let down = sec.entities.filter { $0.domain == "camera" && $0.isBad }
            if down.count == 1 {
                var name = down[0].name
                if name.lowercased().hasSuffix(" camera") { name = String(name.dropLast(7)) }
                out.append(.init(.warn, "\(name) camera offline", room(down[0].area), .system(.security)))
            } else if down.count > 1 {
                out.append(.init(.warn, "\(down.count) cameras offline", down.map(\.name).joined(separator: ", "), .system(.security)))
            }
        }
        if let solar = i.systems[.solar] {
            var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
            let h = cal.component(.hour, from: i.now)
            if h >= 7, h < 18, Systems.summary(solar).state == .offline {
                out.append(.init(.warn, "Solar inverter offline", "during daylight", .system(.solar)))
            }
        }
        if let sw = i.systems[.switches] {
            let down = sw.devices.filter { $0.isOffline && !Systems.isAppliance($0) }
            // A module named after its room ("Family Room" in the family room)
            // says what it is, or the row reads as the whole room being down.
            if down.count == 1 {
                let d = down[0]
                let name = d.name.lowercased() == room(d.area).lowercased() ? "\(d.name) switch module" : d.name
                out.append(.init(.warn, "\(name) offline", room(d.area), .system(.switches)))
            }
            else if down.count > 1 {
                out.append(.init(.warn, "\(down.count) switch modules offline", down.map(\.name).joined(separator: ", "), .system(.switches)))
            }
        }
        return out.enumerated().sorted { ($0.element.level.rawValue, $0.offset) < ($1.element.level.rawValue, $1.offset) }.map(\.element)
    }
}

extension Format {
    /// 10.8 -> "10.8", 7.0 -> "7": a reading as it would be said.
    public static func trim(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d)
    }
}
