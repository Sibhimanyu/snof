import XCTest
@testable import SNOFCore

final class UnreadTests: XCTestCase {
    func testASignedOutControllerSaysSo() {
        var c = IrrigationCache()
        c.program = CurrentProgram(); c.program?.at = 1_000
        c.controllerError = "DCON dashboard: Mobitech signed this session out (the account was signed in on another phone)"
        c.controllerErrorAt = 2_000
        XCTAssertEqual(Unread.controller(c), "Mobitech signed SNOF out")
        // A good read after the failure: it was read.
        c.program?.at = 3_000
        XCTAssertNil(Unread.controller(c))
    }

    func testWords() {
        XCTAssertEqual(Unread.words("DCON dashboard: the farm's bridge did not answer — is the NUC online?"), "The farm box did not answer")
        XCTAssertEqual(Unread.words("DCON nodes: HTTP 403"), "Mobitech did not answer")
        XCTAssertEqual(Unread.words("DCON dashboard: something odd"), "something odd")
    }

    func testParsedFromTheFarm() {
        let c = Parse.irrigation(["program": ["name": "", "running": false, "at": 1_000.0],
                                  "meta": ["errors": ["controller": ["error": "DCON dashboard: Mobitech signed this session out", "at": 2_000.0]]]])
        XCTAssertEqual(Unread.controller(c), "Mobitech signed SNOF out")
    }
}

final class MobitechSignedOutTests: XCTestCase {
    func cache(_ err: String, at: Double?) -> IrrigationCache {
        var c = IrrigationCache()
        c.readErrors["live_readings"] = err
        if let at { c.readErrorAts["live_readings"] = at }
        return c
    }
    let out = "DCON live_readings: Mobitech signed this session out"

    func testNewerErrorMeansSignedOut() {
        XCTAssertEqual(Unread.mobitechSignedOut(cache(out, at: 2_000), signedInAt: 1_000), 2_000)
    }
    func testOlderErrorIsIgnoredAfterSignIn() {
        XCTAssertNil(Unread.mobitechSignedOut(cache(out, at: 500), signedInAt: 1_000))
    }
    func testOtherErrorsAreNotSignedOut() {
        XCTAssertNil(Unread.mobitechSignedOut(cache("DCON live_readings: HTTP 500", at: 2_000), signedInAt: 1_000))
    }
    func testNoErrorsAndControllerError() {
        XCTAssertNil(Unread.mobitechSignedOut(IrrigationCache(), signedInAt: 1_000))
        var c = IrrigationCache(); c.controllerError = out; c.controllerErrorAt = 3_000
        XCTAssertEqual(Unread.mobitechSignedOut(c, signedInAt: 1_000), 3_000)
    }
}
