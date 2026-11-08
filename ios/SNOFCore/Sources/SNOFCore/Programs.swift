import Foundation

/* Saved programs, rain and the controller's own facts: the web's Programs
 * card, Rain line and Controller card (contract: .context/mobitech-more-contract.md).
 * Every field is optional: an older function writes none of them, and an
 * older app ignores them. */

/// One saved program (`irrigation/programs/items/<no>`).
public struct SavedProgram: Identifiable, Hashable, Sendable {
    public var number: Int
    public var name: String
    public var valves: [Int]
    /// "05:30"
    public var start: String
    /// "01:00" (HH:MM).
    public var duration: String
    /// "Daily" or "Mon,Tue".
    public var days: String
    public var enabled: Bool
    public var id: Int { number }

    public init(number: Int, name: String, valves: [Int] = [], start: String = "", duration: String = "",
                days: String = "", enabled: Bool = true) {
        self.number = number; self.name = name; self.valves = valves; self.start = start
        self.duration = duration; self.days = days; self.enabled = enabled
    }

    /// The duration in minutes, nil when it is not "HH:MM".
    public var minutes: Int? {
        let p = duration.split(separator: ":").compactMap { Int($0) }
        return p.count == 2 ? p[0] * 60 + p[1] : nil
    }

    /// "Coconut (#2)"
    public var label: String { "\(name.isEmpty ? "Program" : name) (#\(number))" }
}

public struct ProgramsCache: Hashable, Sendable {
    /// Server milliseconds of the read.
    public var at: Double?
    public var items: [SavedProgram]
    public init(at: Double? = nil, items: [SavedProgram] = []) { self.at = at; self.items = items }
}

/// `irrigation/rain`, mm.
public struct RainCache: Hashable, Sendable {
    public var at: Double?
    public var today: Double?
    public var last24h: Double?
    public var yesterday: Double?
    public var week: Double?
    public init(at: Double? = nil, today: Double? = nil, last24h: Double? = nil, yesterday: Double? = nil, week: Double? = nil) {
        self.at = at; self.today = today; self.last24h = last24h; self.yesterday = yesterday; self.week = week
    }
}

/// What the controller read adds: firmware, SIM expiry, emergency shutdown.
public struct ControllerInfo: Hashable, Sendable {
    public var firmware: String?
    /// "2027-03-01", or nil when unknown.
    public var simExpiry: String?
    public var shutdown: Bool?
    /// `dcon/current` and `dcon/next`: the timer numbers (text in the node).
    /// `hasCurrent` is false when the node is absent: fall back to names.
    public var hasCurrent = false
    public var currentRunning = false
    public var currentNumber: Int?
    public var nextNumber: Int?
    public init(firmware: String? = nil, simExpiry: String? = nil, shutdown: Bool? = nil) {
        self.firmware = firmware; self.simExpiry = simExpiry; self.shutdown = shutdown
    }
    public var isEmpty: Bool { firmware == nil && simExpiry == nil && shutdown == nil }
}

extension Parse {
    public static func controllerInfo(_ d: [String: Any]) -> ControllerInfo {
        var i = ControllerInfo(firmware: string(d["firmware"]).flatMap { $0.isEmpty ? nil : $0 },
                               simExpiry: string(d["simExpiry"]).flatMap { $0.isEmpty ? nil : $0 },
                               shutdown: bool(d["shutdown"]))
        if let c = d["current"] as? [String: Any] {
            i.hasCurrent = true
            i.currentRunning = bool(c["running"]) ?? false
            i.currentNumber = string(c["number"]).flatMap { Int($0) }
        }
        if let n = d["next"] as? [String: Any] { i.nextNumber = string(n["number"]).flatMap { Int($0) } }
        return i
    }

    /// nil when the node is absent, so "never read" and "no programs" differ.
    public static func programs(_ v: Any?) -> ProgramsCache? {
        guard let d = v as? [String: Any] else { return nil }
        var items: [SavedProgram] = []
        // An object keyed "p<no>" (or "<no>"); RTDB hands bare numeric keys back as an array.
        var raws: [(String, Any)] = []
        if let obj = d["items"] as? [String: Any] { raws = obj.map { ($0.key, $0.value) } }
        else if let arr = d["items"] as? [Any] { raws = arr.enumerated().map { (String($0.offset), $0.element) } }
        for (key, raw) in raws {
            guard let n = raw as? [String: Any] else { continue }
            let keyNo = Int(key.hasPrefix("p") ? String(key.dropFirst()) : key)
            guard let no = double(n["number"]).map({ Int($0) }) ?? keyNo, (1...99).contains(no) else { continue }
            items.append(SavedProgram(
                number: no, name: string(n["name"]) ?? "",
                valves: list(n["valves"]).compactMap { double($0).map { Int($0) } },
                start: string(n["start"]) ?? "", duration: string(n["duration"]) ?? "",
                days: string(n["days"]) ?? "", enabled: bool(n["enabled"]) ?? true))
        }
        return ProgramsCache(at: double(d["at"]), items: items.sorted { $0.number < $1.number })
    }

    public static func rain(_ v: Any?) -> RainCache? {
        guard let d = v as? [String: Any] else { return nil }
        return RainCache(at: double(d["at"]), today: double(d["today"]), last24h: double(d["last24h"]),
                         yesterday: double(d["yesterday"]), week: double(d["week"]))
    }
}

public enum ProgramMark: Equatable, Sendable { case running, next }

public enum Programs {
    /// Running / next, taken from the controller's own current timer
    /// (`irrigation/program`): the same name the controller reports.
    public static func mark(_ p: SavedProgram, in cache: IrrigationCache) -> ProgramMark? {
        let info = cache.controllerInfo
        if info.hasCurrent {
            if info.currentRunning, info.currentNumber == p.number { return .running }
            if info.nextNumber == p.number { return .next }
            return nil
        }
        guard let cur = cache.program else { return nil }
        let name = p.name.lowercased()
        if cur.running, !cur.name.isEmpty, cur.name.lowercased() == name { return .running }
        if let n = cur.next, !n.name.isEmpty, n.name.lowercased() == name { return .next }
        return nil
    }

    /// "1 h" / "45 min" for a program's own duration.
    public static func durationText(_ p: SavedProgram) -> String {
        guard let m = p.minutes else { return p.duration }
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    /// Confirm text, from the contract.
    public static func confirm(_ p: SavedProgram) -> String {
        "Start \(p.label) for \(durationText(p))? It takes over from any run going now."
    }

    /// "Rain today 0 mm · week 3.2 mm"
    public static func rainLine(_ r: RainCache) -> String? {
        func mm(_ v: Double) -> String { v == v.rounded() ? "\(Int(v)) mm" : String(format: "%.1f mm", v) }
        var bits: [String] = []
        if let t = r.today { bits.append("Rain today \(mm(t))") }
        if let w = r.week { bits.append("week \(mm(w))") }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    /// "1 Mar 2027", nil when it is not a YYYY-MM-DD.
    public static func simText(_ s: String, locale: Locale = Locale(identifier: "en_GB")) -> String {
        guard let d = Format.day(s) else { return s }
        let f = DateFormatter(); f.locale = locale; f.dateFormat = "d MMM yyyy"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }
}
