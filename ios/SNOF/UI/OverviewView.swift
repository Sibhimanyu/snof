import SwiftUI
import SNOFCore

/// The web dashboard's Overview, in the same order a phone needs it: what is
/// wrong, how the farm is, the numbers, what you can switch, then the rooms.
/// At iPad width it splits into the web's two columns.
struct OverviewView: View {
    @Environment(FarmStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Page(eyebrow: Self.today(), title: "Your farm, right now.") {
            if !store.firstSnapshot {
                LoadingBlock()
            } else if sizeClass == .regular {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 14) { PulsePanel(); StatTiles(); AreasGlance() }
                    VStack(spacing: 14) { AttentionCard(); QuickControls() }.frame(width: 340)
                }
            } else {
                AttentionCard()
                PulsePanel()
                StatTiles()
                QuickControls()
                AreasGlance()
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

/* ---- farm pulse ---- */

/// One sentence a person would say, then the number of rooms. The only
/// tinted surface in the app.
struct PulsePanel: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        let areas = store.groupedAreas.count
        let s = Pulse.summary(devices: store.devices, areaCount: areas, bridge: store.bridgeStatus,
                              areaName: store.areaName)
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Farm pulse").eyebrowStyle()
                Text(s.title).font(Theme.pulseTitle).tracking(-0.9).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(s.body).font(Theme.font(14, .regular, relativeTo: .subheadline)).lineSpacing(3)
                    .foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 8) {
                Text(pad2(areas)).font(Theme.font(56, .heavy, relativeTo: .largeTitle).monospacedDigit())
                    .tracking(-3).foregroundStyle(s.quiet ? Theme.warn : Theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(areas == 1 ? "Area" : "Areas").eyebrowStyle()
            }
        }
        .tintPanel(padding: 20)
        .accessibilityElement(children: .combine)
    }
}

/* ---- the three numbers ---- */

struct StatTiles: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        // Counted in devices, not entities: one switched-off printer is one
        // thing to look at, not 67. Mirrors statTiles() in app.js.
        let devices = store.devices
        let bad = devices.filter(\.isOffline).count
        let on = devices.filter(\.isActive).count
        HStack(spacing: 8) {
            StatTile(value: pad2(devices.count - bad), of: pad2(devices.count), label: "Reporting") {
                store.showDevices(status: .active)
            }
            StatTile(value: pad2(on), label: "Active now") { store.showDevices(status: .active) }
            StatTile(value: pad2(bad), label: "Unavailable", tone: bad > 0 ? Theme.bad : Theme.ink) {
                store.showDevices(status: .offline)
            }
        }
    }
}

struct StatTile: View {
    let value: String
    var of: String? = nil
    let label: String
    var tone: Color = Theme.ink
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(value).font(Theme.font(26, .bold, relativeTo: .title2).monospacedDigit())
                        .tracking(-1.2).foregroundStyle(tone)
                    if let of {
                        Text("/\(of)").font(Theme.font(12, .semibold, relativeTo: .caption).monospacedDigit())
                            .foregroundStyle(Theme.faint)
                    }
                }
                Text(label).font(Theme.font(10.5, .bold, relativeTo: .caption2)).tracking(1)
                    .textCase(.uppercase).foregroundStyle(Theme.faint)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 16)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label): \(value)\(of.map { " of \($0)" } ?? "")")
    }
}

/* ---- attention ---- */

/// Which devices are down, and where — a to-do list, not an entity count.
struct AttentionCard: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        let devices = store.devices
        let troubled = Sorting.troubledDevices(devices, limit: .max)
        let dead = troubled.filter(\.isOffline).count
        let rooms = Pulse.troubledAreas(devices, name: store.areaName).map(store.areaName)
        let shown = Array(troubled.prefix(4))

        VStack(alignment: .leading, spacing: 0) {
            Button { store.showDevices(status: .offline) } label: {
                HStack(spacing: 18) {
                    Text(pad2(dead)).font(Theme.font(46, .bold, relativeTo: .largeTitle).monospacedDigit())
                        .tracking(-2.6).foregroundStyle(dead > 0 ? Theme.bad : Theme.faint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(dead == 0 ? "Every device is reporting" : dead == 1 ? "Device needs attention" : "Devices need attention")
                            .font(Theme.font(15.5, .bold, relativeTo: .headline)).foregroundStyle(Theme.text)
                        HStack(spacing: 5) {
                            Text(dead == 0 ? "Nothing needs a look right now."
                                 : rooms.prefix(2).joined(separator: " · ") + (rooms.count > 2 ? " · +\(rooms.count - 2)" : ""))
                                .lineLimit(1)
                            if dead > 0 { Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)) }
                        }
                        .font(Theme.meta).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18).padding(.vertical, 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(dead == 0)

            if dead > 0 {
                Rectangle().fill(Theme.line).frame(height: 1)
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, d in
                    if i > 0 { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 18) }
                    NavigationLink(value: AreaRoute(id: d.area)) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.name).font(Theme.font(14, .semibold, relativeTo: .subheadline))
                                    .foregroundStyle(Theme.text).lineLimit(1)
                                Text(store.areaName(d.area)).font(Theme.meta).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Tag(text: d.isOffline ? "Offline" : "\(d.badCount) of \(d.entities.count) down",
                                kind: d.isOffline ? .bad : .warn)
                        }
                        .padding(.horizontal, 18).frame(minHeight: 54)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if troubled.count > shown.count {
                    Rectangle().fill(Theme.line).frame(height: 1)
                    Button { store.showDevices(status: .offline) } label: {
                        HStack {
                            Text("\(troubled.count - shown.count) more not reporting")
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
        .modifier(Panel(padding: 0))
    }
}

/* ---- quick controls ---- */

struct QuickControls: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        let quick = Sorting.quickControls(store.entities)
        let controllable = store.entities.filter(\.isControllable).count
        TitledPanel(title: store.canControl ? "Quick controls" : "Controllable devices",
                    action: ("All devices", { store.showDevices(status: .active) })) {
            let gate = store.gate(.control)
            if !store.canControl || !gate.ok || !store.connected {
                ControlNote().padding(.horizontal, 18).padding(.vertical, 6)
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            if quick.shown.isEmpty {
                EmptyBlock(title: "Nothing to operate right now",
                           message: controllable > 0
                               ? "All \(controllable) switches, lights and fans are currently unavailable."
                               : "No switches, lights or fans are in a room yet.",
                           symbol: "power", framed: false)
            } else {
                ForEach(Array(quick.shown.enumerated()), id: \.element.id) { i, e in
                    if i > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                    DeviceCard(entity: e)
                }
                let more = quick.operable - quick.shown.count
                if more > 0 {
                    Rectangle().fill(Theme.line).frame(height: 1)
                    Button { store.showDevices(status: .active) } label: {
                        HStack {
                            Text("\(more) more operable \(more == 1 ? "device" : "devices")")
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
    }
}

/* ---- areas ---- */

struct AreasGlance: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        let areas = store.groupedAreas
        TitledPanel(title: "Areas at a glance",
                    action: (areas.count > 6 ? "View all \(areas.count)" : "View all", { store.selectedTab = .areas })) {
            if areas.isEmpty {
                EmptyBlock(title: "No areas yet",
                           message: "Assign devices to an area in Home Assistant and they will group themselves here.",
                           framed: false)
            } else {
                AdaptiveGrid(min: 150) {
                    ForEach(areas.prefix(6), id: \.id) { a in
                        NavigationLink(value: AreaRoute(id: a.id)) {
                            AreaCard(name: store.areaName(a.id), entities: a.entities)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
            }
        }
    }
}

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
