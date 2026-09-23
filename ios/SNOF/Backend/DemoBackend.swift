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
 *   -demo-viewer      viewer, not controller
 *   -demo-controloff  bridge publishes control: false
 *   -demo-reportsoff  bridge publishes irrigation.enabled: false
 *   -demo-stale       bridge heartbeat 400 s old
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

        var meta = tree["meta"] as? [String: Any] ?? [:]
        var bridge = meta["bridge"] as? [String: Any] ?? [:]
        bridge["lastSeen"] = now - (flag("stale") ? 400_000 : 5_000)
        bridge["control"] = !flag("controloff")
        var irr = bridge["irrigation"] as? [String: Any] ?? [:]
        irr["enabled"] = !flag("reportsoff")
        bridge["irrigation"] = irr
        meta["bridge"] = bridge
        tree["meta"] = meta
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
        handler(.admin(false))
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
        handler?(.entities(tree["entities"]))
        handler?(.irrigation(tree["irrigation"]))
        handler?(.reports(tree["irrigation_reports"]))
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
        let key = "demo_\(Int(Date().timeIntervalSince1970 * 1000))"
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard let self, !self.flag("reportsoff") else { return }
            var reports = self.tree["irrigation_reports"] as? [String: Any] ?? [:]
            reports[key] = Self.canned(type: type, from: from, to: to)
            self.tree["irrigation_reports"] = reports
            self.handler?(.reports(reports))
        }
        return key
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
