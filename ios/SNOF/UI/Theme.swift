import SwiftUI
import SNOFCore

/* The web dashboard's tokens (dashboard/public/styles.css), carried over
 * value for value. The "Area workspace" direction the owner chose on
 * 2026-09-24: a cool slate canvas, white panels on hairlines, one tinted
 * pulse panel, big tabular numerals, uppercase eyebrows, Manrope throughout.
 * Colour only ever means something: brand green on/live, amber stale, muted
 * brick unavailable/error. Green is a fill or text, never a wash behind
 * anything. Dark is Apple's neutral system dark (owner, 2026-09-24: no
 * charcoal-green): black, #1c1c1e, #2c2c2e, white text, no hue in the greys.
 *
 * Shape and depth follow iOS (owner, 2026-09-24: "a soft, elegant iPhone
 * feel" instead of sharp corners): cards are 22pt continuous rounds on a
 * whisper of shadow with a near-invisible edge, controls are 12pt, and the
 * bars are the system's frosted material. Mirrors styles.css. */
enum Theme {
    static let bg = dyn(light: 0xf5f7f7, dark: 0x000000)
    static let bar = dyn(light: 0xffffff, dark: 0x1c1c1e)
    static let panel = dyn(light: 0xffffff, dark: 0x1c1c1e)
    static let panel2 = dyn(light: 0xf0f4f4, dark: 0x2c2c2e)
    static let panel3 = dyn(light: 0xe6eced, dark: 0x3a3a3c)
    /// The farm pulse panel, and nothing else.
    static let tint = dyn(light: 0xeaf0ef, dark: 0x242426)
    static let tintLine = dyn(light: 0xd2e0df, dark: 0x38383a)
    static let line = dyn(light: 0xdce4e4, dark: 0x38383a)
    static let line2 = dyn(light: 0xc9d4d5, dark: 0x48484a)
    static let text = dyn(light: 0x17252a, dark: 0xffffff)
    /// Big numerals.
    static let ink = dyn(light: 0x25393d, dark: 0xf2f2f7)
    static let muted = dyn(light: 0x56696e, dark: 0xa1a1a6)
    static let faint = dyn(light: 0x5b6e73, dark: 0x8e8e93)
    static let track = dyn(light: 0xdfe6e7, dark: 0x39393d)

    /// The brand green, from the Sibhi Natural Orchards logo. Fills only:
    /// toggles, sliders, bars, chart lines, the live dot, primary buttons.
    static let brand = Color(UIColor(hex: 0x018843))
    /// Green text: the same hue, shaded per theme to clear 4.5:1 on every
    /// surface it sits on.
    static let on = dyn(light: 0x017a3c, dark: 0x01ae56)
    static let warn = dyn(light: 0x7a5a12, dark: 0xe3b95c)
    static let bad = dyn(light: 0xa0504a, dark: 0xff8a80)

    /// Buttons, fields, inner tiles (web --r).
    static let rSm: CGFloat = 12
    /// Cards: every panel, block and area card (web --r-xl).
    static let rMd: CGFloat = 22
    /// Sheets-within-sheets and banners.
    static let rLg: CGFloat = 24
    /// Row icon squircles (web --r-sm).
    static let rIcon: CGFloat = 8

    /// A card's outline: barely there, so the shadow does the lifting.
    static let edge = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.06) : UIColor(red: 23/255, green: 37/255, blue: 42/255, alpha: 0.055) })
    /// The soft lift under a card (web --shadow-card).
    static let cardShadow = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0, alpha: 0.45) : UIColor(red: 23/255, green: 37/255, blue: 42/255, alpha: 0.09) })
    /// Filled neutral fields and capsules (web --seg-track).
    static let fill = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 118/255, green: 118/255, blue: 128/255, alpha: 0.24)
        : UIColor(red: 86/255, green: 105/255, blue: 110/255, alpha: 0.12) })

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
        // Not the dashed square, which reads as broken (snapshot review).
        case "alarm_control_panel": return "shield.lefthalf.filled"
        case "remote": return "appletvremote.gen1"
        case "time", "date", "datetime": return "clock"
        case "text", "input_text": return "character.cursor.ibeam"
        case "image": return "photo"
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

/// A soft card, like an inset-grouped cell: continuous corners, a
/// near-invisible edge, and a two-layer shadow on the shape only (never on
/// the text inside it). `lifted: false` for the tinted pulse, which sits flat.
struct Card: ViewModifier {
    var radius: CGFloat = Theme.rMd
    var fill: Color = Theme.panel
    var lifted = true
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(
                shape.fill(fill)
                    .shadow(color: lifted ? Theme.cardShadow.opacity(0.5) : .clear, radius: 1, y: 1)
                    .shadow(color: lifted ? Theme.cardShadow : .clear, radius: 12, y: 6)
            )
            .overlay(shape.strokeBorder(lifted ? Theme.edge : .clear, lineWidth: 1))
    }
}

/// A padded card.
struct Panel: ViewModifier {
    var radius: CGFloat = Theme.rMd
    var padding: CGFloat = 14
    var fill: Color = Theme.panel
    var lifted = true
    func body(content: Content) -> some View {
        content.padding(padding).modifier(Card(radius: radius, fill: fill, lifted: lifted))
    }
}

extension View {
    func panel(radius: CGFloat = Theme.rMd, padding: CGFloat = 14) -> some View {
        modifier(Panel(radius: radius, padding: padding))
    }
    /// The one tinted surface: the farm pulse. Flat, borderless.
    func tintPanel(padding: CGFloat = 18) -> some View {
        modifier(Panel(padding: padding, fill: Theme.tint, lifted: false))
    }
    /// An unpadded card, for blocks that lay out their own rows.
    func card(radius: CGFloat = Theme.rMd) -> some View {
        modifier(Card(radius: radius))
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

/* ---- haptics ----
 * One small vocabulary, fired from the press itself — never from a state
 * change, so a device someone else switches does not buzz your phone.
 *   select  — a choice among options: tabs, chips, segments, valve picks
 *   toggle  — a switch flipped: firmer turning on than off
 *   tick    — a slider crossing each 10%
 *   commit  — something that moves water: a heavy, rigid thump
 *   warn    — a destructive confirm (stopping a run)
 * Toasts already carry success/error (FarmStore.show). */
@MainActor
enum Haptics {
    static func select() { UISelectionFeedbackGenerator().selectionChanged() }
    static func toggle(on: Bool) {
        UIImpactFeedbackGenerator(style: on ? .medium : .soft).impactOccurred(intensity: on ? 0.9 : 0.7)
    }
    static func tick() { UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.45) }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func commit() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 1) }
    static func warn() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}
