import Testing
import Foundation
@testable import SNOFCore

/// What the apps refuse before a motor press; the motor_command function and
/// the RTDB rules decide, and are tested in dashboard/functions.
@Suite struct MotorControlTests {
    func motor(running: Bool?, vendor: String = "livesky") -> WaterMotor {
        var m = WaterMotor(id: "river", name: "River Motor", vendor: vendor)
        m.running = running
        return m
    }
    var armed: MotorControl {
        var c = MotorControl(); c.enabled = true; c.motors = ["river": true]; return c
    }
    func why(_ c: MotorControl, _ m: WaterMotor?, current: Bool = true, admin: Bool = true, pending: Bool = false,
             lock: Bool = false, online: Bool = true, now: Double = 1_000_000) -> String? {
        var c = c
        if lock { c.lockUntil = now + 60_000 }
        return c.refusal("river", motor: m, current: current, isAdmin: admin, pending: pending, confirming: false,
                         online: online, nowMs: now)
    }

    @Test func parsesMetaAndNeedsBothSwitches() {
        let m = Parse.meta(["motorControl": ["enabled": true, "motors": ["river": true, "well-motor": false],
                                             "lastByMotor": ["river": 5000.0], "lock": ["cmd": "c", "until": 9000.0]]])
        #expect(m.motorControl.lockUntil == 9000)
        #expect(m.motorControl.armed("river") && !m.motorControl.armed("well-motor") && !m.motorControl.armed("x"))
        #expect(m.motorControl.lastByMotor["river"] == 5000)
        #expect(!Parse.meta(["motorControl": ["enabled": false, "motors": ["river": true]]]).motorControl.armed("river"))
        #expect(!Parse.meta([:]).motorControl.armed("river"), "off by default")
    }

    @Test func refusesUntilEveryConditionHolds() {
        #expect(why(armed, motor(running: true)) == nil)
        #expect(why(armed, motor(running: true), admin: false)?.contains("admins") == true)
        #expect(why(MotorControl(), motor(running: true))?.contains("turned off") == true)
        #expect(why(armed, motor(running: true), pending: true) == "Sending…")
        #expect(why(armed, motor(running: true), lock: true)?.contains("still being confirmed") == true)
        #expect(why(armed, motor(running: true), online: false)?.contains("Offline") == true)
        #expect(why(armed, motor(running: true), current: false)?.contains("not current") == true)
        #expect(why(armed, motor(running: nil))?.contains("unknown") == true)
        #expect(why(armed, nil)?.contains("No reading") == true)
        var cool = armed; cool.lastByMotor = ["river": 1_000_000 - 30_000]
        #expect(why(cool, motor(running: true)) == "This motor changed moments ago. Wait 90s.")
        #expect(why(cool, motor(running: true), now: 1_000_000 + 91_000) == nil)
    }

    @Test func theQuestionSaysWhatHappens() {
        var r = motor(running: true); r.autoStart = true
        #expect(MotorControl.question(r, action: "off").contains("may start it again"))
        var drip = WaterMotor(id: "well-motor", name: "Well motor", vendor: "niagara"); drip.role = "drip"
        #expect(MotorControl.question(drip, action: "on").contains("drip program starts with it"))
        var main = WaterMotor(id: "wellmotor75hp", name: "Wellmotor75HP", vendor: "niagara"); main.role = "main-farm"
        #expect(MotorControl.question(main, action: "on") == "Start Wellmotor75HP? It sends water to Farm.")
    }

    @Test func zoneChangesNeedTheirOwnSwitchAndARunningProgram() {
        var c = armed; c.motors["well-motor"] = true
        var m = WaterMotor(id: "well-motor", name: "Well motor", vendor: "niagara")
        m.running = true; m.program = "P1"; m.zone = 3; m.zoneLeft = "00:30:00"
        m.liveAt = Date(timeIntervalSince1970: (1_000_000 - 10_000) / 1000)
        let z = { (c: MotorControl, m: WaterMotor, zone: Int) in
            c.zoneRefusal("well-motor", motor: m, zone: zone, current: true, isAdmin: true, pending: false,
                          confirming: false, nowMs: 1_000_000) }
        #expect(z(c, m, 5)?.contains("turned off") == true, "zones armed separately")
        c.zones = ["well-motor": true]
        #expect(z(c, m, 5) == nil)
        #expect(z(c, m, 3) == "It is already on zone 3.")
        var off = m; off.running = false
        #expect(z(c, off, 5)?.contains("No program") == true, "never starts a motor")
        var ending = m; ending.zoneLeft = "00:04:00"
        #expect(z(c, ending, 5)?.contains("under 5 minutes") == true)
        var quiet = m; quiet.liveAt = Date(timeIntervalSince1970: (1_000_000 - 200_000) / 1000)
        #expect(z(c, quiet, 5)?.contains("90 s") == true)
        var cool = c; cool.lastByMotor = ["well-motor": 1_000_000 - 10_000]
        #expect(z(cool, m, 5) == nil, "an on/off does not hold a zone change")
        cool.lastZoneByMotor = ["well-motor": 1_000_000 - 10_000]
        #expect(z(cool, m, 5)?.contains("moments ago") == true)
        #expect(cool.cooldownLeft("well-motor", nowMs: 1_000_000, action: "off") == nil, "stopping is never held")
        #expect(Parse.meta(["motorControl": ["enabled": true, "motors": ["well-motor": true],
                                             "zones": ["well-motor": true]]]).motorControl.zonesArmed("well-motor"))
    }
}
