import SwiftUI
import SNOFCore

/// A list of devices, not of the hundreds of readings they publish: a
/// printer is one line with a status, and opens to show its readings.
/// Filters and search still work on readings; a device appears when any of
/// its readings match, and opens itself when a filter is doing the choosing.
/// Mirrors devicesView() in app.js.
struct DevicesView: View {
    @Environment(FarmStore.self) private var store
    @State private var search = ""
    @State private var open: Set<String> = []

    var body: some View {
        @Bindable var store = store
        let all = store.entities
        let scoped = all.filter {
            switch store.deviceStatus {
            case .all: return true
            case .active: return !$0.isBad
            case .offline: return $0.isBad
            }
        }
        let domains = Dictionary(grouping: scoped, by: \.domain).mapValues(\.count)
            .sorted { $0.key < $1.key }
        let list = scoped.filter {
            (store.deviceDomain == nil || $0.domain == store.deviceDomain) &&
            $0.matches(search, areaName: store.areaName($0.area))
        }
        let groups = Sorting.byDevice(list, names: store.deviceNames).sorted { Sorting.natural($0.name, $1.name) }
        let whole = Dictionary(store.devices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let filtering = !search.isEmpty || store.deviceDomain != nil || store.deviceStatus == .offline

        Page(eyebrow: "Everything in a room", title: "All devices",
             subtitle: "\(store.devices.count) devices · \(all.count) readings") {
            Picker("Status", selection: $store.deviceStatus) {
                ForEach(StatusFilter.allCases) { f in
                    Text("\(f.label) \(count(f, all))").tag(f)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: store.deviceStatus) { _, _ in
                if let d = store.deviceDomain, !scoped.contains(where: { $0.domain == d }) { store.deviceDomain = nil }
            }

            if domains.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(domains, id: \.key) { d, n in
                            Chip(label: Entity.humanDomain(d).capitalized, count: n, on: store.deviceDomain == d) {
                                store.deviceDomain = store.deviceDomain == d ? nil : d
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
                .scrollClipDisabled()
            }

            if !store.firstSnapshot {
                LoadingBlock()
            } else if groups.isEmpty {
                EmptyBlock(title: "Nothing matches", message: "Try a different search term, or clear the filter.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { i, g in
                        if i > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                        DeviceGroupRow(group: g, whole: whole[g.id] ?? g,
                                       open: filtering || open.contains(g.id)) {
                            if open.contains(g.id) { open.remove(g.id) } else { open.insert(g.id) }
                        }
                    }
                }
                .modifier(Panel(padding: 0))
            }
        }
        .navigationTitle("All devices")
        .searchable(text: $search, prompt: "Name, entity id, state or room")
    }

    /// Devices with at least one reading in each state.
    private func count(_ f: StatusFilter, _ all: [Entity]) -> Int {
        switch f {
        case .all: return store.devices.count
        case .active: return Sorting.byDevice(all.filter { !$0.isBad }, names: [:]).count
        case .offline: return Sorting.byDevice(all.filter(\.isBad), names: [:]).count
        }
    }
}

struct DeviceGroupRow: View {
    @Environment(FarmStore.self) private var store
    let group: DeviceGroup
    let whole: DeviceGroup
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // No device id (an older bridge): the single reading stands alone.
            if group.entities.count == 1 && group.entities[0].device == nil {
                DeviceRow(entity: group.entities[0], withArea: true).padding(.horizontal, 16)
            } else {
                Button(action: toggle) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name).font(Theme.font(15, .bold, relativeTo: .subheadline)).tracking(-0.2)
                                .foregroundStyle(Theme.text).lineLimit(1)
                            Text("\(store.areaName(group.area)) · \(shown)").font(Theme.meta)
                                .foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        status
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.faint).rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .padding(.horizontal, 16).frame(minHeight: 62)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(open ? "Hides its readings" : "Shows its readings")
                if open {
                    RowList(items: group.entities, framed: false) { DeviceRow(entity: $0) }
                        .background(Theme.bg)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: open)
    }

    private var shown: String {
        group.entities.count == whole.entities.count
            ? "\(whole.entities.count) \(whole.entities.count == 1 ? "reading" : "readings")"
            : "\(group.entities.count) of \(whole.entities.count) readings"
    }

    @ViewBuilder private var status: some View {
        let down = whole.badCount
        if down == 0 { Tag(text: "All reporting", kind: .on) }
        else if down == whole.entities.count { Tag(text: "Offline", kind: .bad) }
        else { Tag(text: "\(down) of \(whole.entities.count) down", kind: .warn) }
    }
}

/// Looks 32 pt, hits 44 pt.
struct Chip: View {
    let label: String
    let count: Int
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label).font(Theme.font(13, .semibold, relativeTo: .footnote))
                Text("\(count)").font(Theme.font(12, .medium, relativeTo: .caption).monospacedDigit())
                    .foregroundStyle(on ? Theme.panel.opacity(0.75) : Theme.muted)
            }
            .foregroundStyle(on ? Theme.panel : Theme.text)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(on ? Theme.text : Theme.panel, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? Color.clear : Theme.line2, lineWidth: 1))
            .frame(minHeight: Theme.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
