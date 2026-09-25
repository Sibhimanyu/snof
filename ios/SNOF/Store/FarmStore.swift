import Foundation
import Observation
import SNOFCore
import UIKit

enum Phase: Equatable {
    case boot
    case signedOut
    case denied(email: String?)
    case misconfigured(String)
    case app
}

enum AppTab: Hashable { case overview, irrigation, water, areas }
/// The Rooms tab shows rooms, or the same devices as one list.
enum RoomsMode: Hashable { case rooms, devices }

enum StatusFilter: String, CaseIterable, Identifiable {
    case all, active, offline
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All"
        case .active: return "Reporting"
        case .offline: return "Not reporting"
        }
    }
}

struct Toast: Identifiable, Equatable {
    enum Kind { case ok, err }
    let id = UUID()
    let kind: Kind
    let message: String
}

/* One source of truth for the whole app, fed by exactly one backend.
 * The same bookkeeping as app.js: optimistic controls with a 12 s deadline,
 * reconciled on agreement rather than on a transition, and gated on what the
 * bridge says it will actually act on. */
@MainActor
@Observable
final class FarmStore {

    let backend: FarmBackend

    private(set) var phase: Phase = .boot
    private(set) var user: AppUser?

    private(set) var meta = FarmMeta()
    /// meta has arrived at least once. Before that nothing is known, and
    /// "not reporting" would be a false alarm on every launch.
    private(set) var metaLoaded = false
    private(set) var areas: [String: Area] = [:]
    /// Device id -> name, for devices in a room.
    private(set) var deviceNames: [String: String] = [:]
    /// Home Assistant's own device names, before DeviceNames tidies them.
    private var rawDeviceNames: [String: String] = [:]
    /// Entities in a room — the only ones the app knows about. See `Sorting.inRooms`.
    private(set) var entities: [Entity] = []
    /// Everything the entities node carried, before the room filter.
    private var received: [Entity] = []
    private(set) var index: [String: Entity] = [:]
    private(set) var irrigation = IrrigationCache()
    private(set) var reports: [Report] = []
    private(set) var firstSnapshot = false

    private(set) var canControl = false
    private(set) var isAdmin = false
    private(set) var connected = true
    private var skewMs: Double = 0

    /// Re-evaluated every 5 s so "stale 40s" keeps counting without data.
    private(set) var now = Date()

    /// entity key -> the position it was asked to take.
    private(set) var pending: [String: String] = [:]
    private var pendingTasks: [String: Task<Void, Never>] = [:]

    /// irrigation_requests keys still waiting for a report.
    private(set) var waitingReports: Set<String> = []
    private var reportTasks: [String: Task<Void, Never>] = [:]

    var toast: Toast?
    var selectedTab: AppTab = .overview
    var roomsMode: RoomsMode = .rooms
    var deviceStatus: StatusFilter = .all
    var deviceDomain: String?

    private var clock: Task<Void, Never>?

    init(backend: FarmBackend) {
        self.backend = backend
    }

    /* ---- lifecycle ---- */

    func start() {
        if let problem = backend.configurationProblem {
            phase = .misconfigured(problem)
            return
        }
        backend.observeAuth { [weak self] user in
            guard let self else { return }
            if let user { self.enter(user) } else { self.leave() }
        }
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.now = Date()
            }
        }
    }

    /// The last sign-in failure, in full. Kept on the gate rather than in a
    /// 4-second toast: from a sideloaded build this text is the only way to
    /// learn why sign-in failed, and it has to survive a screenshot.
    private(set) var signInError: String?

    func signIn() async {
        signInError = nil
        do {
            try await backend.signIn()
        } catch BackendError.cancelled {
            // The user closed the sheet; nothing to say.
        } catch {
            signInError = Self.describe(error)
            NSLog("SNOF: sign-in failed: %@", signInError ?? "")
        }
    }

    /// Domain, code and the underlying cause, so a report pins it down.
    static func describe(_ error: Error) -> String {
        var lines: [String] = []
        var current: NSError? = error as NSError
        var depth = 0
        while let e = current, depth < 3 {
            lines.append("\(e.domain) \(e.code): \(e.localizedDescription)")
            if let name = e.userInfo["FIRAuthErrorUserInfoNameKey"] as? String { lines.append("  \(name)") }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        let bundle = Bundle.main.bundleIdentifier ?? "?"
        lines.append("app \(UpdateCheck.installedVersion) (\(UpdateCheck.installedBuild)) · \(bundle)")
        return lines.joined(separator: "\n")
    }

    func signOut() { backend.signOut() }

    private func enter(_ user: AppUser) {
        guard self.user?.uid != user.uid else { return }
        reset()
        self.user = user
        phase = .app
        backend.attach(user: user) { [weak self] event in self?.receive(event) }
    }

    private func leave() {
        backend.detach()
        reset()
        user = nil
        phase = .signedOut
    }

    private func reset() {
        pendingTasks.values.forEach { $0.cancel() }
        reportTasks.values.forEach { $0.cancel() }
        pendingTasks = [:]; reportTasks = [:]
        pending = [:]; waitingReports = []; refreshKeys = []
        irrigationTask?.cancel(); irrigationPending = nil
        motorTask?.cancel(); motorPending = nil; motorPendingKey = nil; motorConfirming = false
        meta = FarmMeta(); metaLoaded = false; mobitechStatus = nil; mobitechPendingToken = nil; areas = [:]; deviceNames = [:]; rawDeviceNames = [:]; entities = []; received = []; index = [:]
        irrigation = IrrigationCache(); reports = []
        water = WaterState(); rawWater = nil; rawMeta = nil; waterAsked = .distantPast
        systems = [:]; deviceSystems = [:]
        firstSnapshot = false; canControl = false; isAdmin = false
        deviceStatus = .all; deviceDomain = nil
    }

    private func receive(_ event: FarmEvent) {
        switch event {
        case .meta(let v):
            meta = Parse.meta(v)
            metaLoaded = true
            rawMeta = v
            water = Parse.water(rawWater, meta: rawMeta)
        case .water(let v):
            rawWater = v
            water = Parse.water(rawWater, meta: rawMeta)
        case .areas(let v):
            areas = Parse.areas(v)
            applyRooms()
        case .devices(let v):
            rawDeviceNames = Parse.devices(v)
            applyRooms()
        case .entities(let v):
            received = Parse.entities(v).sorted(by: Sorting.byName)
            applyRooms()
            firstSnapshot = true
            reconcilePending()
        case .irrigation(let v): irrigation = Parse.irrigation(v)
        case .reports(let v):
            reports = Parse.reports(v)
            settleReports()
        case .irrigationResults(let v): settleIrrigation(v)
        case .mobitechStatus(let v):
            let d = v as? [String: Any]
            mobitechStatus = d.flatMap { d in Parse.double(d["at"]).map {
                MobitechStatus(at: $0, name: Parse.string(d["name"]) ?? "", user: Parse.string(d["user"]) ?? "",
                               mobileLast4: Parse.string(d["mobileLast4"]) ?? "",
                               lastOk: Parse.double(d["lastOk"]), lastRejected: Parse.double(d["lastRejected"])) } }
        case .irrigationLock(let v):
            irrigationLockUntil = Parse.double((v as? [String: Any])?["until"])
        case .motorResults(let v): settleMotor(v)
        case .controller(let b): canControl = b
        case .admin(let b): isAdmin = b
        case .serverTimeOffset(let s): skewMs = s
        case .connected(let c): connected = c
        case .denied:
            backend.detach()
            phase = .denied(email: user?.email)
        }
    }

    /* ---- derived ---- */

    var farmName: String { meta.name ?? "SNOF" }

    var role: Role { isAdmin ? .admin : canControl ? .controller : .viewer }

    private var nowMs: Double { now.timeIntervalSince1970 * 1000 }

    var bridgeStatus: BridgeStatus { BridgeStatus(meta.bridge, nowMs: nowMs, skewMs: skewMs) }

    /// "Live · 5s ago", as the web dashboard's pill says it. `long` adds
    /// "Bridge" for places with room for it.
    func bridgeText(long: Bool = false) -> String {
        let prefix = long ? "Bridge " : ""
        switch bridgeStatus {
        case .unknown: return long ? "No bridge data yet" : "Connecting"
        case .offline: return long ? "Bridge offline" : "Offline"
        case .stale(let age): return "\(long ? "Bridge stale" : "Stale") · \(Format.age(age)) ago"
        case .live:
            guard let seen = meta.bridge?.lastSeen else { return prefix + "live" }
            let age = max(0, (nowMs + skewMs - seen) / 1000)
            return "\(long ? "Bridge live" : "Live") · \(Format.age(age)) ago"
        }
    }

    func gate(_ c: Capability) -> Gate {
        // Evaluated against the real clock, not the 5 s tick, at press time.
        Gate.evaluate(c, bridge: meta.bridge, reportsEnabled: meta.reportsEnabled,
                      cloudIrrigationControl: meta.cloudIrrigationControl,
                      reportsTransport: meta.reportsTransport,
                      nowMs: Date().timeIntervalSince1970 * 1000, skewMs: skewMs)
    }

    /// Areas and entities arrive on separate listeners, so either can change
    /// which entities are in a real room.
    /// Device names are tidied here too (a printer called by its serial
    /// number reads "P1S printer"), so every screen gets the same names.
    private func applyRooms() {
        let tidy = DeviceNames.apply(Sorting.inRooms(received, areas: areas), names: rawDeviceNames)
        // Re-sorted: "T8400P… Motion detected" was placed under T, and now reads "Goats …".
        entities = tidy.names == rawDeviceNames ? tidy.entities : tidy.entities.sorted(by: Sorting.byName)
        deviceNames = tidy.names
        index = Dictionary(entities.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        rebuildSystems()
    }

    /// Devices whose being offline is a fault (not an appliance at rest).
    var faultyDevices: [DeviceGroup] {
        devices.filter { $0.isOffline && Systems.offlineIsFault($0, system: deviceSystems[$0.id]) }
    }

    /// Systems are rebuilt when entities or device names change, not on every
    /// read: Home reads them from several cards on every clock tick.
    private func rebuildSystems() {
        systems = Systems.build(entities, names: deviceNames, raw: rawDeviceNames)
        var out: [String: FarmSystemID] = [:]
        for (id, sys) in systems { for d in sys.devices { out[d.id] = id } }
        deviceSystems = out
    }

    func areaName(_ id: String) -> String {
        areas[id]?.name ?? id
    }

    /// What the farm counts: devices, not entities.
    var devices: [DeviceGroup] { Sorting.byDevice(entities, names: deviceNames) }

    var groupedAreas: [(id: String, entities: [Entity])] {
        Sorting.groupByArea(entities, name: areaName)
    }

    /// What a control should show: the pending request if any, else truth.
    func displayOn(_ e: Entity) -> Bool {
        if let want = pending[e.key] { return want == "on" }
        return e.isOn
    }

    func canOperate(_ e: Entity) -> Bool {
        canControl && e.isControllable && !e.isBad && gate(.control).ok
    }

    /* ---- commands ---- */

    func toggle(_ e: Entity) {
        // Checked before the optimistic flip, not after: a control that snaps
        // back twelve seconds later reads as a broken farm, not a switched-off
        // feature.
        if let why = refusal(for: e) { show(.err, why); return }
        let want = !e.isOn
        guard let cmd = Command.toggle(e, on: want) else { return }
        markPending(e.key, want ? "on" : "off")
        dispatch(cmd, key: e.key)
    }

    func setLevel(_ e: Entity, percent: Int) {
        if let why = refusal(for: e) { show(.err, why); return }
        guard let cmd = Command.level(e, percent: percent) else { return }
        // A level change on an off light or fan also turns it on.
        if percent > 0, !e.isOn { markPending(e.key, "on") }
        dispatch(cmd, key: e.key)
    }

    private func refusal(for e: Entity) -> String? {
        if !canControl { return "Your account can view, but not control." }
        let g = gate(.control)
        if !g.ok { return g.why }
        if !connected { return BackendError.notConnected.localizedDescription }
        if e.isBad { return "\(e.name) is not reporting, so nothing would answer." }
        return nil
    }

    private func dispatch(_ cmd: Command, key: String) {
        guard let uid = user?.uid else { return }
        Task {
            do {
                try await backend.send(cmd, uid: uid)
            } catch BackendError.cancelled {
                // Purged by the timeout below; it has already said so.
            } catch {
                clearPending(key)
                show(.err, (error as? BackendError) == .refused
                     ? "The database refused that command." : "Could not send: \(error.localizedDescription)")
            }
        }
    }

    private func markPending(_ key: String, _ want: String) {
        clearPending(key)
        pending[key] = want
        pendingTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: Farm.commandTimeout)
            guard let self, !Task.isCancelled, self.pending[key] != nil else { return }
            self.pending[key] = nil
            self.pendingTasks[key] = nil
            // If the write never reached the server (no signal), drop it now
            // rather than let it fire whenever the phone reconnects.
            self.backend.cancelUnsentWrites()
            self.show(.err, "No response from the farm — the control was reset.")
        }
    }

    private func clearPending(_ key: String) {
        pendingTasks[key]?.cancel()
        pendingTasks[key] = nil
        pending[key] = nil
    }

    /// Settle on agreement, checked on every update — not on a transition,
    /// which never arrives if the entity already reports what was asked.
    private func reconcilePending() {
        for (key, want) in pending {
            if let e = index[key], (want == "on") == e.isOn { clearPending(key) }
        }
    }

    /* ---- irrigation ---- */

    func requestReport(type: String, from: Date, to: Date) async {
        if !canControl { show(.err, "Your account can view, but not run reports."); return }
        let g = gate(.irrigation)
        if !g.ok { show(.err, g.why); return }
        if !connected { show(.err, BackendError.notConnected.localizedDescription); return }
        guard let t = IrrigationTypes.find(type), let uid = user?.uid else { return }
        let f = Format.dayString(from), e = Format.dayString(to)
        if let why = IrrigationTypes.validate(type: type, from: f, to: e) { show(.err, why); return }

        do {
            let key = try await backend.requestReport(type: type, from: t.needsRange ? f : nil,
                                                      to: t.needsRange ? e : nil, uid: uid)
            waitingReports.insert(key)
            reportTasks[key] = Task { [weak self] in
                try? await Task.sleep(for: Farm.reportTimeout)
                guard let self, !Task.isCancelled, self.waitingReports.remove(key) != nil else { return }
                self.reportTasks[key] = nil
                self.show(.err, "No answer yet — it will appear below when the controller responds.")
            }
            settleReports()
            if waitingReports.contains(key) {
                show(.ok, "Report requested — pulling it from the irrigation controller now.")
            }
        } catch {
            show(.err, (error as? BackendError) == .refused
                 ? "The database refused that request." : "Could not send: \(error.localizedDescription)")
        }
    }

    /// irrigation_requests keys sent by the Overview's Refresh; they settle
    /// quietly, with one toast for the lot.
    private var refreshKeys: Set<String> = []
    /// The refresh in flight was a background one: settle it without toasts.
    private var quietRefresh = false
    var refreshingIrrigation: Bool { !refreshKeys.isDisjoint(with: waitingReports) }

    /// Overview → Refresh: what the controller is doing now, power and
    /// pressure now, and yesterday-and-today's runs. Three ordinary report
    /// requests — each a press, never a poll — so the rules, the kill switch
    /// and the function's own checks all apply unchanged.
    func refreshIrrigation(quiet: Bool = false) async {
        if !canControl { if !quiet { show(.err, "Your account can view, but not run reports.") }; return }
        let g = gate(.irrigation)
        if !g.ok { if !quiet { show(.err, g.why) }; return }
        if !connected { if !quiet { show(.err, BackendError.notConnected.localizedDescription) }; return }
        guard let uid = user?.uid, !refreshingIrrigation else { return }
        quietRefresh = quiet
        // Three reads through the farm box per press: a second press within
        // 45 s of the last read adds load and nothing new (27 presses were
        // seen in one evening, 2026-09-24).
        if let last = irrigation.program?.at ?? irrigation.lastUpdated, nowMs + skewMs - last < 45_000 {
            if !quiet { show(.ok, "Just checked.") }
            return
        }
        let zone = FarmTime.zone(irrigation.timeZone)
        let today = FarmTime.today(Date(), zone: zone), yesterday = FarmTime.yesterday(Date(), zone: zone)
        var sent = 0
        for (type, from, to) in [("controller", nil, nil), ("live_readings", nil, nil),
                                 ("session_log", yesterday, today)] as [(String, String?, String?)] {
            do {
                let key = try await backend.requestReport(type: type, from: from, to: to, uid: uid)
                refreshKeys.insert(key)
                waitingReports.insert(key)
                sent += 1
                reportTasks[key] = Task { [weak self] in
                    try? await Task.sleep(for: Farm.reportTimeout)
                    guard let self, !Task.isCancelled, self.waitingReports.remove(key) != nil else { return }
                    self.reportTasks[key] = nil
                    self.refreshKeys.remove(key)
                }
            } catch {
                show(.err, (error as? BackendError) == .refused
                     ? "The database refused that request." : "Could not send: \(error.localizedDescription)")
                break
            }
        }
        if sent > 0 { settleReports() }
    }

    /// Opening Home or Irrigation with controller data older than 15 minutes
    /// fetches it again, at most once every 10 minutes, so nobody has to press
    /// Refresh to trust what they see. Quiet unless it fails.
    private var autoRefreshedAt = Date.distantPast
    func autoRefreshIrrigationIfStale() async {
        guard canControl, connected, !refreshingIrrigation, gate(.irrigation).ok else { return }
        let last = irrigation.program?.at ?? irrigation.lastUpdated ?? 0
        guard nowMs + skewMs - last > 15 * 60_000, Date().timeIntervalSince(autoRefreshedAt) > 10 * 60 else { return }
        autoRefreshedAt = Date()
        await refreshIrrigation(quiet: true)
    }

    /// Swipe down on Overview or Irrigation: the same three requests as the
    /// Refresh button, but the spinner stays until the controller has
    /// answered (or 30 s pass — the "Irrigation updated." toast or the
    /// timeout says the rest), as a pull-to-refresh should.
    func pullToRefreshIrrigation() async {
        if !refreshingIrrigation { await refreshIrrigation() }
        let deadline = Date().addingTimeInterval(30)
        while refreshingIrrigation && Date() < deadline && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func settleReports() {
        for key in waitingReports where refreshKeys.contains(key) {
            guard let rep = reports.first(where: { $0.key == key }) else { continue }
            waitingReports.remove(key)
            reportTasks[key]?.cancel()
            reportTasks[key] = nil
            refreshKeys.remove(key)
            // A background refresh stays silent; a failure still shows up in
            // Needs a look ("Could not reach the controller").
            if quietRefresh { continue }
            if rep.status == "error" { show(.err, "\(rep.label) failed: \(rep.error.isEmpty ? "controller error" : rep.error)") }
            else if !refreshingIrrigation { show(.ok, "Irrigation updated.") }
        }
        for key in waitingReports where !refreshKeys.contains(key) {
            guard let rep = reports.first(where: { $0.key == key }) else { continue }
            waitingReports.remove(key)
            reportTasks[key]?.cancel()
            reportTasks[key] = nil
            switch rep.status {
            case "ok": show(.ok, "Report ready.")
            case "partial": show(.err, "Report partly ready — one part did not come back.")
            default: show(.err, "Report failed: \(rep.error.isEmpty ? "controller error" : rep.error)")
            }
        }
    }

    /* ---- irrigation control ---- */

    /* ---- the farm, by system (SNOFCore Systems.swift) ---- */

    /// Devices sorted into what they are; appliances off at the wall are not faults.
    private(set) var systems: [FarmSystemID: FarmSystem] = [:]

    /// Device id -> its system, so any screen can tell a fault from an
    /// appliance switched off at the wall.
    private(set) var deviceSystems: [String: FarmSystemID] = [:]

    /// Everything that deserves a look, worst first (Home's first card).
    var attention: [AttentionItem] {
        var i = Attention.Input()
        switch bridgeStatus {
        case .offline: i.bridgeDown = true
        case .stale(let age): i.bridgeDown = true; i.bridgeQuietFor = Format.age(age)
        default: break
        }
        i.irrigation = irrigation
        i.programRunning = WaterNow.say(cache: irrigation, zone: FarmTime.zone(irrigation.timeZone), now: now).running
        i.now = now
        i.mobitechSignInNeeded = isAdmin && mobitechProblem != nil
        i.liveskySignInNeeded = isAdmin && water.enabled && [.none, .expired].contains(liveskyKind)
        i.water = water
        i.systems = systems
        i.areaName = areas.mapValues(\.name)
        return Attention.items(i)
    }

    /// The newest report of each kind and range: every Refresh writes three
    /// reports, and dozens of identical cards buried the one asked for.
    var latestReports: [Report] {
        var seen = Set<String>()
        return reports.filter { seen.insert("\($0.type)|\($0.from ?? "")|\($0.to ?? "")").inserted }.prefix(12).map { $0 }
    }

    /* ---- water chain (read-only) ---- */

    /// The river motor and the other farm's two motors, as the water
    /// functions last read them (docs/water.md). Parsed from farms/<farm>/water
    /// and meta/water together, so the gate and the session travel with it.
    private(set) var water = WaterState()
    private var rawWater: Any?
    private var rawMeta: Any?
    private var waterAsked = Date.distantPast

    var waterGateWhy: String? { water.enabled ? nil : "Water readings are switched off for now." }

    /// Ask the functions for a fresh read. Called when the Water tab opens and
    /// every 30 s while it stays open; `force` (pull to refresh) may ask again
    /// after 5 s. The function spaces pulls 15 s apart whoever asks.
    func refreshWater(force: Bool = false) async {
        guard let uid = user?.uid, water.enabled else { return }
        let since = Date().timeIntervalSince(waterAsked)
        guard since > (force ? 5 : 28) else { return }
        waterAsked = Date()
        try? await backend.requestWaterRefresh(uid: uid)
    }

    var liveskyKind: LiveskySession.Kind { water.livesky.kind(nowMs: nowMs + skewMs) }

    /// One line for any screen, or nil when the session is fine.
    var liveskyProblem: String? {
        switch liveskyKind {
        case .ok: return nil
        case .none: return "SNOF is not signed in to Livesky, so the river motor cannot be read."
        case .expired:
            let when = water.livesky.expires.map { Date(timeIntervalSince1970: $0 / 1000).formatted(date: .abbreviated, time: .shortened) } ?? ""
            return "The Livesky session ended \(when). Sign in again to read the river motor."
        case .error: return water.livesky.status.error
        }
    }

    /// Ask Livesky to text a code. True when it did.
    func liveskySendCode(_ raw: String) async -> Bool {
        guard isAdmin else { show(.err, "Only farm admins can sign in to Livesky."); return false }
        guard let mobile = Mobitech.mobile(raw) else { show(.err, "Enter the 10-digit mobile number on the Livesky account."); return false }
        do {
            _ = try await backend.waterSession(["action": "send_code", "mobile": mobile])
            return true
        } catch {
            show(.err, "No code sent: \(error.localizedDescription)"); return false
        }
    }

    /// Sign in with the code. The function keeps the token; the app never sees it.
    func liveskySignIn(_ raw: String, code: String) async -> Bool {
        guard isAdmin, let mobile = Mobitech.mobile(raw) else { return false }
        let otp = code.filter(\.isNumber)
        guard (4...8).contains(otp.count) else { show(.err, "Enter the code from the SMS."); return false }
        do {
            let j = try await backend.waterSession(["action": "verify", "mobile": mobile, "code": otp])
            let until = Parse.double(j["expires"]).map { Date(timeIntervalSince1970: $0 / 1000).formatted(date: .abbreviated, time: .shortened) } ?? ""
            show(.ok, "Signed in to Livesky\(until.isEmpty ? "" : " until \(until)"). The river motor is read with this session.")
            return true
        } catch {
            show(.err, "Not signed in: \(error.localizedDescription)"); return false
        }
    }

    func liveskySignOut() async {
        do {
            _ = try await backend.waterSession(["action": "sign_out"])
            show(.ok, "Signed SNOF out of Livesky. The river motor will not be read until someone signs in again.")
        } catch {
            show(.err, "Could not sign out: \(error.localizedDescription)")
        }
    }

    /* ---- Mobitech sign-in (admins) ---- */

    struct MobitechStatus: Equatable {
        let at: Double; let name: String; let user: String; let mobileLast4: String
        /// Written by whatever sends the commands: Mobitech accepted / rejected SNOF's session.
        let lastOk: Double?; let lastRejected: Double?
        /// Rejected more recently than it was signed in or last accepted.
        var rejected: Bool { (lastRejected ?? 0) > max(at, lastOk ?? 0) }
    }

    /// One line for any screen, or nil when SNOF's session is fine.
    var mobitechProblem: String? {
        guard let st = mobitechStatus else { return "SNOF is not signed in to Mobitech. Sign in so valve commands keep working." }
        guard st.rejected, let when = st.lastRejected else { return nil }
        return "Mobitech rejected SNOF's session at \(Date(timeIntervalSince1970: when / 1000).formatted(date: .abbreviated, time: .shortened)). Sign in again to send valve commands."
    }
    private(set) var mobitechStatus: MobitechStatus?
    /// The device token for the login in progress: made when the code is
    /// requested, sent with the code. Never stored.
    private var mobitechPendingToken: String?

    /// Ask Mobitech to text a code. True when it did.
    func mobitechSendCode(_ raw: String) async -> Bool {
        guard isAdmin else { show(.err, "Only farm admins can sign in to Mobitech."); return false }
        guard let mobile = Mobitech.mobile(raw) else { show(.err, "Enter the 10-digit mobile number on the Mobitech account."); return false }
        do {
            let (data, resp) = try await URLSession.shared.data(for: Mobitech.codeRequest(mobile: mobile))
            if let why = Mobitech.codeRefusal(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, data: data) {
                show(.err, "No code sent: \(why)"); return false
            }
            mobitechPendingToken = Mobitech.deviceToken()
            return true
        } catch {
            show(.err, "Could not reach Mobitech: \(error.localizedDescription)"); return false
        }
    }

    /// Log in with the code and store the session. True when signed in.
    func mobitechSignIn(_ raw: String, code: String) async -> Bool {
        guard let uid = user?.uid, isAdmin, let mobile = Mobitech.mobile(raw) else { return false }
        let otp = code.filter(\.isNumber)
        guard (4...8).contains(otp.count) else { show(.err, "Enter the code from the SMS."); return false }
        let token = mobitechPendingToken ?? Mobitech.deviceToken()
        do {
            let (data, _) = try await URLSession.shared.data(for: Mobitech.loginRequest(mobile: mobile, code: otp, token: token))
            switch Mobitech.session(from: data, sent: token) {
            case .failure(.refused(let why)):
                show(.err, "Not signed in: \(why)"); return false
            case .success(let session):
                // Prove it before storing: a dashboard read (read-only) is one
                // of the two calls that check the token.
                let (dash, _) = try await URLSession.shared.data(for: Mobitech.dashboardRequest(token: session.token))
                guard Mobitech.servesController(dash) else {
                    show(.err, "Not signed in: Mobitech took the code but will not serve the controller to this session.")
                    return false
                }
                try await backend.saveMobitechSession(session, mobileLast4: String(mobile.suffix(4)), uid: uid)
                mobitechPendingToken = nil
                show(.ok, "Signed in to Mobitech as \(session.name.isEmpty ? session.user : session.name). Valve commands use this session.")
                return true
            }
        } catch {
            show(.err, "Not signed in: \(error.localizedDescription)"); return false
        }
    }

    /// Stop SNOF using its Mobitech session.
    func mobitechSignOut() async {
        do {
            try await backend.clearMobitechSession()
            show(.ok, "Signed SNOF out of Mobitech. Valve commands are off until someone signs in again.")
        } catch {
            show(.err, "Could not sign out: \(error.localizedDescription)")
        }
    }

    /* ---- motor control (docs/motor-control.md) ----
     * One press, one command; the motor_command function checks, sends once
     * and reads the motor until it confirms. Here: say why a switch is closed
     * (MotorControl.refusal), and stay closed until the result lands. */

    private(set) var motorPending: String?
    private(set) var motorPendingKey: String?
    private(set) var motorConfirming = false
    private var motorTask: Task<Void, Never>?

    func motorRefusal(_ key: String, motor: WaterMotor?) -> String? {
        let nowMs = Date().timeIntervalSince1970 * 1000 + skewMs
        return meta.motorControl.refusal(key, motor: motor, current: water.isCurrent(motor, now: Date()),
                                         isAdmin: isAdmin, pending: motorPending != nil, confirming: motorConfirming,
                                         online: connected, nowMs: nowMs, action: motor?.running == true ? "off" : "on")
    }

    func zoneRefusal(_ key: String, motor: WaterMotor?, zone: Int) -> String? {
        let nowMs = Date().timeIntervalSince1970 * 1000 + skewMs
        return meta.motorControl.zoneRefusal(key, motor: motor, zone: zone, current: water.isCurrent(motor, now: Date()),
                                             isAdmin: isAdmin, pending: motorPending != nil, confirming: motorConfirming,
                                             online: connected, nowMs: nowMs)
    }

    /// Continue the running program from another zone (zoned Niagara only).
    func changeZone(_ key: String, to zone: Int) async {
        let m = water.motors.first { $0.id == key }
        if let why = zoneRefusal(key, motor: m, zone: zone) { show(.err, why); return }
        await sendMotorCommand(key, action: "zone", zone: zone)
    }

    func switchMotor(_ key: String, action: String) async {
        let m = key == "river" ? water.river : water.motors.first { $0.id == key }
        if let why = motorRefusal(key, motor: m) { show(.err, why); return }
        guard action == "on" ? m?.running == false : m?.running == true else {
            show(.err, "The motor is not in the state that button was for."); return
        }
        await sendMotorCommand(key, action: action, zone: nil)
    }

    private func sendMotorCommand(_ key: String, action: String, zone: Int?) async {
        guard let uid = user?.uid else { return }
        // Closed before the send, so a second tap cannot queue a second write.
        motorPending = "sending"
        motorPendingKey = key
        motorConfirming = false
        do {
            let pushed = try await backend.sendMotor(motor: key, action: action, zone: zone, uid: uid,
                                                     clientAt: Date().timeIntervalSince1970 * 1000 + skewMs)
            motorPending = pushed
            // Sending plus the function's 150 s of confirmation reads.
            motorTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(240))
                guard let self, !Task.isCancelled, self.motorPending == pushed else { return }
                self.motorPending = nil
                self.motorConfirming = false
                self.show(.err, "No answer about the motor. Check it before trying again.")
            }
        } catch {
            motorPending = nil
            motorPendingKey = nil
            show(.err, (error as? BackendError) == .refused
                 ? "The database refused that (switched off, or a change is in flight)."
                 : "Could not send: \(error.localizedDescription)")
        }
    }

    private func settleMotor(_ v: Any?) {
        guard let key = motorPending, let node = (v as? [String: Any])?[key] as? [String: Any] else { return }
        let ok = Parse.bool(node["ok"]) ?? false
        if ok, Parse.bool(node["confirming"]) == true { motorConfirming = true; return }
        motorPending = nil
        motorConfirming = false
        motorTask?.cancel()
        let motorKey = Parse.string(node["motor"]) ?? ""
        let name = (motorKey == "river" ? water.river : water.motors.first { $0.id == motorKey })?.name ?? "The motor"
        let on = Parse.string(node["action"]) == "on"
        let isZone = Parse.string(node["action"]) == "zone"
        if ok, Parse.bool(node["verified"]) == true {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            show(.ok, isZone ? "Confirmed: \(name) is on zone \(Parse.string(node["zone"]) ?? "?")."
                 : "Confirmed: \(name) is \(on ? "running" : "off").")
        } else if ok, isZone {
            show(.err, "Sent once. " + (Parse.string(node["message"]).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "The controller has not confirmed it."))
        } else if ok {
            show(.err, "Sent once, but the motor has not confirmed it. Check it before trying again.")
        } else {
            let message = Parse.string(node["message"]) ?? ""
            show(.err, message.isEmpty ? "The farm refused that." : "Not sent: \(message)")
        }
        Task { [weak self] in await self?.refreshWater(force: true) }
    }

    private(set) var irrigationPending: String?
    private var irrigationTask: Task<Void, Never>?
    /// The farm's lock: until when no valve change may be made (server ms).
    private(set) var irrigationLockUntil: Double?
    /// Our own command was sent and the controller is being re-read.
    private(set) var irrigationConfirming = false

    /// No second change until the first is confirmed (owner, 2026-09-24):
    /// Mobitech accepts anything and cannot handle conflicts. The RTDB rules
    /// and the consumer enforce this too; this only says so before a press.
    var irrigationLocked: Bool {
        guard let until = irrigationLockUntil else { return false }
        return until > Date().timeIntervalSince1970 * 1000 + skewMs
    }

    var canRunIrrigation: Bool { isAdmin }

    /// Why Run/Stop cannot be pressed right now, or nil.
    func irrigationRefusal() -> String? {
        if !isAdmin { return "Only farm admins can open or close valves." }
        // Still loading: the buttons wait, but nothing is blamed.
        if !metaLoaded { return "" }
        let g = gate(.irrigationControl)
        if !g.ok { return g.why }
        if !connected { return BackendError.notConnected.localizedDescription }
        if irrigationPending != nil {
            return irrigationConfirming ? "Confirming the last change with the controller — controls unlock when it answers."
                : "Waiting for the farm to answer the last command."
        }
        if irrigationLocked { return "The last valve change is still being confirmed by the controller." }
        return nil
    }

    var irrigationMaxMinutes: Int {
        let cap = meta.cloudIrrigationControl == true ? meta.cloudIrrigationMaxMinutes : meta.bridge?.irrigationMaxMinutes
        return min(IrrigationCommand.maxMinutes, cap ?? IrrigationCommand.maxMinutes)
    }

    func runValves(_ valves: [Int], minutes: Int) async {
        guard let cmd = IrrigationCommand.run(valves: valves, minutes: minutes, cap: irrigationMaxMinutes) else {
            show(.err, "Pick one to five valves and up to \(irrigationMaxMinutes) minutes."); return
        }
        await sendIrrigation(cmd)
    }

    func stopIrrigation() async { await sendIrrigation(.stop) }

    private func sendIrrigation(_ cmd: IrrigationCommand) async {
        if let why = irrigationRefusal() {
            show(.err, why.isEmpty ? "Still loading the farm — try again in a moment." : why); return
        }
        guard let uid = user?.uid else { return }
        do {
            let key = try await backend.sendIrrigation(cmd, uid: uid)
            irrigationPending = key
            irrigationConfirming = false
            // Long enough to cover sending plus the farm's 2-minute
            // confirmation window; the lock itself expires at 3 minutes.
            irrigationTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(200))
                guard let self, !Task.isCancelled, self.irrigationPending == key else { return }
                self.irrigationPending = nil
                self.irrigationConfirming = false
                self.show(.err, "No answer from the farm. Nothing was confirmed — check the controller before trying again.")
            }
        } catch {
            show(.err, (error as? BackendError) == .refused
                 ? "The database refused that — irrigation control is for farm admins."
                 : "Could not send: \(error.localizedDescription)")
        }
    }

    private func settleIrrigation(_ v: Any?) {
        guard let key = irrigationPending, let node = (v as? [String: Any])?[key] as? [String: Any] else { return }
        let ok = Parse.bool(node["ok"]) ?? false
        let message = Parse.string(node["message"]) ?? ""
        let action = Parse.string(node["action"]) ?? ""
        // Sent is not done: while the farm re-reads the controller, stay locked.
        if ok, Parse.bool(node["confirming"]) == true {
            irrigationConfirming = true
            return
        }
        irrigationPending = nil
        irrigationConfirming = false
        irrigationTask?.cancel()
        if ok {
            let verified = Parse.bool(node["verified"])
            let what = action == "stop" ? "Stopped"
                : "\(Parse.string(node["valves"]) ?? "Valves") running for \(Parse.string(node["minutes"]) ?? "?") min"
            if verified == false {
                show(.err, "Sent, but the controller has not confirmed it after 2 minutes. Check it before trying again.")
            } else {
                // A result from an older farm build carries no `verified`: it
                // was sent, not confirmed, so do not claim more than that.
                show(.ok, verified == true ? "Confirmed: \(what)." : (action == "stop" ? "Stop sent to the controller." : "Sent: \(what)."))
            }
            // Let the controller act, then ask it what it is doing.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                await self?.refreshIrrigation()
            }
        } else {
            show(.err, message.isEmpty ? "The farm refused that." : "Not sent: \(message)")
        }
    }

    /* ---- navigation from overview ---- */

    func showDevices(status: StatusFilter, domain: String? = nil) {
        deviceStatus = status == .active ? .all : status
        deviceDomain = domain
        roomsMode = .devices
        selectedTab = .areas
    }

    /* ---- toasts ---- */

    func show(_ kind: Toast.Kind, _ message: String) {
        let t = Toast(kind: kind, message: message)
        toast = t
        UINotificationFeedbackGenerator().notificationOccurred(kind == .ok ? .success : .error)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4.2))
            if self?.toast == t { self?.toast = nil }
        }
    }
}

extension BackendError: Equatable {
    static func == (a: BackendError, b: BackendError) -> Bool {
        a.localizedDescription == b.localizedDescription
    }
}
