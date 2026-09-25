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
                PowerCard()
                if sizeClass == .regular {
                    HStack(alignment: .top, spacing: 14) { IrrigationRingCard(); SecurityCard() }
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    IrrigationRingCard()
                    SecurityCard()
                }
                SwitchTiles()
                AroundTheFarm()
            }
        }
        .navigationTitle("Home")
        // Home is the first screen: keep the water picture current while it is
        // open (the function spaces pulls 15 s apart whoever asks). Restarted
        // once meta arrives: before it the gate is closed and nothing refreshes.
        .task(id: store.metaLoaded) {
            await store.autoRefreshIrrigationIfStale()
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
    /// How old the reading is, when it is not current.
    var age: String? = nil

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
            if let age { Text(age).font(Theme.font(11, .regular, relativeTo: .caption2)).foregroundStyle(Theme.faint).lineLimit(1) }
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
        // Flowing only on a current reading; a stale one shows its age.
        let live = { (m: WaterMotor?) in m?.running == true && w.isCurrent(m, now: store.now) }
        let aged = { (m: WaterMotor?) -> String? in
            guard let m, !w.isCurrent(m, now: store.now) else { return nil }
            if m.vendor == "livesky", w.livesky.kind(nowMs: store.now.timeIntervalSince1970 * 1000) != .ok { return "not read" }
            return w.readingDate(m).map { Water.ago($0, now: store.now) }
        }
        // The pull's age only while every reading drawn is current.
        let allCurrent = [w.river, supply].compactMap { $0 }.allSatisfy { w.isCurrent($0, now: store.now) }
        Button { store.selectedTab = .water } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Water").font(Theme.panelTitle).foregroundStyle(Theme.text)
                    if !w.enabled { Text("readings off").font(Theme.small).foregroundStyle(Theme.faint) }
                    else if let t = w.pulledAt, allCurrent { Text(Water.ago(Date(timeIntervalSince1970: t / 1000), now: store.now)).font(Theme.small).foregroundStyle(Theme.faint) }
                    Spacer()
                    Text("Details").font(Theme.font(13, .bold, relativeTo: .footnote)).foregroundStyle(Theme.on)
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.on)
                }
                HStack(alignment: .top, spacing: 0) {
                    Station(art: live(w.river) ? "art-motor-on" : "art-motor-off", title: "River",
                            sub: word(w.river), on: live(w.river), age: aged(w.river))
                    Pipe(on: live(w.river)).padding(.top, 28)
                    Station(art: live(supply) ? "art-motor-on" : "art-motor-off", title: "Other farm",
                            sub: supply.map { "7.5 HP \(word($0).lowercased())" } ?? "No reading", on: live(supply), age: aged(supply))
                    Pipe(on: live(supply)).padding(.top, 28)
                    Station(art: "art-kulam", title: "Main farm", sub: say.running ? "Watering" : "Not watering", on: say.running)
                }
                if let drip {
                    HStack(spacing: 8) {
                        Image(live(drip) ? "art-motor-on" : "art-motor-off").resizable().scaledToFit().frame(width: 22, height: 22)
                        Text([drip.name, word(drip), drip.program.map { "\($0) zone \(drip.zone.map(String.init) ?? "")" }, aged(drip)]
                                .compactMap { $0 }.joined(separator: " · "))
                            .font(Theme.font(12.5, live(drip) ? .semibold : .regular, relativeTo: .caption))
                            .foregroundStyle(live(drip) ? Theme.on : Theme.muted).lineLimit(1)
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
                        // The same countdown as the Now card: from the controller's
                        // last report, not the raw figure in it.
                        let planned = Double(p.plannedMin ?? 0), left = Double(max(0, say.leftMin ?? p.remainingMin ?? 0))
                        Ring(fraction: planned > 0 ? 1 - left / planned : 0.5, color: Theme.brand,
                             label: say.leftMin.map { Format.minutes(max(0, $0)) } ?? "On", sub: "left")
                    } else if let last {
                        let planned = Double(last.plannedMin ?? 0)
                        let got = Double(last.deliveredMin ?? (last.finished ? last.plannedMin ?? 0 : 0))
                        // Caught part-way by the last read: "so far", neither green nor amber.
                        let readAt = Irrigation.logReadAt(c, now: store.now), zone = FarmTime.zone(c.timeZone)
                        let open = Irrigation.mayStillRun(last, readAt: readAt, zone: zone)
                        let outcome = Irrigation.outcome(last, readAt: readAt, now: store.now, zone: zone)
                            .trimmingCharacters(in: CharacterSet(charactersIn: ", "))
                        Ring(fraction: planned > 0 ? got / planned : 1,
                             color: last.finished ? Theme.brand : open ? Theme.muted : Theme.warn,
                             label: last.deliveredMin.map(Format.minutes) ?? last.amount ?? "—",
                             sub: last.finished ? "last run" : outcome)
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
    /// Own presses only: a switch flipped by someone else must not buzz this phone.
    @State private var presses = 0

    var body: some View {
        let on = store.displayOn(entity)
        let busy = store.pending[entity.id] != nil
        let can = store.canOperate(entity)
        Button { presses += 1; store.toggle(entity) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: Theme.symbol(entity.domain)).font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(on ? .white : Theme.muted)
                    .frame(width: 38, height: 38)
                    .background(on ? Color.white.opacity(0.2) : Theme.panel2, in: Circle())
                    .opacity(can ? 1 : 0.6)
                Spacer(minLength: 10)
                Text(name ?? entity.name).font(Theme.font(14, .bold, relativeTo: .subheadline))
                    .foregroundStyle(on ? .white : Theme.text).lineLimit(2).multilineTextAlignment(.leading)
                Text("\(store.areaName(entity.area)) · \(on ? "On" : "Off")").font(Theme.font(12, .regular, relativeTo: .caption))
                    .foregroundStyle(on ? .white : Theme.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .padding(14)
            .background(on ? Theme.brand : Theme.panel, in: RoundedRectangle(cornerRadius: Theme.rLg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.rLg, style: .continuous).strokeBorder(on ? .clear : Theme.edge, lineWidth: 1))
            // Not pressable: flat, the icon dimmed, but the words at full
            // strength. A whole-tile fade left the name at 2.2:1 and hid the
            // state a viewer came to read.
            .shadow(color: can ? Theme.cardShadow : .clear, radius: 10, y: 4)
            .opacity(busy ? 0.7 : 1)
        }
        .buttonStyle(TileButtonStyle())
        .disabled(!can)
        .sensoryFeedback(.impact(weight: .light), trigger: presses)
        .accessibilityLabel(entity.name)
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
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
    return Water.ago(Date(timeIntervalSince1970: ms / 1000), now: now)
}

/* ---- irrigation ---- */

/// What the controller is doing, with Run / Stop for admins.
struct IrrigationNowCard: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        let c = store.irrigation
        let zone = FarmTime.zone(c.timeZone)
        // Why Refresh (and Run) are off, said once when the quiet bridge is both reasons.
        let reads = store.gate(.irrigation), valves = store.gate(.irrigationControl)
        let both = store.canRunIrrigation && !reads.ok && reads.bridge && !valves.ok && valves.bridge
        // Nothing is known before meta arrives: no "not reporting" on launch.
        let known = store.metaLoaded
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
            if store.canRunIrrigation, !c.isEmpty { IrrigationControls(cache: c, zone: zone, now: store.now, quiet: both || !known) }
            if store.canControl, !reads.ok, known {
                Note(text: both ? Gate.bridgeDownBoth : reads.why, tone: .warn).padding(.horizontal, 18).padding(.bottom, 10)
            }
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
            // A fault names the valve and what went wrong, so it wraps rather
            // than riding on a fixed-width tag that can outgrow the card.
            if s.running, let faults = cache.program?.faults, !faults.isEmpty {
                ForEach(faults, id: \.self) { f in
                    Label(f, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.font(12.5, .bold, relativeTo: .caption)).foregroundStyle(Theme.bad)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    struct Say { var running: Bool; var title: String; var detail: String; var checked: String?; var leftMin: Int? = nil }

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
                return Say(running: true, title: p.name, detail: bits.joined(separator: " · "), checked: checked, leftMin: left)
            }
        }
        if let last = Irrigation.runs(cache).first {
            var bits: [String] = []
            if let a = last.amount {
                bits.append(last.finished ? "\(a), finished" : a + Irrigation.outcome(last, readAt: Irrigation.logReadAt(cache, now: now), now: now, zone: zone))
            }
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
    /// The card already says why (a quiet bridge closes reads and valves alike).
    var quiet = false
    @State private var picking = false
    @State private var confirmStop = false

    var body: some View {
        let refusal = store.irrigationRefusal()
        let program = cache.program
        let manual = program.map { $0.running && $0.isManual } ?? false
        let waiting = store.irrigationPending != nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // A second manual run is refused by the farm while one is going.
                // Disabled reads grey on grey at full strength, not a faded
                // green (white on a 50% brand was 2.0:1).
                let canRun = refusal == nil && !manual
                Button { picking = true } label: {
                    Label("Run valves…", systemImage: "drop")
                        .frame(maxWidth: .infinity, minHeight: Theme.hit)
                        .foregroundStyle(canRun ? .white : Theme.muted)
                        .background(canRun ? Theme.brand : Theme.panel3, in: RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous))
                }
                .buttonStyle(TileButtonStyle())
                .disabled(!canRun)
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
            if let refusal, !refusal.isEmpty, !waiting { if !quiet { Note(text: refusal, tone: .warn) } }
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
            else if manual { Note(text: "One manual run at a time.") }
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
        .sheet(isPresented: $picking) { RunValvesSheet(cache: cache).environment(store) }
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

/* ---- areas (used by the Areas tab) ---- */

struct AreaCard: View {
    @Environment(FarmStore.self) private var store
    let name: String
    let entities: [Entity]

    var body: some View {
        // Devices, like the tiles: one switched-off printer is one offline.
        let devices = Sorting.byDevice(entities, names: store.deviceNames)
        // An AC or TV off at the wall is "off", not an alarm; red is for faults.
        let index = store.deviceSystems
        let down = devices.filter(\.isOffline)
        let fault = down.filter { Systems.offlineIsFault($0, system: index[$0.id]) }.count
        let off = down.count - fault
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(name).font(Theme.font(15.5, .bold, relativeTo: .headline)).tracking(-0.4)
                    .foregroundStyle(Theme.text).lineLimit(2)
                Spacer(minLength: 6)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            (Text("\(devices.count) \(devices.count == 1 ? "device" : "devices")")
                + (fault > 0 ? Text(" · ") + Text("\(fault) offline").foregroundColor(Theme.bad).bold() : Text(""))
                + (off > 0 ? Text(" · \(off) off") : Text("")))
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
