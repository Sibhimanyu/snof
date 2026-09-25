#if os(iOS)
import SqueakCore
import SwiftUI
import UIKit

/// DESIGN.md §3 and §11, as SwiftUI colours. Change DESIGN.md first.
enum Theme {
    private static func adaptive(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(UIColor { traits in UIColor(hex: traits.userInterfaceStyle == .light ? light : dark) })
    }

    static let duck = Color(UIColor(hex: 0xFCD02C))
    static let duckWing = Color(UIColor(hex: 0xFCC010))
    static let bg = adaptive(0x09090B, 0xF4F4F5)
    static let surface = adaptive(0x18181B, 0xFFFFFF)
    static let surfaceRaised = adaptive(0x27272A, 0xFFFFFF)
    static let line = Color(UIColor { $0.userInterfaceStyle == .light ? UIColor(white: 0, alpha: 0.08) : UIColor(white: 1, alpha: 0.08) })
    static let ink = adaptive(0xF4F4F5, 0x18181B)
    static let muted = adaptive(0xA1A1AA, 0x52525B)
    static let subtle = adaptive(0x71717A, 0x71717A)
    static let needsYou = adaptive(0xF87171, 0xDC2626)
    static let working = adaptive(0x22C55E, 0x15803D)
    static let done = adaptive(0x38BDF8, 0x0369A1)
    static let error = adaptive(0xA78BFA, 0x7C3AED)

    /// DESIGN.md §8.9: duck-yellow on dark, ink-black on light (yellow fails on white).
    static let primaryFill = adaptive(0xFCD02C, 0x18181B)
    static let primaryText = adaptive(0x18181B, 0xFFFFFF)

    static func stateColor(_ state: String) -> Color {
        switch state {
        case "awaiting_approval", "awaiting_input": return needsYou
        case "working": return working
        case "finished": return done
        case "error": return error
        default: return subtle
        }
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The state dot (DESIGN.md §8.1): pulses while working or needing you,
/// unless Reduce Motion is on.
struct StateDot: View {
    let state: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Theme.stateColor(state))
            .frame(width: 9, height: 9)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                let period: Double? = state == "working" ? 1.6 : (state.hasPrefix("awaiting") ? 1.0 : nil)
                if let period {
                    withAnimation(.easeInOut(duration: period / 2).repeatForever(autoreverses: true)) { dim = true }
                }
            }
            .accessibilityHidden(true)
    }
}

/// The one loud control (DESIGN.md §8.9).
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isEnabled ? Theme.primaryText : Theme.muted)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                isEnabled ? Theme.primaryFill.opacity(configuration.isPressed ? 0.8 : 1) : Theme.surfaceRaised,
                in: RoundedRectangle(cornerRadius: 8)
            )
    }
}
#endif
