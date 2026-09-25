import Testing
import Foundation
@testable import SNOFCore

/// The farm's three EB lines, from the 2026-09-25 registry: a GoodWe on the
/// single-phase home line, a FoxESS ("V Guard") on the EV line, and the
/// controller's three phases for the free agricultural line.
@Suite struct PowerTests {
    func e(_ id: String, _ name: String, _ state: String, device: String, unit: String? = nil) -> Entity {
        Entity(domain: "sensor", objectId: id, name: name, state: state, area: "a1", device: device, attrs: Attrs(unit: unit))
    }

    func farm(foxState: String = "1.045") -> [Entity] {
        [
            e("pv_power", "GoodWe PV Power", "985", device: "gw", unit: "W"),
            e("on_grid_l1_voltage", "GoodWe On-grid L1 Voltage", "235.3", device: "gw", unit: "V"),
            e("today_s_pv_generation", "GoodWe Today's PV Generation", "0.9", device: "gw", unit: "kWh"),
            e("sibhi_orchards_pv_power", "Solar PV Power", foxState, device: "fox", unit: "kW"),
            e("sibhi_orchards_feed_in_power", "Solar Feed-in Power", foxState == "unavailable" ? "unavailable" : "1.003", device: "fox", unit: "kW"),
            e("sibhi_orchards_r_power", "Solar R Power", foxState == "unavailable" ? "unavailable" : "1.003", device: "fox", unit: "kW"),
            e("sibhi_orchards_r_voltage", "Solar R Voltage", foxState == "unavailable" ? "unavailable" : "233.8", device: "fox", unit: "V"),
            e("sibhi_orchards_energy_generated_today", "Solar Energy Generated Today", foxState == "unavailable" ? "unavailable" : "0.700000000000045", device: "fox", unit: "kWh"),
            e("sibhi_orchards_grid_consumption_today", "Solar Grid Consumption Today", "0.0", device: "fox", unit: "kWh"),
        ]
    }
    var cache: IrrigationCache {
        var c = IrrigationCache()
        c.electricity = [
            ["label": "Supply today", "value": "7h 10m"], ["label": "Pump today", "value": "7h 10m"],
            ["label": "Current", "unit": "A", "value": "9.4 / 9.1 / 9.3"],
            ["label": "Phase voltage", "note": "10.7% imbalance · at 08:16", "unit": "V", "value": "228 / 222 / 263"],
        ]
        return c
    }

    @Test func eachInverterOnItsOwnLine() {
        let sys = Systems.build(farm(), names: ["gw": "GoodWe", "fox": "Solar"])
        let lines = Power.build(systems: sys, irrigation: cache)
        #expect(lines.map(\.id) == ["home", "ev", "farm"])
        #expect(Power.status(lines[0]) == LineStatus(state: .on, figure: "985", unit: "W", sub: "0.9 kWh today"))
        #expect(Power.status(lines[1]) == LineStatus(state: .on, figure: "1.04", unit: "kW", sub: "0.7 kWh today"))
        #expect(lines[1].inverter?.grid == 233.8)
        #expect(Power.status(lines[2]) == LineStatus(state: .on, figure: "3", unit: "phases", sub: "pump running · 08:16"))
        #expect(lines[2].supplyToday == "7h 10m")
    }

    @Test func oneInverterDownIsNamedAndOnlyItsLine() {
        let sys = Systems.build(farm(foxState: "unavailable"), names: ["gw": "GoodWe", "fox": "Solar"])
        let lines = Power.build(systems: sys, irrigation: cache)
        #expect(Power.status(lines[0]).state == .on)
        #expect(Power.status(lines[1]).state == .offline)
        var i = Attention.Input()
        i.systems = sys
        i.irrigation = cache
        i.now = ISO8601DateFormatter().date(from: "2026-09-25T06:00:00Z")!   // 11:30 at the farm
        let items = Attention.items(i).map(\.text)
        #expect(items.contains("V-Guard inverter offline") && !items.contains("GoodWe inverter offline"))
    }

    @Test func freeSupplyOffIsNotAFault() {
        var c = IrrigationCache()
        c.electricity = [["label": "Phase voltage", "value": "0 / 0 / 0", "note": "at 23:10"], ["label": "Supply today", "value": "7h 10m"]]
        let farm = Power.build(systems: [:], irrigation: c)[2]
        #expect(Power.status(farm) == LineStatus(state: .rest, figure: "Power off", unit: "", sub: "7h 10m today · 23:10"))
    }

    @Test func aDeviceNameIsSaidOnce() {
        let out = DeviceNames.apply([e("sibhi_orchards_solar_power", "Solar Solar Power", "1", device: "fox")], names: ["fox": "Solar"])
        #expect(out.entities[0].name == "Solar Power")
    }
}
