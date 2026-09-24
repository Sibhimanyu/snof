import SwiftUI
import SNOFCore

/// What the owner opens the app to learn, in that order: is water going
/// out, what did the farm do today, is the power there, what is left on,
/// is anyone in the sheds, and what is broken. Every block is built from
/// data already mirrored — the irrigation cache the report function leaves
/// behind and the roomed entities — so opening the app costs nothing; the
/// one Refresh is three ordinary report requests.
struct OverviewView: View {
    @Environment(FarmStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Page(eyebrow: Self.today(), title: "Your farm, right now.") {
            if !store.firstSnapshot {
                LoadingBlock()
            } else if sizeClass == .regular {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 14) { IrrigationGlanceView(); SolarPanel() }
                    VStack(spacing: 14) { OnNowPanel(); SecurityPanel(); AttentionRow() }.frame(width: 360)
                }
            } else {
                IrrigationGlanceView()
                OnNowPanel()
                SolarPanel()
                SecurityPanel()
                AttentionRow()
            }
        }
        .navigationTitle("Overview")
    }

    /// "Thursday · 24 September".
    static func today() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEEE · d MMMM"
        return f.string(from: Date())
    }
}

struct AreaRoute: Hashable { let id: String }

/* ---- shared pieces ---- */

/// A panel with a title row: title, a quiet context line, and an optional
/// trailing control. The Overview's one panel shape.
private struct Block<Trailing: View, Content: View>: View {
    let title: String
    var context: String? = nil
    var divided = true
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.panelTitle).tracking(-0.4).foregroundStyle(Theme.text)
                    if let context, !context.isEmpty {
                        Text(context).font(Theme.meta).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .frame(minHeight: 56)
            .accessibilityElement(children: .contain)
            if divided { Rectangle().fill(Theme.line).frame(height: 1) }
            content
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}

extension Block where Trailing == EmptyView {
    init(title: String, context: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, context: context, trailing: { EmptyView() }, content: content)
    }
}

/// A number with its label under it, the Overview's unit of "how much".
private struct Figure: View {
    let value: String
    var unit: String? = nil
    let label: String
    var tone: Color = Theme.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(Theme.font(22, .bold, relativeTo: .title2).monospacedDigit())
                    .tracking(-0.9).foregroundStyle(tone)
                if let unit {
                    Text(unit).font(Theme.font(12, .semibold, relativeTo: .caption)).foregroundStyle(Theme.faint)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(height: 30, alignment: .bottomLeading)
            Text(label).font(Theme.font(10.5, .bold, relativeTo: .caption2)).tracking(1)
                .textCase(.uppercase).foregroundStyle(Theme.faint).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct Hairline: View {
    var inset: CGFloat = 0
    var body: some View { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, inset) }
}

/// "12h ago" for a server-millisecond stamp.
private func ago(_ ms: Double?, now: Date) -> String? {
    guard let ms, ms > 0 else { return nil }
    let s = now.timeIntervalSince1970 - ms / 1000
    return s < 60 ? "just now" : "\(Format.age(max(0, s))) ago"
}

/* ---- irrigation ---- */

struct IrrigationGlanceView: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        let c = store.irrigation
        let zone = FarmTime.zone(c.timeZone)
        let now = store.now
        let updated = ago(c.lastUpdated, now: now)
        Block(title: "Irrigation",
              context: [c.device, updated.map { "updated \($0)" }].compactMap { $0 }.joined(separator: " · ")) {
            if store.canControl { RefreshButton() }
        } content: {
            if c.isEmpty {
                EmptyBlock(title: "No irrigation data yet",
                           message: store.canControl ? "Press Refresh to pull the controller's state and today's runs."
                               : "Nothing has been pulled from the controller yet.",
                           symbol: "drop", framed: false)
            } else {
                WaterNow(cache: c, zone: zone, now: now)
                if let day = Irrigation.latestDay(c) {
                    Hairline()
                    DayFigures(day: day, zone: zone, now: now)
                }
                if Irrigation.supply(c) != nil || Irrigation.pressure(c) != nil {
                    Hairline()
                    SupplyRow(cache: c, zone: zone, now: now)
                }
                let runs = Array(Irrigation.runs(c).prefix(4))
                if !runs.isEmpty {
                    Hairline()
                    let first = runs[0].day
                    Text("Recent runs · " + FarmTime.dayLabel(first, now: now, zone: zone)).eyebrowStyle()
                        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 4)
                    ForEach(Array(runs.enumerated()), id: \.offset) { i, r in
                        if i > 0 { Hairline(inset: 18) }
                        RunRow(run: r, otherDay: r.day == first ? nil : FarmTime.dayLabel(r.day, now: now, zone: zone))
                    }
                }
            }
            if store.canControl, !store.gate(.irrigation).ok {
                Hairline()
                Note(text: store.gate(.irrigation).why, tone: .warn).padding(.horizontal, 18).padding(.vertical, 6)
            }
            Hairline()
            Button { store.selectedTab = .irrigation } label: {
                HStack {
                    Text("Reports and history")
                    Spacer()
                    Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold))
                }
                .font(Theme.font(13.5, .bold, relativeTo: .subheadline)).foregroundStyle(Theme.on)
                .padding(.horizontal, 18).frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct RefreshButton: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        let busy = store.refreshingIrrigation
        let ok = store.gate(.irrigation).ok && store.connected
        Button { Task { await store.refreshIrrigation() } } label: {
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.mini) }
                else { Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .bold)) }
                Text(busy ? "Checking…" : "Refresh")
            }
            .font(Theme.font(13, .bold, relativeTo: .caption))
            .foregroundStyle(Theme.on)
            .padding(.horizontal, 12).frame(minHeight: 32)
            .overlay(Capsule().strokeBorder(Theme.line2, lineWidth: 1))
            .frame(minHeight: Theme.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy || !ok)
        .opacity(ok ? 1 : 0.5)
        .accessibilityHint("Asks the controller what it is doing now, and for today's runs")
    }
}

/// Watering now, or what ran last — the one tinted surface in the app.
private struct WaterNow: View {
    let cache: IrrigationCache
    let zone: TimeZone
    let now: Date

    var body: some View {
        let s = state
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(s.running ? Theme.brand : Theme.faint.opacity(0.5)).frame(width: 8, height: 8)
                Text(s.running ? "Watering now" : "Not watering").eyebrowStyle()
                    .foregroundStyle(s.running ? Theme.on : Theme.faint)
                Spacer(minLength: 4)
                if let checked = s.checked {
                    Text(checked).font(Theme.font(12, .medium, relativeTo: .caption)).foregroundStyle(Theme.faint)
                }
            }
            Text(s.title).font(Theme.pulseTitle).tracking(-0.9).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            if !s.detail.isEmpty {
                Text(s.detail).font(Theme.font(14, .regular, relativeTo: .subheadline)).lineSpacing(2)
                    .foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if s.running, let faults = cache.program?.faults, !faults.isEmpty {
                ForEach(faults, id: \.self) { Tag(text: $0, kind: .bad) }
            }
            if let next = cache.program?.next {
                Rectangle().fill(Theme.tintLine).frame(height: 1).padding(.vertical, 2)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Next").eyebrowStyle()
                    Text([next.name, next.valves, next.plannedMin.map(Format.minutes)]
                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(Theme.font(14, .semibold, relativeTo: .subheadline)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tintPanel(padding: 16)
        .padding(12)
        .accessibilityElement(children: .combine)
    }

    private struct Say { var running: Bool; var title: String; var detail: String; var checked: String? }

    private var state: Say {
        // The controller's own answer, if a recent pull has one, counted
        // down from when it was asked. Past its end it is a last run.
        if let p = cache.program, p.running, !p.name.isEmpty {
            // The countdown is as of the controller's last report, not the pull.
            let asOf = FarmTime.date(p.lastSeen, zone: zone)?.timeIntervalSince1970 ?? p.at.map { $0 / 1000 }
            let elapsed = asOf.map { max(0, (now.timeIntervalSince1970 - $0) / 60) } ?? 0
            let left = p.remainingMin.map { $0 - Int(elapsed.rounded()) }
            let checked = ago(p.at, now: now).map { "checked \($0)" }
            if left.map({ $0 > 0 }) ?? (elapsed < 60) {
                var bits = [p.valves].filter { !$0.isEmpty }
                if let left, let planned = p.plannedMin { bits.append("about \(Format.minutes(left)) left of \(Format.minutes(planned))") }
                if let since = FarmTime.when(p.start, now: now, zone: zone) { bits.append("since \(since)") }
                return Say(running: true, title: p.name, detail: bits.joined(separator: " · "), checked: checked)
            }
        }
        if let last = Irrigation.runs(cache).first {
            var bits: [String] = []
            if let a = last.amount { bits.append(last.finished ? "\(a), finished" : "\(a), stopped early") }
            if !last.valves.isEmpty { bits.append(last.valves) }
            if let w = FarmTime.when(last.start, now: now, zone: zone) { bits.append("started \(w)") }
            return Say(running: false, title: "Last: \(last.name)", detail: bits.joined(separator: " · "),
                       checked: ago(cache.program?.at, now: now).map { "checked \($0)" })
        }
        if let p = cache.program, !p.name.isEmpty {
            return Say(running: false, title: "Last: \(p.name)", detail: p.valves,
                       checked: ago(p.at, now: now).map { "checked \($0)" })
        }
        return Say(running: false, title: "No runs logged yet", detail: "", checked: nil)
    }
}

/// The newest day the logs cover: runs, water, pump, energy.
private struct DayFigures: View {
    let day: Irrigation.Day
    let zone: TimeZone
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(FarmTime.dayLabel(day.day, now: now, zone: zone)).eyebrowStyle()
                Spacer()
                if day.stopped > 0 {
                    Tag(text: "\(day.stopped) stopped early", kind: .warn)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                Figure(value: "\(day.runs.count)", label: day.runs.count == 1 ? "Run" : "Runs")
                Figure(value: Format.minutes(day.waterMin), label: "Water")
                Figure(value: day.pump.map { Format.minutes($0.pumpMin) } ?? "—", label: "Pump")
                Figure(value: day.pump?.kwh.map { String(format: "%.1f", $0) } ?? "—", unit: day.pump?.kwh == nil ? nil : "kWh",
                       label: "Energy")
            }
            if let pump = day.pump, pump.supplyMin > 0 {
                Text("Power was on for \(Format.minutes(pump.supplyMin)); the pump used \(Int((Double(pump.pumpMin) / Double(pump.supplyMin) * 100).rounded()))% of it.")
                    .font(Theme.meta).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}

/// Three-phase supply and pressure, from the last live reading.
private struct SupplyRow: View {
    let cache: IrrigationCache
    let zone: TimeZone
    let now: Date

    var body: some View {
        let supply = Irrigation.supply(cache)
        let pressure = Irrigation.pressure(cache)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                if let supply, supply.hasVoltage {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(supply.phaseV.map { String(Int($0.rounded())) }.joined(separator: " · "))
                                .font(Theme.font(18, .bold, relativeTo: .title3).monospacedDigit()).tracking(-0.5)
                                .foregroundStyle(supply.missingPhase || !supply.powerOn ? Theme.bad : Theme.ink)
                            Text("V").font(Theme.font(12, .semibold, relativeTo: .caption)).foregroundStyle(Theme.faint)
                        }
                        Text("Supply" + (supply.at.map { " · \($0)" } ?? "")).font(Theme.font(10.5, .bold, relativeTo: .caption2))
                            .tracking(1).textCase(.uppercase).foregroundStyle(Theme.faint)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let pressure {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(pressure.value).font(Theme.font(18, .bold, relativeTo: .title3).monospacedDigit())
                            .tracking(-0.5).foregroundStyle(Theme.ink)
                        Text("Pressure" + (FarmTime.when(pressure.at, now: now, zone: zone).map { " · \($0)" } ?? ""))
                            .font(Theme.font(10.5, .bold, relativeTo: .caption2)).tracking(1).textCase(.uppercase)
                            .foregroundStyle(Theme.faint).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let supply {
                HStack(spacing: 14) {
                    if !supply.powerOn { Tag(text: "No power", kind: .bad) }
                    else if supply.missingPhase { Tag(text: "Phase missing — \(supply.livePhases) of 3 live", kind: .bad) }
                    else if let imb = supply.imbalancePct, imb >= Supply.imbalanceWarn {
                        Tag(text: "\(imb.formatted(.number.precision(.fractionLength(0...1))))% phase imbalance", kind: .warn)
                    }
                    else if supply.hasVoltage { Tag(text: "All three phases", kind: .on) }
                    if let drawing = supply.pumpDrawing {
                        Tag(text: drawing ? "Pump drawing current" : "Pump off", kind: drawing ? .on : .plain)
                    }
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
}

private struct RunRow: View {
    let run: ProgramRun
    /// Set when the run is on a different day from the header's.
    var otherDay: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(String(run.start.dropFirst(11).prefix(5)))
                if let otherDay { Text(otherDay).font(Theme.font(11, .medium, relativeTo: .caption2)) }
            }
            .font(Theme.font(12.5, .semibold, relativeTo: .caption).monospacedDigit())
            .foregroundStyle(Theme.faint).frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.name).font(Theme.font(14, .semibold, relativeTo: .subheadline)).foregroundStyle(Theme.text)
                    .lineLimit(1)
                if !run.valves.isEmpty {
                    Text(run.valves).font(Theme.meta).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let a = run.amount {
                Text(a).font(Theme.font(13, .bold, relativeTo: .footnote).monospacedDigit())
                    .foregroundStyle(run.finished ? Theme.ink : Theme.warn)
                    .lineLimit(1).fixedSize()
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/* ---- on now ---- */

/// What is switched on, with its switch. The question is "did someone leave
/// the shed lights on", not "show me a sample of every switch".
struct OnNowPanel: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        let on = OnNow.entities(store.entities, areaName: store.areaName)
        let operable = store.entities.filter { $0.isControllable && !$0.isBad }.count
        if operable > 0 || !on.isEmpty {
            Block(title: on.isEmpty ? "Everything is off" : "On right now",
                  context: on.isEmpty ? "\(operable) switches, lights and fans reporting"
                      : "\(on.count) of \(operable) switches, lights and fans",
                  divided: !on.isEmpty || (store.canControl && (!store.gate(.control).ok || !store.connected))) {
                LinkButton(label: "All", run: { store.showDevices(status: .active) })
            } content: {
                let gate = store.gate(.control)
                if store.canControl, !gate.ok || !store.connected {
                    ControlNote().padding(.horizontal, 18).padding(.vertical, 6)
                    if !on.isEmpty { Hairline() }
                }
                ForEach(Array(on.prefix(6).enumerated()), id: \.element.id) { i, e in
                    if i > 0 { Hairline() }
                    DeviceCard(entity: e)
                }
                if on.count > 6 {
                    Hairline()
                    Button { store.showDevices(status: .active) } label: {
                        HStack {
                            Text("\(on.count - 6) more on")
                            Spacer()
                            Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold))
                        }
                        .font(Theme.font(13.5, .bold, relativeTo: .subheadline)).foregroundStyle(Theme.on)
                        .padding(.horizontal, 18).frame(minHeight: 48).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/* ---- solar ---- */

struct SolarPanel: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        if let s = SolarGlance.find(store.entities) {
            NavigationLink(value: AreaRoute(id: s.area)) {
                Block(title: "Solar", context: store.areaName(s.area)) {
                    Image(systemName: "arrow.up.right").font(.system(size: 13)).foregroundStyle(Theme.muted)
                } content: {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 10) {
                            Figure(value: s.watts.map(kw) ?? "—", unit: s.watts == nil ? nil : "kW", label: "Now",
                                   tone: (s.watts ?? 0) > 0 ? Theme.on : Theme.ink)
                            Figure(value: value(s.today), unit: s.today?.isBad == false ? s.today?.attrs.unit : nil, label: "Today")
                            if let t = s.temperature {
                                Figure(value: value(t), unit: t.isBad ? nil : t.attrs.unit, label: "Inverter")
                            }
                        }
                        let foot = [s.total.flatMap { $0.isBad ? nil : "\(value($0)) \($0.attrs.unit ?? "") lifetime" },
                                    s.mode.flatMap { $0.isBad || ($0.state ?? "").isEmpty ? nil : "mode \($0.state!)" },
                                    Format.since(s.now?.lastChanged, now: store.now).map { "reading \($0) old" }]
                            .compactMap { $0 }
                        if !foot.isEmpty {
                            Text(foot.joined(separator: " · ")).font(Theme.meta).foregroundStyle(Theme.muted).lineLimit(2)
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 14)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func kw(_ w: Double) -> String { String(format: w >= 10_000 ? "%.0f" : "%.2f", w / 1000) }
    private func value(_ e: Entity?) -> String {
        guard let e, !e.isBad, let s = e.state, !s.isEmpty else { return "—" }
        if let d = Double(s), d >= 1000 { return d.formatted(.number.precision(.fractionLength(0))) }
        return s
    }
}

/* ---- security ---- */

struct SecurityPanel: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        if let g = SecurityGlance.find(store.entities) {
            let up = g.cameras.count - g.camerasDown
            Block(title: "Security",
                  context: g.cameras.isEmpty ? nil : "\(up) of \(g.cameras.count) cameras online") {
                EmptyView()
            } content: {
                ForEach(Array(g.alarms.enumerated()), id: \.element.id) { i, a in
                    if i > 0 { Hairline(inset: 18) }
                    line(symbol: a.state?.hasPrefix("armed") == true ? "lock.shield" : "shield",
                         title: a.name, value: SecurityGlance.alarmLabel(a.state),
                         kind: a.state == "triggered" ? .bad : a.state?.hasPrefix("armed") == true ? .on : .plain)
                }
                if !g.alarms.isEmpty && !g.sensors.isEmpty { Hairline(inset: 18) }
                let active = g.activeNow
                if !active.isEmpty {
                    ForEach(Array(active.prefix(3).enumerated()), id: \.element.id) { i, e in
                        if i > 0 { Hairline(inset: 18) }
                        line(symbol: "figure.walk", title: place(e), value: "\(SecurityGlance.sensorKind(e)) now", kind: .warn)
                    }
                } else if let last = g.latest {
                    line(symbol: "figure.walk", title: "Last activity · \(place(last))",
                         value: Format.since(last.lastChanged, now: store.now).map { "\($0) ago" } ?? "—", kind: .plain)
                }
                let down = g.cameras.filter(\.isBad)
                if !down.isEmpty {
                    Hairline(inset: 18)
                    line(symbol: "video.slash", title: down.map { place($0) }.joined(separator: ", "),
                         value: down.count == 1 ? "Camera offline" : "\(down.count) offline", kind: .bad)
                }
            }
        }
    }

    /// The camera's device name is the place ("Cow Shed"); fall back to the room.
    private func place(_ e: Entity) -> String {
        e.device.flatMap { store.deviceNames[$0] } ?? store.areaName(e.area)
    }

    private func line(symbol: String, title: String, value: String, kind: Tag.Kind) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Theme.muted).frame(width: 22)
            Text(title).font(Theme.font(14, .semibold, relativeTo: .subheadline)).foregroundStyle(Theme.text)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Tag(text: value, kind: kind, dot: kind != .plain)
        }
        .padding(.horizontal, 18).frame(minHeight: 48)
        .accessibilityElement(children: .combine)
    }
}

/* ---- attention ---- */

/// Broken things, as one line: they matter, but they are not news every time
/// the app opens.
struct AttentionRow: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        let dead = store.devices.filter(\.isOffline).sorted { Sorting.natural($0.name, $1.name) }
        Button { store.showDevices(status: .offline) } label: {
            HStack(spacing: 12) {
                Image(systemName: dead.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(dead.isEmpty ? Theme.on : Theme.bad).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(dead.isEmpty ? "Every device is reporting"
                         : "\(dead.count) \(dead.count == 1 ? "device" : "devices") not reporting")
                        .font(Theme.font(14.5, .bold, relativeTo: .subheadline)).foregroundStyle(Theme.text)
                    if !dead.isEmpty {
                        Text(Pulse.list(dead.map(\.name), max: 3)).font(Theme.meta).foregroundStyle(Theme.muted)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !dead.isEmpty {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(dead.isEmpty)
        .modifier(Panel(padding: 0))
    }
}

/* ---- areas (used by the Areas tab) ---- */

struct AreaCard: View {
    @Environment(FarmStore.self) private var store
    let name: String
    let entities: [Entity]

    var body: some View {
        // Devices, like the tiles: one switched-off printer is one offline.
        let devices = Sorting.byDevice(entities, names: store.deviceNames)
        let on = devices.filter(\.isActive).count
        let bad = devices.filter(\.isOffline).count
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text(name).font(Theme.font(15.5, .bold, relativeTo: .headline)).tracking(-0.4)
                    .foregroundStyle(Theme.text).lineLimit(2)
                Spacer(minLength: 6)
                Image(systemName: "arrow.up.right").font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.muted)
            }
            Text("\(devices.count) \(devices.count == 1 ? "device" : "devices")")
                .font(Theme.meta).foregroundStyle(Theme.muted).padding(.top, 2)
            Spacer(minLength: 18)
            // Own line, never hyphenated: on a narrow card the words would
            // otherwise wrap mid-word.
            HStack(spacing: 10) {
                if on > 0 { Text("\(on) active").foregroundStyle(Theme.on) }
                if bad > 0 { Text("\(bad) unavailable").foregroundStyle(Theme.bad) }
                else { Text("All reporting").foregroundStyle(Theme.on) }
            }
            .font(Theme.font(12, .bold, relativeTo: .caption)).lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct AdaptiveGrid<Content: View>: View {
    var min: CGFloat = 300
    @ViewBuilder let content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: min), spacing: 10, alignment: .top)],
                  alignment: .leading, spacing: 10) { content }
    }
}

struct LoadingBlock: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Connecting to the farm…").font(Theme.meta).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 80)
    }
}
