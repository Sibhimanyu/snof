import SwiftUI
import SNOFCore

/* The web dashboard's tokens (dashboard/public/styles.css), carried over
 * value for value. Near-monochrome on purpose: greys carry the layout, and
 * colour appears only where it means something — green on/live, amber stale,
 * muted red unavailable/error. Never as decoration, never as the only signal. */
enum Theme {
    static let bg = dyn(light: 0xf4f4f3, dark: 0x111111)
    static let panel = dyn(light: 0xffffff, dark: 0x1a1a1a)
    static let panel2 = dyn(light: 0xf5f5f4, dark: 0x212121)
    static let panel3 = dyn(light: 0xebebe9, dark: 0x292929)
    static let line = dyn(light: 0xe2e2e0, dark: 0x272727)
    static let line2 = dyn(light: 0xcfcfcc, dark: 0x363636)
    static let text = dyn(light: 0x141414, dark: 0xe9e9e9)
    static let muted = dyn(light: 0x5b5b5b, dark: 0x9b9b9b)
    static let track = dyn(light: 0xdedede, dark: 0x2e2e2e)

    static let on = dyn(light: 0x3f6b47, dark: 0x7ba37f)
    static let warn = dyn(light: 0x7a5a12, dark: 0xc9a45f)
    static let bad = dyn(light: 0xa13a3a, dark: 0xc47f7f)

    static let rSm: CGFloat = 9
    static let rMd: CGFloat = 12
    static let rLg: CGFloat = 16

    /// Every functional target, per DESIGN.md.
    static let hit: CGFloat = 44

    private static func dyn(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    static func tone(_ t: StateTone) -> Color {
        switch t {
        case .on: return on
        case .unavailable: return bad
        case .off, .neutral: return muted
        }
    }

    /// SF Symbols per HA domain. Unknown domains fall back rather than break.
    static func symbol(_ domain: String) -> String {
        switch domain {
        case "switch": return "power"
        case "light": return "lightbulb"
        case "fan": return "fan"
        case "input_boolean": return "switch.2"
        case "sensor": return "gauge.with.dots.needle.33percent"
        case "binary_sensor": return "sensor"
        case "media_player": return "play.rectangle"
        case "climate": return "thermometer.medium"
        case "update": return "arrow.down.circle"
        case "device_tracker": return "location"
        case "lock": return "lock"
        case "cover": return "blinds.vertical.closed"
        case "camera": return "video"
        case "button", "input_button": return "button.programmable"
        case "number", "input_number": return "number"
        case "select", "input_select": return "list.bullet"
        case "event": return "bolt"
        case "weather": return "cloud.sun"
        case "automation": return "gearshape.2"
        case "script": return "scroll"
        case "scene": return "sparkles"
        case "water_heater", "valve": return "spigot"
        case "vacuum": return "fan.oscillation"
        case "siren": return "light.beacon.max"
        default: return "square.dashed"
        }
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

/// A flat panel with a 1px border. No shadows, no gradients.
struct Panel: ViewModifier {
    var radius: CGFloat = Theme.rMd
    var padding: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}

extension View {
    func panel(radius: CGFloat = Theme.rMd, padding: CGFloat = 14) -> some View {
        modifier(Panel(radius: radius, padding: padding))
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// Dark by default, as the brief asks; "system" follows the phone.
    var scheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}
