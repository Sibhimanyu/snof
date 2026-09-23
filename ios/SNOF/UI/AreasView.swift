import SwiftUI
import SNOFCore

struct AreasView: View {
    @Environment(FarmStore.self) private var store
    @State private var search = ""

    var body: some View {
        let matching = store.entities.filter { $0.matches(search, areaName: store.areaName($0.area)) }
        let areas = Sorting.groupByArea(matching, name: store.areaName)
        Page {
            if !store.firstSnapshot {
                LoadingBlock()
            } else if areas.isEmpty {
                EmptyBlock(title: "Nothing matches", message: "Try a different search term.")
                    .padding(.top, 12)
            } else {
                Text("\(areas.count) areas · \(store.entities.count) entities")
                    .font(.footnote).foregroundStyle(Theme.muted)
                AdaptiveGrid(min: 160) {
                    ForEach(areas, id: \.id) { a in
                        NavigationLink(value: AreaRoute(id: a.id)) {
                            AreaCard(name: store.areaName(a.id), entities: a.entities)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Areas")
        .searchable(text: $search, prompt: "Search devices, states, rooms")
    }
}

/// One area, grouped by domain, operable domains first.
struct AreaDetailView: View {
    @Environment(FarmStore.self) private var store
    let areaId: String
    @State private var search = ""

    var body: some View {
        let inArea = store.entities.filter { $0.area == areaId }
        let list = inArea.filter { $0.matches(search, areaName: store.areaName(areaId)) }
        Page {
            if list.isEmpty {
                // An empty area and an area whose contents the search hid are
                // different problems, and only one of them is the user's to fix.
                if inArea.isEmpty {
                    EmptyBlock(title: "This area is empty",
                               message: "Nothing in Home Assistant is assigned to this area yet.")
                        .padding(.top, 12)
                } else {
                    EmptyBlock(title: "Nothing matches", message: "Nothing here matches that search.")
                        .padding(.top, 12)
                }
            } else {
                Text("\(list.count) devices · \(list.filter(\.isOn).count) active")
                    .font(.footnote).foregroundStyle(Theme.muted)
                ControlNote()
                ForEach(Sorting.domainsForArea(list), id: \.domain) { group in
                    SectionHead(symbol: Theme.symbol(group.domain), title: Entity.humanDomain(group.domain))
                    if Farm.controllable.contains(group.domain) {
                        AdaptiveGrid {
                            ForEach(group.entities) { DeviceCard(entity: $0, showArea: false) }
                        }
                    } else {
                        RowList(items: group.entities) { DeviceRow(entity: $0) }
                    }
                }
            }
        }
        .navigationTitle(store.areaName(areaId))
        .toolbarTitleDisplayMode(.inlineLarge)
        .searchable(text: $search, prompt: "Search this area")
    }
}
