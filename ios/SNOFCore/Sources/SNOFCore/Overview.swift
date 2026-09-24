import Foundation

/* What the Overview says about the farm, worked out from data the app
 * already has: the irrigation cache the report function leaves behind, and
 * the roomed entities. Nothing here fetches; the Overview's Refresh is an
 * ordinary report request. Every parser reads the strings the function
 * writes (dashboard/functions/reports.py: run_row, motor_sections,
 * electricity_sections) and gives up quietly on anything else. */

/* ---- farm time ---- */

public enum FarmTime {
    /// "+05:30" -> a fixed-offset zone. The controller's clock is farm time,
    /// and so is every timestamp it logs; the phone's zone is irrelevant.
    public static func zone(_ offset: String?) -> TimeZone {
        let fallback = TimeZone(secondsFromGMT: 19_800)!
        guard let o = offset, let m = o.range(of: #"^([+-])(\d{2}):?(\d{2})$"#, options: .regularExpression) else {
            return fallback
        }
        let s = String(o[m])
        let sign = s.hasPrefix("-") ? -1 : 1
        let digits = s.filter(\.isNumber)
        guard digits.count == 4, let h = Int(digits.prefix(2)), let mm = Int(digits.suffix(2)) else { return fallback }
        return TimeZone(secondsFromGMT: sign * (h * 3600 + mm * 60)) ?? fallback
    }

    /// "2026-09-23 20:32:00" (or without seconds) in farm time.
    public static func date(_ s: String?, zone: TimeZone) -> Date? {
        guard let s, s.count >= 16 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: String(s.prefix(16)))
    }

    public static func today(_ now: Date, zone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return Format.dayString(now, calendar: cal)
    }

    public static func yesterday(_ now: Date, zone: TimeZone) -> String {
        today(now.addingTimeInterval(-86_400), zone: zone)
    }

    /// "20:32", "20:32 yesterday", "21 Sep 20:32" — for a farm timestamp.
    public static func when(_ s: String?, now: Date, zone: TimeZone) -> String? {
        guard let s, s.count >= 16 else { return nil }
        let day = String(s.prefix(10)), time = String(s.dropFirst(11).prefix(5))
        if day == today(now, zone: zone) { return time }
        if day == yesterday(now, zone: zone) { return "\(time) yesterday" }
        return "\(dayLabel(day)) \(time)"
    }

    /// "2026-09-21" -> "21 Sep"; "Today" / "Yesterday" when it is.
    public static func dayLabel(_ day: String, now: Date? = nil, zone: TimeZone? = nil) -> String {
        if let now, let zone {
            if day == today(now, zone: zone) { return "Today" }
            if day == yesterday(now, zone: zone) { return "Yesterday" }
        }
        guard let d = Format.day(day) else { return day }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "d MMM"
        return f.string(from: d)
    }
}

/* ---- irrigation ---- */

/// One program run, read back from a timerLog row.
public struct ProgramRun: Hashable, Sendable {
    public let kind: String
    public let name: String
    /// Farm time, "2026-09-23 20:32:00".
    public let start: String
    public let deliveredMin: Int?
    public let plannedMin: Int?
    public let finished: Bool
    public let valves: String

    public var day: String { String(start.prefix(10)) }

    /// "1h", "5m of 30m".
    public var amount: String? {
        guard let planned = plannedMin else { return deliveredMin.map(Format.minutes) }
        if finished { return Format.minutes(planned) }
        return "\(Format.minutes(deliveredMin ?? 0)) of \(Format.minutes(planned))"
    }
}

/// One pump day, read back from a motorLog row.
public struct PumpDay: Hashable, Sendable {
    public let day: String
    public let pumpMin: Int
    public let supplyMin: Int
    public let kwh: Double?
}

/// Three phases of the controller's last electricity packet.
public struct Supply: Hashable, Sendable {
    public let phaseV: [Double]
    public let currentA: [Double]
    /// "22:24", when the packet said.
    public let at: String?
    /// Spread of the phase voltages, as the function worked it out.
    public var imbalancePct: Double? = nil
    /// Above this an induction motor runs hot; a figure worth a look, not an alarm.
    public static let imbalanceWarn = 5.0

    /// Below this a phase is not really there.
    static let deadVolts = 120.0

    public var hasVoltage: Bool { !phaseV.isEmpty }
    public var livePhases: Int { phaseV.filter { $0 >= Self.deadVolts }.count }
    public var powerOn: Bool { livePhases > 0 }
    /// Two phases up and one down stalls a three-phase pump.
    public var missingPhase: Bool { phaseV.count == 3 && livePhases > 0 && livePhases < 3 }
    public var pumpDrawing: Bool? { currentA.isEmpty ? nil : currentA.contains { $0 > 0.5 } }
}

public enum Irrigation {

    public static func run(_ row: ReportRow) -> ProgramRun? {
        guard row["source"] == nil || row["source"] == "timer",
              let event = row["event"], let start = row["at"], start.count >= 10 else { return nil }
        let head = event.components(separatedBy: " · ")
        let kind = head.count > 1 ? head[0] : "Program"
        let name = head.count > 1 ? head.dropFirst().joined(separator: " · ") : event
        var pieces = (row["detail"] ?? "").components(separatedBy: " · ")
        var delivered: Int?, planned: Int?, finished = false
        if let first = pieces.first, first.hasSuffix(", finished") || first.hasSuffix(", stopped") {
            finished = first.hasSuffix(", finished")
            let amount = first.components(separatedBy: ",")[0]
            let parts = amount.components(separatedBy: " of ")
            if parts.count == 2 {
                delivered = Format.runtimeMinutes(parts[0])
                planned = Format.runtimeMinutes(parts[1])
            } else {
                planned = Format.runtimeMinutes(amount)
                delivered = finished ? planned : nil
            }
            pieces.removeFirst()
        }
        let valves = pieces.first.flatMap { p -> String? in
            let l = p.lowercased()
            return p.isEmpty || l.contains("backwash") || l.hasPrefix("started by") || l.hasPrefix("ended by") ? nil : p
        } ?? ""
        return ProgramRun(kind: kind, name: name, start: start, deliveredMin: delivered,
                          plannedMin: planned, finished: finished, valves: valves == "no valves" ? "" : valves)
    }

    /// "pump 16h 21m of 19h 42m with power · 77.89 kWh".
    public static func pumpDay(_ row: ReportRow) -> PumpDay? {
        guard row["source"] == nil || row["source"] == "motor",
              let at = row["at"], at.count >= 10, let detail = row["detail"],
              let r = detail.range(of: #"^pump (.+?) of (.+?) with power"#, options: .regularExpression)
        else { return nil }
        let head = String(detail[r]).dropFirst(5).replacingOccurrences(of: " with power", with: "")
        let parts = head.components(separatedBy: " of ")
        guard parts.count == 2 else { return nil }
        let kwh = detail.components(separatedBy: " · ")
            .first { $0.hasSuffix(" kWh") }
            .flatMap { Double($0.replacingOccurrences(of: " kWh", with: "")) }
        return PumpDay(day: String(at.prefix(10)), pumpMin: Format.runtimeMinutes(parts[0]),
                       supplyMin: Format.runtimeMinutes(parts[1]), kwh: kwh)
    }

    /// Newest first, as the log is written.
    public static func runs(_ c: IrrigationCache) -> [ProgramRun] {
        c.timerLog.compactMap(run).sorted { $0.start > $1.start }
    }

    public static func pumpDays(_ c: IrrigationCache) -> [PumpDay] {
        c.motorLog.compactMap(pumpDay).sorted { $0.day > $1.day }
    }

    public struct Day: Hashable, Sendable {
        public let day: String
        public let runs: [ProgramRun]
        public let pump: PumpDay?
        public var waterMin: Int { runs.reduce(0) { $0 + ($1.deliveredMin ?? 0) } }
        public var stopped: Int { runs.filter { !$0.finished }.count }
        /// Programs that ran, by water time, most first.
        public var programs: [(name: String, minutes: Int)] {
            var by: [String: Int] = [:]
            for r in runs { by[r.name, default: 0] += r.deliveredMin ?? 0 }
            return by.map { ($0.key, $0.value) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        }
    }

    /// The newest day the logs cover — today if they reach it.
    public static func latestDay(_ c: IrrigationCache) -> Day? {
        let runs = runs(c), pumps = pumpDays(c)
        guard let day = [runs.first?.day, pumps.first?.day].compactMap({ $0 }).max() else { return nil }
        return Day(day: day, runs: runs.filter { $0.day == day }, pump: pumps.first { $0.day == day })
    }

    /// "254 / 249 / 264" -> [254, 249, 264].
    static func triple(_ s: String?) -> [Double] {
        (s ?? "").components(separatedBy: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    public static func supply(_ c: IrrigationCache) -> Supply? {
        let volts = c.electricity.first { ($0["label"] ?? "").lowercased().contains("phase voltage") }
        let amps = c.electricity.first { ($0["label"] ?? "").lowercased().contains("current") }
        let v = triple(volts?["value"]), a = triple(amps?["value"])
        guard !v.isEmpty || !a.isEmpty else { return nil }
        let note = [volts?["note"], amps?["note"]].compactMap { $0 }.joined(separator: " ")
        let at = note.range(of: #"\d{2}:\d{2}"#, options: .regularExpression).map { String(note[$0]) }
        let imb = (volts?["note"]).flatMap { n in
            n.range(of: #"[\d.]+(?=% imbalance)"#, options: .regularExpression).flatMap { Double(n[$0]) }
        }
        return Supply(phaseV: v, currentA: a, at: at, imbalancePct: imb)
    }

    /// The last inlet reading: value with unit, and its farm timestamp.
    public static func pressure(_ c: IrrigationCache) -> (value: String, at: String?)? {
        guard let last = c.pressure.last, let v = last["value"], !v.isEmpty else { return nil }
        return ([v, last["unit"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "), last["at"])
    }
}

/* ---- solar ---- */

/// An inverter, found by what Home Assistant integrations call things:
/// "PV Power", "Today's PV Generation". Nothing is keyed to one brand.
public struct SolarGlance: Sendable {
    public let now: Entity?
    public let today: Entity?
    public let total: Entity?
    public let temperature: Entity?
    public let mode: Entity?
    public let area: String

    /// The generation right now, in watts.
    public var watts: Double? {
        guard let e = now, !e.isBad, let v = Double(e.state ?? "") else { return nil }
        return (e.attrs.unit ?? "W").lowercased() == "kw" ? v * 1000 : v
    }

    public static func find(_ ents: [Entity]) -> SolarGlance? {
        let sensors = ents.filter { $0.domain == "sensor" }
        func first(_ test: (String, Entity) -> Bool) -> Entity? {
            let hits = sensors.filter { test($0.name.lowercased(), $0) }
            return hits.first { !$0.isBad } ?? hits.first
        }
        let now = first { n, e in
            (e.attrs.deviceClass == "power" || e.attrs.unit == "W" || e.attrs.unit == "kW")
                && (n.hasSuffix("pv power") || n.hasSuffix("solar power"))
        }
        let today = first { n, e in
            n.contains("today") && (n.contains("pv") || n.contains("solar"))
                && (e.attrs.deviceClass == "energy" || e.attrs.unit == "kWh")
        }
        guard now != nil || today != nil else { return nil }
        let device = (now ?? today)?.device
        let same = { (e: Entity) in device == nil || e.device == device }
        let total = first { n, e in same(e) && n.contains("total pv generation") }
        let temp = first { n, e in same(e) && n.hasSuffix("inverter temperature") }
        let mode = first { n, e in same(e) && n.hasSuffix("work mode") }
        return SolarGlance(now: now, today: today, total: total, temperature: temp, mode: mode,
                           area: (now ?? today)!.area)
    }
}

/* ---- security ---- */

public struct SecurityGlance: Sendable {
    public let alarms: [Entity]
    public let cameras: [Entity]
    /// Motion and person sensors that are reporting.
    public let sensors: [Entity]

    public var camerasDown: Int { cameras.filter(\.isBad).count }
    /// Sensors seeing something right now.
    public var activeNow: [Entity] { sensors.filter(\.isOn) }
    /// The sensor that changed most recently.
    public var latest: Entity? {
        sensors.max { ($0.lastChanged ?? "") < ($1.lastChanged ?? "") }
    }

    public static func find(_ ents: [Entity]) -> SecurityGlance? {
        let alarms = ents.filter { $0.domain == "alarm_control_panel" && !$0.isBad }
        let cameras = ents.filter { $0.domain == "camera" }
        let sensors = ents.filter { e in
            guard e.domain == "binary_sensor", !e.isBad else { return false }
            let n = e.name.lowercased()
            return ["motion", "occupancy", "presence"].contains(e.attrs.deviceClass ?? "")
                || n.hasSuffix("motion detected") || n.hasSuffix("person detected")
        }
        guard !alarms.isEmpty || !cameras.isEmpty || !sensors.isEmpty else { return nil }
        return SecurityGlance(alarms: alarms, cameras: cameras, sensors: sensors)
    }

    /// "armed_home" -> "Armed · home".
    public static func alarmLabel(_ state: String?) -> String {
        guard let s = state, !s.isEmpty else { return "Unknown" }
        if s.hasPrefix("armed_") {
            return "Armed · " + s.dropFirst(6).replacingOccurrences(of: "_", with: " ")
        }
        return s.prefix(1).uppercased() + s.dropFirst().replacingOccurrences(of: "_", with: " ")
    }

    /// "Sheep Shed Motion detected" -> "Motion"; the device name is said separately.
    public static func sensorKind(_ e: Entity) -> String {
        let n = e.name.lowercased()
        if n.contains("person") { return "Person" }
        if n.contains("pet") { return "Pet" }
        return "Motion"
    }
}

/* ---- what is on ---- */

public enum OnNow {
    /// Operable things that are on, by room then name: the lights left on in
    /// the car shed, not a sample of every switch on the farm.
    public static func entities(_ ents: [Entity], areaName: (String) -> String) -> [Entity] {
        ents.filter { $0.isControllable && !$0.isBad && $0.isOn }
            .sorted {
                let a = areaName($0.area), b = areaName($1.area)
                return a != b ? Sorting.natural(a, b) : Sorting.byName($0, $1)
            }
    }
}
