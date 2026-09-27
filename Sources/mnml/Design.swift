import SwiftUI
import AppKit

// Lifted from Office Inspiration, with the ground turned white: there the work
// floats on an off-white canvas, here the page *is* the ground and everything
// the browser draws has to get out of its way.
//
// Every colour is a pair — one for a light window, one for a dark — and
// resolves itself against whatever appearance the window has. The window
// takes its appearance from the app, and the app from Settings › Appearance:
// light, dark, or whatever the Mac is doing. Nothing else in the code knows
// which it is.
enum Palette {
    static let ground = Color(nsColor: NS.ground)
    static let ink = Color(nsColor: NS.ink)             // neutral-900 · neutral-100
    static let muted = Color(nsColor: NS.muted)         // neutral-500
    static let faint = Color(nsColor: NS.faint)         // neutral-300 · neutral-700
    static let hairline = Color(nsColor: NS.hairline)   // neutral-200 · neutral-800
    static let wash = Color(nsColor: NS.wash)           // the live tab
    static let hover = Color(nsColor: NS.hover)         // the one under the pointer
    /// The only two that aren't grey: a connection nobody can read on the
    /// way, and one anybody can (see SiteCard.swift).
    static let safe = Color(nsColor: NS.safe)           // green-700 · green-400
    static let unsafe = Color(nsColor: NS.unsafe)       // amber-700 · amber-400

    /// The same colours for the AppKit corners of the app — a text field's
    /// ink, a window's background — which want an NSColor and keep it.
    enum NS {
        static let ground = pair(1.0, 0.11)
        static let ink = pair(0.09, 0.93)
        static let muted = pair(0.55, 0.58)
        static let faint = pair(0.83, 0.32)
        static let hairline = pair(0.91, 0.20)
        static let wash = pair(0.937, 0.175)
        static let hover = pair(0.965, 0.15)
        /// The resting traffic lights, drawn by hand when the app is behind.
        static let resting = pair(0.80, 0.30)
        static let safe = tint(light: (0.08, 0.50, 0.24), dark: (0.29, 0.87, 0.50))
        static let unsafe = tint(light: (0.71, 0.33, 0.04), dark: (0.98, 0.75, 0.14))

        private static func tint(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
            NSColor(name: nil) { appearance in
                let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
            }
        }

        private static func pair(_ light: CGFloat, _ dark: CGFloat) -> NSColor {
            NSColor(name: nil) { appearance in
                let dim = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(white: dim ? dark : light, alpha: 1)
            }
        }
    }
}

/// Light, dark, or the Mac's own — the one choice that colours everything.
enum Look: String, CaseIterable, Identifiable {
    case light, dark, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }

    /// What the app is told to be. Nothing, for "system": the app then
    /// follows the Mac, and changes with it.
    var appearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }

    /// Set on the app rather than on the window, so every panel, alert and
    /// sheet — and every page, which follows the window it is in — agrees.
    ///
    /// Never from inside whatever is happening when it is asked for: the
    /// switch in Settings changes it from within an animation, over a panel
    /// in transition, and re-skinning every window in the middle of that is
    /// how a window ends up with a layer that takes clicks and shows
    /// nothing. The next turn of the run loop is soon enough.
    func apply() {
        let wanted = appearance
        DispatchQueue.main.async {
            guard NSApp.appearance !== wanted, NSApp.appearance?.name != wanted?.name else { return }
            NSApp.appearance = wanted
        }
    }
}

enum Metrics {
    /// The tab strip. The window's title bar is grown to match it so the
    /// traffic lights come down with the tabs — otherwise giving the row room
    /// to breathe just leaves it sitting below three buttons it used to line
    /// up with.
    static let strip: CGFloat = 52
    /// Where the first tab starts. The traffic lights run from 19 to 79 —
    /// measured, not guessed — so this leaves them the same air on their right
    /// that the window gives them on their left.
    static let lights: CGFloat = 100
    /// Back, forward and reload, at the far end of the row beside the
    /// bookmarks: three doors and the air before the next one.
    static let helm: CGFloat = 3 * 26 + 2 * 4 + 8
    /// The same three doors again, in the sidebar, where they sit right of
    /// the lights instead. The column already has 10 of horizontal padding
    /// of its own before this even starts, so this is the lights' own edge
    /// (79) less that padding, and some air after them before back.
    static let sideLights: CGFloat = 84
    /// The band left at the top when there is no strip: just enough for the
    /// traffic lights to sit in, and nothing else.
    static let bare: CGFloat = 34
    /// Tabs are a fixed width rather than the width of their titles, so the
    /// cross always lands in the same place and the row never rearranges
    /// itself while you read it. They give way when there are too many:
    /// narrower than tabTitled they show their site's mark alone, and they
    /// stop at tabMinWidth, the mark and its air. Past that the row scrolls,
    /// inside its own edges.
    static let tabWidth: CGFloat = 186
    static let tabTitled: CGFloat = 80
    static let tabMinWidth: CGFloat = 36
    static let tabGap: CGFloat = 2
    /// A pinned tab is a square the height of the row, holding one letter.
    static let pinWidth: CGFloat = 30
    /// The square at the end of the row that opens a new page.
    static let plusWidth: CGFloat = 30
    /// The address field, in both the places it shows up.
    static let fieldWidth: CGFloat = 560
    /// The column of titles down the left, in the way that has one.
    static let side: CGFloat = 232
    static let sideMin: CGFloat = 188
    static let sideMax: CGFloat = 440
}

// One spring for anything that moves between two places, one for anything that
// arrives or leaves. Using the same two everywhere is most of why a thing feels
// like a single piece of software rather than a pile of views.
enum Motion {
    static let glide = Animation.spring(response: 0.34, dampingFraction: 0.82)
    static let settle = Animation.spring(response: 0.30, dampingFraction: 0.86)
    static let quick = Animation.easeOut(duration: 0.14)
}

/// mnml's mark: F in Morse — dot, dot, dash, dot. A bare shape, like
/// every other icon in the app; only the macOS app icon (`Icon/icon.swift`)
/// puts it on a plate, because the Dock needs an opaque square. Both draw it
/// from the same proportions.
struct Logomark: Shape {
    /// In a row, as on the app icon; or stacked on a three-by-three grid —
    /// two dots, a dash three dots wide, then a dot at the far end — for a
    /// square spot such as the About page. Read left to right, top to bottom,
    /// it is still ··–·.
    var stacked = false

    /// Dots 90 across, a dash three dots long (Morse's own rule), 45 between.
    static let parts: [CGFloat] = [90, 90, 270, 90]
    static let canvas = CGSize(width: parts.reduce(0, +) + 45 * CGFloat(parts.count - 1), height: 90)
    static let stackedCanvas = CGSize(width: 360, height: 360)

    /// Each piece as (x, y, width) on its canvas, every piece 90 tall.
    private var pieces: [(CGFloat, CGFloat, CGFloat)] {
        if stacked { return [(0, 0, 90), (135, 0, 90), (0, 135, 360), (270, 270, 90)] }
        var x: CGFloat = 0
        return Logomark.parts.map { part in defer { x += part + 45 }; return (x, 0, part) }
    }

    func path(in rect: CGRect) -> Path {
        // Fit the canvas into the frame, centred, as an SVG viewBox "meet".
        let canvas = stacked ? Logomark.stackedCanvas : Logomark.canvas
        let scale = min(rect.width / canvas.width, rect.height / canvas.height)
        let ox = rect.midX - canvas.width * scale / 2
        let oy = rect.midY - canvas.height * scale / 2
        let h = 90 * scale
        var path = Path()
        for (x, y, width) in pieces {
            path.addRoundedRect(in: CGRect(x: ox + x * scale, y: oy + y * scale, width: width * scale, height: h),
                                cornerSize: CGSize(width: h / 2, height: h / 2))
        }
        return path
    }
}

/// Wrong address, said without a dialog: the field shivers and stops.
struct Shake: GeometryEffect {
    var travel: CGFloat

    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        // Three there-and-backs, tapering to nothing, so it settles rather than
        // stopping mid-swing.
        let decay = 1 - travel
        return ProjectionTransform(
            CGAffineTransform(translationX: sin(travel * .pi * 6) * 7 * decay, y: 0)
        )
    }
}

/// The Mac's own sidebar material: what is behind the window, blurred and
/// tinted for light or dark, and dimmed when the window isn't in front — as
/// Finder's, Mail's and Notes' sidebars are.
struct Frosted: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    /// The desktop behind the window, or, with the page running under the
    /// chrome (Under.swift), the page beneath it.
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// A colour over the chrome's material, Arc's way (Settings › Tabs): a wash
/// laid on top, so the blur and the page beneath still come through.
enum Tint {
    /// Offered first; "" is none. Anything else from the colour picker.
    static let presets = ["", "8B5CF6", "3B82F6", "14B8A6", "22C55E", "F59E0B", "F43F5E", "EC4899"]
    /// The dark-mode tint that follows the light one.
    static let same = "="
    /// Where the strength starts, and its slider's ends.
    static let strength = 0.22
    static let strengths = 0.05...0.6

    static func color(_ hex: String) -> Color? {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(.sRGB,
                     red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    static func hex(_ color: Color) -> String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return "" }
        return String(format: "%02X%02X%02X",
                      Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()),
                      Int((rgb.blueComponent * 255).rounded()))
    }
}

/// The wash itself, in the light or dark mode's colour, or nothing.
struct TintWash: View {
    @ObservedObject var prefs: Preferences
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = prefs.chromeTintDark == Tint.same ? prefs.chromeTint : prefs.chromeTintDark
        if let color = Tint.color(scheme == .dark ? dark : prefs.chromeTint) {
            color.opacity(prefs.chromeTintStrength).allowsHitTesting(false)
        }
    }
}
