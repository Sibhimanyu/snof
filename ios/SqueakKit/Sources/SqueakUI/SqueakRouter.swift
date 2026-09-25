#if os(iOS)
import Combine
import SqueakCore
import SwiftUI

/// Where a link asks Squeak to go. The host app hands links to it; the
/// session list opens the session once it is in the snapshot — which, right
/// after a cold launch, can take a few seconds to arrive.
@MainActor
public final class SqueakRouter: ObservableObject {
    public static let shared = SqueakRouter()

    /// A Conductor session id waiting to be opened.
    @Published public private(set) var pendingSessionId: String?

    public func open(sessionId: String) { pendingSessionId = sessionId }

    /// Returns true and forgets the request when `url` was a Squeak link.
    @discardableResult
    public func handle(_ url: URL) -> Bool {
        guard let id = SqueakLink.sessionId(from: url) else { return false }
        open(sessionId: id)
        return true
    }

    func consume() { pendingSessionId = nil }
}
#endif
