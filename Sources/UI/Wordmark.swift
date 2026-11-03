import SwiftUI
import AppKit

/// The vector artwork is traced from the chosen wordmark; colors follow the interface theme.
struct Wordmark: View {
    @Environment(\.colorScheme) private var colorScheme
    var xHeight: CGFloat = 8

    static let artworkSize = CGSize(width: 1903, height: 400)
    static let referenceXHeight: CGFloat = 235
    private static let opticalCenter: CGFloat = 203.5
    private static let ivory = load("wordmark-approved-ivory")
    private static let graphite = load("wordmark-approved-graphite")

    private static func load(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "svg").flatMap(NSImage.init(contentsOf:))
    }

    static func image(for scheme: ColorScheme) -> NSImage? {
        scheme == .dark ? graphite : ivory
    }

    var body: some View {
        let scale = xHeight / Self.referenceXHeight
        Group {
            if let image = Self.image(for: colorScheme) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Text("phosdeck").font(.system(size: xHeight * 1.4, weight: .semibold))
            }
        }
        .frame(width: Self.artworkSize.width * scale, height: Self.artworkSize.height * scale)
        .alignmentGuide(.keyCenter) { _ in Self.opticalCenter * scale }
        .accessibilityElement()
        .accessibilityLabel("Phosdeck")
        .accessibilityAddTraits(.isHeader)
    }
}
