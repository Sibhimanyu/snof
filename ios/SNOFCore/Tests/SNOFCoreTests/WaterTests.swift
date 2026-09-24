import Testing
import Foundation
@testable import SNOFCore

/// The shapes the water functions wrote on the first live pull (2026-09-24).
@Suite struct WaterTests {
    let water: [String: Any] = [
        "pulledAt": 1790270066755.0,
        "river": ["name": "River Motor", "vendor": "livesky", "running": true, "pending": false,
                  "connected": true, "power": true, "volts": [467, 457, 453], "amps": [10.1, 10.1],
                  "runMinutes": 42, "stopMinutes": 1, "autoStart": true, "signal": 25,
                  "reportedAt": "2026-09-24T22:44:20+05:30"],
        "motors": [
            "well-motor": ["name": "Well motor", "vendor": "niagara", "role": "drip", "group": "GROUP ONE",
                           "running": true, "requested": true, "program": "P1", "zone": 3,
                           "zoneLeft": "00:32:31", "amps": [8.7, 8.7], "pressureOut": 21.9,
                           "liveAt": "2026-09-24T22:34:16+05:30", "reportedAt": "2026-09-24T22:11:57+05:30"],
            "wellmotor75hp": ["name": "Wellmotor75HP", "vendor": "niagara", "role": "main-farm",
                              "group": "Water 7.5hp", "running": false, "requested": true,
                              "reportedAt": "2026-09-24T22:11:33+05:30"],
        ],
    ]
    let meta: [String: Any] = ["water": [
        "enabled": true,
        "livesky": ["ok": true, "error": "", "expires": 1790353787000.0, "signedInAt": 1790260000000.0],
        "niagara": ["ok": false, "error": "Niagara: HTTP 502"],
    ]]

    @Test func parsesTheChain() {
        let w = Parse.water(water, meta: meta)
        #expect(w.enabled)
        #expect(w.river?.running == true && w.river?.runMinutes == 42)
        #expect(w.river?.volts == [467, 457, 453])
        // The main-farm supply comes first.
        #expect(w.motors.map(\.id) == ["wellmotor75hp", "well-motor"])
        let zoned = w.motors[1]
        #expect(zoned.program == "P1" && zoned.zone == 3 && zoned.pressureOut == 21.9)
        #expect(zoned.lastReport == zoned.liveAt && zoned.liveAt != nil)
        #expect(w.niagara.ok == false && w.niagara.error.contains("502"))
    }

    @Test func pendingOnlyWhenAskedDiffersFromReported() {
        let w = Parse.water(water, meta: meta)
        #expect(w.motors[0].pendingText?.hasPrefix("Asked to start") == true)
        #expect(w.motors[1].pendingText == nil)
        #expect(w.river?.pendingText == nil)
    }

    @Test func offUnlessExplicitlyEnabled() {
        #expect(Parse.water(water, meta: nil).enabled == false)
        #expect(Parse.water(nil, meta: ["water": ["enabled": false]]).enabled == false)
    }

    @Test func liveskySessionKinds() {
        var s = LiveskySession()
        #expect(s.kind(nowMs: 0) == .none)
        s.expires = 1000
        #expect(s.kind(nowMs: 2000) == .expired)
        #expect(s.kind(nowMs: 500) == .ok)
        s.status.ok = false; s.status.error = "Livesky refused the session"
        #expect(s.kind(nowMs: 500) == .error)
    }

    @Test func formats() {
        #expect(WaterFormat.minutes(196) == "3 h 16 min")
        #expect(WaterFormat.minutes(42) == "42 min")
        #expect(WaterFormat.list([467, 457, 453], "V") == "467 · 457 · 453 V")
        #expect(WaterFormat.list([10.1, 10.1], "A") == "10.1 · 10.1 A")
        #expect(WaterFormat.list([], "A") == nil)
        #expect(WaterFormat.hms("00:32:31") == "32:31")
        #expect(WaterFormat.hms("01:04:28") == "1:04:28")
    }

    @Test func aFailedNiagaraPullIsNotCurrentAndDatesFromItsLastGoodRead() {
        // pulledAt is stamped on every pull; niagara.at only on a good read.
        var w = Parse.water(water, meta: meta)
        let pulled = Date(timeIntervalSince1970: 1790270066755.0 / 1000)
        w.niagara.at = pulled.addingTimeInterval(-3 * 3600).timeIntervalSince1970 * 1000
        w.niagara.ok = false
        #expect(!w.isCurrent(w.supply.first, now: pulled.addingTimeInterval(30)))
        #expect(w.readingDate(w.supply.first!) == Date(timeIntervalSince1970: w.niagara.at! / 1000))
        // A good read a minute ago is current, however old its last report.
        w.niagara.ok = true
        w.niagara.at = pulled.addingTimeInterval(-60).timeIntervalSince1970 * 1000
        #expect(w.isCurrent(w.supply.first, now: pulled))
    }

    @Test func onlyACurrentReadingFlows() {
        var w = Parse.water(water, meta: meta)
        #expect(!w.isCurrent(w.supply.first, now: Date(timeIntervalSince1970: 1790270126.755)), "the fixture's Niagara pull failed (502)")
        w.niagara.ok = true
        let pulled = Date(timeIntervalSince1970: 1790270066755.0 / 1000)   // 22:44:26, the river reported at 22:44:20
        #expect(w.isCurrent(w.river, now: pulled.addingTimeInterval(60)))
        // Niagara reports on change: 33 minutes since its last report is still its state.
        #expect(w.isCurrent(w.supply.first, now: pulled.addingTimeInterval(60)))
        // Nothing is current once the pulls stop.
        #expect(!w.isCurrent(w.river, now: pulled.addingTimeInterval(11 * 60)))
        #expect(!w.isCurrent(w.supply.first, now: pulled.addingTimeInterval(11 * 60)))
        // The starter going quiet while pulls continue: not current after 15 minutes.
        w.pulledAt = pulled.addingTimeInterval(20 * 60).timeIntervalSince1970 * 1000
        #expect(!w.isCurrent(w.river, now: pulled.addingTimeInterval(21 * 60)))
        #expect(w.readingDate(w.river!) == w.river?.lastReport)
        // An ended Livesky session: the river is not being read at all.
        w.pulledAt = pulled.timeIntervalSince1970 * 1000
        w.livesky.expires = pulled.addingTimeInterval(-60).timeIntervalSince1970 * 1000
        #expect(!w.isCurrent(w.river, now: pulled.addingTimeInterval(60)))
        // A failed Niagara pull.
        w.niagara.ok = false
        #expect(!w.isCurrent(w.supply.first, now: pulled.addingTimeInterval(60)))
    }
}
