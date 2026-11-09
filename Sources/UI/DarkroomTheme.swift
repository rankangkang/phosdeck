import SwiftUI
import AppKit

/// Darkroom Instrument v3 values from design/darkroom_instrument_tokens_v3.json.
/// Chrome colours resolve against the view appearance: aqua is ivory, darkAqua is graphite.
/// None of these colours may reach ImagePipeline, Metal rendering or export.
enum Palette {
    static let surfaceBase = pair(0xDDDEDC, 0x1C1D1C)
    static let surfacePanel = pair(0xF0F0EE, 0x292A2A)
    static let surfaceRaised = pair(0xFCFCFA, 0x3B3D3D)
    static let surfaceInset = pair(0xD8DAD7, 0x161815)
    static let surfaceSelected = pair(0xDFE0DD, 0x252727)
    static let plateTop = pair(0xF7F7F5, 0x313333)
    static let plateBottom = pair(0xEAEBE8, 0x262828)
    static let textPrimary = pair(0x2A2B29, 0xE8E6E0)
    static let textSecondary = pair(0x5A5B56, 0xB3B2AC)
    static let textDisabled = pair(0x76776F, 0x86878A)
    static let separator = pair(0xCDCECB, 0x181A1A)
    static let seamLight = pair(0xFFFFFF, 0x3B3D3D)
    static let controlBorder = pair(0x77756E, 0x85888B)
    static let accentText = pair(0x974208, 0xF0A04A)
    static let accentSignal = pair(0xB85F14, 0xF0A04A)
    static let focusRing = pair(0x974208, 0xF0A04A)
    static let error = pair(0xA3322C, 0xFFB0A7)
    static let success = pair(0x376244, 0xA7D4AE)
    static let warning = pair(0x855507, 0xF2C979)
    static let lampOn = pair(0xFF920E, 0xFF9B24)
    static let lampSocket = pair(0x3C3C38, 0x0E0F0F)
    static let lampOff = pair(0x8E918B, 0x4B4D4D)
    static let lampSpecular = hex(0xFFE5AF)
    static let capTop = pair(0xFFFFFF, 0x656868)
    static let capBottom = pair(0xE8E9E5, 0x3C3F3F)
    static let materialEdge = pair(0xBABDB7, 0x191C1C)
    static let knobRimTop = pair(0xC0C3BD, 0x171B1B)
    static let knobRimBottom = pair(0xFFFFFF, 0x565A5A)
    /// Visible sidewall under the key face, shortened by the actual key travel.
    static let keyLip = pair(0xC0C3BC, 0x1A1E1E)
    static let keyLipSelected = pair(0xC7C9C3, 0x181C1C)
    static let keyHeld = pair(0xDBDDDA, 0x272D2D)
    static let keyPrimaryLip = hex(0xB44B05)
    static let keyPrimary = hex(0xFF7C10)
    static let keyPrimaryTop = hex(0xFF9A26)
    static let keyPrimaryBottom = hex(0xF26C06)
    static let keyPrimaryText = hex(0x24170D)
    static let keyPrimaryEdge = hex(0x9A4A10)
    static let keyTop = pair(0xFFFFFF, 0x525656)
    static let keyBottom = pair(0xF1F2EE, 0x3B4040)
    static let keyHighlight = dynamic(NSColor(white: 1, alpha: 0.95), NSColor(white: 1, alpha: 0.23))
    static let keyContactShadow = dynamic(NSColor(white: 0, alpha: 0.23), NSColor(white: 0, alpha: 0.65))
    static let keyAmbientShadow = dynamic(NSColor(white: 0, alpha: 0.15), NSColor(white: 0, alpha: 0.32))
    static let insetShadow = dynamic(NSColor(white: 0, alpha: 0.22), NSColor(white: 0, alpha: 0.65))

    // Semantic organization metadata; fixed across themes and never composited into pixels.
    static let labelRed = hex(0xC24D4A)
    static let labelYellow = hex(0xBFA33B)
    static let labelGreen = hex(0x599E61)
    static let labelBlue = hex(0x5285C2)
    static let labelPurple = hex(0x9666B5)

    static let scopeBackground = hex(0x121413)
    static let scopeBezel = hex(0x0A0B0B)
    static let scopeGrid = hex(0x2B302E)
    static let scopeAxis = hex(0x8F9995)
    static let scopeText = hex(0xC8D0C9)
    static let scopeLampOff = hex(0x2F3432)
    static let traceNeutral = hex(0xD8DEDA)
    static let traceActive = hex(0xF2A03D)
    static let traceRed = hex(0xF08A87)
    static let traceGreen = hex(0x9FCC9D)
    static let traceBlue = hex(0x92B5F0)
    static let clipHighlight = hex(0xC2187F)
    static let clipShadow = hex(0x3FA9FF)
    /// photoOverlay.light / photoOverlay.dark. Mask mats only; not a viewing-mat colour.
    static let overlayLight = hex(0xFFFFFF)
    static let overlayDark = hex(0x000000)

    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }
    private static func pair(_ ivory: UInt32, _ graphite: UInt32) -> NSColor { dynamic(hex(ivory), hex(graphite)) }
    private static func dynamic(_ ivory: NSColor, _ graphite: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? graphite : ivory }
    }
}

enum Theme {
    static let base = Color(nsColor: Palette.surfaceBase)
    static let panel = Color(nsColor: Palette.surfacePanel)
    static let raised = Color(nsColor: Palette.surfaceRaised)
    static let inset = Color(nsColor: Palette.surfaceInset)
    static let selected = Color(nsColor: Palette.surfaceSelected)
    static let plateTop = Color(nsColor: Palette.plateTop)
    static let plateBottom = Color(nsColor: Palette.plateBottom)
    static let text = Color(nsColor: Palette.textPrimary)
    static let textSecondary = Color(nsColor: Palette.textSecondary)
    static let textDisabled = Color(nsColor: Palette.textDisabled)
    static let separator = Color(nsColor: Palette.separator)
    static let seamLight = Color(nsColor: Palette.seamLight)
    static let controlBorder = Color(nsColor: Palette.controlBorder)
    static let accentText = Color(nsColor: Palette.accentText)
    static let accentSignal = Color(nsColor: Palette.accentSignal)
    static let focusRing = Color(nsColor: Palette.focusRing)
    static let error = Color(nsColor: Palette.error)
    static let success = Color(nsColor: Palette.success)
    static let warning = Color(nsColor: Palette.warning)
    static let lampOn = Color(nsColor: Palette.lampOn)
    static let lampSocket = Color(nsColor: Palette.lampSocket)
    static let lampOff = Color(nsColor: Palette.lampOff)
    static let lampSpecular = Color(nsColor: Palette.lampSpecular)
    static let capTop = Color(nsColor: Palette.capTop)
    static let capBottom = Color(nsColor: Palette.capBottom)
    static let materialEdge = Color(nsColor: Palette.materialEdge)
    static let knobRimTop = Color(nsColor: Palette.knobRimTop)
    static let knobRimBottom = Color(nsColor: Palette.knobRimBottom)
    static let keyLip = Color(nsColor: Palette.keyLip)
    static let keyLipSelected = Color(nsColor: Palette.keyLipSelected)
    static let keyHeld = Color(nsColor: Palette.keyHeld)
    static let keyPrimaryLip = Color(nsColor: Palette.keyPrimaryLip)
    static let keyTop = Color(nsColor: Palette.keyTop)
    static let keyBottom = Color(nsColor: Palette.keyBottom)
    static let keyHighlight = Color(nsColor: Palette.keyHighlight)
    static let keyContactShadow = Color(nsColor: Palette.keyContactShadow)
    static let keyAmbientShadow = Color(nsColor: Palette.keyAmbientShadow)
    static let insetShadow = Color(nsColor: Palette.insetShadow)
    static let keyPrimaryTop = Color(nsColor: Palette.keyPrimaryTop)
    static let keyPrimaryBottom = Color(nsColor: Palette.keyPrimaryBottom)
    static let keyPrimaryText = Color(nsColor: Palette.keyPrimaryText)
    static let keyPrimaryEdge = Color(nsColor: Palette.keyPrimaryEdge)

    static let scopeBackground = Color(nsColor: Palette.scopeBackground)
    static let scopeBezel = Color(nsColor: Palette.scopeBezel)
    static let scopeGrid = Color(nsColor: Palette.scopeGrid)
    static let scopeAxis = Color(nsColor: Palette.scopeAxis)
    static let scopeText = Color(nsColor: Palette.scopeText)
    static let scopeLampOff = Color(nsColor: Palette.scopeLampOff)
    static let traceNeutral = Color(nsColor: Palette.traceNeutral)
    static let traceActive = Color(nsColor: Palette.traceActive)
    static let traceRGB = [Color(nsColor: Palette.traceRed), Color(nsColor: Palette.traceGreen), Color(nsColor: Palette.traceBlue)]
}

enum Metrics {
    static let topBar: CGFloat = 32
    /// Centre line of the system window buttons inside the hidden title bar.
    static let topBarKeyLine: CGFloat = 16
    /// Chassis rim around the side panels and filmstrip; the status bar serves as its bottom edge.
    static let rim: CGFloat = 8
    static let toolbar: CGFloat = 30
    static let statusBar: CGFloat = 24
    static let filmBar: CGFloat = 26
    /// Thumbnail band only; with the 26 pt bar the filmstrip totals 80–160 (122 by default).
    static let filmstrip = (initial: 96.0, range: 54.0...134.0)
    static let thumbnailCell = (inset: CGFloat(8), imageInset: CGFloat(12), header: CGFloat(24), footer: CGFloat(28), imageGap: CGFloat(10), seamWidth: CGFloat(1))
    static let thumbnailCellFill = (idle: CGFloat(0.025), hover: CGFloat(0.075), selected: CGFloat(0.1), selectedHover: CGFloat(0.14))
    static let filmCell = (inset: CGFloat(4), imageInset: CGFloat(8), footer: CGFloat(18))
    static let thumbnailStack = (handleHeight: CGFloat(32), markHeight: CGFloat(18), countHeight: CGFloat(18), minWidth: CGFloat(18), maxWidth: CGFloat(52))
    static let leftPanel = (initial: 232.0, range: 200.0...280.0)
    static let rightPanel = (initial: 336.0, range: 304.0...400.0)
    static let photoMinWidth: CGFloat = 480
    static let compactMaskWindowHeight: CGFloat = 800
    static let histogramPlot = (regular: CGFloat(80), compact: CGFloat(36))
    static let padding: CGFloat = 16
    static let sectionHeader: CGFloat = 32
    static let row: CGFloat = 32
    static let rowLabel: CGFloat = 80
    static let rowValue: CGFloat = 64
    static let rowUnit: CGFloat = 16
    static let gap: CGFloat = 8
    static let key: CGFloat = 28
    static let keyRadius: CGFloat = 3
    static let inputRadius: CGFloat = 2
    static let scopeRadius: CGFloat = 3
    static let lamp: CGFloat = 6
    /// Distance from a key's bottom edge to the bottom of its lamp.
    static let lampDrop: CGFloat = 10
    static let switchTrack = CGSize(width: 58, height: 26)
    static let switchCap = CGSize(width: 25, height: 20)
    static let switchTravel: CGFloat = 27
    static let leverTrack = CGSize(width: 26, height: 50)
    static let leverCap = CGSize(width: 20, height: 20)
    static let leverTravel: CGFloat = 24
}

extension Font {
    static let body13 = Font.system(size: 13)
    static let section = Font.system(size: 12, weight: .semibold)
    static let value = Font.system(size: 12, weight: .medium).monospacedDigit()
    static let caption11 = Font.system(size: 11)
    static let silk = Font.system(size: 11, weight: .semibold)
}

/// Silk-screen label: Latin text is upper-cased and tracked; CJK text keeps natural spacing.
struct SilkText: View {
    let text: String
    init(_ text: String) { self.text = text }
    private var latin: Bool { !text.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) } }
    var body: some View {
        Text(latin ? text.uppercased() : text).font(.silk).tracking(latin ? 11 * 0.08 : 0)
    }
}

/// User-selected chrome theme. It changes only the interface appearance, never photo pixels.
enum ChromeTheme: String, CaseIterable, Identifiable {
    case system, ivory, graphite
    var id: String { rawValue }
    var title: String { switch self { case .system: L10n.text("app.followSystem", defaultValue: "Follow System"); case .ivory: L10n.text("app.ivory", defaultValue: "Ivory"); case .graphite: L10n.text("app.graphite", defaultValue: "Graphite") } }
    var colorScheme: ColorScheme? { switch self { case .system: nil; case .ivory: .light; case .graphite: .dark } }
}

/// Neutral viewing mat behind photos, independent of the chrome theme.
enum PhotoMat: String, CaseIterable, Identifiable {
    case dark, medium, light, white
    var id: String { rawValue }
    var title: String { switch self { case .dark: L10n.text("app.darkGray", defaultValue: "Dark Gray"); case .medium: L10n.text("app.mediumGray", defaultValue: "Medium Gray"); case .light: L10n.text("app.lightGray", defaultValue: "Light Gray"); case .white: L10n.text("app.white", defaultValue: "White") } }
    /// sRGB grey level; photoMat.default #303030, medium #777777, light #D6D6D6, white #FFFFFF.
    var gray: Double { switch self { case .dark: 0x30 / 255; case .medium: 0x77 / 255; case .light: 0xD6 / 255; case .white: 1 } }
    var color: Color { Color(nsColor: nsColor) }
    var nsColor: NSColor { NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1) }
    /// matStates: marks drawn on the mat use these, never chrome accents.
    var text: NSColor { switch self { case .dark: Palette.hex(0xE7E5DF); case .medium: .black; case .light, .white: Palette.hex(0x2E302E) } }
    var textSecondary: NSColor { switch self { case .dark: Palette.hex(0xB2B3AF); case .medium: .black; case .light: Palette.hex(0x3A3A3A); case .white: Palette.hex(0x5E605A) } }
    var selection: NSColor { text }
    var focus: NSColor { switch self { case .dark: Palette.hex(0xF0A34B); case .medium: .white; case .light, .white: Palette.hex(0x9C4509) } }
}
