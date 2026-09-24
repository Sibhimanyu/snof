import XCTest
@testable import SNOFCore

final class MobitechTests: XCTestCase {
    func testNumbersAreTenDigits() {
        XCTAssertEqual(Mobitech.mobile("98765 43210"), "9876543210")
        XCTAssertEqual(Mobitech.mobile("+91 98765 43210"), "9876543210")
        XCTAssertNil(Mobitech.mobile("12345"))
    }

    func testDeviceTokenLooksLikeTheApps() {
        let t = Mobitech.deviceToken()
        XCTAssertTrue(t.hasSuffix("@ios"))
        XCTAssertTrue(t.contains(":APA91b"))
        XCTAssertEqual(t.count, 22 + 7 + 134 + 4)
        XCTAssertNotEqual(t, Mobitech.deviceToken(), "fresh every time")
    }

    func testRequestsMatchTheCapture() throws {
        let code = Mobitech.codeRequest(mobile: "9876543210")
        XCTAssertEqual(code.url?.absoluteString, "https://dcon.mobitechwireless.com/v1/otp/")
        XCTAssertEqual(String(data: code.httpBody!, encoding: .utf8), "{\"mobile\":\"919876543210\"}")
        XCTAssertEqual(code.value(forHTTPHeaderField: "content-type"), "application/x-www-form-urlencoded")

        let login = Mobitech.loginRequest(mobile: "9876543210", code: "123456", token: "abc:APA91b-x_y@ios")
        XCTAssertEqual(login.url?.absoluteString, "https://dcon.mobitechwireless.com/v1/http/?")
        XCTAssertEqual(String(data: login.httpBody!, encoding: .utf8),
                       "action=login&type=otp&otp=123456&mobile=9876543210&token=abc%3AAPA91b-x_y%40ios&product=DCON&app_id=com.mobitech.drip")
    }

    func testTheSessionIsWhatMobitechEchoes() {
        let tok = String(repeating: "a", count: 60) + "@ios"
        let ok = Data("{\"state\":\"ok\",\"id\":\"\(tok)\",\"name\":\"Sibhi\",\"uname\":\"sibhi\"}".utf8)
        XCTAssertEqual(try Mobitech.session(from: ok, sent: tok).get(), Mobitech.Session(token: tok, name: "Sibhi", user: "sibhi"))
        let bad = Data("{\"state\":\"failed\",\"msg\":\"Invalid OTP\"}".utf8)
        XCTAssertEqual(Mobitech.session(from: bad, sent: tok), .failure(.refused("Invalid OTP")))
        XCTAssertEqual(Mobitech.session(from: Data("<html>".utf8), sent: tok),
                       .failure(.refused("Mobitech's answer was not understood")))
    }
}
