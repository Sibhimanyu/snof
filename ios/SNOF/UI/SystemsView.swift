import SwiftUI
import SNOFCore

/* Home v3 and the system pages (2026-09-25 night). Mirrors attentionPanel(),
 * solarCard(), securityCard(), systemsGrid(), systemView(), irrCropsModule()
 * and irrSupplyModule() in dashboard/public/app.js — the same modules, the
 * same words, on both apps. The rules themselves live in SNOFCore
 * (Systems.swift) and are tested there. */

struct SystemRoute: Hashable { let id: FarmSystemID }

/* ---- needs a look ---- */

struct AttentionCard: View {
    @Environment(FarmStore.self) private var store
    @State private var open = false     // collapsed until asked, as on the web
    @State private var all = false      // "N more" opened by hand

    var body: some View {
        let items = store.attention
        if items.isEmpty {
            HStack(spacing: 14) {
                Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34).background(Theme.brand, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("All clear").font(Theme.font(15, .bold, relativeTo: .subheadline)).foregroundStyle(Theme.text)
                    Text("Nothing on the farm needs a look.").font(Theme.meta).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .modifier(Panel(padding: 0))
            .accessibilityElement(children: .combine)
        } else {
            let bad = items.contains { $0.level == .bad }
            VStack(alignment: .leading, spacing: 0) {
                // Closed, the header still names the worst thing, so a glance says enough.
                Button { withAnimation(.snappy) { open.toggle() } } label: {
                    HStack(spacing: 12) {
                        Text("\(items.count)").font(Theme.font(14, .bold, relativeTo: .subheadline).monospacedDigit())
                            .foregroundStyle(bad ? Theme.bad : Theme.warn)
                            .frame(minWidth: 30, minHeight: 30).padding(.horizontal, 2)
                            .background((bad ? Theme.bad : Theme.warn).opacity(0.12), in: Capsule())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(items.count == 1 ? "Thing needs a look" : "Things need a look")
                                .font(Theme.panelTitle).foregroundStyle(Theme.text)
                            if !open {
                                Text(items[0].text + (items.count > 1 ? " · +\(items.count - 1) more" : ""))
                                    .font(Theme.meta).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.faint).rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(open ? "Hides the list" : "Shows the list")
                if open {
                    ForEach(all ? items : Array(items.prefix(5))) { item in
                        Hairline()
                        AttentionRowView(item: item)
                    }
                }
                if open && items.count > 5 {
                    Hairline()
                    Button { withAnimation(.snappy) { all.toggle() } } label: {
                        Text(all ? "Show fewer" : "\(items.count - 5) more")
                            .font(Theme.font(13, .bold, relativeTo: .footnote)).foregroundStyle(Theme.on)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .modifier(Panel(padding: 0))
        }
    }
}

private struct AttentionRowView: View {
    @Environment(FarmStore.self) private var store
    let item: AttentionItem

    var body: some View {
        switch item.place {
        case .system(let id):
            NavigationLink(value: SystemRoute(id: id)) { label }.buttonStyle(.plain)
        case .irrigation:
            Button { store.openMotor(FarmStore.dconKey) } label: { label }.buttonStyle(.plain)
        case .water:
            Button { store.selectedTab = .water } label: { label }.buttonStyle(.plain)
        case .home:
            label
        }
    }

    private var label: some View {
        HStack(spacing: 12) {
            Circle().fill(item.level == .bad ? Theme.bad : Theme.warn).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text).font(Theme.font(14.5, .bold, relativeTo: .subheadline))
                    .foregroundStyle(item.level == .bad ? Theme.bad : Theme.text)
                if !item.sub.isEmpty {
                    Text(item.sub).font(Theme.meta).foregroundStyle(Theme.muted).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if item.place != .home {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/* ---- power and security cards ---- */

/// A meter board, not a picture. Water is a chain (river → farm), so it is
/// drawn as one; the three EB lines are separate supplies, so they are rows:
/// what the line is for, then its number. Solar on top as one bar, split by
/// inverter. (Owner, 2026-09-25: the two panels looked the same.) Mirrors
/// powerPanel() on the web.
struct PowerCard: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        let lines = Power.build(systems: store.systems, irrigation: store.irrigation, now: store.now)
        if lines.contains(where: { $0.device != nil || $0.supply?.hasVoltage == true }) {
            let solar = lines.filter { $0.spec.inverter != nil }
            let solarW = solar.compactMap { $0.inverter?.watts }.reduce(0, +)
            NavigationLink(value: SystemRoute(id: .solar)) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Power").font(Theme.panelTitle).foregroundStyle(Theme.text)
                        Spacer()
                        Text("Details").font(Theme.font(13, .bold, relativeTo: .footnote)).foregroundStyle(Theme.on)
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.on)
                    }
                    .padding(.horizontal, 16).padding(.top, 16)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if solarW > 0 {
                            Text(Systems.power(solarW)).font(Theme.font(26, .bold, relativeTo: .title).monospacedDigit()).tracking(-1)
                                .foregroundStyle(Theme.ink)
                            Text("solar right now").font(Theme.meta).foregroundStyle(Theme.muted)
                        } else {
                            Text("No solar right now").font(Theme.meta).foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 10)
                    if solarW > 0 {
                        GeometryReader { geo in
                            HStack(spacing: 3) {
                                ForEach(Array(solar.enumerated()), id: \.offset) { i, l in
                                    Capsule().fill(Theme.brand.opacity(i == 0 ? 1 : 0.42))
                                        .frame(width: max(0, (geo.size.width - 3) * (l.inverter?.watts ?? 0) / solarW))
                                }
                            }
                        }
                        .frame(height: 8).padding(.horizontal, 16).padding(.top, 10)
                        .accessibilityHidden(true)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { _, l in
                            Hairline()
                            PowerRow(line: l, key: solar.firstIndex { $0.id == l.id })
                        }
                    }
                    .padding(.top, 12)
                }
                .modifier(Panel(padding: 0))
            }
            .buttonStyle(.plain)
        }
    }
}

/// A line's picture on a square tile: the house, the car, the motor.
struct LineTile: View {
    let id: String
    var size: CGFloat = 44

    var body: some View {
        Group {
            if id == "ev" {
                Image(systemName: "bolt.car").font(.system(size: size * 0.42)).foregroundStyle(Theme.ink)
            } else {
                Image(id == "home" ? "art-house" : "art-motor-on").resizable().scaledToFit().frame(width: size * 0.68, height: size * 0.68)
            }
        }
        .frame(width: size, height: size)
        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

private struct PowerRow: View {
    let line: PowerLine
    /// Which segment of the solar bar this line is, if it has an inverter.
    let key: Int?

    var body: some View {
        let st = Power.status(line)
        let stale = line.spec.inverter == nil && !line.current
        HStack(spacing: 12) {
            LineTile(id: line.id)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    if let key { RoundedRectangle(cornerRadius: 2).fill(Theme.brand.opacity(key == 0 ? 1 : 0.42)).frame(width: 8, height: 8) }
                    Text(line.spec.title).font(Theme.font(14.5, .bold, relativeTo: .subheadline)).foregroundStyle(Theme.text)
                        .lineLimit(1).minimumScaleFactor(0.9)
                }
                Text("\(line.spec.phase) · \(line.spec.brand.isEmpty ? "free supply" : "\(line.spec.brand) solar")")
                    .font(Theme.meta).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The line's name wins the width; the reading truncates, so an
            // offline inverter's longer words never wrap the title.
            .layoutPriority(1)
            VStack(alignment: .trailing, spacing: 2) {
                if line.spec.inverter == nil, let s = line.supply, s.hasVoltage, st.state != .rest {
                    MiniPhases(volts: s.phaseV, stale: stale)
                } else {
                    LineFigure(status: st, stale: stale, big: 19)
                }
                if !st.sub.isEmpty { Text(st.sub).font(Theme.font(12, .regular, relativeTo: .caption)).foregroundStyle(Theme.muted).lineLimit(1) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Three small bars, one per phase: the free line at a glance.
private struct MiniPhases: View {
    let volts: [Double]
    var stale = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(volts.enumerated()), id: \.offset) { _, v in
                let tone: Color = stale ? Theme.faint : v < 120 ? Theme.bad : (v < 200 || v > 260) ? Theme.warn : Theme.brand
                RoundedRectangle(cornerRadius: 2).fill(tone).frame(width: 6, height: 22 * max(0.08, min(1, v / 300)))
            }
        }
        .frame(height: 22, alignment: .bottom)
        .accessibilityLabel("Phase voltages " + volts.map { "\(Int($0.rounded()))" }.joined(separator: ", ") + " volts")
    }
}

/// "965 W", "3 phases", "Inverter offline", in the line's tone.
struct LineFigure: View {
    let status: LineStatus
    var stale = false
    var big: CGFloat = 19

    var body: some View {
        let words = status.unit.isEmpty && Double(status.figure) == nil
        let tone: Color = stale ? Theme.muted : Self.tone(status.state)
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(status.figure).font(Theme.font(words ? 13.5 : big, .bold, relativeTo: .title3).monospacedDigit()).tracking(words ? 0 : -0.6)
            if !status.unit.isEmpty { Text(status.unit).font(Theme.font(12.5, .semibold, relativeTo: .caption)).foregroundStyle(Theme.muted) }
        }
        // Words never shrink: two offline lines once showed "Not reporting" at
        // two sizes, each scaled to its own row's leftover width.
        .foregroundStyle(tone).lineLimit(1).minimumScaleFactor(words ? 1 : 0.7)
    }

    static func tone(_ s: LineStatus.State) -> Color {
        switch s {
        case .on: return Theme.on
        case .bad: return Theme.bad
        case .offline, .off: return Theme.warn
        case .rest: return Theme.muted
        }
    }
}

/// Three phase bars against 0–300 V; out of 200–260 V or missing reads warm.
struct PhaseBars: View {
    let volts: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ForEach(Array(volts.enumerated()), id: \.offset) { i, v in
                let tone: Color = v < 120 ? Theme.bad : (v < 200 || v > 260) ? Theme.warn : Theme.brand
                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 6).fill(Theme.panel3)
                        RoundedRectangle(cornerRadius: 6).fill(tone).frame(height: 72 * min(1, v / 300))
                    }
                    .frame(width: 22, height: 72)
                    Text("\(Int(v.rounded()))").font(Theme.font(14, .bold, relativeTo: .subheadline).monospacedDigit())
                        .foregroundStyle(tone == Theme.brand ? Theme.ink : tone)
                    Text("L\(i + 1)").font(Theme.font(10.5, .bold, relativeTo: .caption2)).foregroundStyle(Theme.faint)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Phase voltages " + volts.map { "\(Int($0.rounded()))" }.joined(separator: ", ") + " volts")
    }
}

/// The Power page: both inverters together, then one panel per line.
struct PowerPage: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        let lines = Power.build(systems: store.systems, irrigation: store.irrigation, now: store.now)
        let solarW = lines.compactMap { $0.inverter?.watts }.reduce(0, +)
        let solarKwh = lines.compactMap { $0.inverter?.kwh }.reduce(0, +)
        HStack(spacing: 16) {
            Image(systemName: solarW > 0 ? "sun.max.fill" : "sun.max").font(.system(size: 28))
                .foregroundStyle(solarW > 0 ? Theme.warn : Theme.faint)
                .frame(width: 64, height: 64).background((solarW > 0 ? Theme.warn : Theme.faint).opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(solarW > 0 ? "\(Systems.power(solarW)) solar" : "No solar right now")
                    .font(Theme.font(22, .bold, relativeTo: .title2)).foregroundStyle(solarW > 0 ? Theme.on : Theme.text)
                Text("\(Power.kwh(solarKwh)) today from both inverters").font(Theme.meta).foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 18)
        ForEach(lines) { l in section(l) }
    }

    @ViewBuilder private func section(_ l: PowerLine) -> some View {
        let st = Power.status(l)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                LineTile(id: l.id, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(l.spec.title).font(Theme.panelTitle).foregroundStyle(Theme.text)
                    Text([l.spec.phase, l.spec.inverter != nil ? "\(l.spec.brand) solar" : nil, l.spec.use].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.meta).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                LineFigure(status: st, stale: l.spec.inverter == nil && !l.current, big: 22)
            }
            if l.spec.inverter != nil {
                if let i = l.inverter { Facts(items: facts(l, i)) }
                else { Text("The \(l.spec.brand) inverter is not reporting to Home Assistant.").font(Theme.meta).foregroundStyle(Theme.muted) }
            } else {
                if let s = l.supply, s.hasVoltage { PhaseBars(volts: s.phaseV) }
                Facts(items: supplyFacts(l))
                Button { store.openMotor(FarmStore.dconKey) } label: {
                    HStack(spacing: 4) {
                        Text("Pump & irrigation").font(Theme.font(13, .bold, relativeTo: .footnote))
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(Theme.on)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 18)
    }

    private func facts(_ l: PowerLine, _ i: InverterReading) -> [(String, String)] {
        var out: [(String, String)] = [
            ("Solar now", i.watts.map(Systems.power) ?? "—"),
            ("Today", i.kwh.map(Power.kwh) ?? "—"),
            ("Lifetime", i.total.map { "\(Int($0.rounded()).formatted()) kWh" } ?? "—"),
            ("Grid", i.grid.map { "\(Int($0.rounded())) V" } ?? "—"),
            ("Inverter temp", i.temp.map { "\(Format.trim($0)) °C" } ?? "—"),
        ]
        if let m = i.mode { out.append(("Mode", m)) }
        let ents = l.device?.entities ?? []
        func f(_ suffix: String) -> Entity? { ents.first { $0.name.lowercased().hasSuffix(suffix) && !$0.isBad } }
        if let sw = f("export limit switch") {
            let pct = f("grid export limit").flatMap { Double($0.state ?? "") }
            out.append(("Export limit", sw.state == "on" ? "On, at " + (pct.map { "\(Format.trim($0))%" } ?? "its set value")
                                                     : "Not in use" + (pct.map { " (set to \(Format.trim($0))%)" } ?? "")))
        }
        return out
    }

    private func supplyFacts(_ l: PowerLine) -> [(String, String)] {
        var out: [(String, String)] = [("Supply today", l.supplyToday ?? "—"), ("Pump today", l.pumpToday ?? "—")]
        if let s = l.supply {
            if !s.currentA.isEmpty { out.append(("Current", s.currentA.map { String(format: "%.1f", $0) }.joined(separator: " / ") + " A")) }
            if let imb = s.imbalancePct { out.append(("Imbalance", "\(Format.trim(imb))%")) }
            if let at = s.at { out.append(("Read at", at)) }
        }
        return out
    }
}

private struct Facts: View {
    let items: [(String, String)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], spacing: 12) {
            ForEach(items, id: \.0) { k, v in
                VStack(alignment: .leading, spacing: 3) {
                    Text(k).eyebrowStyle()
                    Text(v).font(Theme.font(15, .semibold, relativeTo: .subheadline).monospacedDigit()).foregroundStyle(Theme.text)
                }
            }
        }
    }
}

struct SecurityCard: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        if let sys = store.systems[.security] {
            let s = Systems.summary(sys)
            let tone: Color = s.state == .bad ? Theme.bad : s.armed ? Theme.on : Theme.faint
            let cams = sys.entities.filter { $0.domain == "camera" }
            NavigationLink(value: SystemRoute(id: .security)) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Security").eyebrowStyle()
                    Image(systemName: s.armed ? "shield.lefthalf.filled" : "shield").font(.system(size: 28))
                        .foregroundStyle(tone).frame(width: 64, height: 64)
                        .background(tone.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.line).font(Theme.font(16, .bold, relativeTo: .headline))
                            .foregroundStyle(s.state == .bad ? Theme.bad : Theme.text).lineLimit(1).minimumScaleFactor(0.8)
                        Text(s.detecting > 0 ? "\(s.detecting) detecting now" : s.cameras > 0 ? "\(s.camerasOnline) of \(s.cameras) cameras" : s.sub)
                            .font(Theme.meta).foregroundStyle(Theme.muted)
                        HStack(spacing: 5) {
                            ForEach(cams) { c in Circle().fill(c.isBad ? Theme.bad : Theme.brand).frame(width: 8, height: 8) }
                        }
                        .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(14)
                .modifier(Panel(padding: 0))
            }
            .buttonStyle(.plain)
        }
    }
}

/* ---- around the farm ---- */

struct AroundTheFarm: View {
    @Environment(FarmStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let systems = store.systems
        // Switches have their own tiles (and an "All" link) right above.
        let ids = [FarmSystemID.climate, .media, .printer, .other].filter { systems[$0] != nil }
        if !ids.isEmpty {
            Text("Around the farm").font(Theme.panelTitle).foregroundStyle(Theme.text).padding(.top, 10)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: sizeClass == .regular ? 4 : 2), spacing: 10) {
                ForEach(ids) { id in
                    let s = Systems.summary(systems[id]!)
                    NavigationLink(value: SystemRoute(id: id)) {
                        let icon = Image(systemName: id.symbol).font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(s.state == .on ? Theme.on : Theme.muted)
                            .frame(width: 36, height: 36)
                            .background(s.state == .on ? Theme.brand.opacity(0.15) : Theme.panel2, in: Circle())
                        let words = VStack(alignment: .leading, spacing: 2) {
                            Text(id.title).font(Theme.font(14, .bold, relativeTo: .subheadline)).foregroundStyle(Theme.text)
                            Text(s.line).font(Theme.font(13, .semibold, relativeTo: .footnote))
                                .foregroundStyle(s.state == .on ? Theme.on : s.state == .offline || s.state == .warn ? Theme.warn : Theme.muted)
                            if !s.sub.isEmpty { Text(s.sub).font(Theme.font(12, .regular, relativeTo: .caption)).foregroundStyle(Theme.faint) }
                        }
                        // Words from the top, whatever their count (a tile
                        // with no third line once sat lower than its
                        // neighbours); on a phone, across, as the switches.
                        Group {
                            if sizeClass == .compact {
                                HStack(spacing: 10) { icon; words; Spacer(minLength: 0) }
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .padding(.horizontal, 12).padding(.vertical, 10)
                            } else {
                                VStack(alignment: .leading, spacing: 10) { icon; words }
                                    .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
                                    .padding(14)
                            }
                        }
                        .modifier(Panel(padding: 0))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/* ---- one system, in full ---- */

struct SystemView: View {
    @Environment(FarmStore.self) private var store
    let id: FarmSystemID

    var body: some View {
        let sys = store.systems[id]
        Page(title: id.title) {
            if let sys {
                let s = Systems.summary(sys)
                if id == .solar { PowerPage() } else { hero(sys, s) }
                if id == .security { cameras(sys) }
                if [.switches, .other].contains(id) {
                    let ops = sys.entities.filter { $0.isControllable && !$0.isBad }
                        .sorted { $0.isOn != $1.isOn ? $0.isOn : Sorting.natural($0.name, $1.name) }
                    if !ops.isEmpty {
                        ControlNote()
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(ops) { e in SwitchTile(entity: e, name: Systems.shortName(e, deviceName: store.deviceNames[e.device ?? ""], roomName: store.areaName(e.area))) }
                        }
                    }
                }
                if ![.security, .solar, .switches].contains(id) {
                    ForEach(sys.devices.filter { !$0.isOffline }.sorted { Sorting.natural($0.name, $1.name) }) { d in
                        let rows = d.entities.filter { !$0.isBad && !$0.isControllable && !$0.isBackstage }
                            .sorted { Sorting.natural($0.name, $1.name) }
                        TitledPanel(title: d.name) {
                            if rows.isEmpty {
                                Text(store.areaName(d.area)).font(Theme.meta).foregroundStyle(Theme.muted).padding(14)
                            } else {
                                RowList(items: Array(rows.prefix(12)), framed: false) { DeviceRow(entity: $0) }
                            }
                        }
                    }
                }
                // Per device, as on a room page: a fan on the switches page is
                // switched off, not offline.
                let off = id == .security ? [] : sys.devices.filter(\.isOffline)
                let offFault = off.filter { Systems.offlineIsFault($0, system: id) }
                let offRest = off.filter { !Systems.offlineIsFault($0, system: id) }
                if !offFault.isEmpty { Note(text: "Offline: " + offFault.map(\.name).joined(separator: ", "), tone: .warn) }
                if !offRest.isEmpty { Note(text: "Switched off: " + offRest.map(\.name).joined(separator: ", ")) }
            } else {
                EmptyBlock(title: "Nothing here", message: "This part of the farm has no devices right now.")
            }
        }
        .navigationTitle(id.title)
        .toolbarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
    }

    @ViewBuilder private func hero(_ sys: FarmSystem, _ s: SystemSummary) -> some View {
        let tone: Color = s.state == .bad ? Theme.bad : s.state == .on || (id == .security && s.armed) ? Theme.on : Theme.faint
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                Image(systemName: id == .solar && s.state == .on ? "sun.max.fill" : id.symbol).font(.system(size: 28))
                    .foregroundStyle(id == .solar && s.state == .on ? Theme.warn : tone)
                    .frame(width: 64, height: 64).background(tone.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.line).font(Theme.font(22, .bold, relativeTo: .title2)).foregroundStyle(s.state == .bad ? Theme.bad : Theme.text)
                    if !s.sub.isEmpty { Text(s.sub).font(Theme.meta).foregroundStyle(Theme.muted) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 18)
    }

    @ViewBuilder private func cameras(_ sys: FarmSystem) -> some View {
        let cams = sys.entities.filter { $0.domain == "camera" }
        VStack(spacing: 0) {
            ForEach(Array(cams.enumerated()), id: \.element.id) { i, cam in
                if i > 0 { Hairline() }
                let dev = sys.devices.first { $0.entities.contains(cam) }
                let now = (dev?.entities ?? []).filter { $0.domain == "binary_sensor" && $0.isOn }
                    .compactMap { e -> String? in
                        let n = e.name.lowercased()
                        for k in ["person", "motion", "pet", "sound"] where n.contains("\(k) detected") { return k }
                        return nil
                    }
                HStack(spacing: 12) {
                    Image(systemName: "video").font(.system(size: 14)).foregroundStyle(cam.isBad ? Theme.bad : Theme.muted)
                        .frame(width: 32, height: 32).background(Theme.panel2, in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(dev?.name ?? cam.name).font(Theme.rowTitle).foregroundStyle(Theme.text)
                        Text(store.areaName(cam.area)).font(Theme.meta).foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if cam.isBad { Tag(text: "Offline", kind: .bad) }
                    else if !now.isEmpty { Tag(text: now.joined(separator: ", ").capitalized + " now", kind: .on) }
                    else { Tag(text: "Online") }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .accessibilityElement(children: .combine)
            }
        }
        .modifier(Panel(padding: 0))
    }
}

/* ---- irrigation: watered by crop ---- */

struct WateredCard: View {
    @Environment(FarmStore.self) private var store
    @State private var pick: String?     // "today" | "yesterday", once chosen by hand

    var body: some View {
        let c = store.irrigation
        let zone = FarmTime.zone(c.timeZone)
        let today = FarmTime.today(store.now, zone: zone), yesterday = FarmTime.yesterday(store.now, zone: zone)
        let hasToday = Irrigation.runs(c).contains { $0.day == today && !$0.valves.isEmpty }
        let which = pick ?? (hasToday ? "today" : "yesterday")
        let day = which == "today" ? today : yesterday
        let r = Irrigation.crops(c, day: day, now: store.now)
        let checked = (c.program?.at ?? c.lastUpdated).map { Water.ago(Date(timeIntervalSince1970: $0 / 1000), now: store.now) }
        let pump = Irrigation.pumpDays(c).first { $0.day == day }
        if !Irrigation.runs(c).isEmpty || !Irrigation.pumpDays(c).isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // The age sits under the title: beside it, title + age + the
                // day picker is wider than a 375pt phone has room for.
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Watered").font(Theme.panelTitle).foregroundStyle(Theme.text)
                        if let checked { Text(checked).font(Theme.small).foregroundStyle(Theme.faint) }
                    }
                    Spacer(minLength: 8)
                    Picker("Day", selection: Binding(get: { which }, set: { pick = $0 })) {
                        Text("Today").tag("today")
                        Text("Yesterday").tag("yesterday")
                    }
                    .pickerStyle(.segmented).fixedSize()
                    .sensoryFeedback(.selection, trigger: pick)
                }
                .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
                let water = r.runs.reduce(0) { $0 + ($1.deliveredMin ?? 0) }
                HStack(alignment: .top, spacing: 10) {
                    Figure(value: "\(r.runs.count)", label: r.runs.count == 1 ? "Run" : "Runs")
                    Figure(value: Format.minutes(water), label: "Water")
                    Figure(value: pump.map { Format.minutes($0.pumpMin) } ?? "—", label: "Pump")
                    Figure(value: pump?.kwh.map { String(Int($0.rounded())) } ?? "—", unit: pump?.kwh == nil ? nil : "kWh", label: "Energy")
                }
                .padding(.horizontal, 18).padding(.bottom, 12)
                if r.crops.isEmpty {
                    Hairline()
                    Text(which == "today" ? "Nothing watered yet today." : "Nothing watered yesterday.")
                        .font(Theme.meta).foregroundStyle(Theme.muted).padding(18)
                } else {
                    let maxMin = max(1, r.crops.map(\.minutes).max() ?? 1)
                    ForEach(r.crops) { crop in
                        Hairline()
                        CropRow(crop: crop, fraction: Double(crop.minutes) / Double(maxMin))
                    }
                    if r.partial {
                        Hairline()
                        Text("Only the latest runs of this day are here. Pull down to refresh for the full day.")
                            .font(Theme.meta).foregroundStyle(Theme.muted)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                    } else if !r.dry.isEmpty {
                        Hairline()
                        Text("Not watered: " + r.dry.joined(separator: ", "))
                            .font(Theme.meta).foregroundStyle(Theme.muted)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                    }
                }
            }
            .modifier(Panel(padding: 0))
        }
    }
}

private struct CropRow: View {
    let crop: CropWater
    let fraction: Double

    var body: some View {
        let cut = crop.cutShort > 0
        HStack(spacing: 12) {
            if let art = crop.art {
                Image("art-\(art)").resizable().scaledToFit().frame(width: 34, height: 34)
            } else {
                Image(systemName: "spigot").font(.system(size: 14)).foregroundStyle(Theme.faint)
                    .frame(width: 34, height: 34).background(Theme.panel2, in: Circle())
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(crop.label).font(Theme.font(14.5, .bold, relativeTo: .subheadline)).foregroundStyle(Theme.text)
                Text((crop.sameMinutes ? crop.valves.map(\.name) : crop.valves.map { "\($0.name) \(Format.minutes($0.minutes))" })
                        .joined(separator: ", ") + (cut ? " · \(crop.cutShort) cut short" : ""))
                    .font(Theme.font(12, .regular, relativeTo: .caption)).foregroundStyle(cut ? Theme.warn : Theme.muted).lineLimit(1)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.panel3)
                        Capsule().fill(cut ? Theme.warn : Theme.brand).frame(width: max(4, g.size.width * fraction))
                    }
                }
                .frame(height: 5)
            }
            Text(Format.minutes(crop.minutes)).font(Theme.font(14, .bold, relativeTo: .subheadline).monospacedDigit())
                .foregroundStyle(Theme.ink).frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/* ---- irrigation: pump & power ---- */

struct PumpPowerCard: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        let c = store.irrigation
        let supply = Irrigation.supply(c)
        let pressure = Irrigation.pressure(c)
        if supply != nil || pressure != nil {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Pump & power").font(Theme.panelTitle).foregroundStyle(Theme.text)
                    Spacer()
                    // Its age, not a bare "at 23:58" that says nothing after midnight.
                    if let t = c.program?.at ?? c.lastUpdated {
                        Text(Water.ago(Date(timeIntervalSince1970: t / 1000), now: store.now)).font(Theme.small).foregroundStyle(Theme.faint)
                    }
                }
                HStack(alignment: .bottom, spacing: 24) {
                    if let s = supply, s.hasVoltage {
                        PhaseBars(volts: s.phaseV)
                    }
                    if let p = pressure {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.value).font(Theme.font(22, .bold, relativeTo: .title2).monospacedDigit()).foregroundStyle(Theme.ink)
                            Text("Inlet pressure").eyebrowStyle()
                            if let d = c.pressure.last?["detail"], let r = d.range(of: #"outlet [\d.]+ ?bar"#, options: .regularExpression) {
                                Text(String(d[r])).font(Theme.meta).foregroundStyle(Theme.muted)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                }
                if let s = supply {
                    FlowRow {
                        if s.hasVoltage {
                            if !s.powerOn { Tag(text: "No power", kind: .bad) }
                            else if s.missingPhase { Tag(text: "Phase missing · \(s.livePhases) of 3 live", kind: .bad) }
                            else if let imb = s.imbalancePct, imb >= Supply.imbalanceWarn { Tag(text: "\(Format.trim(imb))% phase imbalance", kind: .warn) }
                            else { Tag(text: "All three phases", kind: .on) }
                        }
                        if let d = s.pumpDrawing {
                            let at = s.at.map { " at \($0)" } ?? ""
                            Tag(text: d ? "Pump on\(at) · " + s.currentA.map { String(format: "%.1f", $0) }.joined(separator: " / ") + " A" : "Pump off\(at)",
                                kind: d ? .on : .plain)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel(padding: 18)
        }
    }
}
