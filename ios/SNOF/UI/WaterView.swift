import SwiftUI
import SNOFCore

/* Water: every motor alike (owner, 2026-09-25: "a plain visual of all the
 * motors, and when we click a motor the controls and reports and related
 * data of that one motor shows up … don't be biased"). Four equal tiles —
 * the river motor (Livesky), the other farm's two motors (Niagara) and the
 * main farm's controller (Mobitech DCON) — each opening its own page.
 * Mirrors waterView() / motorView() in app.js. */
struct MotorRoute: Hashable { let key: String }

extension FarmStore {
    /// The main farm's controller, as one of the motors.
    static let dconKey = "dcon"
    var waterMotorList: [WaterMotor] { [water.river].compactMap { $0 } + water.motors }
    var dconName: String { irrigation.device ?? "Mobitech DCON" }
}

struct WaterView: View {
    @Environment(FarmStore.self) private var store
    private var water: WaterState { store.water }

    var body: some View {
        Page(title: "Water", subtitle: water.pulledAt.map { "Read \(Water.ago(Date(timeIntervalSince1970: $0 / 1000), now: store.now))" } ?? "Not read yet",
             refresh: refresh) {
            if let why = store.waterGateWhy { Note(text: why, tone: .warn) }
            if store.isAdmin, let problem = store.liveskyProblem { Note(text: problem, tone: .warn) }
            if water.niagara.ok == false, !water.niagara.error.isEmpty {
                Note(text: "\(water.niagara.error) Showing the last readings.", tone: .warn)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                ForEach(store.waterMotorList) { m in
                    NavigationLink(value: MotorRoute(key: m.id)) { MotorTile(motor: m) }.buttonStyle(TileButtonStyle())
                }
                NavigationLink(value: MotorRoute(key: FarmStore.dconKey)) { DconTile() }.buttonStyle(TileButtonStyle())
            }
        }
        .navigationTitle("Water")
        // Ask now, and every 30 s while this tab is on screen.
        .task {
            while !Task.isCancelled {
                await store.refreshWater()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var refresh: (@MainActor () async -> Void)? {
        guard water.enabled else { return nil }
        let store = store
        return { await store.refreshWater(force: true) }
    }
}

/// One motor as a tile: picture, name, what it does, state, and age when
/// the reading is not current. All tiles alike.
private struct TileBody: View {
    let name: String
    let sub: String
    let word: String
    let on: Bool
    let age: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(on ? "art-motor-on" : "art-motor-off").resizable().scaledToFit().frame(width: 44, height: 44)
                .padding(.bottom, 6)
            Text(name).font(Theme.font(15.5, .bold, relativeTo: .headline)).foregroundStyle(Theme.text).lineLimit(2)
            Text(sub).font(Theme.meta).foregroundStyle(Theme.muted).lineLimit(2)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Tag(text: word, kind: on ? .on : .plain)
                if let age { Text(age).font(Theme.small).foregroundStyle(Theme.faint) }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .padding(16)
        .modifier(Panel(padding: 0))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct MotorTile: View {
    @Environment(FarmStore.self) private var store
    let motor: WaterMotor
    var body: some View {
        let w = store.water
        let current = w.isCurrent(motor, now: store.now)
        let on = motor.running == true && current
        let word = motor.running == true ? (current ? "Running" : "Was running") : motor.running == false ? (current ? "Off" : "Was off") : "Unknown"
        let age: String? = current ? nil : w.readingDate(motor).map { Water.ago($0, now: store.now) }
        TileBody(name: motor.name, sub: [motor.vendor == "livesky" ? "Livesky" : "Niagara", motor.roleText].filter { !$0.isEmpty }.joined(separator: " · "),
                 word: word, on: on, age: age)
    }
}

struct DconTile: View {
    @Environment(FarmStore.self) private var store
    var body: some View {
        let c = store.irrigation
        let say = WaterNow.say(cache: c, zone: FarmTime.zone(c.timeZone), now: store.now)
        let checked = (c.program?.at ?? c.lastUpdated).map { Water.ago(Date(timeIntervalSince1970: $0 / 1000), now: store.now) }
        TileBody(name: store.dconName, sub: "Mobitech · Farm valves", word: say.running ? "Watering" : "Not watering",
                 on: say.running, age: checked)
    }
}

/// One motor's own page: its controls, readings and reports.
struct MotorDetailView: View {
    @Environment(FarmStore.self) private var store
    let key: String
    @State private var account = false

    var body: some View {
        if key == FarmStore.dconKey {
            // The controller's page is the Irrigation view itself, named for it.
            IrrigationView(title: store.dconName, subtitle: "Mobitech · Farm valves")
                .toolbarTitleDisplayMode(.inline)
                .toolbar(removing: .title)
        } else if let m = store.waterMotorList.first(where: { $0.id == key }) {
            let w = store.water
            let river = key == "river"
            let noted = river && store.isAdmin && store.liveskyProblem != nil
            let vendorError: String? = river ? (!noted && w.livesky.status.ok == false ? w.livesky.status.error : nil)
                : (w.niagara.ok == false ? w.niagara.error : nil)
            Page(title: m.name, subtitle: [m.vendor == "livesky" ? "Livesky" : "Niagara", m.roleText].filter { !$0.isEmpty }.joined(separator: " · "),
                 refresh: { await store.refreshWater(force: true) }) {
                if noted, let problem = store.liveskyProblem { Note(text: problem, tone: .warn) }
                MotorCard(motor: m, now: store.now, vendorError: vendorError, current: w.isCurrent(m, now: store.now),
                          key: key, onPage: true)
                if river, store.isAdmin {
                    AccountRow(title: "Livesky account", problem: store.liveskyProblem) { account = true }.padding(.top, 10)
                }
            }
            .navigationTitle(m.name)
            .toolbarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .sheet(isPresented: $account) {
                NavigationStack {
                    Form { Section { LiveskySignIn() } }
                        .navigationTitle("Livesky account").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { account = false } } }
                }
                .environment(store)
            }
            .task {
                while !Task.isCancelled {
                    await store.refreshWater()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        } else {
            EmptyBlock(title: "No reading from this motor", message: "It appears after the next water pull.", symbol: "drop")
                .padding(16)
        }
    }
}

enum Water {
    /// "just now", "12m ago", "2h ago", "3d ago": the app's one age format,
    /// as agoText() in app.js. (Two formats once put "checked 2h ago" and
    /// "1 h ago" for the same pull on one screen.)
    static func ago(_ d: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(d))
        return s < 45 ? "just now" : "\(Format.age(s)) ago"
    }
}

/// On or off for an armed motor, confirmed by the motor itself
/// (docs/motor-control.md). Nothing shows for a motor that is not armed.
struct MotorSwitch: View {
    @Environment(FarmStore.self) private var store
    let key: String
    let motor: WaterMotor
    @State private var asking = false

    var body: some View {
        if store.isAdmin, store.meta.motorControl.armed(key) {
            let why = store.motorRefusal(key, motor: motor)
            let busy = store.motorPending != nil && store.motorPendingKey == key
            let action = motor.running == true ? "off" : "on"
            VStack(alignment: .leading, spacing: 8) {
                Button { asking = true } label: {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.small) }
                        Text(busy ? (store.motorConfirming ? "Confirming…" : "Sending…") : action == "on" ? "Turn on" : "Turn off")
                    }
                    .font(Theme.font(15, .semibold, relativeTo: .body))
                    .frame(maxWidth: .infinity, minHeight: Theme.hit)
                    .foregroundStyle(why != nil ? Theme.muted : action == "on" ? Color.white : Theme.bad)
                    .background(why != nil ? Theme.panel3 : action == "on" ? Theme.brand : Theme.bad.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous))
                }
                .buttonStyle(TileButtonStyle())
                .disabled(why != nil)
                if let why { Note(text: why, tone: busy ? .plain : .warn) }
                ZoneSwitch(key: key, motor: motor)
            }
            .confirmationDialog(MotorControl.question(motor, action: action), isPresented: $asking, titleVisibility: .visible) {
                Button(action == "on" ? "Turn on" : "Turn off", role: action == "off" ? .destructive : nil) {
                    Haptics.warn()
                    Task { await store.switchMotor(key, action: action) }
                }
            } message: {
                Text("SNOF sends it once and waits for the motor to confirm (up to 2½ minutes).")
            }
        }
    }
}

/// Continue the running program from another zone (the zoned Niagara
/// controller). Only while it runs a program; the current zone is marked.
struct ZoneSwitch: View {
    @Environment(FarmStore.self) private var store
    let key: String
    let motor: WaterMotor
    @State private var picked: Int?

    var body: some View {
        if store.meta.motorControl.zonesArmed(key), motor.running == true, let program = motor.program, let now = motor.zone {
            VStack(alignment: .leading, spacing: 6) {
                Text("Zone · \(program)").eyebrowStyle()
                HStack(spacing: 6) {
                    ForEach(1...8, id: \.self) { z in
                        let closed = z == now || store.zoneRefusal(key, motor: motor, zone: z) != nil
                        Button { picked = z } label: {
                            Text("\(z)").font(Theme.font(15, .bold, relativeTo: .body).monospacedDigit())
                                .frame(maxWidth: .infinity, minHeight: Theme.hit)
                                .foregroundStyle(z == now ? Color.white : closed ? Theme.muted : Theme.text)
                                .background(z == now ? Theme.brand : closed ? Theme.panel2 : Theme.panel,
                                            in: RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous)
                                    .strokeBorder(z == now ? Color.clear : Theme.line2, lineWidth: 1))
                        }
                        .buttonStyle(TileButtonStyle())
                        .disabled(closed)
                        .accessibilityLabel(z == now ? "Zone \(z), current" : "Move to zone \(z)")
                    }
                }
                if let why = store.zoneRefusal(key, motor: motor, zone: now % 8 + 1) { Note(text: why) }
            }
            .padding(.top, 4)
            .confirmationDialog("Move \(motor.name) from zone \(now) to zone \(picked ?? 0)?",
                                isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } }),
                                titleVisibility: .visible) {
                Button("Move to zone \(picked ?? 0)") {
                    let z = picked ?? 0
                    Haptics.warn()
                    Task { await store.changeZone(key, to: z) }
                }
            } message: {
                Text("The controller continues \(program) from there. SNOF sends it once and waits for the controller to confirm (up to 2½ minutes).")
            }
        }
    }
}

struct MotorCard: View {
    let motor: WaterMotor
    let now: Date
    var vendorError: String? = nil
    /// The reading says what the motor is doing now (WaterState.isCurrent);
    /// if not, its last state shows in grey, as on Home.
    var current = true
    /// The motor_command key ("river", or the Niagara slug): shows the switch
    /// when the motor is armed.
    var key: String? = nil
    /// On the motor's own page, whose title already names it.
    var onPage = false
    @State private var showDetails = false

    private static let headlineKeys: Set<String> = ["Running for", "Off for", "Program", "Zone time left"]
    private static let timed: Set<String> = ["Running for", "Off for", "Zone time left"]
    /// Timers are only true as of the controller's report: say when that was
    /// once it is more than 15 minutes old.
    private var headline: [(String, String)] {
        let stale = motor.lastReport.map { now.timeIntervalSince($0) > 15 * 60 } ?? false
        return facts.filter { Self.headlineKeys.contains($0.0) }.map { k, v in
            (k, stale && Self.timed.contains(k) ? "\(v) · as of \(Water.ago(motor.lastReport!, now: now))" : v)
        }
    }
    private var details: [(String, String)] { facts.filter { !Self.headlineKeys.contains($0.0) } }

    private func factGrid(_ items: [(String, String)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                  alignment: .leading, spacing: 12) {
            ForEach(items, id: \.0) { k, v in
                // "2 h 07 min · as of 1 h ago": the age on its own line.
                let parts = v.components(separatedBy: " · as of ")
                VStack(alignment: .leading, spacing: 3) {
                    Text(k).eyebrowStyle()
                    Text(parts[0]).font(Theme.font(14.5, .semibold, relativeTo: .subheadline).monospacedDigit())
                        .foregroundStyle(Theme.text)
                    if parts.count > 1 {
                        Text("as of \(parts[1])").font(Theme.font(12, .medium, relativeTo: .caption)).foregroundStyle(Theme.warn)
                    }
                }
            }
        }
    }

    var body: some View {
        let m = motor
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(m.running == true && current ? "art-motor-on" : "art-motor-off").resizable().scaledToFit()
                    .frame(width: 44, height: 44)
                    .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
                if !onPage {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.name).font(Theme.panelTitle).foregroundStyle(Theme.text)
                        Text([m.vendor == "livesky" ? "Livesky" : "Niagara", m.roleText].filter { !$0.isEmpty }
                            .joined(separator: " · "))
                            .font(Theme.meta).foregroundStyle(Theme.muted)
                    }
                }
                Spacer(minLength: 8)
                Tag(text: m.running == true ? (current ? "Running" : "Was running") : m.running == false ? (current ? "Off" : "Was off") : "Unknown",
                    kind: m.running == true && current ? .on : .plain)
            }
            if !headline.isEmpty { factGrid(headline) }
            if let p = m.pendingText { Note(text: p, tone: .warn) }
            if !m.trips.isEmpty { Note(text: "Tripped: \(m.trips.joined(separator: ", ")).", tone: .bad) }
            if let z = m.skippedZone { Note(text: "Zone \(z) was skipped: no valve feedback.", tone: .bad) }
            if let e = vendorError, !e.isEmpty { Note(text: "\(e) Showing the last reading.", tone: .warn) }
            if let key { MotorSwitch(key: key, motor: m) }
            Divider().overlay(Theme.line)
            DisclosureGroup(isExpanded: $showDetails) {
                factGrid(details).padding(.top, 8)
            } label: {
                // Says it opens something, and when the motor last spoke.
                Text("Details" + (m.lastReport.map { " · reported \(Water.ago($0, now: now))" } ?? ""))
                    .font(Theme.small).foregroundStyle(Theme.faint)
            }
            .tint(Theme.faint)
        }
        .panel(padding: 16)
        // A container, not one combined element: combined, VoiceOver could
        // not reach the Details disclosure inside it.
        .accessibilityElement(children: .contain)
    }

    private var facts: [(String, String)] {
        let m = motor
        var out: [(String, String)] = []
        if m.vendor == "livesky" {
            if m.running == true, let r = m.runMinutes { out.append(("Running for", WaterFormat.minutes(r))) }
            if m.running == false, let s = m.stopMinutes { out.append(("Off for", WaterFormat.minutes(s))) }
        }
        if let p = m.program {
            out.append(("Program", p + (m.zone.map { " · zone \($0)" } ?? "")))
            if let left = m.zoneLeft { out.append(("Zone time left", WaterFormat.hms(left))) }
        }
        if let v = WaterFormat.list(m.volts, "V") { out.append(("Voltage", v)) }
        if let a = WaterFormat.list(m.amps, "A"), m.running == true || m.amps.contains(where: { $0 > 0 }) {
            out.append(("Current", a))
        }
        if let p = m.pressureOut, m.running == true { out.append(("Outlet pressure", String(format: p == p.rounded() ? "%.0f" : "%.1f", p))) }
        out.append(("Power", m.power ? (m.supply.isEmpty ? "present" : m.supply.lowercased().replacingOccurrences(of: "phase", with: "phase present")) : "none reported"))
        if let a = m.autoStart { out.append(("Auto-start", a ? "on" : "off")) }
        if m.vendor == "livesky", m.connected == false { out.append(("Starter link", "not connected")) }
        return out
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// SNOF's Livesky session (the river motor): an SMS code through the
/// water_session function, which keeps the 24-hour token. Admins only.
struct LiveskySignIn: View {
    enum Step { case idle, mobile, code }
    @Environment(FarmStore.self) private var store
    @State private var step = Step.idle
    @State private var mobile = ""
    @State private var code = ""
    @State private var busy = false
    @State private var confirmSignOut = false

    var body: some View {
        let ls = store.water.livesky
        let signedIn = ls.signedInAt != nil || ls.expires != nil
        Text("The river motor is read with a Livesky session that lasts 24 hours. Signing SNOF in does not sign the phone out.")
            .font(Theme.meta).foregroundStyle(Theme.muted)
        if !ls.mobileLast4.isEmpty { LabeledContent("Number", value: "ending \(ls.mobileLast4)") }
        if let e = ls.expires {
            LabeledContent("Session ends", value: FarmTime.when(ms: e, now: store.now))
        }
        if let problem = store.liveskyProblem { Text(problem).foregroundStyle(Theme.warn) }

        switch step {
        case .idle:
            Button(signedIn ? "Sign in again" : "Sign in to Livesky") { step = .mobile }
            if signedIn {
                Button("Sign SNOF out", role: .destructive) { confirmSignOut = true }
                    .disabled(busy)
                    .confirmationDialog("Sign SNOF out of Livesky?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                        Button("Sign out", role: .destructive) {
                            busy = true
                            Task { await store.liveskySignOut(); busy = false }
                        }
                    } message: { Text("The river motor is not read until someone signs in again.") }
            }
        case .mobile:
            TextField("Livesky mobile number", text: $mobile)
                .keyboardType(.numberPad).textContentType(.telephoneNumber)
            Button(busy ? "Sending…" : "Send code") {
                busy = true
                Task { if await store.liveskySendCode(mobile) { step = .code }; busy = false }
            }
            .disabled(busy || Mobitech.mobile(mobile) == nil)
            Button("Cancel", role: .cancel) { step = .idle; mobile = "" }.disabled(busy)
        case .code:
            TextField("Code from the SMS", text: $code)
                .keyboardType(.numberPad).textContentType(.oneTimeCode)
            Button(busy ? "Signing in…" : "Sign in") {
                busy = true
                Task {
                    if await store.liveskySignIn(mobile, code: code) { step = .idle; code = ""; mobile = "" }
                    busy = false
                }
            }
            .disabled(busy || code.filter(\.isNumber).count < 4)
            Button("Use another number", role: .cancel) { step = .mobile; code = "" }.disabled(busy)
        }
    }
}
