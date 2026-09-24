import Testing
import Foundation
@testable import SNOFCore

/// Shapes from the real farm (2026-09-25 snapshot): an inverter, Eufy
/// cameras with their own (unavailable) alarm panels and the station that
/// holds the real state, ACs and a printer switched off, switch modules.
@Suite struct SystemsTests {
    func e(_ domain: String, _ id: String, _ name: String, _ state: String?, device: String,
           area: String = "a1", unit: String? = nil) -> Entity {
        Entity(domain: domain, objectId: id, name: name, state: state, area: area, device: device, attrs: Attrs(unit: unit))
    }

    var farm: [Entity] {
        [
            e("sensor", "gw_pv", "GoodWe PV Power", "0", device: "gw", unit: "W"),
            e("sensor", "gw_today", "GoodWe Today's PV Generation", "0.0", device: "gw", unit: "kWh"),
            e("sensor", "gw_mode", "GoodWe Work Mode", "Wait Mode", device: "gw"),
            e("switch", "gw_limit", "GoodWe Grid export limit switch", "off", device: "gw"),
            e("alarm_control_panel", "home", "Sibhi Home", "armed_home", device: "station"),
            e("camera", "cow", "Cow Shed", "idle", device: "cow"),
            e("alarm_control_panel", "cow_p", "Cow Shed Sheep Shed", "unavailable", device: "cow"),
            e("binary_sensor", "cow_person", "Cow Shed Person detected", "off", device: "cow"),
            e("camera", "wh", "Warehouse", "unavailable", device: "wh"),
            e("alarm_control_panel", "wh_p", "Warehouse", "unavailable", device: "wh"),
            e("climate", "ac", "Abhi’s AC", "unavailable", device: "ac"),
            e("switch", "ac_disp", "Abhi’s AC Display", "unavailable", device: "ac"),
            e("camera", "p1s_cam", "P1S Camera", "unavailable", device: "p1s"),
            e("binary_sensor", "p1s_err", "P1S Print error", "unavailable", device: "p1s"),
            e("sensor", "ams_h", "P1S_AMS_1 Humidity", "unavailable", device: "ams"),
            e("media_player", "tv", "Samsung 5 Series (32)", "off", device: "tv"),
            e("switch", "ss4", "Storage Shed Smart Switch Switch 4", "on", device: "ss"),
            e("switch", "ss1", "Storage Shed Smart Switch Switch 1", "off", device: "ss"),
            e("switch", "fr1", "Desk Light", "unavailable", device: "fr"),
        ]
    }
    let names = ["gw": "GoodWe", "station": "Sibhi Home", "cow": "Cow Shed", "wh": "Warehouse", "ac": "Abhi’s AC",
                 "p1s": "P1S", "ams": "P1S_AMS_1", "tv": "Samsung 5 Series (32)", "ss": "Storage Shed Smart Switch", "fr": "Family Room"]

    @Test func classifiesByWhatDevicesAre() {
        let s = Systems.build(farm, names: names)
        #expect(Set(s.keys) == [.solar, .security, .climate, .printer, .media, .switches])
        #expect(s[.security]?.devices.count == 3)          // station + two cameras, not the printer's camera
        #expect(s[.printer]?.devices.map(\.name).sorted() == ["P1S", "P1S_AMS_1"])  // the AMS joins its printer
        #expect(s[.switches]?.devices.count == 2)
    }

    @Test func summariesSayItPlainly() {
        let s = Systems.build(farm, names: names)
        let solar = Systems.summary(s[.solar]!)
        #expect(solar.state == .rest && solar.line == "Resting" && solar.sub == "No sun right now")
        let sec = Systems.summary(s[.security]!)
        #expect(sec.line == "Armed · Home" && sec.cameras == 2 && sec.camerasOnline == 1 && sec.armed)
        #expect(Systems.summary(s[.climate]!).line == "All off")
        #expect(Systems.summary(s[.printer]!).line == "Off")
        let sw = Systems.summary(s[.switches]!)
        #expect(sw.line == "1 on" && sw.sub == "2 of 3 reachable")
    }

    @Test func solarGenerating() {
        var f = farm
        f[0] = e("sensor", "gw_pv", "GoodWe PV Power", "2486", device: "gw", unit: "W")
        f[1] = e("sensor", "gw_today", "GoodWe Today's PV Generation", "10.8", device: "gw", unit: "kWh")
        let solar = Systems.summary(Systems.build(f, names: names)[.solar]!)
        #expect(solar.state == .on && solar.line == "2.49 kW" && solar.sub == "10.8 kWh today")
    }

    @Test func attentionFlagsFaultsNotAppliances() {
        var i = Attention.Input()
        i.systems = Systems.build(farm, names: names)
        let items = Attention.items(i)
        let texts = items.map(\.text)
        #expect(texts.contains("Warehouse camera offline"))
        #expect(texts.contains("Family Room offline"))
        #expect(!texts.contains { $0.contains("AC") || $0.contains("P1S") || $0.contains("Samsung") })
        i.bridgeDown = true
        #expect(Attention.items(i).first?.text == "Farm box offline")   // worst first
    }

    @Test func shortNames() {
        let sw = farm[16]
        #expect(Systems.shortName(sw, deviceName: "Storage Shed Smart Switch") == "Switch 4")
        #expect(Systems.shortName(farm[18], deviceName: "Family Room") == "Desk Light")
    }

    @Test func cropsCountRunsNotValveRuns() {
        var c = IrrigationCache()
        c.timerLog = [
            ["at": "2026-09-24 21:43:45", "event": "Program · Coconut", "detail": "2m of 1h, stopped · 12 Coco 1, 15 Coco 2 · started by timer", "source": "timer"],
            ["at": "2026-09-24 19:02:05", "event": "Program · Coconut", "detail": "1h, finished · 12 Coco 1, 15 Coco 2 · 4 backwash pauses · started by timer", "source": "timer"],
            ["at": "2026-09-24 18:13:12", "event": "Program · Amla", "detail": "0m of 1h, stopped · no valves · started by timer", "source": "timer"],
            ["at": "2026-09-24 06:58:01", "event": "Program · Pomegranat", "detail": "30m, finished · 21 Pomegra · started by timer", "source": "timer"],
        ]
        c.valveNames = [["id": "12", "name": "12 Coco 1", "type": "Irrigation"], ["id": "15", "name": "15 Coco 2", "type": "Irrigation"],
                        ["id": "21", "name": "21 Pomegranate", "type": "Irrigation"], ["id": "5", "name": "5 Onion", "type": "Irrigation"],
                        ["id": "3", "name": "3 Backwash", "type": "Backwash"]]
        let r = Irrigation.crops(c, day: "2026-09-24")
        let coco = r.crops.first { $0.label == "Coconut" }
        #expect(coco?.minutes == 62 && coco?.cutShort == 1 && coco?.valves.count == 2)
        #expect(r.crops.contains { $0.label == "Pomegranate" && $0.art == "pomegranate" })
        #expect(r.dry == ["5 Onion"])                      // backwash is not an irrigation valve
        #expect(!r.crops.contains { $0.label.contains("Amla") })  // a program with no valves waters nothing
    }

    // ---- review findings (2026-09-25) ----

    @Test func aRunStillGoingIsNotCutShort() {
        var c = IrrigationCache()
        c.timeZone = "+05:30"
        c.timerLog = [["at": "2026-09-24 23:23:06", "event": "Program · Mango1", "detail": "22m of 1h, stopped · 16 Mango 1 · started by timer", "source": "timer"]]
        let zone = FarmTime.zone("+05:30")
        let start = FarmTime.date("2026-09-24 23:23:06", zone: zone)!
        let r = Irrigation.crops(c, day: "2026-09-24", now: start.addingTimeInterval(30 * 60))
        #expect(r.crops.first?.cutShort == 0, "22 minutes into a 1h run is not cut short")
        var i = Attention.Input(); i.irrigation = c; i.now = start.addingTimeInterval(30 * 60)
        #expect(!Attention.items(i).contains { $0.text.contains("stopped early") })
        i.now = start.addingTimeInterval(90 * 60)
        #expect(Attention.items(i).contains { $0.text == "1 run stopped early" }, "once its hour has passed it is")
    }

    @Test func failedNameLookupStillResolves() {
        var c = IrrigationCache()
        c.timerLog = [["at": "2026-09-24 19:02:05", "event": "Program · Coconut", "detail": "1h, finished · valve 12 · started by timer", "source": "timer"]]
        c.valveNames = [["id": "12", "name": "12 Coco 1", "type": "Irrigation"], ["id": "5", "name": "5 Onion", "type": "Irrigation"]]
        let r = Irrigation.crops(c, day: "2026-09-24")
        #expect(r.crops.first?.label == "Coconut" && r.crops.first?.valves.first?.name == "12 Coco 1")
        #expect(r.dry == ["5 Onion"], "12 was watered, whatever the log called it")
    }

    @Test func valvesInSeparateProgramsKeepTheirMinutes() {
        var c = IrrigationCache()
        c.timerLog = [
            ["at": "2026-09-24 16:32:19", "event": "Program · Mango2", "detail": "1h, finished · 17 Mango 2 · started by timer", "source": "timer"],
            ["at": "2026-09-24 15:17:01", "event": "Program · Mango1", "detail": "1h, finished · 16 Mango 1 · started by timer", "source": "timer"],
            ["at": "2026-09-24 12:00:00", "event": "Program · Mango1", "detail": "30m, finished · 16 Mango 1 · started by timer", "source": "timer"],
        ]
        let mango = Irrigation.crops(c, day: "2026-09-24").crops.first { $0.label == "Mango" }!
        #expect(mango.minutes == 90 && !mango.sameMinutes)
        #expect(mango.valves.map(\.minutes).sorted() == [60, 90])
    }

    @Test func partialDayIsFlagged() {
        var c = IrrigationCache()
        c.timerLog = (0..<32).map { i in ["at": "2026-09-24 \(String(format: "%02d", 23 - i / 2)):00:00", "event": "Program · X", "detail": "1h, finished · 12 Coco 1", "source": "timer"] }
        #expect(Irrigation.crops(c, day: "2026-09-24").partial, "32 rows all on the day: earlier runs may be missing")
        c.timerLog.removeLast()
        #expect(!Irrigation.crops(c, day: "2026-09-24").partial, "31 rows is the whole log")
    }

    @Test func aFanIsNeverASwitchModuleFault() {
        let fan = [e("fan", "f", "Fan", "unavailable", device: "fan"), e("switch", "fs", "Fan Sleep mode", "unavailable", device: "fan")]
        var i = Attention.Input()
        i.systems = Systems.build(fan, names: ["fan": "Fan"])
        #expect(Attention.items(i).isEmpty)
    }

    @Test func theAlarmStationGoingQuietIsFlagged() {
        var f = farm
        f[4] = e("alarm_control_panel", "home", "Sibhi Home", "unavailable", device: "station")
        var i = Attention.Input(); i.systems = Systems.build(f, names: names)
        #expect(Attention.items(i).contains { $0.text == "Alarm station offline" })
    }

    @Test func alarmStatesReadLikeTheWeb() {
        var f = farm
        f[4] = e("alarm_control_panel", "home", "Sibhi Home", "armed_custom_bypass", device: "station")
        #expect(Systems.summary(Systems.build(f, names: names)[.security]!).line == "Armed · Custom bypass")
    }
}
