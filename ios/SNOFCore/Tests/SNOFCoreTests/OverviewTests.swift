import Foundation
import XCTest
@testable import SNOFCore

/// The strings below are the ones dashboard/functions writes into
/// /irrigation (run_row, motor_sections, electricity_sections), copied from
/// production on 2026-09-24.
final class OverviewTests: XCTestCase {

    private let farm = FarmTime.zone("+05:30")

    private func cache() -> IrrigationCache {
        Parse.irrigation([
            "dcon": ["device": "SibhiSump", "timeZone": "+05:30"],
            "timerLog": [
                ["at": "2026-09-23 20:32:00", "event": "Program · Vegetable", "source": "timer",
                 "detail": "5m of 30m, stopped · 4 Veg, 6 Kulam · 1 backwash pause · started by timer · ended by U1"],
                ["at": "2026-09-23 18:57:08", "event": "Program · Coconut", "source": "timer",
                 "detail": "1h, finished · 12 Coco 1, 15 Coco 2 · 6 backwash pauses · started by timer"],
                ["at": "2026-09-22 22:45:06", "event": "Program · House", "source": "timer",
                 "detail": "1h, finished · 8 House, 9 Mulberry · 7 backwash pauses · started by timer"],
            ],
            "motorLog": [
                ["at": "2026-09-23 23:59:05", "event": "Pump day", "source": "motor",
                 "detail": "pump 16h 21m of 19h 42m with power · 77.89 kWh"],
                ["at": "2026-09-22 23:59:02", "event": "Pump day", "source": "motor",
                 "detail": "pump 13h 27m of 20h 13m with power · meter reset"],
            ],
            "electricity": [
                ["label": "Current", "value": "0 / 0 / 0", "unit": "A", "note": "pump is off"],
                ["label": "Phase voltage", "value": "254 / 249 / 12", "unit": "V", "note": "3% imbalance · at 22:24"],
            ],
            "pressure": [["at": "2026-09-23 18:10:00", "value": "2.4", "unit": "bar"]],
            "program": ["name": "Mango1", "kind": "Program", "running": true, "valves": "16 Mango 1",
                        "start": "2026-09-24 05:30:00", "lastSeen": "2026-09-24 06:05:00",
                        "faults": ["6 Kulam no signal"],
                        "next": ["name": "Coconut", "valves": "12 Coco 1, 15 Coco 2", "plannedMin": 60], "plannedMin": 60, "remainingMin": 25, "at": 1790223215792],
        ])
    }

    func testRunsReadBackFromTheLog() {
        let runs = Irrigation.runs(cache())
        XCTAssertEqual(runs.count, 3)
        let veg = runs[0]
        XCTAssertEqual(veg.name, "Vegetable")
        XCTAssertEqual(veg.kind, "Program")
        XCTAssertEqual(veg.deliveredMin, 5)
        XCTAssertEqual(veg.plannedMin, 30)
        XCTAssertFalse(veg.finished)
        XCTAssertEqual(veg.valves, "4 Veg, 6 Kulam")
        XCTAssertEqual(veg.amount, "5m of 30m")
        XCTAssertEqual(runs[1].deliveredMin, 60)
        XCTAssertTrue(runs[1].finished)
        XCTAssertEqual(runs[1].amount, "1h")
    }

    func testTheLatestDayAddsUp() throws {
        let day = try XCTUnwrap(Irrigation.latestDay(cache()))
        XCTAssertEqual(day.day, "2026-09-23")
        XCTAssertEqual(day.runs.count, 2)
        XCTAssertEqual(day.waterMin, 65)
        XCTAssertEqual(day.stopped, 1)
        XCTAssertEqual(day.pump?.pumpMin, 981)
        XCTAssertEqual(day.pump?.supplyMin, 1182)
        XCTAssertEqual(day.pump?.kwh, 77.89)
        XCTAssertEqual(day.programs.first?.name, "Coconut")
    }

    func testAMeterResetDayHasNoEnergy() {
        let days = Irrigation.pumpDays(cache())
        XCTAssertEqual(days.count, 2)
        XCTAssertNil(days[1].kwh)
        XCTAssertEqual(days[1].pumpMin, 807)
    }

    func testSupplySeesAMissingPhaseAndAnIdlePump() throws {
        let s = try XCTUnwrap(Irrigation.supply(cache()))
        XCTAssertEqual(s.phaseV, [254, 249, 12])
        XCTAssertTrue(s.powerOn)
        XCTAssertTrue(s.missingPhase)
        XCTAssertEqual(s.pumpDrawing, false)
        XCTAssertEqual(s.at, "22:24")
        XCTAssertEqual(s.imbalancePct, 3)
        XCTAssertEqual(Irrigation.pressure(cache())?.value, "2.4 bar")
    }

    func testProgramIsParsed() throws {
        let p = try XCTUnwrap(cache().program)
        XCTAssertTrue(p.running)
        XCTAssertEqual(p.remainingMin, 25)
        XCTAssertEqual(p.valves, "16 Mango 1")
        XCTAssertEqual(p.at, 1790223215792)
        XCTAssertEqual(p.lastSeen, "2026-09-24 06:05:00")
        XCTAssertEqual(p.faults, ["6 Kulam no signal"])
        XCTAssertEqual(p.next, NextProgram(name: "Coconut", valves: "12 Coco 1, 15 Coco 2", plannedMin: 60))
    }

    func testFarmTimeIsNotThePhonesTime() {
        // 2026-09-23 19:00 UTC is already the 24th on the farm.
        let now = ISO8601DateFormatter().date(from: "2026-09-23T19:00:00Z")!
        XCTAssertEqual(FarmTime.today(now, zone: farm), "2026-09-24")
        XCTAssertEqual(FarmTime.when("2026-09-24 00:10:00", now: now, zone: farm), "00:10")
        XCTAssertEqual(FarmTime.when("2026-09-23 20:32:00", now: now, zone: farm), "20:32 yesterday")
        XCTAssertEqual(FarmTime.when("2026-09-21 07:00:00", now: now, zone: farm), "21 Sep 07:00")
        XCTAssertEqual(FarmTime.dayLabel("2026-09-23", now: now, zone: farm), "Yesterday")
    }

    func testSolarIsFoundByWhatItIsCalled() throws {
        let dev = "inv"
        let ents = [
            Entity(domain: "sensor", objectId: "pv1_power", name: "GoodWe PV1 Power", state: "900", area: "store",
                   device: dev, attrs: Attrs(unit: "W", deviceClass: "power")),
            Entity(domain: "sensor", objectId: "pv_power", name: "GoodWe PV Power", state: "1854", area: "store",
                   device: dev, attrs: Attrs(unit: "W", deviceClass: "power")),
            Entity(domain: "sensor", objectId: "e_day", name: "GoodWe Today's PV Generation", state: "10.8",
                   area: "store", device: dev, attrs: Attrs(unit: "kWh", deviceClass: "energy")),
            Entity(domain: "sensor", objectId: "t", name: "GoodWe Inverter Temperature", state: "62.8",
                   area: "store", device: dev, attrs: Attrs(unit: "°C", deviceClass: "temperature")),
        ]
        let s = try XCTUnwrap(SolarGlance.find(ents))
        XCTAssertEqual(s.now?.objectId, "pv_power", "the total, not one string")
        XCTAssertEqual(s.watts, 1854)
        XCTAssertEqual(s.today?.state, "10.8")
        XCTAssertEqual(s.temperature?.state, "62.8")
        XCTAssertNil(SolarGlance.find([ents[3]]))
    }

    func testSecurityCountsWhatIsReporting() throws {
        let ents = [
            Entity(domain: "alarm_control_panel", objectId: "home", name: "Home", state: "armed_home", area: "a"),
            Entity(domain: "alarm_control_panel", objectId: "wh", name: "Warehouse", state: "unavailable", area: "a"),
            Entity(domain: "camera", objectId: "c1", name: "Cow Shed", state: "idle", area: "a"),
            Entity(domain: "camera", objectId: "c2", name: "Warehouse", state: "unavailable", area: "a"),
            Entity(domain: "binary_sensor", objectId: "m1", name: "Cow Shed Motion detected", state: "off", area: "a",
                   lastChanged: "2026-09-24T06:00:00+00:00"),
            Entity(domain: "binary_sensor", objectId: "p1", name: "Storeroom Person detected", state: "on", area: "a",
                   lastChanged: "2026-09-24T07:00:00+00:00"),
            Entity(domain: "binary_sensor", objectId: "d", name: "Cow Shed Debug (device)", state: "on", area: "a"),
        ]
        let g = try XCTUnwrap(SecurityGlance.find(ents))
        XCTAssertEqual(g.alarms.count, 1, "an unavailable panel is not a status")
        XCTAssertEqual(g.camerasDown, 1)
        XCTAssertEqual(g.sensors.count, 2, "debug flags are not motion")
        XCTAssertEqual(g.activeNow.map(\.objectId), ["p1"])
        XCTAssertEqual(g.latest?.objectId, "p1")
        XCTAssertEqual(SecurityGlance.alarmLabel("armed_home"), "Armed · home mode")
        XCTAssertEqual(SecurityGlance.alarmLabel("disarmed"), "Disarmed")
        XCTAssertEqual(SecurityGlance.sensorKind(ents[5]), "Person")
    }

    func testOnNowIsOnlyOperableThingsThatAreOn() {
        let ents = [
            Entity(domain: "switch", objectId: "b", name: "Light 2", state: "on", area: "car"),
            Entity(domain: "switch", objectId: "a", name: "Light 1", state: "off", area: "car"),
            Entity(domain: "light", objectId: "c", name: "Lamp", state: "unavailable", area: "car"),
            Entity(domain: "binary_sensor", objectId: "d", name: "Motion", state: "on", area: "car"),
        ]
        XCTAssertEqual(OnNow.entities(ents, areaName: { $0 }).map(\.objectId), ["b"])
    }

    func testIrrigationCommandsAreBounded() {
        XCTAssertEqual(IrrigationCommand.run(valves: [12, 15], minutes: 20)?.payload["valves"] as? String, "12,15")
        XCTAssertNil(IrrigationCommand.run(valves: [], minutes: 20))
        XCTAssertNil(IrrigationCommand.run(valves: [1, 2, 3, 4, 5, 6], minutes: 20))
        XCTAssertNil(IrrigationCommand.run(valves: [4, 4], minutes: 20))
        XCTAssertNil(IrrigationCommand.run(valves: [12], minutes: 61))
        XCTAssertNil(IrrigationCommand.run(valves: [12], minutes: 45, cap: 30), "the bridge's cap wins")
        XCTAssertEqual(IrrigationCommand.stop.payload.count, 1)
    }

    func testOnlyIrrigationValvesAreOffered() {
        var c = IrrigationCache()
        c.valveNames = [["id": "2", "name": "2 BPump", "type": "Booster Pump"],
                        ["id": "3", "name": "3 Backwash", "type": "Backwash"],
                        ["id": "15", "name": "15 Coco 2", "type": "Irrigation"],
                        ["id": "12", "name": "12 Coco 1", "type": "Irrigation"]]
        XCTAssertEqual(Irrigation.operableValves(c).map(\.id), [12, 15])
    }

    func testIrrigationControlNeedsAnExplicitYes() {
        let now = 1_000_000.0
        var hb = BridgeMeta(status: "online", lastSeen: now, heartbeatSeconds: 30, control: true)
        XCTAssertFalse(Gate.evaluate(.irrigationControl, bridge: hb, nowMs: now, skewMs: 0).ok, "nil is off")
        hb.irrigationControl = true
        XCTAssertTrue(Gate.evaluate(.irrigationControl, bridge: hb, nowMs: now, skewMs: 0).ok)
        XCTAssertFalse(Gate.evaluate(.irrigationControl, bridge: hb, nowMs: now + 200_000, skewMs: 0).ok, "stale bridge")
    }
}
