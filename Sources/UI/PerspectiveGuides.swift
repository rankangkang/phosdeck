import SwiftUI

/// Matches the crop canvas, including its display-only rotation for neutral perspective.
struct PerspectiveGuideFrame {
    let sourceSize: CGSize
    let geometry: PhotoGeometry
    let imageSize: CGSize
    let frame: CGRect
    let rotation: CGAffineTransform
    init(sourceSize: CGSize, imageSize: CGSize, canvas: CGSize, recipe: EditRecipe) throws {
        self.sourceSize = sourceSize; self.imageSize = imageSize
        geometry = try PhotoGeometry(size: sourceSize, recipe: recipe.cropRenderRecipe)
        frame = CropPreviewGeometry.outputFrame(size: imageSize, canvas: canvas, degrees: recipe.cropPreviewAngle)
        rotation = CropPreviewGeometry.transform(size: imageSize, degrees: recipe.cropPreviewAngle)
    }
    func view(_ point: MaskPoint) -> CGPoint? {
        guard let p = geometry.transform.point(CGPoint(x: point.x*sourceSize.width, y: point.y*sourceSize.height)) else { return nil }
        let q = CGPoint(x: p.x/geometry.output.width*imageSize.width, y: p.y/geometry.output.height*imageSize.height).applying(rotation)
        return CGPoint(x: frame.minX+q.x/imageSize.width*frame.width, y: frame.maxY-q.y/imageSize.height*frame.height)
    }
    func source(_ point: CGPoint) -> MaskPoint? {
        let p = CGPoint(x: (point.x-frame.minX)/frame.width*imageSize.width, y: (frame.maxY-point.y)/frame.height*imageSize.height).applying(rotation.inverted())
        let output = CGPoint(x: p.x/imageSize.width*geometry.output.width, y: p.y/imageSize.height*geometry.output.height)
        guard let q = geometry.transform.inverted().point(output) else { return nil }
        let result = MaskPoint(q.x/sourceSize.width, q.y/sourceSize.height)
        return (0...1).contains(result.x) && (0...1).contains(result.y) ? result : nil
    }
}

struct PerspectiveGuides: View {
    @Bindable var model: AppModel
    let imageSize: CGSize
    let canvas: CGSize
    @State private var drawing: (CGPoint, CGPoint)?
    var body: some View {
        if let size = model.orientedSourceSize, let recipe = model.recipe,
           let frame = try? PerspectiveGuideFrame(sourceSize: size, imageSize: imageSize, canvas: canvas, recipe: recipe) {
            Canvas { context, _ in
                for line in model.perspectiveGuides {
                    if let a = frame.view(line.start), let b = frame.view(line.end) { stroke(a, b, context: &context) }
                }
                if let drawing { stroke(drawing.0, drawing.1, context: &context) }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 5).onChanged { value in
                if frame.source(value.startLocation) != nil { drawing = (value.startLocation, value.location) }
            }.onEnded { value in
                drawing = nil
                if let a = frame.source(value.startLocation), let b = frame.source(value.location) { model.addPerspectiveGuide(start: a, end: b) }
            })
            .accessibilityLabel(L10n.text("geometry.drawGuides", defaultValue: "Draw along horizontal or vertical edges"))
            .accessibilityIdentifier("perspective-guide-canvas")
            .onChange(of: model.recipe) { drawing = nil }
            .onChange(of: model.perspectiveGuideTool) { drawing = nil }
        }
    }
    private func stroke(_ a: CGPoint, _ b: CGPoint, context: inout GraphicsContext) {
        var path = Path(); path.move(to: a); path.addLine(to: b)
        context.stroke(path, with: .color(.black.opacity(0.8)), lineWidth: 3)
        context.stroke(path, with: .color(.white), lineWidth: 1)
        for point in [a, b] { context.fill(Path(ellipseIn: CGRect(x: point.x-3, y: point.y-3, width: 6, height: 6)), with: .color(.white)) }
    }
}
