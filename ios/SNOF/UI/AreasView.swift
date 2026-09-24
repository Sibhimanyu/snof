import SwiftUI
import SNOFCore

struct AreasView: View {
    @Environment(FarmStore.self) private var store
    @State private var search = ""

    var body: some View {
        let matching = store.entities.filter { $0.matches(search, areaName: store.areaName($0.area)) }
        let areas = Sorting.groupByArea(matching, name: store.areaName)
        Page(title: "Rooms") {
            RoomsSwitch()
            SearchField(text: $search, prompt: "Search devices, rooms, states")
            if !store.firstSnapshot {
                LoadingBlock()
            } else if areas.isEmpty {
                EmptyBlock(title: "Nothing matches", message: "Try a different search term.")
            } else {
                AdaptiveGrid(min: 150) {
                    ForEach(areas, id: \.id) { a in
                        NavigationLink(value: AreaRoute(id: a.id)) {
                            AreaCard(name: store.areaName(a.id), entities: a.entities)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Rooms")
    }
}

/// One area: a titled panel per kind of thing in it, operable kinds first.
struct AreaDetailView: View {
    @Environment(FarmStore.self) private var store
    let areaId: String
    @State private var search = ""

    var body: some View {
        let inArea = store.entities.filter { $0.area == areaId }
        let list = inArea.filter { $0.matches(search, areaName: store.areaName(areaId)) }
        let devices = Sorting.byDevice(inArea, names: store.deviceNames)
        let index = store.deviceSystems
        let down = devices.filter(\.isOffline)
        let fault = down.filter { Systems.offlineIsFault($0, system: index[$0.id]) }.count
        Page(title: store.areaName(areaId),
             subtitle: "\(devices.count) \(devices.count == 1 ? "device" : "devices")"
                + (fault > 0 ? " · \(fault) offline" : "") + (down.count - fault > 0 ? " · \(down.count - fault) off" : "")) {
            SearchField(text: $search, prompt: "Search this room")
            if list.isEmpty {
                // An empty area and an area whose contents the search hid are
                // different problems, and only one of them is the user's to fix.
                if inArea.isEmpty {
                    EmptyBlock(title: "This area is empty",
                               message: "Nothing in Home Assistant is assigned to this area yet.")
                } else {
                    EmptyBlock(title: "Nothing matches", message: "Nothing here matches that search.")
                }
            } else {
                if store.canControl && !store.gate(.control).ok { ControlNote() }
                // A wholly offline device shows nothing but "unavailable":
                // one line at the end instead (a switched-off printer was 56
                // dead rows). A search still finds its readings.
                let deadIDs = Set(devices.filter(\.isOffline).map(\.id))
                // Settings (power-on behaviour, timers, firmware notices) stay
                // out unless searched for, as on the system pages.
                let shown = search.isEmpty
                    ? list.filter { !deadIDs.contains($0.device ?? $0.key) && !$0.isBackstage } : list
                ForEach(Sorting.domainsForArea(shown), id: \.domain) { group in
                    TitledPanel(title: Entity.sectionTitle(group.domain), count: group.entities.count) {
                        if Farm.controllable.contains(group.domain) {
                            ForEach(Array(group.entities.enumerated()), id: \.element.id) { i, e in
                                if i > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                                DeviceCard(entity: e, showArea: false)
                            }
                        } else {
                            RowList(items: group.entities, framed: false) { DeviceRow(entity: $0, showDomain: false) }
                        }
                    }
                }
                if search.isEmpty {
                    let deadDevices = devices.filter(\.isOffline)
                    let faults = deadDevices.filter { Systems.offlineIsFault($0, system: index[$0.id]) }
                    let off = deadDevices.filter { !Systems.offlineIsFault($0, system: index[$0.id]) }
                    if !faults.isEmpty { Note(text: "Offline: " + faults.map(\.name).joined(separator: ", "), tone: .warn) }
                    if !off.isEmpty { Note(text: "Switched off: " + off.map(\.name).joined(separator: ", ")) }
                }
            }
        }
        .navigationTitle(store.areaName(areaId))
        .toolbarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
    }
}

/// Rooms or the same devices as one list: one tab, a switch at the top.
struct RoomsSwitch: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Picker("Show", selection: $store.roomsMode) {
            Text("Rooms").tag(RoomsMode.rooms)
            Text("All devices").tag(RoomsMode.devices)
        }
        .pickerStyle(.segmented)
        .sensoryFeedback(.selection, trigger: store.roomsMode)
    }
}
