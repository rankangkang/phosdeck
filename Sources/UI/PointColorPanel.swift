import SwiftUI

struct PointColorPanel:View {
    @Bindable var model: AppModel
    private var points:[PointColor] { model.editorRecipe?.develop.pointColors ?? [] }
    private var selected:PointColor? { points.first { $0.id == model.selectedPointColorID } ?? points.first }
    private func note(_ text:String) -> some View { Text(text).font(.caption11).foregroundStyle(Theme.textSecondary).frame(maxWidth:.infinity,alignment:.leading).fixedSize(horizontal:false,vertical:true) }
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            Button(model.pointSampling ? L10n.text("app.cancelSampling", defaultValue: "Cancel Sampling") : L10n.text("app.samplePhoto8", defaultValue: "Sample Photo (\(points.count)/8)")) { model.togglePointColorSampling() }
                .buttonStyle(.key(selected:model.pointSampling)).disabled(!model.canEdit || points.count >= 8 && !model.pointSampling || model.editorRecipe?.develop.blackAndWhite == true)
                .accessibilityIdentifier("point-color-pick")
                .accessibilityValue(model.pointSampling ? L10n.text("app.on", defaultValue: "On") : L10n.text("app.off", defaultValue: "Off"))
                .accessibilityAddTraits(model.pointSampling ? .isSelected : [])
                .padding(.bottom, 8)
            if model.editorRecipe?.develop.blackAndWhite == true { note(L10n.text("app.pointColorAppliesInColorModeSamplesAreRetained", defaultValue: "Point Color applies in color mode. Samples are retained and bypassed in black-and-white mode.")) }
            if model.pointSampling { note(model.pointReferenceReady ? L10n.text("app.clickAColoredAreaToSampleFullyTransparentPixels", defaultValue: "Click a colored area to sample. Fully transparent pixels are excluded.") : L10n.text("app.preparingFloatingPointColorSampling", defaultValue: "Preparing floating-point color sampling…")) }
            if !points.isEmpty {
                SubgroupLabel(L10n.text("app.sampledColor", defaultValue: "Sampled Color"))
                LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:4),count:4),spacing:8) {
                    ForEach(Array(points.enumerated()),id:\.element.id) { index,point in
                        Button { model.selectedPointColorID = point.id } label:{
                            let h = point.hue * .pi/180
                            let c = PerceptualColor.encoded(PerceptualColor.gamutMap(SIMD3(point.lightness,point.chroma*cos(h),point.chroma*sin(h))))
                            HStack(spacing:4) {
                                Rectangle().fill(Color(.sRGB,red:c.x,green:c.y,blue:c.z,opacity:1))
                                    .overlay(Rectangle().strokeBorder(Theme.controlBorder,lineWidth:1)).frame(width:14,height:14)
                                Text("\(index+1)")
                            }.frame(maxWidth:.infinity)
                        }.buttonStyle(.key(selected:selected?.id == point.id))
                            .keyLamp(selected?.id == point.id).lampRow()
                            .accessibilityLabel(L10n.text("app.colorSample", defaultValue: "Color Sample \(index+1)"))
                            .accessibilityAddTraits(selected?.id == point.id ? .isSelected : [])
                            .help(L10n.text("app.selectColorSample", defaultValue: "Select Color Sample \(index+1)"))
                    }
                }
            }
            if let selected {
                SubgroupLabel(L10n.text("app.colorAdjustment", defaultValue: "Color Adjustment"))
                Group {
                    row(L10n.text("app.hueShift", defaultValue: "Hue Shift"),selected,\.hueShift)
                    row(L10n.text("app.saturationShift", defaultValue: "Saturation Shift"),selected,\.saturationShift)
                    row(L10n.text("app.luminanceShift", defaultValue: "Luminance Shift"),selected,\.luminanceShift)
                    row(L10n.text("app.colorDifference", defaultValue: "Color Difference"),selected,\.variance)
                    SubgroupLabel(L10n.text("app.affectedRange", defaultValue: "Affected Range"))
                    row(L10n.text("app.overallRange", defaultValue: "Overall Range"),selected,\.range,range:0...100,reset:50)
                    row(L10n.text("app.hueRange", defaultValue: "Hue Range"),selected,\.hueRange,range:0...100,reset:50)
                    row(L10n.text("app.saturationRange", defaultValue: "Saturation Range"),selected,\.saturationRange,range:0...100,reset:50)
                    row(L10n.text("app.luminanceRange_1749", defaultValue: "Luminance Range"),selected,\.luminanceRange,range:0...100,reset:50)
                }.disabled(model.editorRecipe?.develop.blackAndWhite == true)
                Toggle(L10n.text("app.showAffectedRange", defaultValue: "Show Affected Range"),isOn:$model.showPointColorRange).toggleStyle(.instrument)
                    .disabled(model.editorRecipe?.develop.blackAndWhite == true).padding(.vertical, 8)
                if model.showPointColorRange { note(L10n.text("app.whiteIsFullyAffectedBlackIsUnaffectedThisView", defaultValue: "White is fully affected; black is unaffected. This view is for display only.")+(model.pointRangeImage == nil ? L10n.text("app.updating", defaultValue: " Updating…") : "")) }
                HStack { Button(L10n.text("app.resetSample", defaultValue: "Reset Sample")) { model.resetPointColor(selected.id) }; Spacer(); Button(L10n.text("app.deleteSample", defaultValue: "Delete Sample"),role:.destructive) { model.deletePointColor(selected.id) } }.buttonStyle(.key).padding(.vertical, 8)
                note(L10n.text("app.colorDifferenceNegativeCompressesPositiveExpandsSamplesApplyIn", defaultValue: "Color Difference: negative compresses; positive expands. Samples apply in numbered order and overlapping ranges influence each other."))
            } else { note(L10n.text("app.sampleThePhotoThenAdjustNearbyColorsUpTo", defaultValue: "Sample the photo, then adjust nearby colors. Up to 8 samples.")) }
        }
        .onAppear { if model.selectedPointColorID == nil { model.selectedPointColorID = points.first?.id } }
    }
    private func row(_ title:String,_ point:PointColor,_ key:WritableKeyPath<PointColor,Double>,range:ClosedRange<Double> = -100...100,reset:Double = 0) -> some View {
        AdjustmentRow(label:title,value:point[keyPath:key],range:range,reset:reset,change:{ value,save in model.updatePointColor(id:point.id,key:key,value:value,commit:save) },commit:{ model.commitRecipe() })
    }
}
