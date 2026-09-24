import SwiftUI
import SNOFCore

/* The web dashboard's tokens (dashboard/public/styles.css), carried over
 * value for value. The "Area workspace" direction the owner chose on
 * 2026-09-24: a cool slate canvas, white panels on hairlines, one tinted
 * pulse panel, big tabular numerals, uppercase eyebrows, Manrope throughout.
 * Colour only ever means something: brand green on/live, amber stale, muted
 * brick unavailable/error. Green is a fill or text, never a wash behind
 * anything. Dark is the light theme's complement: same slate hue, low
 * chroma, every text pair re-checked for 4.5:1. */
enum Theme {
    static let bg = dyn(light: 0xf5f7f7, dark: 0x0e1314)
    static let bar = dyn(light: 0xffffff, dark: 0x121819)
    static let panel = dyn(light: 0xffffff, dark: 0x141b1d)
    static let panel2 = dyn(light: 0xf0f4f4, dark: 0x1a2325)
    static let panel3 = dyn(light: 0xe6eced, dark: 0x212c2f)
    /// The farm pulse panel, and nothing else.
    static let tint = dyn(light: 0xeaf0ef, dark: 0x192326)
    static let tintLine = dyn(light: 0xd2e0df, dark: 0x2a3a3d)
    static let line = dyn(light: 0xdce4e4, dark: 0x233033)
    static let line2 = dyn(light: 0xc9d4d5, dark: 0x314145)
    static let text = dyn(light: 0x17252a, dark: 0xe3ebec)
    /// Big numerals.
    static let ink = dyn(light: 0x25393d, dark: 0xd2e0e2)
    static let muted = dyn(light: 0x56696e, dark: 0x8c9fa4)
    static let faint = dyn(light: 0x5b6e73, dark: 0x82969b)
    static let track = dyn(light: 0xdfe6e7, dark: 0x2a3639)

    /// The brand green, from the Sibhi Natural Orchards logo. Fills only:
    /// toggles, sliders, bars, chart lines, the live dot, primary buttons.
    static let brand = Color(UIColor(hex: 0x018843))
    /// Green text: the same hue, shaded per theme to clear 4.5:1 on every
    /// surface it sits on.
    static let on = dyn(light: 0x017a3c, dark: 0x01ae56)
    static let warn = dyn(light: 0x7a5a12, dark: 0xd3b06c)
    static let bad = dyn(light: 0xa0504a, dark: 0xdd8f87)

    static let rSm: CGFloat = 3
    static let rMd: CGFloat = 3
    static let rLg: CGFloat = 4

    /* ---- type: Manrope, scaled with Dynamic Type from a base size ---- */
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular,
                     relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("Manrope", size: size, relativeTo: style).weight(weight)
    }
    /// "Your farm, right now." — the page title.
    static let display = font(34, .bold, relativeTo: .largeTitle)
    static let pulseTitle = font(24, .bold, relativeTo: .title)
    static let panelTitle = font(16.5, .bold, relativeTo: .headline)
    static let rowTitle = font(15, .semibold, relativeTo: .subheadline)
    static let body = font(15, .regular, relativeTo: .body)
    static let meta = font(13, .medium, relativeTo: .footnote)
    static let small = font(12.5, .semibold, relativeTo: .caption)
    static let eyebrow = font(11.5, .bold, relativeTo: .caption)

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
    var fill: Color = Theme.panel
    var stroke: Color = Theme.line
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(stroke, lineWidth: 1))
    }
}

extension View {
    func panel(radius: CGFloat = Theme.rMd, padding: CGFloat = 14) -> some View {
        modifier(Panel(radius: radius, padding: padding))
    }
    /// The one tinted surface: the farm pulse.
    func tintPanel(padding: CGFloat = 18) -> some View {
        modifier(Panel(padding: padding, fill: Theme.tint, stroke: Theme.tintLine))
    }
    /// Uppercase, tracked, faint: where you are, above what you are looking at.
    func eyebrowStyle() -> some View {
        self.font(Theme.eyebrow).tracking(1.5).textCase(.uppercase).foregroundStyle(Theme.faint)
    }
}

/// "6" -> "06": two-digit counts read as a dashboard and line up.
func pad2(_ n: Int) -> String { n >= 0 && n < 10 ? "0\(n)" : "\(n)" }

enum Appearance: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// Follows the phone by default; light and dark are both first-class.
    var scheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}
