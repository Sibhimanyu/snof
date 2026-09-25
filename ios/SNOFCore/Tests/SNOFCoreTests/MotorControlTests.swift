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
             lock: Bool = false, now: Double = 1_000_000) -> String? {
        c.refusal("river", motor: m, current: current, isAdmin: admin, pending: pending, confirming: false,
                  lockLive: lock, nowMs: now)
    }

    @Test func parsesMetaAndNeedsBothSwitches() {
        let m = Parse.meta(["motorControl": ["enabled": true, "motors": ["river": true, "well-motor": false],
                                             "lastByMotor": ["river": 5000.0]]])
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
        #expect(MotorControl.question(main, action: "on") == "Start Wellmotor75HP? It sends water to the main farm.")
    }
}
