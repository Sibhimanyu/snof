import XCTest
@testable import SNOFCore

final class AccessTests: XCTestCase {
    func testTiersOrderAndInvites() {
        let acl: [String: Any] = [
            "admins": ["a": true],
            "controllers": ["c": true],
            "viewers": ["a": true, "c": true, "v": true],
            "directory": ["a": ["email": "owner@x.com"], "c": ["email": "c@x.com", "name": "Cee"],
                          "v": ["email": "v@x.com"], "n": ["email": "n@x.com"]],
            "invites": ["new,person@x,com": ["tier": "control"], "v@x,com": ["tier": "view"]],
        ]
        let list = Parse.access(acl)
        XCTAssertEqual(list.people.map(\.tier), [.admin, .control, .view, .none])
        XCTAssertEqual(list.people[1].name, "Cee")
        // v@x.com has signed in already: its invite is the claim in flight, not pending.
        XCTAssertEqual(list.invites.map(\.email), ["new.person@x.com"])
        XCTAssertEqual(list.invites.first?.tier, .control)
    }

    func testInviteKeyRoundTrip() {
        let key = Invites.key(for: " First.Last@Example.com ")
        XCTAssertEqual(key, "first,last@example,com")
        XCTAssertEqual(Invites.email(forKey: key!), "first.last@example.com")
        XCTAssertTrue(Invites.isEmail("a@b.co"))
        XCTAssertFalse(Invites.isEmail("not an email"))
    }
}
