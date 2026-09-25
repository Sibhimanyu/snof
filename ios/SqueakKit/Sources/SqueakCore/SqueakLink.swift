import Foundation

/// Links that open Squeak on one session: `<host-app-scheme>://squeak?s=<conductorSessionId>`.
///
/// Telegram cards carry them (through an https redirect page, since Telegram
/// buttons only take https links), so tapping "Open in Squeak" on a card
/// lands on that session. The scheme belongs to whichever app hosts Squeak;
/// this only reads the part that is Squeak's.
public enum SqueakLink {
    /// Conductor session ids are UUIDs; anything else is not ours.
    private static let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")

    public static func sessionId(from url: URL) -> String? {
        guard url.host == "squeak",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = components.queryItems?.first(where: { $0.name == "s" })?.value,
              (8...64).contains(id.count),
              id.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else { return nil }
        return id
    }
}
