import XCTest
@testable import SNOFCore

final class ProgramsTests: XCTestCase {
    private let tree: [String: Any] = [
        "dcon": ["device": "SibhiSump", "firmware": "V9.2", "simExpiry": "2027-03-01", "shutdown": true],
        "program": ["name": "Coconut", "running": true, "at": 1_000.0, "next": ["name": "Mango"]],
        "programs": ["at": 5_000.0, "items": [
            "3": ["number": 3, "name": "Mango", "valves": [1, 2], "start": "06:00", "duration": "00:45", "days": "Daily", "enabled": false],
            "2": ["number": 2, "name": "Coconut", "valves": [12, 13], "start": "05:30", "duration": "01:00", "days": "Mon,Tue", "enabled": true],
        ]],
        "rain": ["at": 6_000.0, "today": 0.0, "week": 3.2, "last24h": 1.0, "yesterday": 0.5],
    ]

    func testParsesProgramsRainAndControllerFacts() {
        let c = Parse.irrigation(tree)
        XCTAssertEqual(c.programs?.items.map(\.number), [2, 3])
        XCTAssertEqual(c.programs?.at, 5_000)
        XCTAssertEqual(c.programs?.items.first?.valves, [12, 13])
        XCTAssertEqual(c.programs?.items.last?.enabled, false)
        XCTAssertEqual(c.rain?.week, 3.2)
        XCTAssertEqual(Programs.rainLine(c.rain!), "Rain today 0 mm · week 3.2 mm")
        XCTAssertEqual(c.controllerInfo, ControllerInfo(firmware: "V9.2", simExpiry: "2027-03-01", shutdown: true))
        XCTAssertEqual(Programs.simText("2027-03-01"), "1 Mar 2027")
    }

    func testOlderFarmWritesNone() {
        let c = Parse.irrigation(["dcon": ["device": "X"]])
        XCTAssertNil(c.programs); XCTAssertNil(c.rain); XCTAssertTrue(c.controllerInfo.isEmpty)
    }

    func testMarksAndConfirmText() {
        let c = Parse.irrigation(tree)
        let p = c.programs!.items
        XCTAssertEqual(Programs.mark(p[0], in: c), .running)
        XCTAssertEqual(Programs.mark(p[1], in: c), .next)
        XCTAssertEqual(Programs.confirm(p[0]), "Start Coconut (#2) for 1 h? It takes over from any run going now.")
        XCTAssertEqual(Programs.durationText(p[1]), "45 min")
    }

    func testMarksByNumberWhenDconCurrentIsThere() {
        var t = tree
        t["dcon"] = ["current": ["number": "3", "name": "Coconut", "running": true], "next": ["number": "2", "name": "Coconut"]]
        t["programs"] = ["at": 1.0, "items": ["2": ["number": 2, "name": "Coconut", "start": "", "days": ""],
                                               "3": ["number": 3, "name": "Coconut", "start": "", "days": ""]]]
        let c = Parse.irrigation(t)
        let p = c.programs!.items
        XCTAssertEqual(Programs.mark(p[0], in: c), .next)
        XCTAssertEqual(Programs.mark(p[1], in: c), .running)
    }

    func testCommandShape() {
        let cmd = IrrigationCommand.startProgram(2)!
        XCTAssertEqual(cmd.payload["action"] as? String, "program")
        XCTAssertEqual(cmd.payload["program"] as? Int, 2)
        XCTAssertNil(cmd.payload["valves"])
        XCTAssertNil(IrrigationCommand.startProgram(0)); XCTAssertNil(IrrigationCommand.startProgram(100))
        XCTAssertNil(IrrigationCommand.run(valves: [1], minutes: 5)?.payload["program"])
    }

    func testGateNeedsProgramStart() {
        var hb = BridgeMeta(status: "online", lastSeen: 1_000, heartbeatSeconds: 30)
        hb.irrigationControl = true
        func g() -> Gate { Gate.evaluate(.programStart, bridge: hb, nowMs: 2_000, skewMs: 0) }
        XCTAssertFalse(g().ok)
        hb.programStart = true
        XCTAssertTrue(g().ok)
        hb.irrigationControl = false
        XCTAssertFalse(g().ok)
    }

    func testNewReportTypes() {
        XCTAssertEqual(IrrigationTypes.label(for: "power_day"), "Power, whole day")
        XCTAssertEqual(IrrigationTypes.label(for: "pressure_day"), "Pressure, whole day")
        XCTAssertNil(IrrigationTypes.validate(type: "power_day", from: "", to: ""))
        XCTAssertEqual(Parse.meta(["bridge": ["programStart": true]]).bridge?.programStart, true)
    }
}
