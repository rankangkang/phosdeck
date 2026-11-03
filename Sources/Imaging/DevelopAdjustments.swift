import Foundation

struct HSLBand: Codable, Equatable {
    var hue = 0.0
    var saturation = 0.0
    var luminance = 0.0
    static let names = [L10n.text("app.red", defaultValue: "Red"), L10n.text("app.orange", defaultValue: "Orange"), L10n.text("app.yellow", defaultValue: "Yellow"), L10n.text("app.green", defaultValue: "Green"), L10n.text("app.aqua", defaultValue: "Aqua"), L10n.text("app.blue", defaultValue: "Blue"), L10n.text("app.purple", defaultValue: "Purple"), L10n.text("app.magenta", defaultValue: "Magenta")]
    static let centers: [Double] = [0, 30, 60, 120, 180, 240, 270, 300]
}

struct GradingTone: Codable, Equatable {
    var hue = 0.0
    var saturation = 0.0
    var luminance = 0.0
}

struct ColorGrading: Codable, Equatable {
    var shadows = GradingTone()
    var midtones = GradingTone()
    var highlights = GradingTone()
    var global = GradingTone()
    var blending = 50.0
    var balance = 0.0
}

/// Our SDR rendering controls, not Adobe Process Version parameters.
struct DevelopAdjustments: Codable, Equatable {
    var highlights = 0.0
    var shadows = 0.0
    var whites = 0.0
    var blacks = 0.0
    var texture = 0.0
    var clarity = 0.0
    var dehaze = 0.0
    var vibrance = 0.0
    var blackAndWhite = false
    /// Post-HSL OkLCh bands; inactive while color mode is selected. Required in
    /// saved payloads so the former original-hue mapping cannot be reinterpreted.
    var blackWhiteMixVersion = "oklch-bw-v2"
    var blackWhiteMixer = Array(repeating: 0.0, count: 8)
    var mixer = Array(repeating: HSLBand(), count: 8)
    var grading = ColorGrading()
    var pointColorVersion = "oklch-point-v1"
    var pointColors: [PointColor] = []
    var curves: ToneCurves?
    var zones: ToneZones?

    func validate() throws {
        guard blackWhiteMixVersion == "oklch-bw-v2" else { throw LRCError(L10n.text("app.unsupportedBlackAndWhiteMixerProcessingIdentifierOriginalData", defaultValue: "Unsupported black-and-white mixer processing identifier. Original data preserved")) }
        guard pointColorVersion == "oklch-point-v1", pointColors.count <= 8, Set(pointColors.map(\.id)).count == pointColors.count else { throw LRCError(L10n.text("app.unsupportedPointColorDataOriginalRecordPreserved", defaultValue: "Unsupported point color data. Original record preserved")) }
        for point in pointColors { try point.validate() }
        try curves?.validate()
        try zones?.validate()
        let signed = [highlights, shadows, whites, blacks, texture, clarity, dehaze, vibrance, grading.balance]
            + mixer.flatMap { [$0.hue, $0.saturation, $0.luminance] } + blackWhiteMixer
        let tones = [grading.shadows, grading.midtones, grading.highlights, grading.global]
        guard mixer.count == 8, blackWhiteMixer.count == 8, signed.allSatisfy({ $0.isFinite && (-100...100).contains($0) }),
              grading.blending.isFinite, (0...100).contains(grading.blending),
              tones.allSatisfy({ $0.hue.isFinite && (0...360).contains($0.hue)
                  && $0.saturation.isFinite && (0...100).contains($0.saturation)
                  && $0.luminance.isFinite && (-100...100).contains($0.luminance) })
        else { throw LRCError(L10n.text("app.invalidBasicBlackAndWhiteMixerHSLOrColor", defaultValue: "Invalid basic, black-and-white mixer, HSL, or color grading parameters")) }
    }
}
