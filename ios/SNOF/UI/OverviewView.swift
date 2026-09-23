import SwiftUI
import SNOFCore

/// Bridge and urgent state first, then what can be operated, then what is
/// not reporting, then rooms — the order DESIGN.md gives for mobile.
struct OverviewView: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        Page {
            if !store.firstSnapshot {
                LoadingBlock()
            } else {
                StatTiles(entities: store.entities)

                let quick = Sorting.quickControls(store.entities)
                let controllable = store.entities.filter(\.isControllable).count
                SectionHead(symbol: "power",
                            title: store.canControl ? "Quick controls" : "Controllable devices",
                            action: ("See all", { store.showDevices(status: .active) }))
                ControlNote()
                if quick.shown.isEmpty {
                    EmptyBlock(title: "Nothing to operate right now",
                               message: controllable > 0
                                   ? "All \(controllable) switches, lights and fans are currently unavailable."
                                   : "No switches, lights or fans are exposed by Home Assistant yet.",
                               symbol: "power")
                } else {
                    AdaptiveGrid {
                        ForEach(quick.shown) { DeviceCard(entity: $0) }
                    }
                    let more = quick.operable - quick.shown.count
                    if more > 0 {
                        Button("\(more) more operable \(more == 1 ? "device" : "devices")") {
                            store.showDevices(status: .active)
                        }
                        .font(.footnote.weight(.medium)).foregroundStyle(Theme.text)
                        .frame(minHeight: Theme.hit)
                    }
                }

                let offline = store.entities.filter(\.isBad)
                if !offline.isEmpty {
                    SectionHead(symbol: "exclamationmark.triangle", title: "Not reporting",
                                action: ("See all", { store.showDevices(status: .offline) }))
                    Note(text: "\(offline.count) \(offline.count == 1 ? "entity is" : "entities are") unavailable or unknown. Most likely a handful of integrations, not \(offline.count) separate faults.")
                    OfflineBreakdown(rows: Sorting.offlineBreakdown(store.entities))
                }

                SectionHead(symbol: "square.grid.2x2", title: "Areas",
                            action: ("See all", { store.selectedTab = .areas }))
                let areas = store.groupedAreas
                if areas.isEmpty {
                    EmptyBlock(title: "No areas yet",
                               message: "Assign entities to an area in Home Assistant and they will group themselves here.")
                } else {
                    AdaptiveGrid(min: 160) {
                        ForEach(areas.prefix(8), id: \.id) { a in
                            NavigationLink(value: AreaRoute(id: a.id)) {
                                AreaCard(name: store.areaName(a.id), entities: a.entities)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        // "SNOF", not the farm's full name: short enough to share the bar
        // with the account button instead of taking a row of its own.
        .navigationTitle("SNOF")
    }
}

struct AreaRoute: Hashable { let id: String }

/// The primary status band: is the bridge live, and how current is this?
struct BridgeBand: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        let status = store.bridgeStatus
        HStack(spacing: 10) {
            BridgePill(status: status)
            Text(detail(status)).font(.footnote).foregroundStyle(Theme.muted).lineLimit(2)
            Spacer(minLength: 0)
            if store.backend.isDemo { DemoBadge() }
        }
        .padding(.top, 4)
    }

    private func detail(_ s: BridgeStatus) -> String {
        switch s {
        case .live: return "Mirroring Home Assistant."
        case .stale(let age): return "No heartbeat for \(Format.age(age)). What you see may be out of date."
        case .offline: return "The bridge reported itself offline."
        case .unknown: return "The bridge has not published a heartbeat yet."
        }
    }
}

struct StatTiles: View {
    let entities: [Entity]

    var body: some View {
        let bad = entities.filter(\.isBad).count
        let on = entities.filter(\.isOn).count
        let areas = Set(entities.map(\.area)).count
        // "698 live entities" is a lie when 373 are not reporting. Lead with
        // how many are actually answering, and keep the total as context.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            StatTile(label: "Reporting", value: entities.count - bad, note: "of \(entities.count) mirrored")
            StatTile(label: "Areas", value: areas, note: "rooms and zones")
            StatTile(label: "Active now", value: on, note: "on, open or running", tone: on > 0 ? .on : .neutral)
            StatTile(label: "Needs a look", value: bad, note: bad > 0 ? "unavailable or unknown" : "everything reporting",
                     tone: bad > 0 ? .unavailable : .neutral)
        }
    }
}

struct StatTile: View {
    let label: String
    let value: Int
    let note: String
    var tone: StateTone = .neutral

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(Theme.muted)
            Text("\(value)").font(.system(.title, design: .default, weight: .semibold).monospacedDigit())
                .foregroundStyle(tone == .neutral ? Theme.text : Theme.tone(tone))
                .contentTransition(.numericText())
            Text(note).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        .accessibilityElement(children: .combine)
    }
}

/// 373 unavailable entities listed alphabetically is noise. Grouped by domain
/// it is a to-do list: which integration died, and how much of it.
struct OfflineBreakdown: View {
    @Environment(FarmStore.self) private var store
    let rows: [(domain: String, count: Int)]

    var body: some View {
        RowList(items: rows.map { BreakdownItem(domain: $0.domain, count: $0.count) }) { r in
            Button { store.showDevices(status: .offline, domain: r.domain) } label: {
                HStack(spacing: 12) {
                    DeviceIcon(domain: r.domain, tone: .unavailable, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Entity.humanDomain(r.domain).capitalized).font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.text)
                        Text("not reporting").font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Text("\(r.count)").font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.bad)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.muted)
                }
                .frame(minHeight: Theme.hit).padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(r.count) \(Entity.humanDomain(r.domain)) not reporting")
        }
    }
}

private struct BreakdownItem: Identifiable {
    let domain: String
    let count: Int
    var id: String { domain }
}

struct AreaCard: View {
    let name: String
    let entities: [Entity]

    var body: some View {
        let on = entities.filter(\.isOn).count
        let bad = entities.filter(\.isBad).count
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                DeviceIcon(domain: Sorting.dominantDomain(entities) ?? "default")
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.muted)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(name).font(.headline).foregroundStyle(Theme.text).lineLimit(2)
                Text("\(entities.count) \(entities.count == 1 ? "device" : "devices")")
                    .font(.caption).foregroundStyle(Theme.muted)
                // Own line, never hyphenated: on a narrow card the tags would
                // otherwise wrap mid-word.
                HStack(spacing: 6) {
                    if on > 0 { Tag(text: "\(on) active", kind: .on).fixedSize() }
                    if bad > 0 { Tag(text: "\(bad) offline", kind: .bad).fixedSize() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// One column on a phone, more on an iPad — cards, never a fixed layout.
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
            Text("Connecting to the farm…").font(.subheadline).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 80)
    }
}
