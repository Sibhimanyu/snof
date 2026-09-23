import Foundation
import Observation
import UIKit

/* SideStore finds new versions in the source it was given
 * (https://snof-ios.web.app/source.json) but only shows an Update button in
 * its own My Apps tab, and nobody opens that tab. This reads the same file
 * and puts one line in the app when a newer build exists, pointing at
 * SideStore. It never downloads or installs anything itself.
 *
 * Cost: one small JSON GET per foregrounding, at most once an hour. */
@MainActor
@Observable
final class UpdateCheck {
    private(set) var available: String?
    private var lastCheck: Date?

    private let sourceURL = (Bundle.main.object(forInfoDictionaryKey: "SNOFSourceURL") as? String)
        .flatMap { $0.isEmpty ? nil : URL(string: $0) }

    static var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    static var installedBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    func check() async {
        guard let sourceURL else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 3600 { return }
        lastCheck = Date()
        var req = URLRequest(url: sourceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let app = (root["apps"] as? [[String: Any]])?.first,
              let latest = (app["versions"] as? [[String: Any]])?.first,
              let build = Int(latest["buildVersion"] as? String ?? "")
        else { return }
        // Build numbers only ever go up (scripts/release.sh), so they are the
        // comparison; the marketing version is just the label.
        available = build > Self.installedBuild ? (latest["version"] as? String ?? "a new version") : nil
    }

    func openSideStore() {
        guard let url = URL(string: "sidestore://") else { return }
        UIApplication.shared.open(url)
    }
}
