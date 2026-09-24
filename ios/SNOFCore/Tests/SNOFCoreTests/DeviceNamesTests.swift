import Testing
import Foundation
@testable import SNOFCore

/// The real farm's serial-named devices (2026-09-25 snapshot): a Bambu P1S,
/// its AMS and external spool, and a Eufy station whose entity ids still say
/// "goats". Mirrors the replay checks in dashboard/preview/qa.mjs.
@Suite struct DeviceNamesTests {
    func e(_ domain: String, _ id: String, _ name: String, device: String, state: String = "unavailable") -> Entity {
        Entity(domain: domain, objectId: id, name: name, state: state, area: "a1", device: device)
    }

    @Test func tidiesSerialNames() {
        #expect(DeviceNames.tidy("P1S_01P09C510500118", objectIds: []) == "P1S printer")
        #expect(DeviceNames.tidy("P1S_01P09C510500118_AMS_1", objectIds: []) == "P1S AMS 1")
        #expect(DeviceNames.tidy("P1S_01P09C510500118_ExternalSpool", objectIds: []) == "P1S external spool")
        #expect(DeviceNames.tidy("X1C_00M09A350100222_AMS_2", objectIds: []) == "X1C AMS 2")
        #expect(DeviceNames.tidy("T8400P202040124D", objectIds: ["goats", "goats_motion_detected", "goats_crying_detected"]) == "Goats")
    }

    @Test func leavesEverythingElseAlone() {
        // Ids that do not agree, or that are the serial itself, say nothing better.
        #expect(DeviceNames.tidy("T8400P202040124D", objectIds: ["goats", "t8400p202040124d_battery"]) == "T8400P202040124D")
        #expect(DeviceNames.tidy("SONOFF1000123456", objectIds: ["sonoff1000123456_power"]) == "SONOFF1000123456")
        #expect(DeviceNames.tidy("T8400P202040124D", objectIds: []) == "T8400P202040124D")
        // One id is no shared prefix: it would be "Goats motion detected".
        #expect(DeviceNames.tidy("T8400P202040124D", objectIds: ["goats_motion_detected"]) == "T8400P202040124D")
        #expect(DeviceNames.tidy("HVAC_CONTROLLER01", objectIds: []) == "HVAC_CONTROLLER01")
        #expect(DeviceNames.tidy("Pump House Light", objectIds: ["pump_house_light"]) == "Pump House Light")
        #expect(DeviceNames.tidy("ABCDEFGHIJKL", objectIds: ["abc"]) == "ABCDEFGHIJKL")
    }

    @Test func rebasesEntityNamesWithoutDoubling() {
        let ents = [
            e("alarm_control_panel", "goats", "T8400P202040124D Goats", device: "eufy"),
            e("binary_sensor", "goats_motion_detected", "T8400P202040124D Motion detected", device: "eufy"),
            e("binary_sensor", "goats_debug_station", "T8400P202040124D Goats Debug (station)", device: "eufy"),
            e("sensor", "p1s_01p09c510500118_ams_1_humidity", "P1S_01P09C510500118_AMS_1 Humidity", device: "ams"),
            e("light", "desk", "Desk Light", device: "fr", state: "on"),
        ]
        let raw = ["eufy": "T8400P202040124D", "ams": "P1S_01P09C510500118_AMS_1", "fr": "Family Room"]
        let out = DeviceNames.apply(ents, names: raw)
        #expect(out.entities.map(\.name) == ["Goats", "Goats Motion detected", "Goats Debug (station)", "P1S AMS 1 Humidity", "Desk Light"])
        #expect(out.names == ["eufy": "Goats", "ams": "P1S AMS 1", "fr": "Family Room"])
        // The same entities otherwise: key, state, device and area untouched.
        #expect(out.entities.map(\.key) == ents.map(\.key))
        #expect(out.entities[4] == ents[4])
    }

    @Test func printerKeepsItsAddOnsAfterRenaming() {
        let ents = [
            e("binary_sensor", "p1s_err", "P1S_01P09C510500118 Print error", device: "p1s"),
            e("sensor", "ams_h", "P1S_01P09C510500118_AMS_1 Humidity", device: "ams"),
            e("sensor", "spool", "P1S_01P09C510500118_ExternalSpool External spool", device: "spool"),
        ]
        let raw = ["p1s": "P1S_01P09C510500118", "ams": "P1S_01P09C510500118_AMS_1", "spool": "P1S_01P09C510500118_ExternalSpool"]
        let tidy = DeviceNames.apply(ents, names: raw)
        let s = Systems.build(tidy.entities, names: tidy.names, raw: raw)
        #expect(s[.printer]?.devices.map(\.name).sorted() == ["P1S AMS 1", "P1S external spool", "P1S printer"])
        #expect(s[.other] == nil)
    }
}
