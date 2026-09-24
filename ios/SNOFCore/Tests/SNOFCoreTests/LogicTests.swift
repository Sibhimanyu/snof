import Foundation
import XCTest
@testable import SNOFCore

final class LogicTests: XCTestCase {

    private func ent(_ domain: String, _ id: String, _ state: String?, name: String? = nil,
                     area: String? = nil, attrs: Attrs = Attrs()) -> Entity {
        Entity(domain: domain, objectId: id, name: name ?? id, state: state, area: area, attrs: attrs)
    }

    /* ---- parsing ---- */

    func testParsesTheRealFixture() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("SNOF/Resources/mock-farm-real.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let ents = Parse.entities(root?["entities"])
        XCTAssertEqual(ents.count, 698, "the production-shaped fixture")
        XCTAssertGreaterThan(ents.filter(\.isBad).count, 300)
        XCTAssertEqual(Parse.areas(root?["areas"]).count, 12)
        let reports = Parse.reports(root?["irrigation_reports"])
        XCTAssertEqual(reports.count, 3)
        XCTAssertGreaterThanOrEqual(reports[0].at, reports[1].at, "newest first")
    }

    func testMissingAreaIsUnassignedAndMissingNameFallsBack() {
        let e = Parse.entities(["sensor": ["x": ["state": "3"]]])
        XCTAssertEqual(e.first?.area, Area.unassigned)
        XCTAssertEqual(e.first?.name, "sensor.x")
    }

    func testBoolIsNotANumber() {
        XCTAssertNil(Parse.double(NSNumber(value: true)))
        XCTAssertEqual(Parse.bool(NSNumber(value: false)), false)
        XCTAssertNil(Parse.bool(NSNumber(value: 0)), "a 0 is not a false")
        XCTAssertEqual(Parse.string(NSNumber(value: 3.0)), "3")
        XCTAssertEqual(Parse.string(NSNumber(value: 2.08)), "2.08")
    }

    func testWrongShapesAreSkippedNotTrapped() {
        XCTAssertTrue(Parse.entities("nonsense").isEmpty)
        XCTAssertTrue(Parse.entities(["switch": 4, "light": ["a": "b"]]).isEmpty)
        XCTAssertNil(Parse.report(key: "k", 7))
        XCTAssertNil(Parse.section(["title": "no kind"]))
    }

    func testSparseArrayFromRTDB() {
        let rows = Parse.rows(["0": ["name": "a"], "2": ["name": "c"], "10": ["name": "k"]])
        XCTAssertEqual(rows.map { $0["name"] }, ["a", "c", "k"])
    }

    func testSectionLegendIsParsed() {
        let s = Parse.section(["kind": "lines", "unit": "V", "rows": [["at": "t", "v0": 240.5, "on": 1]],
                               "legend": [["key": "v0", "label": "Phase 1"], ["label": "no key"]]])
        XCTAssertEqual(s?.legend.map { $0["key"] }, ["v0"], "a legend entry without a key is dropped")
        XCTAssertEqual(s?.rows.first?["v0"], "240.5")
        XCTAssertEqual(s?.rows.first?["on"], "1")
    }

    func testBridgeControlAbsentIsNotFalse() {
        let m = Parse.meta(["bridge": ["lastSeen": 1, "heartbeatSeconds": 30]])
        XCTAssertNil(m.bridge?.control)
        XCTAssertNil(m.reportsEnabled)
        XCTAssertEqual(Parse.meta(["reports": ["enabled": false]]).reportsEnabled, false)
    }

    /* ---- state ---- */

    func testStates() {
        XCTAssertTrue(ent("switch", "a", "on").isOn)
        XCTAssertTrue(ent("switch", "a", "unavailable").isBad)
        XCTAssertTrue(ent("switch", "a", nil).isBad)
        XCTAssertTrue(ent("switch", "a", "").isBad)
        XCTAssertEqual(ent("switch", "a", "off").tone, .off)
        XCTAssertEqual(ent("sensor", "a", "31.4", attrs: Attrs(unit: "°C")).formattedState, "31.4 °C")
        XCTAssertEqual(ent("sensor", "a", "34.2", attrs: Attrs(unit: "%")).formattedState, "34.2%")
        XCTAssertEqual(ent("switch", "a", "on").formattedState, "ON")
    }

    func testLevel() {
        XCTAssertEqual(ent("light", "a", "on", attrs: Attrs(brightness: 128)).level, 50)
        XCTAssertEqual(ent("fan", "a", "on", attrs: Attrs(percentage: 66)).level, 66)
        XCTAssertNil(ent("switch", "a", "on").level)
        XCTAssertNil(ent("light", "a", "on").level, "no brightness attr, no slider")
    }

    func testQuickControlsNeverOfferADeadSwitch() {
        let all = [ent("switch", "a_dead", "unavailable", name: "A dead"),
                   ent("switch", "b_off", "off", name: "B off"),
                   ent("light", "c_on", "on", name: "C on"),
                   ent("lock", "gate", "locked", name: "Gate"),
                   ent("sensor", "t", "3", name: "T")]
        let q = Sorting.quickControls(all)
        XCTAssertEqual(q.shown.map(\.objectId), ["c_on", "b_off"])
        XCTAssertEqual(q.operable, 2)
    }

    func testDevicesAreCountedNotEntities() {
        func on(_ id: String, _ st: String, dev: String?) -> Entity {
            Entity(domain: "switch", objectId: id, state: st, area: "shed", device: dev)
        }
        let all = [on("p1", "unavailable", dev: "printer"), on("p2", "unknown", dev: "printer"),
                   on("s1", "on", dev: "shed_sw"), on("s2", "unavailable", dev: "shed_sw"),
                   on("loose", "off", dev: nil)]
        let d = Sorting.byDevice(all, names: ["printer": "Printer"])
        XCTAssertEqual(d.count, 3, "two devices plus one entity with no device id")
        XCTAssertEqual(d.first { $0.id == "printer" }?.name, "Printer")
        XCTAssertEqual(d.filter(\.isOffline).map(\.id), ["printer"], "partly reporting is not offline")
        XCTAssertEqual(d.filter(\.isActive).map(\.id), ["shed_sw"])
        XCTAssertEqual(Sorting.troubledDevices(d).map(\.id), ["printer", "shed_sw"], "fully offline first")
        XCTAssertEqual(Parse.entities(["switch": ["a": ["state": "on", "device": "abc"]]]).first?.device, "abc")
        XCTAssertEqual(Parse.devices(["abc": ["name": "Printer"]]), ["abc": "Printer"])
    }

    func testPulseSaysWhatIsTrue() {
        func dev(_ id: String, _ area: String, _ st: String) -> DeviceGroup {
            DeviceGroup(id: id, name: id, area: area,
                        entities: [Entity(domain: "switch", objectId: id, state: st, area: area, device: id)])
        }
        let name: (String) -> String = { ["cs": "Cold Store", "eo": "East Orchard", "ph": "Pump House"][$0] ?? $0 }
        let calm = (0..<22).map { dev("d\($0)", "ph", "off") } + [dev("x1", "cs", "unavailable"), dev("x2", "eo", "unavailable")]
        let s = Pulse.summary(devices: calm, areaCount: 6, bridge: .live, areaName: name)
        XCTAssertEqual(s.title, "Most areas are running normally.")
        XCTAssertEqual(s.body, "22 of 24 devices are reporting. Two need a closer look in Cold Store and East Orchard.")
        XCTAssertEqual(Pulse.summary(devices: calm, areaCount: 6, bridge: .stale(ageSeconds: 400), areaName: name).title,
                       "The bridge has gone quiet.", "a quiet bridge outranks the device count")
        let fine = (0..<3).map { dev("d\($0)", "ph", "on") }
        XCTAssertEqual(Pulse.summary(devices: fine, areaCount: 1, bridge: .live, areaName: name).body,
                       "All 3 devices across 1 area are answering, and three are on right now.")
        XCTAssertEqual(Pulse.list(["A", "B", "C", "D"]), "A, B and 2 others")
    }

    func testSinceReadsHomeAssistantTimestamps() {
        let now = ISO8601DateFormatter().date(from: "2026-09-24T04:31:52Z")!
        XCTAssertEqual(Format.since("2026-09-24T01:31:52.437263+00:00", now: now), "3h")
        XCTAssertEqual(Format.since("2026-09-20T04:31:52+00:00", now: now), "4 days")
        XCTAssertNil(Format.since("not a date", now: now))
        XCTAssertNil(Format.since("2026-09-25T00:00:00+00:00", now: now), "future stamps say nothing")
    }

    func testCloudIrrigationControlDoesNotNeedTheBridge() {
        let now = 1_800_000_000_000.0
        // No bridge at all, but the Cloud Function says it is on: open.
        XCTAssertTrue(Gate.evaluate(.irrigationControl, bridge: nil, cloudIrrigationControl: true,
                                    nowMs: now, skewMs: 0).ok)
        // Cloud switch off or absent: the bridge decides, exactly as before.
        let live = BridgeMeta(status: "online", lastSeen: now, heartbeatSeconds: 30)
        var on = live; on.irrigationControl = true
        XCTAssertTrue(Gate.evaluate(.irrigationControl, bridge: on, cloudIrrigationControl: false, nowMs: now, skewMs: 0).ok)
        XCTAssertFalse(Gate.evaluate(.irrigationControl, bridge: live, cloudIrrigationControl: nil, nowMs: now, skewMs: 0).ok)
        XCTAssertFalse(Gate.evaluate(.irrigationControl, bridge: nil, cloudIrrigationControl: false, nowMs: now, skewMs: 0).ok)
        // It never opens device control, which still needs the bridge.
        XCTAssertFalse(Gate.evaluate(.control, bridge: nil, cloudIrrigationControl: true, nowMs: now, skewMs: 0).ok)
        let meta = Parse.meta(["irrigationControl": ["enabled": true, "maxMinutes": 45]])
        XCTAssertEqual(meta.cloudIrrigationControl, true)
        XCTAssertEqual(meta.cloudIrrigationMaxMinutes, 45)
    }

    func testAreasInNaturalOrder() {
        let all = [ent("sensor", "b", "1", area: "z10"), ent("sensor", "c", "1", area: "z2")]
        let g = Sorting.groupByArea(all) { $0 == "z10" ? "Zone 10" : $0 == "z2" ? "Zone 2" : $0 }
        XCTAssertEqual(g.map(\.id), ["z2", "z10"])
    }

    func testOnlyEntitiesInARealRoomExist() {
        let areas = ["z2": Area(id: "z2", name: "Zone 2")]
        let all = [ent("switch", "a", "on", area: nil), ent("switch", "b", "on", area: "z2"),
                   ent("switch", "c", "on", area: "deleted_room"),
                   ent("switch", "d", "on", area: Area.unassigned)]
        XCTAssertEqual(Sorting.inRooms(all, areas: areas).map(\.objectId), ["b"])
        XCTAssertTrue(Sorting.inRooms(all, areas: [:]).isEmpty, "no areas loaded, nothing shown")
    }

    func testOperableDomainsFirstInAnArea() {
        let d = Sorting.domainsForArea([ent("binary_sensor", "a", "on"), ent("sensor", "b", "1"),
                                        ent("switch", "c", "off"), ent("fan", "d", "off")])
        XCTAssertEqual(d.map(\.domain), ["fan", "switch", "binary_sensor", "sensor"])
    }

    /* ---- gate ---- */

    func testGate() {
        let now = 1_000_000.0
        let live = BridgeMeta(status: "online", lastSeen: now - 5000, heartbeatSeconds: 30, control: true)
        XCTAssertTrue(Gate.evaluate(.control, bridge: live, nowMs: now, skewMs: 0).ok)

        XCTAssertFalse(Gate.evaluate(.control, bridge: nil, nowMs: now, skewMs: 0).ok)

        var off = live; off.control = false
        XCTAssertFalse(Gate.evaluate(.control, bridge: off, nowMs: now, skewMs: 0).ok)
        XCTAssertTrue(Gate.evaluate(.irrigation, bridge: off, nowMs: now, skewMs: 0).ok,
                      "control off does not block reports")
        XCTAssertTrue(Gate.evaluate(.irrigation, bridge: nil, nowMs: now, skewMs: 0).ok,
                      "reports run in a Cloud Function, not on the NUC")
        XCTAssertFalse(Gate.evaluate(.irrigation, bridge: live, reportsEnabled: false,
                                     nowMs: now, skewMs: 0).ok)

        var old = live; old.control = nil
        XCTAssertTrue(Gate.evaluate(.control, bridge: old, nowMs: now, skewMs: 0).ok, "absent is not false")

        var stale = live; stale.lastSeen = now - 76_000
        XCTAssertFalse(Gate.evaluate(.control, bridge: stale, nowMs: now, skewMs: 0).ok)
        XCTAssertEqual(BridgeStatus(stale, nowMs: now, skewMs: 0), .stale(ageSeconds: 76))

        // A wrong phone clock is corrected by the server offset.
        XCTAssertTrue(Gate.evaluate(.control, bridge: stale, nowMs: now, skewMs: -72_000).ok)

        var down = live; down.status = "offline"
        XCTAssertEqual(BridgeStatus(down, nowMs: now, skewMs: 0), .offline)
    }

    /* ---- commands: the app's own refusal cases ---- */

    func testCommandRefusals() {
        XCTAssertNil(Command.toggle(ent("lock", "gate", "locked"), on: false), "lock is never controllable")
        XCTAssertNil(Command.toggle(ent("cover", "door", "closed"), on: true))
        XCTAssertNil(Command.toggle(ent("alarm_control_panel", "a", "armed"), on: false))
        let spoofed = Entity(domain: "switch", objectId: "x", entityId: "lock.gate", state: "off")
        XCTAssertNil(Command.toggle(spoofed, on: true), "domain must be the one the entity_id names")
        let weird = Entity(domain: "switch", objectId: "X Y", entityId: "switch.X Y", state: "off")
        XCTAssertNil(Command.toggle(weird, on: true), "entity_id must match the rules' regex")
        XCTAssertNil(Command.level(ent("switch", "a", "on"), percent: 50), "no level on a switch")
    }

    func testCommandShapes() {
        let on = Command.toggle(ent("switch", "pump", "off"), on: true)
        XCTAssertEqual(on?.service, "turn_on")
        XCTAssertTrue(on?.dataPayload.isEmpty ?? false)
        XCTAssertEqual(Command.level(ent("light", "l", "on"), percent: 50)?.dataPayload, ["brightness": 128])
        XCTAssertEqual(Command.level(ent("fan", "f", "on"), percent: 140)?.dataPayload, ["percentage": 100])
        XCTAssertEqual(Command.level(ent("fan", "f", "on"), percent: 40)?.service, "set_percentage")
    }

    /* ---- irrigation ---- */

    func testReportValidation() {
        XCTAssertNil(IrrigationTypes.validate(type: "live_readings", from: "", to: ""))
        XCTAssertNotNil(IrrigationTypes.validate(type: "valves", from: "", to: "2026-09-01"))
        XCTAssertNotNil(IrrigationTypes.validate(type: "valves", from: "2026-09-05", to: "2026-09-01"))
        XCTAssertNotNil(IrrigationTypes.validate(type: "valves", from: "2026-07-01", to: "2026-09-01"))
        XCTAssertNil(IrrigationTypes.validate(type: "valves", from: "2026-09-01", to: "2026-09-03"))
        XCTAssertNotNil(IrrigationTypes.validate(type: "operate_pump", from: "", to: ""))
        XCTAssertEqual(IrrigationTypes.all.count, 12)
    }

    func testRuntime() {
        XCTAssertEqual(Format.runtimeMinutes("1h 20m"), 80)
        XCTAssertEqual(Format.runtimeMinutes("40m"), 40)
        XCTAssertEqual(Format.runtimeMinutes("15"), 15)
        XCTAssertEqual(Format.minutes(125), "2h 5m")
        XCTAssertEqual(Format.minutes(120), "2h")
    }

    func testInviteKey() {
        XCTAssertEqual(Invites.key(for: " New.Hire@Example.com "), "new,hire@example,com")
        XCTAssertNil(Invites.key(for: ""))
    }
}

final class ValveArtTests: XCTestCase {
    /// The farm's real valve names and types, from /farms/snof/irrigation on 2026-09-23.
    func testRealValveNames() {
        let cases: [(String, String, String?, String?)] = [
            ("1 Tank", "Fertilizer", "off", nil),
            ("2 BPump", "Booster Pump", "off", "motor-off"),
            ("2 BPump", "Booster Pump", "on", "motor-on"),
            ("3 Backwash", "Backwash", "on", "backwash"),
            ("4 Veg", "Irrigation", "on", "veg"),
            ("5 Onion", "Irrigation", "off", "onion"),
            ("6 Kulam", "Irrigation", "on", "kulam"),
            ("7 Grass", "Irrigation", "on", "grass"),
            ("8 House", "Irrigation", "on", "house"),
            ("9 Mulberry", "Irrigation", "on", "mulberry"),
            ("10 Spring", "Irrigation", "off", nil),
            ("11 Main", "Master1", "off", nil),
            ("12 Coco 1", "Irrigation", "on", "coconut"),
            ("13 Gova 1", "Irrigation", "on", "guava"),
            ("16 Mango 1", "Irrigation", "on", "mango"),
        ]
        for (name, type, status, want) in cases {
            XCTAssertEqual(ValveArt.key(name: name, type: type, status: status), want, name)
        }
    }

    func testUnknownGetsNothing() {
        XCTAssertNil(ValveArt.key(name: nil))
        XCTAssertNil(ValveArt.key(name: "Valve 7"))
        XCTAssertNil(ValveArt.key(name: "Mangrove"), "whole words only")
        XCTAssertEqual(ValveArt.key(name: "VEG-EAST"), "veg")
    }

    func testTimeline() {
        XCTAssertEqual(ValveArt.key(timelineSource: "motor"), "motor-on")
        XCTAssertEqual(ValveArt.key(timelineSource: "timer"), "timer")
        XCTAssertNil(ValveArt.key(timelineSource: "dcon"))
    }
}
