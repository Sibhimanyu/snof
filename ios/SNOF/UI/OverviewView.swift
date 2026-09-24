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

    /// Home (owner, 2026-09-25: "basic and simple to navigate"): one row per
    /// system, what is not reporting, and what is switched on. Each row opens
    /// the tab that has the rest.
    var body: some View {
        Page(title: "Home", refresh: homeRefresh) {
            if !store.firstSnapshot {
                LoadingBlock()
            } else {
                AttentionCard()
                FlowHero()
                if sizeClass == .regular {
                    HStack(alignment: .top, spacing: 14) { IrrigationRingCard(); SolarSystemCard(); SecurityCard() }
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    IrrigationRingCard()
                    HStack(alignment: .top, spacing: 12) { SolarSystemCard(); SecurityCard() }
                        .fixedSize(horizontal: false, vertical: true)
                }
                SwitchTiles()
                AroundTheFarm()
            }
        }
        .navigationTitle("Home")
        // Home is the first screen: keep the water picture current while it is
        // open (the function spaces pulls 15 s apart whoever asks).
        .task {
            while !Task.isCancelled {
                await store.refreshWater()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Swipe down: fresh water readings, and (controllers) the irrigation data.
    private var homeRefresh: @MainActor () async -> Void {
        let store = store
        return {
            await store.refreshWater(force: true)
            if store.canControl { await store.pullToRefreshIrrigation() }
        }
    }
}

/* ---- Home, drawn (2026-09-25: "so dull … I need more visuals") ----
 * Mirrors the web Home: the water chain as pipes that flow while their motor
 * runs, a ring for the irrigation run, solar, a donut of what reports, and
 * the switches as tiles. Green = on / flowing, brick = offline. */

/// A pipe between two stations; dashes move while water does.
private struct Pipe: View {
    let on: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            Path { p in p.move(to: CGPoint(x: 0, y: 3)); p.addLine(to: CGPoint(x: g.size.width, y: 3)) }
                .stroke(on ? Theme.brand : Theme.line2,
                        style: StrokeStyle(lineWidth: 6, lineCap: .round, dash: on ? [10, 8] : [], dashPhase: phase))
        }
        .frame(height: 6)
        .onAppear {
            guard on, !reduceMotion else { return }
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { phase = -18 }
        }
        .accessibilityHidden(true)
    }
}

private struct Station: View {
    let art: String
    let title: String
    let sub: String
    let on: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(art).resizable().scaledToFit().frame(width: 38, height: 38)
                .frame(width: 62, height: 62)
                .background(Theme.panel2, in: Circle())
                .overlay(Circle().strokeBorder(on ? Theme.brand : Theme.line, lineWidth: 2))
                .background(Circle().fill(on ? Theme.brand.opacity(0.22) : .clear).padding(-6))
            Text(title).font(Theme.font(13, .bold, relativeTo: .footnote)).foregroundStyle(Theme.text).padding(.top, 4)
            Text(sub).font(Theme.font(11.5, on ? .semibold : .regular, relativeTo: .caption))
                .foregroundStyle(on ? Theme.on : Theme.muted).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(width: 88)
        .accessibilityElement(children: .combine)
    }
}

struct FlowHero: View {
    @Environment(FarmStore.self) private var store

    private func word(_ m: WaterMotor?) -> String {
        m.map { $0.running == true ? "Running" : $0.running == false ? "Off" : "Unknown" } ?? "No reading"
    }

    var body: some View {
        let w = store.water
        let supply = w.supply.first
        let drip = w.motors.first { $0.role == "drip" }
        let c = store.irrigation
        let say = WaterNow.say(cache: c, zone: FarmTime.zone(c.timeZone), now: store.now)
        Button { store.selectedTab = .water } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Water").font(Theme.panelTitle).foregroundStyle(Theme.text)
                    if let t = w.pulledAt { Text(Water.ago(Date(timeIntervalSince1970: t / 1000), now: store.now)).font(Theme.small).foregroundStyle(Theme.faint) }
                    Spacer()
                    Text("Details").font(Theme.font(13, .bold, relativeTo: .footnote)).foregroundStyle(Theme.on)
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.on)
                }
                HStack(alignment: .top, spacing: 0) {
                    Station(art: w.river?.running == true ? "art-motor-on" : "art-motor-off", title: "River",
                            sub: word(w.river), on: w.river?.running == true)
                    Pipe(on: w.river?.running == true).padding(.top, 28)
                    Station(art: supply?.running == true ? "art-motor-on" : "art-motor-off", title: "Other farm",
                            sub: supply.map { "7.5 HP \(word($0).lowercased())" } ?? "No reading", on: supply?.running == true)
                    Pipe(on: supply?.running == true).padding(.top, 28)
                    Station(art: "art-kulam", title: "Main farm", sub: say.running ? "Watering" : "Not watering", on: say.running)
                }
                if let drip {
                    HStack(spacing: 8) {
                        Image(drip.running == true ? "art-motor-on" : "art-motor-off").resizable().scaledToFit().frame(width: 22, height: 22)
                        Text([drip.name, word(drip), drip.program.map { "\($0) zone \(drip.zone.map(String.init) ?? "")" }]
                                .compactMap { $0 }.joined(separator: " · "))
                            .font(Theme.font(12.5, drip.running == true ? .semibold : .regular, relativeTo: .caption))
                            .foregroundStyle(drip.running == true ? Theme.on : Theme.muted).lineLimit(1)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Theme.panel2, in: Capsule())
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(16)
            .modifier(Panel(padding: 0))
        }
        .buttonStyle(.plain)
    }
}

/// A ring: how far through the current run, or how much of the last one
/// was delivered. Stopped early is amber, never green.
struct Ring: View {
    let fraction: Double
    let color: Color
    let label: String
    let sub: String
    var track: Color = Theme.panel3
    var size: CGFloat = 84

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: 9)
            Circle().trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(label).font(Theme.font(16, .bold, relativeTo: .headline).monospacedDigit()).foregroundStyle(Theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(sub).font(Theme.font(10, .semibold, relativeTo: .caption2)).foregroundStyle(Theme.faint)
            }
            .padding(10)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .combine)
    }
}

private struct VCard<Content: View>: View {
    let label: String
    let go: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button { Haptics.select(); go() } label: {
            VStack(alignment: .leading, spacing: 12) {
                Text(label).eyebrowStyle()
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(14)
            .modifier(Panel(padding: 0))
        }
        .buttonStyle(.plain)
    }
}

struct IrrigationRingCard: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        let c = store.irrigation
        let say = WaterNow.say(cache: c, zone: FarmTime.zone(c.timeZone), now: store.now)
        let last = Irrigation.runs(c).first
        let checked = (c.program?.at ?? c.lastUpdated).map { Water.ago(Date(timeIntervalSince1970: $0 / 1000), now: store.now) }
        VCard(label: "Irrigation" + (checked.map { " · \($0)" } ?? ""), go: { store.selectedTab = .irrigation }) {
            if c.isEmpty {
                Text("No data yet").font(Theme.meta).foregroundStyle(Theme.muted)
            } else {
                HStack(spacing: 14) {
                    if say.running, let p = c.program {
                        let planned = Double(p.plannedMin ?? 0), left = Double(max(0, p.remainingMin ?? 0))
                        Ring(fraction: planned > 0 ? 1 - left / planned : 0.5, color: Theme.brand,
                             label: p.remainingMin.map { Format.minutes(max(0, $0)) } ?? "On", sub: "left")
                    } else if let last {
                        let planned = Double(last.plannedMin ?? 0)
                        let got = Double(last.deliveredMin ?? (last.finished ? last.plannedMin ?? 0 : 0))
                        Ring(fraction: planned > 0 ? got / planned : 1, color: last.finished ? Theme.brand : Theme.warn,
                             label: last.deliveredMin.map(Format.minutes) ?? last.amount ?? "—",
                             sub: last.finished ? "last run" : "stopped")
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(say.running ? say.title : say.title.replacingOccurrences(of: "Last: ", with: ""))
                            .font(Theme.font(16, .bold, relativeTo: .headline)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(say.running ? "Watering now" : (last.flatMap { FarmTime.when($0.start, now: store.now, zone: FarmTime.zone(c.timeZone)) } ?? "Not watering"))
                            .font(Theme.meta).foregroundStyle(Theme.muted)
                        let valves = (say.running ? c.program?.valves : last?.valves) ?? ""
                        HStack(spacing: 4) {
                            ForEach(valves.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                                        .compactMap { ValveArt.key(name: $0, type: "irrigation") }.prefix(5), id: \.self) {
                                Image("art-\($0)").resizable().scaledToFit().frame(width: 24, height: 24)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }
    }
}

struct SolarCard: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        if let solar = SolarGlance.find(store.entities) {
            VCard(label: "Solar", go: { store.selectedTab = .areas }) {
                Image(systemName: "sun.max.fill").font(.system(size: 30)).foregroundStyle(Theme.warn)
                    .frame(width: 64, height: 64).background(Theme.warn.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(solar.watts.map { $0 >= 1000 ? String(format: "%.2f", $0 / 1000) : "\(Int($0))" } ?? "—")
                            .font(Theme.font(28, .bold, relativeTo: .title).monospacedDigit()).tracking(-1).foregroundStyle(Theme.ink)
                        Text((solar.watts ?? 0) >= 1000 ? "kW" : "W").font(Theme.font(13, .semibold, relativeTo: .caption)).foregroundStyle(Theme.faint)
                    }
                    Text(solar.today.flatMap { $0.isBad ? nil : "\($0.state ?? "") \($0.attrs.unit ?? "") today" } ?? "now")
                        .font(Theme.meta).foregroundStyle(Theme.muted)
                }
            }
        }
    }
}

struct HealthCard: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        let devices = store.devices
        let bad = devices.filter(\.isOffline).count, ok = devices.count - bad
        VCard(label: "Devices", go: { store.showDevices(status: bad > 0 ? .offline : .all) }) {
            Ring(fraction: devices.isEmpty ? 0 : Double(ok) / Double(devices.count), color: Theme.brand,
                 label: "\(ok)", sub: "of \(devices.count)", track: bad > 0 ? Theme.bad.opacity(0.3) : Theme.panel3, size: 64)
            Text(bad > 0 ? "\(bad) not reporting" : "All reporting")
                .font(Theme.font(15, .bold, relativeTo: .subheadline)).foregroundStyle(Theme.text)
        }
    }
}

/// The switches as tiles; the whole tile is the button. On tiles fill green.
struct SwitchTiles: View {
    @Environment(FarmStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        // Only real switch and light modules: an inverter's export-limit
        // switch or an AC's sleep mode is a setting, not a Home tile.
        let operable = (store.systems[.switches]?.entities ?? []).filter { $0.isControllable && !$0.isBad }
            .sorted { (store.displayOn($0) ? 0 : 1, $0.name) < (store.displayOn($1) ? 0 : 1, $1.name) }
        let shown = Array(operable.prefix(8))
        if !shown.isEmpty {
            HStack {
                Text("Switches").font(Theme.panelTitle).foregroundStyle(Theme.text)
                Spacer()
                NavigationLink(value: SystemRoute(id: .switches)) {
                    HStack(spacing: 4) {
                        Text(operable.count > shown.count ? "All \(operable.count)" : "All")
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold))
                    }
                    .font(Theme.font(13, .bold, relativeTo: .footnote)).foregroundStyle(Theme.on)
                }
            }
            .padding(.top, 10)
            ControlNote()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: sizeClass == .regular ? 4 : 2), spacing: 10) {
                ForEach(shown) { e in SwitchTile(entity: e, name: Systems.shortName(e, deviceName: store.deviceNames[e.device ?? ""])) }
            }
        }
    }
}

struct SwitchTile: View {
    @Environment(FarmStore.self) private var store
    let entity: Entity
    var name: String? = nil

    var body: some View {
        let on = store.displayOn(entity)
        let busy = store.pending[entity.id] != nil
        Button { store.toggle(entity) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: Theme.symbol(entity.domain)).font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(on ? .white : Theme.muted)
                    .frame(width: 38, height: 38)
                    .background(on ? Color.white.opacity(0.2) : Theme.panel2, in: Circle())
                Spacer(minLength: 10)
                Text(name ?? entity.name).font(Theme.font(14, .bold, relativeTo: .subheadline))
                    .foregroundStyle(on ? .white : Theme.text).lineLimit(2).multilineTextAlignment(.leading)
                Text("\(store.areaName(entity.area)) · \(on ? "On" : "Off")").font(Theme.font(12, .regular, relativeTo: .caption))
                    .foregroundStyle(on ? .white.opacity(0.85) : Theme.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .padding(14)
            .background(on ? Theme.brand : Theme.panel, in: RoundedRectangle(cornerRadius: Theme.rLg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.rLg, style: .continuous).strokeBorder(on ? .clear : Theme.edge, lineWidth: 1))
            .shadow(color: Theme.cardShadow, radius: 10, y: 4)
            .opacity(busy ? 0.7 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!store.canOperate(entity))
        .sensoryFeedback(.impact(weight: .light), trigger: on)
        .accessibilityLabel(entity.name)
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// Irrigation, water and solar, one line each.
struct SystemsCard: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        let c = store.irrigation
        let zone = FarmTime.zone(c.timeZone)
        let say = WaterNow.say(cache: c, zone: zone, now: store.now)
        let w = store.water
        let solar = SolarGlance.find(store.entities)
        VStack(spacing: 0) {
            row("Irrigation", value: c.isEmpty ? "No data yet" : say.running ? "Watering · \(say.title)" : "Not watering",
                meta: c.isEmpty ? "" : say.running ? say.detail : say.title + (say.detail.isEmpty ? "" : " · " + (say.detail.components(separatedBy: " · ").last ?? "")),
                on: say.running) { store.selectedTab = .irrigation }
            if w.river != nil || !w.motors.isEmpty {
                let motors = [w.river] + w.motors.map { Optional($0) }
                let any = motors.contains { $0?.running == true }
                let bits: [String] = [("River", w.river), ("7.5 HP", w.supply.first), ("Drip", w.motors.first { $0.role == "drip" })]
                    .compactMap { label, m in m.map { "\(label) \($0.running == true ? "on" : $0.running == false ? "off" : "?")" } }
                Hairline()
                row("Water", value: any ? "Motors running" : "All motors off", meta: bits.joined(separator: " · "), on: any) {
                    store.selectedTab = .water
                }
            }
            if let solar {
                Hairline()
                row("Solar", value: solar.watts.map { $0 >= 1000 ? String(format: "%.2f kW now", $0 / 1000) : "\(Int($0)) W now" } ?? "No reading",
                    meta: solar.today.flatMap { $0.isBad ? nil : "\($0.state ?? "") \($0.attrs.unit ?? "") today" } ?? "", on: false) {
                    store.selectedTab = .areas
                }
            }
        }
        .modifier(Panel(padding: 0))
    }

    private func row(_ title: String, value: String, meta: String, on: Bool, go: @escaping () -> Void) -> some View {
        Button { Haptics.select(); go() } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).eyebrowStyle()
                    Text(value).font(Theme.font(16, .bold, relativeTo: .headline)).foregroundStyle(on ? Theme.on : Theme.text)
                    if !meta.isEmpty { Text(meta).font(Theme.meta).foregroundStyle(Theme.muted).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct AreaRoute: Hashable { let id: String }

/* ---- shared pieces ---- */

/// A panel with a title row: title, a quiet context line, and an optional
/// trailing control. The Overview's one panel shape.
struct Block<Trailing: View, Content: View>: View {
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
            if divided { Rectangle().fill(Theme.line.opacity(0.6)).frame(height: 1) }
            content
        }
        .card()
    }
}

extension Block where Trailing == EmptyView {
    init(title: String, context: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, context: context, trailing: { EmptyView() }, content: content)
    }
}

/// A number with its label under it, the Overview's unit of "how much".
struct Figure: View {
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

struct Hairline: View {
    var inset: CGFloat = 0
    var body: some View { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, inset) }
}

/// "12h ago" for a server-millisecond stamp.
func ago(_ ms: Double?, now: Date) -> String? {
    guard let ms, ms > 0 else { return nil }
    let s = now.timeIntervalSince1970 - ms / 1000
    return s < 60 ? "just now" : "\(Format.age(max(0, s))) ago"
}

/* ---- irrigation ---- */

/// What the controller is doing, with Run / Stop for admins.
struct IrrigationNowCard: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        let c = store.irrigation
        let zone = FarmTime.zone(c.timeZone)
        Block(title: "Now", context: c.device) {
            if store.canControl { RefreshButton() }
        } content: {
            if c.isEmpty {
                EmptyBlock(title: "No data yet",
                           message: store.canControl ? "Press Refresh to ask the controller." : "Nothing has been pulled yet.",
                           symbol: "drop", framed: false)
            } else {
                WaterNow(cache: c, zone: zone, now: store.now)
            }
            if store.canRunIrrigation, !c.isEmpty { IrrigationControls(cache: c, zone: zone, now: store.now) }
            if store.canControl, !store.gate(.irrigation).ok {
                Note(text: store.gate(.irrigation).why, tone: .warn).padding(.horizontal, 18).padding(.bottom, 10)
            }
        }
    }
}

/// Every valve with its picture; the ones the running program has open are marked.
struct IrrigationValvesCard: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        let c = store.irrigation
        let rows = (c.valveNames.isEmpty ? c.valves : c.valveNames)
            .filter { $0["id"] != nil }
            .sorted { (Int($0["id"] ?? "") ?? 0) < (Int($1["id"] ?? "") ?? 0) }
        let say = WaterNow.say(cache: c, zone: FarmTime.zone(c.timeZone), now: store.now)
        let open = Set(say.running ? (c.program?.valves ?? "").lowercased().components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } : [])
        if !rows.isEmpty {
            Block(title: "Valves", context: "\(rows.count)") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                    ForEach(rows, id: \.self) { r in
                        let name = r["name"] ?? "Valve \(r["id"] ?? "")"
                        let on = open.contains(name.lowercased())
                        HStack(spacing: 8) {
                            if let art = ValveArt.key(name: name, type: r["type"], status: on ? "on" : "off") {
                                Image("art-\(art)").resizable().scaledToFit().frame(width: 24, height: 24)
                            } else {
                                Image(systemName: "spigot").font(.system(size: 13)).foregroundStyle(Theme.faint).frame(width: 24)
                            }
                            Text(name).font(Theme.font(12.5, .semibold, relativeTo: .caption)).foregroundStyle(Theme.text)
                                .lineLimit(1).minimumScaleFactor(0.85)
                            Spacer(minLength: 0)
                            if on { Circle().fill(Theme.brand).frame(width: 7, height: 7) }
                        }
                        .padding(.horizontal, 9).frame(minHeight: 44)
                        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous)
                            .strokeBorder(on ? Theme.brand.opacity(0.5) : .clear, lineWidth: 1))
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(on ? "open" : "")
                    }
                }
                .padding(12)
            }
        }
    }
}

/// The newest day the logs cover: four figures and the last runs.
struct IrrigationDayCard: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        let c = store.irrigation
        let zone = FarmTime.zone(c.timeZone)
        let runs = Array(Irrigation.runs(c).prefix(4))
        if let day = Irrigation.latestDay(c) {
            Block(title: FarmTime.dayLabel(day.day, now: store.now, zone: zone)) {
                DayFigures(day: day, zone: zone, now: store.now)
                ForEach(Array(runs.enumerated()), id: \.offset) { i, r in
                    Hairline(inset: 18)
                    RunRow(run: r, otherDay: r.day == day.day ? nil : FarmTime.dayLabel(r.day, now: store.now, zone: zone))
                }
            }
        }
    }
}

struct IrrigationSupplyCard: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        let c = store.irrigation
        if Irrigation.supply(c) != nil || Irrigation.pressure(c) != nil {
            Block(title: "Supply") { SupplyRow(cache: c, zone: FarmTime.zone(c.timeZone), now: store.now) }
        }
    }
}

struct RefreshButton: View {
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
            .background(Theme.fill, in: Capsule())
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
struct WaterNow: View {
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

    struct Say { var running: Bool; var title: String; var detail: String; var checked: String? }

    private var state: Say { Self.say(cache: cache, zone: zone, now: now) }

    static func say(cache: IrrigationCache, zone: TimeZone, now: Date) -> Say {
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

/// Admins only: open valves for a while, or end a manual run. Every press
/// is confirmed, and the NUC reads the controller before it sends anything.
struct IrrigationControls: View {
    @Environment(FarmStore.self) private var store
    let cache: IrrigationCache
    let zone: TimeZone
    let now: Date
    @State private var picking = false
    @State private var confirmStop = false

    var body: some View {
        let refusal = store.irrigationRefusal()
        let program = cache.program
        let manual = program.map { $0.running && $0.isManual } ?? false
        let waiting = store.irrigationPending != nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { picking = true } label: {
                    Label("Run valves…", systemImage: "drop")
                        .frame(maxWidth: .infinity, minHeight: Theme.hit)
                        .foregroundStyle(.white)
                        .background(Theme.brand, in: RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(refusal != nil)
                .opacity(refusal != nil ? 0.5 : 1)
                if manual {
                    Button { confirmStop = true } label: {
                        HStack(spacing: 6) {
                            if waiting { ProgressView().controlSize(.small) }
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .frame(maxWidth: .infinity, minHeight: Theme.hit)
                        .foregroundStyle(Theme.bad)
                        .background(Theme.bad.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(refusal != nil)
                }
            }
            .font(Theme.font(15, .semibold, relativeTo: .body))
            if let refusal, !refusal.isEmpty, !waiting { Note(text: refusal, tone: .warn) }
            else if store.isAdmin, let problem = store.mobitechProblem {
                // Where it matters: an admin about to press Run learns the
                // session is missing or rejected, and where to fix it.
                Note(text: problem, tone: .warn)
            }
            else if waiting {
                Note(text: store.irrigationConfirming
                     ? "Sent — confirming with the controller. Run and Stop unlock when it shows the change."
                     : "Sent to the farm — waiting for the controller to answer.")
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
        .sheet(isPresented: $picking) { RunValvesSheet(cache: cache) }
        .confirmationDialog("Stop the manual run?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop watering", role: .destructive) { Haptics.warn(); Task { await store.stopIrrigation() } }
        } message: {
            Text([program?.valves, "The controller closes the valves and ends Manual Mode."]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
        }
    }
}

/// Pick up to five irrigation valves and a duration, then confirm.
struct RunValvesSheet: View {
    @Environment(FarmStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let cache: IrrigationCache
    @State private var picked: [Int] = []
    @State private var minutes = 15
    @State private var confirm = false

    private static let choices = [5, 10, 15, 20, 30, 45, 60]

    var body: some View {
        let valves = Irrigation.operableValves(cache)
        let busy = cache.program.map { $0.running } ?? false
        let cap = store.irrigationMaxMinutes
        NavigationStack {
            List {
                if busy, let p = cache.program {
                    Section {
                        // A scheduled cycle does not block a manual run; only
                        // another manual run does (owner, 2026-09-24).
                        if p.isManual {
                            Note(text: "A manual run is already going. Stop it before starting another.", tone: .warn)
                        } else {
                            Note(text: "\(p.name) is running on its schedule. A manual run can still be started.")
                        }
                    }
                }
                Section {
                    Picker("Minutes", selection: $minutes) {
                        ForEach(Self.choices.filter { $0 <= cap }, id: \.self) { Text(Format.minutes($0)).tag($0) }
                    }
                    .sensoryFeedback(.selection, trigger: minutes)
                } footer: {
                    Text("The controller stops by itself when the time is up.")
                }
                Section {
                    ForEach(valves) { v in
                        let on = picked.contains(v.id)
                        Button {
                            Haptics.select()
                            if on { picked.removeAll { $0 == v.id } }
                            else if picked.count < IrrigationCommand.maxValves { picked.append(v.id) }
                        } label: {
                            HStack {
                                Text(v.name).foregroundStyle(Theme.text)
                                Spacer()
                                if on { Image(systemName: "checkmark").foregroundStyle(Theme.on) }
                            }
                        }
                        .disabled(!on && picked.count >= IrrigationCommand.maxValves)
                    }
                } header: {
                    Text("Valves · up to \(IrrigationCommand.maxValves)")
                } footer: {
                    Text("Only irrigation valves are listed — never the tank, booster pump or backwash valve.")
                }
            }
            .navigationTitle("Run valves")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Run") { confirm = true }.disabled(picked.isEmpty || store.irrigationRefusal() != nil)
                }
            }
            .confirmationDialog(summary(valves), isPresented: $confirm, titleVisibility: .visible) {
                Button("Open the valves") {
                    Haptics.commit()
                    let chosen = picked, mins = minutes
                    dismiss()
                    Task { await store.runValves(chosen, minutes: mins) }
                }
            } message: {
                Text("Sent to the controller as Manual Mode, from the farm's own connection.")
            }
        }
    }

    private func summary(_ valves: [IrrigationValve]) -> String {
        let names = picked.compactMap { id in valves.first { $0.id == id }?.name }
        return "Water \(names.joined(separator: ", ")) for \(Format.minutes(minutes))?"
    }
}

/// The newest day the logs cover: runs, water, pump, energy.
struct DayFigures: View {
    let day: Irrigation.Day
    let zone: TimeZone
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if day.stopped > 0 { Tag(text: "\(day.stopped) stopped early", kind: .warn) }
            HStack(alignment: .top, spacing: 10) {
                Figure(value: "\(day.runs.count)", label: day.runs.count == 1 ? "Run" : "Runs")
                Figure(value: Format.minutes(day.waterMin), label: "Water")
                Figure(value: day.pump.map { Format.minutes($0.pumpMin) } ?? "—", label: "Pump")
                Figure(value: day.pump?.kwh.map { String(format: "%.1f", $0) } ?? "—", unit: day.pump?.kwh == nil ? nil : "kWh",
                       label: "Energy")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}

/// Three-phase supply and pressure, from the last live reading.
struct SupplyRow: View {
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

struct RunRow: View {
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
                LinkButton(label: "All", run: { store.showDevices(status: .all) })
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
                    Button { store.showDevices(status: .all) } label: {
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
        let bad = devices.filter(\.isOffline).count
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(name).font(Theme.font(15.5, .bold, relativeTo: .headline)).tracking(-0.4)
                    .foregroundStyle(Theme.text).lineLimit(2)
                Spacer(minLength: 6)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            (Text("\(devices.count) \(devices.count == 1 ? "device" : "devices")")
                + (bad > 0 ? Text(" · ") + Text("\(bad) offline").foregroundColor(Theme.bad).bold() : Text("")))
                .font(Theme.meta).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(14)
        .card()
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
