import Foundation
import SNOFCore

/* Bundled fixtures standing in for the farm — the same data as the web
 * preview harness (dashboard/preview/stub.html), exported to JSON. Used when
 * the build has no GoogleService-Info.plist, or when launched with -demo.
 * Every screen says "Demo data" while this is active, so it can never be
 * mistaken for the farm.
 *
 * Launch arguments, mirroring the preview's query flags:
 *   -demo-real        698 entities, 373 unavailable, real HA naming
 *   -demo-live        production on 2026-09-24: 297 entities on 21 roomed
 *                     devices, with device ids and names (debug builds only)
 *   -demo-viewer      viewer, not controller
 *   -demo-admin       admin: sees irrigation Run / Stop
 *   -demo-irrigationoff  bridge publishes irrigationControl: false
 *   -demo-controloff  bridge publishes control: false
 *   -demo-reportsoff  meta/reports.enabled: false (the report kill switch)
 *   -demo-stale       bridge heartbeat 400 s old
 *   -demo-fresh       (with SNOF_DEMO_TREE) water readings moved to now
 *   -demo-signedout   start on the sign-in screen
 *   -demo-denied      signed in, but not on the allowlist
 *   -demo-signinfail  sign-in fails the way a real one can (shows the report) */
@MainActor
final class DemoBackend: FarmBackend {

    let isDemo = true
    let configurationProblem: String? = nil

    private let args = Set(ProcessInfo.processInfo.arguments)
    private func flag(_ f: String) -> Bool { args.contains("-demo-\(f)") }

    private var tree: [String: Any] = [:]
    private var handler: ((FarmEvent) -> Void)?
    private var authHandler: ((AppUser?) -> Void)?
    private var signedIn: Bool
    private var ticker: Task<Void, Never>?

    private static let user = AppUser(uid: "demo", email: "operator@example.com", displayName: "Demo operator")

    init() {
        signedIn = !ProcessInfo.processInfo.arguments.contains("-demo-signedout")
        load()
    }

    private func load() {
        // The real-shaped fixture is excluded from Release builds (it carries
        // real room names); fall back to the clean one there.
        let names = flag("real") ? ["mock-farm-real", "mock-farm-clean"] : ["mock-farm-clean"]
        guard let url = names.lazy.compactMap({ Bundle.main.url(forResource: $0, withExtension: "json") }).first,
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        tree = root
        #if DEBUG
        if flag("live"), let url = Bundle.main.url(forResource: "mock-farm-live", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let live = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["areas", "devices", "entities", "irrigation"] { tree[key] = live[key] }
        }
        // Review hook: SNOF_DEMO_REPORTS=<json> swaps in report cards the Cloud
        // Function built from real controller payloads (dashboard/preview's
        // reports-real.json). Debug builds only; the file is never bundled.
        if let path = ProcessInfo.processInfo.environment["SNOF_DEMO_REPORTS"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let reports = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            tree["irrigation_reports"] = reports
        }
        #endif

        // The fixture was exported with absolute timestamps; move them to now.
        let now = Date().timeIntervalSince1970 * 1000
        var reports = tree["irrigation_reports"] as? [String: Any] ?? [:]
        let newest = reports.values.compactMap { Parse.double(($0 as? [String: Any])?["at"]) }.max() ?? now
        let shift = now - (newest + 3_600_000)
        for (k, v) in reports {
            guard var r = v as? [String: Any], let at = Parse.double(r["at"]) else { continue }
            r["at"] = at + shift
            reports[k] = r
        }
        tree["irrigation_reports"] = reports
        if !flag("live") { tree["irrigation"] = Self.moveToToday(tree["irrigation"], now: now) }

        var meta = tree["meta"] as? [String: Any] ?? [:]
        var bridge = meta["bridge"] as? [String: Any] ?? [:]
        bridge["lastSeen"] = now - (flag("stale") ? 400_000 : 5_000)
        bridge["control"] = !flag("controloff")
        bridge["irrigationControl"] = !flag("controloff") && !flag("irrigationoff")
        bridge["irrigationControlStatus"] = ["maxMinutes": 60]
        meta["bridge"] = bridge
        if flag("reportsoff") { meta["reports"] = ["enabled": false] }
        // The water chain, as the water functions write it. -demo-wateroff is
        // the kill switch off; -demo-liveskyexpired an ended Livesky session.
        let iso = { (ms: Double) in ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: ms / 1000)) }
        meta["water"] = [
            "enabled": !flag("wateroff"), "lastPull": now - 20_000,
            "livesky": flag("liveskyexpired")
                ? ["ok": false, "error": "The Livesky session has expired.", "expires": now - 3_600_000,
                   "signedInAt": now - 90_000_000, "mobileLast4": "3210"] as [String: Any]
                : ["ok": true, "error": "", "at": now - 20_000, "expires": now + 20 * 3_600_000,
                   "signedInAt": now - 4 * 3_600_000, "mobileLast4": "3210"],
            "niagara": ["ok": true, "error": "", "at": now - 20_000],
        ] as [String: Any]
        // -demo-motors: the water-chain motors armed for switching.
        if flag("motors") { meta["motorControl"] = ["enabled": true, "motors": ["river": true, "wellmotor75hp": true, "well-motor": true],
                                                    "zones": ["well-motor": true]] }
        tree["meta"] = meta
        #if DEBUG
        // Review hook: SNOF_DEMO_TREE=<farm.json> replays a whole production
        // snapshot (a local file, never bundled or committed), so every screen
        // can be checked against the real farm; the heartbeat is moved to now.
        if let path = ProcessInfo.processInfo.environment["SNOF_DEMO_TREE"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let real = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in real { tree[k] = v }
            // -demo-watering: a manual run in progress, 6 of 20 minutes done.
            if flag("watering"), var irr = tree["irrigation"] as? [String: Any] {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = TimeZone(secondsFromGMT: 19_800); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
                irr["program"] = ["name": "Manual Mode", "kind": "Manual", "running": true, "valves": "4 Veg, 6 Kulam",
                                  "start": f.string(from: Date(timeIntervalSince1970: now / 1000 - 360)), "plannedMin": 20,
                                  "remainingMin": 14, "lastSeen": f.string(from: Date(timeIntervalSince1970: now / 1000 - 60)),
                                  "at": now - 60_000] as [String: Any]
                tree["irrigation"] = irr
            }
            // The state flags apply to the replayed tree too (they were lost
            // to its own meta, so -demo-stale showed "Live").
            var m = tree["meta"] as? [String: Any] ?? [:]
            var b = m["bridge"] as? [String: Any] ?? [:]
            b["lastSeen"] = now - (flag("stale") ? 400_000 : 5_000)
            if flag("controloff") { b["control"] = false; b["irrigationControl"] = false }
            if flag("irrigationoff") { b["irrigationControl"] = false }
            m["bridge"] = b
            if flag("reportsoff") { m["reports"] = ["enabled": false] }
            if var wm = m["water"] as? [String: Any] {
                if flag("wateroff") { wm["enabled"] = false }
                if flag("liveskyexpired") {
                    var ls = wm["livesky"] as? [String: Any] ?? [:]
                    ls["expires"] = now - 3_600_000; ls["ok"] = false; ls["error"] = "The Livesky session has expired."
                    wm["livesky"] = ls
                }
                m["water"] = wm
            }
            tree["meta"] = m
            // -demo-fresh: the water readings as if pulled just now, for
            // reviewing the live look with the real farm's values.
            if flag("fresh"), var w = tree["water"] as? [String: Any], let pulled = Parse.double(w["pulledAt"]) {
                let shift = (now - 10_000 - pulled) / 1000
                let fmt = ISO8601DateFormatter()
                func moved(_ v: Any?) -> Any? {
                    guard let s = v as? String, let d = fmt.date(from: s) else { return v }
                    return fmt.string(from: d.addingTimeInterval(shift))
                }
                func touch(_ v: Any?) -> Any? {
                    guard var d = v as? [String: Any] else { return v }
                    for k in ["reportedAt", "liveAt"] where d[k] != nil { d[k] = moved(d[k]) }
                    return d
                }
                w["pulledAt"] = now - 10_000
                w["river"] = touch(w["river"])
                if let motors = w["motors"] as? [String: Any] { w["motors"] = motors.mapValues { touch($0) ?? $0 } }
                tree["water"] = w
                if var wm = (tree["meta"] as? [String: Any])?["water"] as? [String: Any] {
                    for k in ["livesky", "niagara"] { if var st = wm[k] as? [String: Any] { st["at"] = now - 10_000; wm[k] = st } }
                    var mm = tree["meta"] as? [String: Any] ?? [:]; mm["water"] = wm; tree["meta"] = mm
                }
            }
            return
        }
        #endif
        tree["water"] = [
            "pulledAt": now - 20_000,
            "river": ["name": "River Motor", "vendor": "livesky", "running": true, "pending": false,
                      "connected": true, "power": true, "volts": [467, 457, 453], "amps": [10.1, 10.1],
                      "runMinutes": 196, "stopMinutes": 1, "autoStart": true, "reportedAt": iso(now - 45_000)],
            "motors": [
                "wellmotor75hp": ["name": "Wellmotor75HP", "vendor": "niagara", "role": "main-farm",
                                  "group": "Water 7.5hp", "running": false, "requested": false, "power": true,
                                  "supply": "3 PHASE", "event": "MOTOR OFF III PHASE", "eventCode": "020",
                                  "reportedAt": iso(now - 3 * 3_600_000)],
                "well-motor": ["name": "Well motor", "vendor": "niagara", "role": "drip", "group": "GROUP ONE",
                               "running": true, "requested": true, "power": true, "supply": "3 PHASE",
                               "event": "Zone changed", "eventCode": "044", "program": "P1", "zone": 3,
                               "zoneLeft": "00:32:31", "volts": [232, 232, 234], "amps": [8.7, 8.7],
                               "pressureOut": 21.9, "reportedAt": iso(now - 70_000), "liveAt": iso(now - 30_000)],
            ],
        ] as [String: Any]
    }

    /// The clean fixture's controller logs are from 2026-02-22; say they are
    /// from today (farm time), and that the controller was asked 12 minutes ago.
    private static func moveToToday(_ v: Any?, now: Double) -> Any? {
        guard let data = try? JSONSerialization.data(withJSONObject: v ?? [:]),
              var text = String(data: data, encoding: .utf8) else { return v }
        let zone = FarmTime.zone("+05:30"), date = Date(timeIntervalSince1970: now / 1000)
        text = text.replacingOccurrences(of: "2026-02-22", with: FarmTime.today(date, zone: zone))
            .replacingOccurrences(of: "2026-02-21", with: FarmTime.yesterday(date, zone: zone))
        guard var tree = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return v }
        if var p = tree["program"] as? [String: Any] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = zone; f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            p["at"] = now - 12 * 60_000
            p["lastSeen"] = f.string(from: date.addingTimeInterval(-12 * 60))
            p["start"] = f.string(from: date.addingTimeInterval(-24 * 60))
            tree["program"] = p
        }
        tree["meta"] = ["lastUpdated": now - 12 * 60_000, "lastType": "controller", "lastError": ""]
        return tree
    }

    /* ---- auth ---- */

    func observeAuth(_ handler: @escaping (AppUser?) -> Void) {
        authHandler = handler
        handler(signedIn ? Self.user : nil)
    }

    func signIn() async throws {
        try await Task.sleep(for: .milliseconds(400))
        if flag("signinfail") {
            let cause = NSError(domain: "com.google.HTTPStatus", code: 400,
                                userInfo: [NSLocalizedDescriptionKey: "invalid_request"])
            throw NSError(domain: "com.google.GIDSignIn", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Demo: the sign-in request was refused.",
                                     NSUnderlyingErrorKey: cause])
        }
        signedIn = true
        authHandler?(Self.user)
    }

    func signOut() {
        signedIn = false
        authHandler?(nil)
    }

    /* ---- listeners ---- */

    func attach(user: AppUser, _ handler: @escaping (FarmEvent) -> Void) {
        self.handler = handler
        handler(.serverTimeOffset(0))
        handler(.connected(true))
        if flag("denied") { handler(.denied); return }
        handler(.controller(!flag("viewer")))
        handler(.admin(flag("admin")))
        emitAll()

        ticker = Task { [weak self] in
            var beat = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                beat += 1
                self.nudgeASensor(beat)
                if !self.flag("stale"), beat % 2 == 0 { self.heartbeat() }
            }
        }
    }

    func detach() {
        ticker?.cancel()
        ticker = nil
        handler = nil
    }

    private func emitAll() {
        handler?(.meta(tree["meta"]))
        handler?(.areas(tree["areas"]))
        handler?(.devices(tree["devices"]))
        handler?(.entities(tree["entities"]))
        handler?(.irrigation(tree["irrigation"]))
        handler?(.reports(tree["irrigation_reports"]))
        handler?(.water(tree["water"]))
        handler?(.mobitechStatus(tree["mobitech_status"]))
    }

    private func heartbeat() {
        var meta = tree["meta"] as? [String: Any] ?? [:]
        var bridge = meta["bridge"] as? [String: Any] ?? [:]
        bridge["lastSeen"] = Date().timeIntervalSince1970 * 1000
        meta["bridge"] = bridge
        tree["meta"] = meta
        handler?(.meta(meta))
    }

    /// The real farm changes something about once a second. Keep the demo
    /// moving too, so a screen that loses a drag or focus on update shows it.
    private func nudgeASensor(_ beat: Int) {
        guard var ents = tree["entities"] as? [String: Any],
              var sensors = ents["sensor"] as? [String: Any] else { return }
        let numeric = sensors.keys.sorted().filter {
            Parse.double((sensors[$0] as? [String: Any])?["state"]) != nil
        }
        guard !numeric.isEmpty else { return }
        let key = numeric[beat % numeric.count]
        guard var node = sensors[key] as? [String: Any], let v = Parse.double(node["state"]) else { return }
        let next = max(0, v + (beat % 2 == 0 ? 0.1 : -0.1))
        node["state"] = String(format: "%.1f", next)
        sensors[key] = node
        ents["sensor"] = sensors
        tree["entities"] = ents
        handler?(.entities(ents))
    }

    /* ---- writes: a stand-in bridge ---- */

    func send(_ command: Command, uid: String) async throws {
        if flag("viewer") { throw BackendError.refused }
        try await Task.sleep(for: .milliseconds(150))
        let cmd = command
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            self?.apply(cmd)
        }
    }

    private func apply(_ c: Command) {
        guard !flag("controloff"),
              var ents = tree["entities"] as? [String: Any],
              var domain = ents[c.domain] as? [String: Any] else { return }
        let objectId = String(c.entityId.dropFirst(c.domain.count + 1))
        guard var node = domain[objectId] as? [String: Any] else { return }
        var attrs = node["attrs"] as? [String: Any] ?? [:]
        switch c.service {
        case "turn_off": node["state"] = "off"
        case "turn_on":
            node["state"] = "on"
            if let b = c.brightness { attrs["brightness"] = b; if b == 0 { node["state"] = "off" } }
        case "set_percentage":
            let p = c.percentage ?? 0
            attrs["percentage"] = p
            node["state"] = p > 0 ? "on" : "off"
        default: return
        }
        node["attrs"] = attrs
        domain[objectId] = node
        ents[c.domain] = domain
        tree["entities"] = ents
        handler?(.entities(ents))
    }

    func requestReport(type: String, from: String?, to: String?, uid: String) async throws -> String {
        if flag("viewer") { throw BackendError.refused }
        let key = "demo_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(6))"
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard let self, !self.flag("reportsoff") else { return }
            var reports = self.tree["irrigation_reports"] as? [String: Any] ?? [:]
            reports[key] = Self.canned(type: type, from: from, to: to)
            self.tree["irrigation_reports"] = reports
            self.handler?(.reports(reports))
            // As the function does: the cache says when it was last asked.
            if var irr = self.tree["irrigation"] as? [String: Any] {
                let at = Date().timeIntervalSince1970 * 1000
                irr["meta"] = ["lastUpdated": at, "lastType": type, "lastError": ""]
                if type == "controller", var p = irr["program"] as? [String: Any] { p["at"] = at; irr["program"] = p }
                self.tree["irrigation"] = irr
                self.handler?(.irrigation(irr))
            }
        }
        return key
    }

    func saveMobitechSession(_ session: Mobitech.Session, mobileLast4: String, uid: String) async throws {
        if flag("viewer") { throw BackendError.refused }
        let status: [String: Any] = ["at": Date().timeIntervalSince1970 * 1000, "uid": uid,
                                     "name": session.name, "user": session.user, "mobileLast4": mobileLast4]
        tree["mobitech_status"] = status
        handler?(.mobitechStatus(status))
    }

    func clearMobitechSession() async throws {
        tree["mobitech_status"] = nil
        handler?(.mobitechStatus(nil))
    }

    /// As the function does it: lock, "confirming", then the motor confirms.
    func sendMotor(motor: String, action: String, zone: Int?, uid: String, clientAt: Double) async throws -> String {
        if flag("viewer") || !flag("motors") { throw BackendError.refused }
        let key = "demo_motor_\(UUID().uuidString.prefix(8))"
        Task { [weak self] in
            guard let self else { return }
            let at = Date().timeIntervalSince1970 * 1000
            var results = self.tree["motor_command_results"] as? [String: Any] ?? [:]
            results[key] = ["ok": true, "confirming": true, "verified": false, "motor": motor, "action": action]
            self.handler?(.motorResults(results))
            try? await Task.sleep(for: .seconds(3))
            var water = self.tree["water"] as? [String: Any] ?? [:]
            if motor == "river", var r = water["river"] as? [String: Any] { r["running"] = action == "on"; water["river"] = r }
            else if var ms = water["motors"] as? [String: Any], var m = ms[motor] as? [String: Any] {
                if action == "zone" { m["zone"] = zone ?? 1 } else { m["running"] = action == "on" }
                ms[motor] = m; water["motors"] = ms
            }
            self.tree["water"] = water
            self.handler?(.water(water))
            results[key] = ["ok": true, "confirming": false, "verified": true, "motor": motor, "action": action,
                            "zone": zone ?? 0, "message": "confirmed by the motor"]
            self.tree["motor_command_results"] = results
            self.handler?(.motorResults(results))
        }
        return key
    }

    func sendIrrigation(_ command: IrrigationCommand, uid: String) async throws -> String {
        if flag("viewer") || flag("controloff") { throw BackendError.refused }
        let key = "demo_irr_\(UUID().uuidString.prefix(8))"
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self else { return }
            var irr = self.tree["irrigation"] as? [String: Any] ?? [:]
            let names = Parse.rows(irr["valveNames"])
            let picked = (command.valves ?? "").split(separator: ",").map(String.init)
            let valveText = picked.map { id in names.first { $0["id"] == id }?["name"] ?? "valve \(id)" }
                .joined(separator: ", ")
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = FarmTime.zone("+05:30")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let now = Date(), at = now.timeIntervalSince1970 * 1000
            var program = irr["program"] as? [String: Any] ?? [:]
            if command.action == "run" {
                program = ["at": at, "name": "Manual Mode", "kind": "Manual", "running": true, "valves": valveText,
                           "start": f.string(from: now), "lastSeen": f.string(from: now),
                           "plannedMin": command.minutes ?? 0, "remainingMin": command.minutes ?? 0,
                           "next": program["next"] ?? NSNull()]
            } else {
                program["running"] = false
                program["at"] = at
            }
            irr["program"] = program
            // As the farm does it: lock, send, "confirming", then confirmed
            // once the controller shows the change, and the lock released.
            self.handler?(.irrigationLock(["cmd": key, "action": command.action, "until": at + 180_000]))
            var results = self.tree["irrigation_command_results"] as? [String: Any] ?? [:]
            let sent: [String: Any] = ["ok": true, "action": command.action, "status": 200, "valves": valveText,
                                       "minutes": command.minutes ?? 0, "message": "Command has been sent successfully", "at": at]
            results[key] = sent.merging(["verified": false, "confirming": true]) { $1 }
            self.handler?(.irrigationResults(results))
            try? await Task.sleep(for: .seconds(4))
            self.tree["irrigation"] = irr
            self.handler?(.irrigation(irr))
            results[key] = sent.merging(["verified": true, "confirming": false]) { $1 }
            self.tree["irrigation_command_results"] = results
            self.handler?(.irrigationResults(results))
            self.handler?(.irrigationLock(nil))
        }
        return key
    }

    func requestWaterRefresh(uid: String) async throws {
        if flag("wateroff") { return }
        var w = tree["water"] as? [String: Any] ?? [:]
        w["pulledAt"] = Date().timeIntervalSince1970 * 1000
        tree["water"] = w
        handler?(.water(w))
    }

    func waterSession(_ body: [String: Any]) async throws -> [String: Any] {
        if !flag("admin") { throw BackendError.other("Only farm admins can sign in to Livesky.") }
        try? await Task.sleep(for: .milliseconds(600))
        return ["ok": true, "expires": Date().timeIntervalSince1970 * 1000 + 86_400_000, "device": "River Motor"]
    }

    func cancelUnsentWrites() {}

    /// Same section kinds and row shapes the bridge writes, so what renders
    /// here renders against the NUC.
    private static func canned(type: String, from: String?, to: String?) -> [String: Any] {
        func sec(_ kind: String, _ title: String, _ rows: [[String: Any]]) -> [String: Any] {
            ["kind": kind, "title": title, "note": "", "source": "dcon", "status": "ok", "error": "", "rows": rows]
        }
        func m(_ label: String, _ value: Any, _ unit: String = "", _ note: String = "") -> [String: Any] {
            ["label": label, "value": value, "unit": unit, "note": note]
        }
        let win = (from != nil && to != nil) ? "\(from!) → \(to!)" : ""
        let press: [[String: Any]] = [("06:00", "1.8"), ("09:00", "2.4"), ("12:00", "2.0"),
                                      ("15:00", "1.6"), ("18:00", "2.6"), ("21:00", "2.1")]
            .map { ["at": "2026-09-22 \($0.0)", "value": $0.1, "unit": "bar"] }
        let bars: [[String: Any]] = [["name": "4 Veg", "value": 125, "unit": "min", "status": "off"],
                                     ["name": "6 Kulam", "value": 80, "unit": "min", "status": "on"],
                                     ["name": "9 Mulberry", "value": 40, "unit": "min", "status": "off"]]
        let log: [[String: Any]] = [
            ["at": "2026-09-21 06:00", "event": "timer", "detail": "Timer 11 completed", "source": "timer"],
            ["at": "2026-09-22 06:00", "event": "timer", "detail": "Timer 12 completed", "source": "timer"],
            ["at": "2026-09-22 06:05", "event": "motor", "detail": "Well motor stopped", "source": "motor"]]
        let valveSecs = [sec("metrics", "Valves", [m("Valves run", 3, "", win), m("Total runtime", "4h 5m", "", "longest 2h 5m")]),
                         sec("bars", "Runtime per valve", bars)]
        let pressSecs = [sec("metrics", "Pressure", [m("Average", 2.08, "bar", "6 readings"), m("Low", 1.6, "bar"), m("High", 2.6, "bar")]),
                         sec("series", "Pressure over time", press)]
        var sections: [[String: Any]]
        var summary: String
        switch type {
        case "controller":
            sections = [sec("facts", "Controller", [["label": "Device", "value": "SibhiSump"],
                                                    ["label": "Last packet", "value": "2026-09-22 09:00:43"]]),
                        sec("status", "Valves on this controller", [["name": "4 Veg", "status": "unknown", "meta": "Irrigation", "source": "dcon"],
                                                                    ["name": "2 BPump", "status": "unknown", "meta": "Booster Pump", "source": "dcon"]])]
            summary = "SibhiSump · 16 valves"
        case "electricity", "pressure", "live_readings":
            sections = [sec("metrics", "Now", [m("Phase voltage", "231 / 229 / 233", "V"), m("Pressure", 2.1, "bar", "inlet")])]
            summary = "231 V · 2.1 bar"
        case "valves": sections = valveSecs; summary = "3 valves · 1 open"
        case "pressure_range": sections = pressSecs; summary = "1.6–2.6 bar"
        case "performance": sections = valveSecs + pressSecs; summary = "4h 5m of valve runtime · pressure 1.6–2.6 bar"
        default: sections = [sec("timeline", "Log", log)]; summary = "\(log.count) entries"
        }
        var rep: [String: Any] = ["type": type, "label": IrrigationTypes.label(for: type) ?? type, "status": "ok",
                                  "summary": summary + (win.isEmpty ? "" : " · \(win)"), "sections": sections,
                                  "rows": [], "at": Date().timeIntervalSince1970 * 1000]
        if let from, let to { rep["params"] = ["from": from, "to": to] }
        return rep
    }
}
