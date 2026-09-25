import Foundation

/// Who sees the Squeak tab: the owner's own pager for their coding agents,
/// carried inside SNOF only because a free Apple ID allows three sideloaded
/// apps. It has nothing to do with the farm, and nobody else sees it.
///
/// This is a *visibility* rule, not the security boundary. The tab can do
/// nothing until the owner's Mac shows a pairing code, the phone scans it,
/// and the owner approves it on the Mac; after that, every reply is signed
/// by this phone's Secure Enclave and checked by the Mac. See Squeak's
/// docs/remote-channel.md.
enum SqueakAccess {
    static let ownerEmail = "sibhi.gv@gmail.com"

    static func shows(for email: String?) -> Bool {
        #if DEBUG
        // Screenshots of the demo, whose user is not the owner.
        if ProcessInfo.processInfo.arguments.contains("-squeak-tab") { return true }
        #endif
        return email?.trimmingCharacters(in: .whitespaces).lowercased() == ownerEmail
    }
}
