import SwiftUI
import SNOFCore

/* Water: every motor alike (owner, 2026-09-25: "a plain visual of all the
 * motors, and when we click a motor the controls and reports and related
 * data of that one motor shows up … don't be biased"). Four equal rows on
 * the water's path — the river motor (Livesky), the other farm's two motors
 * (Niagara) and the main farm's controller (Mobitech DCON) — each opening
 * its own page.
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
            WaterPath()
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

/// The water's path (owner, 2026-09-25: "a visual representation of the
/// water flow"; then "bad use of space and not clean"). One panel, one row per
/// motor on the pipe the water takes: River → River Motor → Thoppu →
/// Wellmotor75HP → Farm → SibhiSump, with the Well motor on a branch to
/// Thoppu's drip zones. Every motor row is the same and opens its own page; a
/// pipe segment is green only while the motor pushing water through it runs
/// on a current reading. Mirrors waterPath() in app.js.
struct WaterPath: View {
    @Environment(FarmStore.self) private var store
    /// Home: the same rows without the place names, inside its own card.
    var compact = false

    var body: some View {
        let w = store.water, now = store.now
        let river = w.river, supply = w.supply.first, drip = w.motors.first { $0.role == "drip" }
        let rest = w.motors.filter { $0.id != supply?.id && $0.id != drip?.id }
        let c = store.irrigation
        let say = WaterNow.say(cache: c, zone: FarmTime.zone(c.timeZone), now: now)
        let live = { (m: WaterMotor?) in m?.running == true && w.isCurrent(m, now: now) }
        let onRiver = live(river), onSupply = live(supply), onDrip = live(drip), onFarm = say.running
        let checked = (c.program?.at ?? c.lastUpdated).map { Water.ago(Date(timeIntervalSince1970: $0 / 1000), now: now) }
        let farmLine = onFarm
            ? [c.program?.valves.isEmpty == false ? c.program!.valves : say.title,
               say.leftMin.flatMap { $0 > 0 ? "\(Format.minutes($0)) left" : nil }].compactMap { $0 }.joined(separator: " · ")
            : "Valves closed"
        VStack(spacing: 0) {
            place("River", up: nil, down: onRiver)
            motorRow(river, fallback: "river", up: onRiver, down: onRiver)
            // Both Thoppu motors draw from the pipe between Thoppu and the branch.
            place("Thoppu", up: onRiver, down: onSupply || onDrip)
            motorRow(drip, fallback: "well-motor", up: onSupply || onDrip, down: onSupply, branch: onDrip)
            motorRow(supply, fallback: "wellmotor75hp", up: onSupply, down: onSupply)
            place("Farm", up: onSupply, down: onFarm)
            row(key: FarmStore.dconKey, name: store.dconName, line: farmLine, word: onFarm ? "Watering" : "Not watering",
                on: onFarm, age: checked, up: onFarm, down: nil)
            ForEach(rest) { m in motorRow(m, fallback: m.id, up: nil, down: nil) }
        }
        .padding(.vertical, compact ? 0 : 6)
        .modifier(PathCard(on: !compact))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Where the water goes")
    }

    private static let way = ["river": "River to Thoppu", "main-farm": "Thoppu to Farm", "drip": "Thoppu's drip zones"]

    /// What a motor row says under its name: what it is doing, else its job.
    private func line(_ m: WaterMotor, current: Bool) -> String {
        if current, m.vendor == "livesky" {
            if m.running == true, let r = m.runMinutes { return "For \(WaterFormat.minutes(r))" }
            if m.running == false, let r = m.stopMinutes { return "Off for \(WaterFormat.minutes(r))" }
        }
        if current, m.running == true, let p = m.program {
            return [p, m.zone.map { "zone \($0)" }, m.zoneLeft.map { "\(WaterFormat.hms($0)) left" }].compactMap { $0 }.joined(separator: " · ")
        }
        return Self.way[m.id == "river" ? "river" : m.role] ?? m.group
    }

    @ViewBuilder
    private func motorRow(_ m: WaterMotor?, fallback: String, up: Bool?, down: Bool?, branch: Bool? = nil) -> some View {
        if let m {
            let w = store.water
            let cur = w.isCurrent(m, now: store.now)
            let word = m.running == true ? (cur ? "Running" : "Was running") : m.running == false ? (cur ? "Off" : "Was off") : "Unknown"
            let age: String? = cur ? nil : (m.vendor == "livesky" && store.liveskyProblem != nil ? "not read"
                : w.readingDate(m).map { Water.ago($0, now: store.now) })
            row(key: m.id, name: m.name, line: line(m, current: cur), word: word, on: m.running == true && cur,
                age: age, up: up, down: down, branch: branch)
        } else {
            row(key: fallback, name: ["river": "River Motor", "well-motor": "Well motor", "wellmotor75hp": "Wellmotor75HP"][fallback] ?? "Motor", line: "No reading yet", word: "No reading",
                on: false, age: nil, up: up, down: down, branch: branch)
        }
    }

    private func row(key: String, name: String, line: String, word: String, on: Bool, age: String?,
                     up: Bool?, down: Bool?, branch: Bool? = nil) -> some View {
        NavigationLink(value: MotorRoute(key: key)) {
            HStack(spacing: 0) {
                if let branch {
                    Rail(up: up, down: down).frame(width: 56)
                    ZStack(alignment: .trailing) {
                        Rectangle().fill(branch ? Theme.brand : Theme.line2).frame(height: 4)
                            .padding(.leading, -28).padding(.trailing, 20)
                        Station(on: on)
                    }
                    .frame(width: 50)
                    .padding(.trailing, 10)
                } else {
                    ZStack { Rail(up: up, down: down); Station(on: on) }.frame(width: 56)
                        .padding(.trailing, 12)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(Theme.font(15, .bold, relativeTo: .headline)).foregroundStyle(Theme.text)
                    if !line.isEmpty { Text(line).font(Theme.font(12.5, .regular, relativeTo: .caption)).foregroundStyle(Theme.muted) }
                }
                .lineLimit(1)
                .padding(.vertical, 10)
                Spacer(minLength: 10)
                VStack(alignment: .trailing, spacing: 2) {
                    Tag(text: word, kind: on ? .on : .plain)
                    if let age { Text(age).font(Theme.font(11.5, .regular, relativeTo: .caption2)).foregroundStyle(Theme.faint) }
                }
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint)
                    .padding(.leading, 10)
            }
            .frame(minHeight: compact ? 58 : 68)
            .padding(.trailing, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(TileButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name): \(word)\(line.isEmpty ? "" : ", \(line)")\(age.map { ", \($0)" } ?? "")")
    }

    @ViewBuilder
    private func place(_ name: String, up: Bool?, down: Bool?) -> some View {
        if !compact { placeRow(name, up: up, down: down) }
    }

    private func placeRow(_ name: String, up: Bool?, down: Bool?) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Rail(up: up, down: down)
                Circle().fill(Theme.line2).frame(width: 10, height: 10)
            }
            .frame(width: 56)
            Text(name).font(Theme.font(11, .bold, relativeTo: .caption2)).tracking(0.9).textCase(.uppercase)
                .foregroundStyle(Theme.faint)
            Spacer()
        }
        .frame(height: 30)
        .accessibilityHidden(true)
    }
}

/// The Water tab's panel; on Home the card around it is Home's own.
private struct PathCard: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.modifier(Panel(padding: 0)) } else { content }
    }
}

/// The pipe through a row: the half above its centre and the half below,
/// each on (brand green), off (grey) or absent (nil).
private struct Rail: View {
    let up: Bool?
    let down: Bool?
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(up == true ? Theme.brand : Theme.line2).frame(width: 4).opacity(up == nil ? 0 : 1)
            Rectangle().fill(down == true ? Theme.brand : Theme.line2).frame(width: 4).opacity(down == nil ? 0 : 1)
        }
        .frame(maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}

/// A motor on the pipe: every one the same size.
private struct Station: View {
    let on: Bool
    var body: some View {
        Image(on ? "art-motor-on" : "art-motor-off").resizable().scaledToFit().frame(width: 26, height: 26)
            .frame(width: 40, height: 40)
            .background(Theme.panel2, in: Circle())
            .overlay(Circle().strokeBorder(on ? Theme.brand : Theme.line2, lineWidth: on ? 3 : 2))
            .background(Circle().fill(on ? Theme.brand.opacity(0.14) : .clear).padding(-4))
            .accessibilityHidden(true)
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
