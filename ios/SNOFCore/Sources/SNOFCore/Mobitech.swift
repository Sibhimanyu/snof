import Foundation

/* Signing in to Mobitech, the way Mobitech's own iOS app does (captured
 * 2026-09-24), so valve commands have a live session that anyone can renew
 * from the app instead of a hand-copied token that dies. Mirrors the
 * dashboard's mobitechSendCode / mobitechSignIn in app.js.
 *
 *   1. POST /v1/otp/     body: {"mobile":"91XXXXXXXXXX"} sent as the whole
 *                        form-encoded body. Mobitech texts a code.
 *   2. POST /v1/http/?   action=login&type=otp&otp&mobile(10 digits)
 *                        &token=<device token>@ios&product=DCON
 *                        &app_id=com.mobitech.drip
 *                        -> {"state":"ok","id":"<the same token>", name, uname…}
 *
 * The phone talks to Mobitech directly: Mobitech refuses Google Cloud, so a
 * function could not. The number and the code are never stored. */
public enum Mobitech {
    public static let base = URL(string: "https://dcon.mobitechwireless.com")!

    /// "98765 43210", "+91 98765 43210" -> "9876543210"; nil unless 10 digits.
    public static func mobile(_ raw: String) -> String? {
        var d = raw.filter(\.isNumber)
        if d.count == 12, d.hasPrefix("91") { d.removeFirst(2) }
        return d.count == 10 ? d : nil
    }

    /// A device token shaped like the Mobitech app's (an FCM registration
    /// token with "@ios"): 22 url-safe characters, ":APA91b", 134 more.
    public static func deviceToken(random: (Int) -> [UInt8] = { n in
        var g = SystemRandomNumberGenerator()
        return (0..<n).map { _ in UInt8.random(in: 0...255, using: &g) }
    }) -> String {
        let abc = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        func pick(_ n: Int) -> String { String(random(n).map { abc[Int($0) % 64] }) }
        return "\(pick(22)):APA91b\(pick(134))@ios"
    }

    public static func codeRequest(mobile: String) -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent("v1/otp/"))
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        // Byte for byte what the app sends: a JSON object as the whole body.
        r.httpBody = Data("{\"mobile\":\"91\(mobile)\"}".utf8)
        r.timeoutInterval = 30
        return r
    }

    public static func loginRequest(mobile: String, code: String, token: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "\(base.absoluteString)/v1/http/?")!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        let fields: [(String, String)] = [("action", "login"), ("type", "otp"), ("otp", code),
                                          ("mobile", mobile), ("token", token), ("product", "DCON"),
                                          ("app_id", "com.mobitech.drip")]
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        r.httpBody = Data(fields.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)" }
            .joined(separator: "&").utf8)
        r.timeoutInterval = 30
        return r
    }

    public struct Session: Equatable, Sendable {
        public let token: String
        public let name: String
        public let user: String
    }

    public enum LoginError: Error, Equatable {
        case refused(String)
    }

    /// The session Mobitech created, or why it did not. The token commands
    /// use is the `id` it echoes (our own device token when it echoes it).
    public static func session(from data: Data, sent token: String) -> Result<Session, LoginError> {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.refused("Mobitech's answer was not understood"))
        }
        guard (obj["state"] as? String) == "ok" else {
            let why = (obj["msg"] ?? obj["message"] ?? obj["reason"]) as? String
            return .failure(.refused(why ?? "the code was not accepted"))
        }
        let id = (obj["id"] as? String) ?? token
        guard id.hasSuffix("@ios"), id.count >= 40 else {
            return .failure(.refused("Mobitech did not return a session"))
        }
        return .success(Session(token: id, name: String(((obj["name"] as? String) ?? "").prefix(64)),
                                user: String(((obj["uname"] as? String) ?? "").prefix(64))))
    }
}
