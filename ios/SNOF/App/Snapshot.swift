#if DEBUG
import SwiftUI
import UIKit

/* Debug-only: render the window to a PNG and quit, so screens can be reviewed
 * on a machine with no simulator and no screen-recording permission.
 *
 *   SNOF.app -demo -snapshot /tmp/out.png [-tab devices] [-area pump_house]
 *            [-account] [-snapshot-delay 3]
 *
 * Used by scripts/shoot.sh. Compiled out of Release builds. */
@MainActor
enum Snapshot {
    static var args: [String] { ProcessInfo.processInfo.arguments }

    static func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func prepare(_ store: FarmStore) {
        switch value("-tab") {
        case "areas": store.selectedTab = .areas
        case "devices": store.selectedTab = .devices
        case "irrigation": store.selectedTab = .irrigation
        default: break
        }
        if value("-status") == "offline" { store.deviceStatus = .offline }
    }

    static func runIfRequested() {
        guard let out = value("-snapshot") else { return }
        let delay = Double(value("-snapshot-delay") ?? "") ?? 3
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow ?? ($0 as? UIWindowScene)?.windows.first }).first
            else { exit(2) }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            let img = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try? img.pngData()?.write(to: URL(fileURLWithPath: out))
            exit(0)
        }
    }
}
#endif
