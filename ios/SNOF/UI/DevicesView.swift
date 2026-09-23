import SwiftUI
import SNOFCore

/// Everything, with a status segment and domain chips.
struct DevicesView: View {
    @Environment(FarmStore.self) private var store
    @State private var search = ""

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

        Page {
            Picker("Status", selection: $store.deviceStatus) {
                ForEach(StatusFilter.allCases) { f in
                    Text("\(f.label) \(count(f, all))").tag(f)
                }
            }
            .pickerStyle(.segmented)
            .padding(.top, 4)
            .onChange(of: store.deviceStatus) { _, _ in
                if let d = store.deviceDomain, !scoped.contains(where: { $0.domain == d }) { store.deviceDomain = nil }
            }

            if domains.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(domains, id: \.key) { d, n in
                            Chip(label: Entity.humanDomain(d), count: n, on: store.deviceDomain == d) {
                                store.deviceDomain = store.deviceDomain == d ? nil : d
                            }
                        }
                    }
                }
                .scrollClipDisabled()
            }

            Text("\(list.count) shown of \(all.count) entities").font(.footnote).foregroundStyle(Theme.muted)

            if !store.firstSnapshot {
                LoadingBlock()
            } else if list.isEmpty {
                EmptyBlock(title: "Nothing matches", message: "Try a different search term, or clear the filter.")
            } else {
                RowList(items: list) { DeviceRow(entity: $0, withArea: true) }
            }
        }
        .navigationTitle("All devices")
        .searchable(text: $search, prompt: "Name, entity id, state or room")
    }

    private func count(_ f: StatusFilter, _ all: [Entity]) -> Int {
        switch f {
        case .all: return all.count
        case .active: return all.filter { !$0.isBad }.count
        case .offline: return all.filter(\.isBad).count
        }
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
                Text(label).font(.footnote.weight(.medium))
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(on ? Theme.bg.opacity(0.75) : Theme.muted)
            }
            .foregroundStyle(on ? Theme.bg : Theme.text)
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
