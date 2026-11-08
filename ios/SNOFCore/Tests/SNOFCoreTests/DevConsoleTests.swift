import XCTest
@testable import SNOFCore

final class DevConsoleTests: XCTestCase {
    let tok = String(repeating: "a", count: 148) + "@ios"

    func testPostWithHeaderAndFormBody() throws {
        let r = try DevConsole.parseCurl("""
        curl -X POST 'https://dcon.mobitechwireless.com/v1/http/' \\
          -H 'authorization: \(tok)' --data-raw 'action=dashboard&p=app&token_id=\(tok)&product=DCON'
        """)
        XCTAssertEqual(r.method, "POST"); XCTAssertEqual(r.path, "/v1/http/")
        XCTAssertTrue(r.auth); XCTAssertEqual(r.bodyType, "form")
        XCTAssertEqual(r.body, "action=dashboard&p=app&token_id={{token}}&product=DCON")
        XCTAssertFalse(DevConsole.curl(r).contains("aaaa"))
    }

    func testJSONBodyImpliesPost() throws {
        let r = try DevConsole.parseCurl(#"curl https://dcon.mobitechwireless.com/v1/http/ -H 'Content-Type: application/json' -d '{"action":"dashboard"}'"#)
        XCTAssertEqual(r.method, "POST"); XCTAssertEqual(r.bodyType, "json"); XCTAssertFalse(r.auth)
    }

    func testGetWithQueryAndTokenReplaced() throws {
        let enc = tok.replacingOccurrences(of: "@", with: "%40")
        let r = try DevConsole.parseCurl("curl 'https://dcon.mobitechwireless.com/v1/weather/cumulative/?device_id=X1&type=rain&t=\(enc)'")
        XCTAssertEqual(r.method, "GET"); XCTAssertEqual(r.path, "/v1/weather/cumulative/")
        XCTAssertEqual(r.query, "device_id=X1&type=rain&t={{token}}"); XCTAssertEqual(r.bodyType, "none")
    }

    func testWrongHostAndNotCurl() {
        XCTAssertThrowsError(try DevConsole.parseCurl("curl https://example.com/v1/http/"))
        XCTAssertThrowsError(try DevConsole.parseCurl("wget https://dcon.mobitechwireless.com/"))
    }

    func testRefusals() {
        func r(_ path: String = "/v1/http/", q: String = "", b: String = "") -> String? {
            DevConsole.refusal(DevRequest(method: "POST", path: path, query: q, body: b, bodyType: "form"))
        }
        XCTAssertNil(r(q: "action=dashboard"))
        XCTAssertNotNil(r("/v1/command/")); XCTAssertNotNil(r("/v1/otp/")); XCTAssertNotNil(r("/v1/version/"))
        XCTAssertNotNil(r(b: "action=login&type=otp")); XCTAssertNotNil(r(q: "action=logout&token_id=x"))
        XCTAssertNotNil(r(b: #"{"action": "login"}"#)); XCTAssertNotNil(r(b: "action%3Dlogout"))
        XCTAssertNotNil(r("/v1/Http/")); XCTAssertNotNil(r("/v2/http/"))
    }

    func testAllowList() {
        func r(_ q: String, path: String = "/v1/http/", b: String = "", t: String = "form") -> String? {
            DevConsole.refusal(DevRequest(method: "POST", path: path, query: q, body: b, bodyType: t))
        }
        for ok in ["action=dashboard", "action=dcon_node_details&type=get", "action=dcon_node&method=get_all_valve",
                   "action=dcon_timer&method=select", "action=logs&method=flow_log", "action=reports&type=anything",
                   "action=ferti&type=tank_log_web", "action=fertiSett&type=get", "action=getWliData", "action=cmd_status&random_no=1"] {
            XCTAssertNil(r(ok), ok)
        }
        for bad in ["", "action=dcon_node&method=set_valve", "action=dcon_timer&method=insert", "action=ferti&type=set",
                    "action=unknown", "action=dashboard&action=login", "action=logs&method=delete"] {
            XCTAssertEqual(r(bad), DevConsole.readsOnly, bad)
        }
        XCTAssertNil(r("device_id=1&type=rain", path: "/v1/weather/cumulative/"))
        XCTAssertNotNil(r("type=snow", path: "/v1/weather/cumulative/"))
        XCTAssertNotNil(r("action=dashboard", path: "/v1/other/"))
        XCTAssertNil(r("", b: #"{"action":"dashboard"}"#, t: "json"))
        XCTAssertNotNil(r("", b: #"{"action":"dcon_node","method":"set"}"#, t: "json"))
        XCTAssertNotNil(r("action=dashboard", b: "action=dcon_node&method=set"))
    }

    func testScrubbedBeforeHistory() {
        let t = String(repeating: "b", count: 60) + "@ios"
        let s = DevConsole.scrubbed(DevRequest(query: "token_id=\(t)", body: "x=\(t)"))
        XCTAssertEqual(s.query, "token_id={{token}}"); XCTAssertEqual(s.body, "x={{token}}")
    }

    func testRoundTripCurl() throws {
        let a = DevRequest(method: "POST", path: "/v1/http/", query: "x=1", body: "action=a&b='c'", bodyType: "form", auth: true)
        XCTAssertEqual(try DevConsole.parseCurl(DevConsole.curl(a)), a)
    }

    func testQueryRows() {
        let rows = DevConsole.queryRows("a=1&b=&c=x=y")
        XCTAssertEqual(rows.map(\.key), ["a", "b", "c"]); XCTAssertEqual(rows[2].value, "x=y")
        XCTAssertEqual(DevConsole.joinRows(rows), "a=1&b=&c=x=y")
    }

    func testJSONTree() throws {
        let n = try XCTUnwrap(JSONTree.parse(#"{"b":[1,true,null],"a":{"s":"x"}}"#))
        XCTAssertEqual(n.children.map { $0.key }, ["a", "b"])
        XCTAssertEqual(JSONTree.containerIDs(n).count, 3)
        XCTAssertEqual(JSONTree.rows(n, open: []).count, 1)
        XCTAssertEqual(JSONTree.rows(n, open: JSONTree.containerIDs(n)).count, 7)
        let kinds = JSONTree.rows(n, open: JSONTree.containerIDs(n)).map(\.kind)
        XCTAssertTrue(kinds.contains(.bool)); XCTAssertTrue(kinds.contains(.null)); XCTAssertTrue(kinds.contains(.number))
        XCTAssertNil(JSONTree.parse("not json"))
    }

    func testGateAndHistory() {
        let hb = { (on: Bool?) -> BridgeMeta in var b = BridgeMeta(status: "online", lastSeen: 1_000, heartbeatSeconds: 30); b.devConsole = on; return b }
        XCTAssertFalse(Gate.evaluate(.devConsole, bridge: hb(nil), nowMs: 1_000, skewMs: 0).ok)
        XCTAssertTrue(Gate.evaluate(.devConsole, bridge: hb(true), nowMs: 1_000, skewMs: 0).ok)
        var h: [DevConsole.HistoryEntry] = []
        for i in 0..<25 { h = DevConsole.pushHistory(h, .init(at: Double(i), request: DevRequest(), result: DevResult(status: 200, ms: 1, json: false, body: "", truncated: false))) }
        XCTAssertEqual(h.count, 20); XCTAssertEqual(h.first?.at, 24)
    }
}
