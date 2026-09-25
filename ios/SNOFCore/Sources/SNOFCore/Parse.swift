import Foundation

/* RTDB snapshots arrive as untyped Foundation trees (NSDictionary, NSArray,
 * NSNumber, NSString) — from the Firebase SDK and from JSONSerialization
 * alike, so the mock and the real farm go through the same code. Everything
 * here is total: a node of the wrong shape is skipped, never trapped on. */
public enum Parse {

    public static func string(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return isBool(n) ? (n.boolValue ? "true" : "false") : format(n)
        default: return nil
        }
    }

    public static func double(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber: return isBool(n) ? nil : n.doubleValue
        case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    public static func bool(_ v: Any?) -> Bool? {
        if let n = v as? NSNumber, isBool(n) { return n.boolValue }
        return nil
    }

    /// RTDB returns a list with integer-like keys as an array, and a sparse one
    /// as a dictionary. Accept either.
    public static func list(_ v: Any?) -> [Any] {
        if let a = v as? [Any] { return a.filter { !($0 is NSNull) } }
        if let d = v as? [String: Any] {
            return d.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map(\.value)
        }
        return []
    }

    /// A row of display strings. Nested values are dropped: rows are flat by contract.
    public static func row(_ v: Any?) -> ReportRow? {
        guard let d = v as? [String: Any] else { return nil }
        var out: ReportRow = [:]
        for (k, val) in d { if let s = string(val) { out[k] = s } }
        return out
    }

    public static func rows(_ v: Any?) -> [ReportRow] { list(v).compactMap(row) }

    /* ---- nodes ---- */

    public static func meta(_ v: Any?) -> FarmMeta {
        guard let d = v as? [String: Any] else { return FarmMeta() }
        var bridge: BridgeMeta?
        if let b = d["bridge"] as? [String: Any] {
            bridge = BridgeMeta(
                status: string(b["status"]),
                lastSeen: double(b["lastSeen"]),
                heartbeatSeconds: double(b["heartbeatSeconds"]),
                control: bool(b["control"]),
                commandsRun: double(b["commandsRun"]).map { Int($0) },
                commandsRefused: double(b["commandsRefused"]).map { Int($0) })
            bridge?.irrigationControl = bool(b["irrigationControl"])
            bridge?.irrigationMaxMinutes = double((b["irrigationControlStatus"] as? [String: Any])?["maxMinutes"])
                .map { Int($0) }
        }
        let cloud = d["irrigationControl"] as? [String: Any]
        let reports = d["reports"] as? [String: Any]
        var m = FarmMeta(name: string(d["name"]), bridge: bridge,
                         reportsEnabled: bool(reports?["enabled"]),
                         cloudIrrigationControl: bool(cloud?["enabled"]),
                         cloudIrrigationMaxMinutes: double(cloud?["maxMinutes"]).map { Int($0) })
        m.reportsTransport = string(reports?["transport"])
        let mc = d["motorControl"] as? [String: Any]
        m.motorControl.enabled = bool(mc?["enabled"]) == true
        m.motorControl.motors = (mc?["motors"] as? [String: Any] ?? [:]).compactMapValues { $0 as? Bool }
        m.motorControl.lastByMotor = (mc?["lastByMotor"] as? [String: Any] ?? [:]).compactMapValues { double($0) }
        m.motorControl.lockUntil = double((mc?["lock"] as? [String: Any])?["until"])
        m.motorControl.zones = (mc?["zones"] as? [String: Any] ?? [:]).compactMapValues { $0 as? Bool }
        m.motorControl.lastZoneByMotor = (mc?["lastZoneByMotor"] as? [String: Any] ?? [:]).compactMapValues { double($0) }
        return m
    }

    public static func areas(_ v: Any?) -> [String: Area] {
        guard let d = v as? [String: Any] else { return [:] }
        var out: [String: Area] = [:]
        for (id, node) in d {
            let name = string((node as? [String: Any])?["name"]) ?? id
            out[id] = Area(id: id, name: name)
        }
        return out
    }

    /// `devices`: device id -> name, for devices in a room.
    public static func devices(_ v: Any?) -> [String: String] {
        guard let d = v as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (id, node) in d { out[id] = string((node as? [String: Any])?["name"]) ?? id }
        return out
    }

    public static func entities(_ v: Any?) -> [Entity] {
        guard let domains = v as? [String: Any] else { return [] }
        var out: [Entity] = []
        out.reserveCapacity(1024)
        for (domain, objs) in domains {
            guard let objs = objs as? [String: Any] else { continue }
            for (objectId, node) in objs {
                guard let n = node as? [String: Any] else { continue }
                let a = n["attrs"] as? [String: Any] ?? [:]
                out.append(Entity(
                    domain: domain, objectId: objectId,
                    entityId: string(n["entity_id"]),
                    name: string(n["name"]),
                    state: string(n["state"]),
                    area: string(n["area"]),
                    device: string(n["device"]),
                    attrs: Attrs(unit: string(a["unit_of_measurement"]),
                                 deviceClass: string(a["device_class"]),
                                 batteryLevel: double(a["battery_level"]),
                                 brightness: double(a["brightness"]),
                                 percentage: double(a["percentage"])),
                    lastChanged: string(n["lastChanged"])))
            }
        }
        return out
    }

    public static func irrigation(_ v: Any?) -> IrrigationCache {
        var c = IrrigationCache()
        guard let d = v as? [String: Any] else { return c }
        if let dcon = d["dcon"] as? [String: Any] {
            c.device = string(dcon["device"])
            c.serial = string(dcon["serial"])
            c.lastPacket = string(dcon["lastPacket"])
            c.serverTime = string(dcon["serverTime"])
            c.timeZone = string(dcon["timeZone"]).flatMap { $0.isEmpty ? nil : $0 }
        }
        c.timerLog = rows(d["timerLog"])
        c.timerLogAt = double(d["timerLogAt"])
        c.motorLog = rows(d["motorLog"])
        if let p = d["program"] as? [String: Any] {
            c.program = CurrentProgram(name: string(p["name"]) ?? "", kind: string(p["kind"]) ?? "",
                                       running: bool(p["running"]) ?? false, valves: string(p["valves"]) ?? "",
                                       start: string(p["start"]) ?? "",
                                       plannedMin: double(p["plannedMin"]).map { Int($0) },
                                       remainingMin: double(p["remainingMin"]).map { Int($0) },
                                       at: double(p["at"]))
            c.program?.lastSeen = string(p["lastSeen"]) ?? ""
            c.program?.faults = list(p["faults"]).compactMap(string)
            if let n = p["next"] as? [String: Any], let name = string(n["name"]), !name.isEmpty {
                c.program?.next = NextProgram(name: name, valves: string(n["valves"]) ?? "",
                                              plannedMin: double(n["plannedMin"]).map { Int($0) })
            }
        }
        c.valveNames = rows(d["valveNames"])
        c.valves = rows(d["valves"])
        c.electricity = rows(d["electricity"])
        c.pressure = rows(d["pressure"])
        if let m = d["meta"] as? [String: Any] {
            c.lastUpdated = double(m["lastUpdated"])
            c.lastType = string(m["lastType"])
            c.lastError = string(m["lastError"]).flatMap { $0.isEmpty ? nil : $0 }
        }
        return c
    }

    public static func section(_ v: Any?) -> ReportSection? {
        guard let d = v as? [String: Any], let kind = string(d["kind"]) else { return nil }
        return ReportSection(kind: kind,
                             title: string(d["title"]) ?? "",
                             note: string(d["note"]) ?? "",
                             source: string(d["source"]) ?? "",
                             status: string(d["status"]) ?? "ok",
                             error: string(d["error"]) ?? "",
                             unit: string(d["unit"]) ?? "",
                             rows: rows(d["rows"]),
                             legend: rows(d["legend"]).filter { !($0["key"] ?? "").isEmpty })
    }

    public static func report(key: String, _ v: Any?) -> Report? {
        guard let d = v as? [String: Any] else { return nil }
        let type = string(d["type"]) ?? ""
        let params = d["params"] as? [String: Any]
        return Report(key: key, type: type,
                      label: string(d["label"]) ?? IrrigationTypes.label(for: type) ?? "Report",
                      from: string(params?["from"]), to: string(params?["to"]),
                      status: string(d["status"]) ?? "",
                      summary: string(d["summary"]) ?? "",
                      error: string(d["error"]) ?? "",
                      at: double(d["at"]) ?? 0,
                      sections: list(d["sections"]).compactMap(section),
                      legacyRows: rows(d["rows"]))
    }

    /// Newest first.
    public static func reports(_ v: Any?) -> [Report] {
        guard let d = v as? [String: Any] else { return [] }
        return d.compactMap { report(key: $0.key, $0.value) }.sorted { $0.at > $1.at }
    }

    /* ---- helpers ---- */

    /// NSNumber carries bools too; JSON `true` must not read as `1`.
    static func isBool(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    static func format(_ n: NSNumber) -> String {
        let d = n.doubleValue
        if d.isFinite, d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }
}
