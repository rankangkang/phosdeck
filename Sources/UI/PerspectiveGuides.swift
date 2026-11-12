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
    private enum Interaction {
        case drawing
        case endpoint(index: Int, endpoint: PerspectiveGuideEndpoint)
        case selection
    }
    @State private var drawing: (CGPoint, CGPoint)?
    @State private var interaction: Interaction?
    @State private var dragFrame: PerspectiveGuideFrame?
    var body: some View {
        if let size = model.orientedSourceSize, let recipe = model.recipe,
           let frame = try? PerspectiveGuideFrame(sourceSize: size, imageSize: imageSize, canvas: canvas, recipe: recipe) {
            Canvas { context, _ in
                for (index, line) in model.perspectiveGuides.enumerated() {
                    if let a = frame.view(line.start), let b = frame.view(line.end) {
                        let selected = model.selectedPerspectiveGuideIndex == index
                        stroke(a, b, selected: selected, endpoint: selected ? model.selectedPerspectiveGuideEndpoint : nil, context: &context)
                    }
                }
                if let drawing { stroke(drawing.0, drawing.1, context: &context) }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if interaction == nil {
                    guard model.canvasCoordinatesCurrent else { return }
                    guard frame.source(value.startLocation) != nil else { return }
                    if let hit = hitTest(value.startLocation, frame: frame) {
                        if let endpoint = hit.endpoint, model.beginPerspectiveGuideDrag(index: hit.index, endpoint: endpoint) {
                            dragFrame = frame
                            interaction = .endpoint(index: hit.index, endpoint: endpoint)
                        } else {
                            _ = model.selectPerspectiveGuide(index: hit.index)
                            interaction = .selection
                        }
                    } else {
                        interaction = .drawing
                    }
                }
                switch interaction {
                case .some(.drawing):
                    drawing = (value.startLocation, value.location)
                case let .some(.endpoint(index, endpoint)):
                    if let point = (dragFrame ?? frame).source(value.location) {
                        _ = model.updatePerspectiveGuide(index: index, endpoint: endpoint, point: point)
                    }
                case .some(.selection), .none:
                    break
                }
            }.onEnded { value in
                switch interaction {
                case .some(.drawing):
                    if model.canvasCoordinatesCurrent, let a = frame.source(value.startLocation), let b = frame.source(value.location),
                       hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y) >= 5 {
                        model.addPerspectiveGuide(start: a, end: b)
                    }
                case .some(.endpoint):
                    _ = model.endPerspectiveGuideDrag()
                case .some(.selection), .none:
                    break
                }
                drawing = nil
                interaction = nil
                dragFrame = nil
            })
            .accessibilityLabel(L10n.text("geometry.drawGuides", defaultValue: "Draw along horizontal or vertical edges"))
            .accessibilityIdentifier("perspective-guide-canvas")
            .onChange(of: model.recipe) {
                if case .some(.endpoint) = interaction { return }
                drawing = nil; interaction = nil; dragFrame = nil
            }
            .onChange(of: model.perspectiveGuideTool) { drawing = nil; interaction = nil; dragFrame = nil }
            .onChange(of: model.activeID) { drawing = nil; interaction = nil; dragFrame = nil }
        }
    }
    private struct Hit {
        let index: Int
        let endpoint: PerspectiveGuideEndpoint?
    }

    private func hitTest(_ point: CGPoint, frame: PerspectiveGuideFrame) -> Hit? {
        let endpointRadius = 12.0
        for (index, line) in model.perspectiveGuides.enumerated().reversed() {
            guard let a = frame.view(line.start), let b = frame.view(line.end) else { continue }
            if hypot(point.x - a.x, point.y - a.y) <= endpointRadius { return Hit(index: index, endpoint: .start) }
            if hypot(point.x - b.x, point.y - b.y) <= endpointRadius { return Hit(index: index, endpoint: .end) }
        }
        for (index, line) in model.perspectiveGuides.enumerated().reversed() {
            guard let a = frame.view(line.start), let b = frame.view(line.end), distance(point, to: (a, b)) <= 8 else { continue }
            return Hit(index: index, endpoint: nil)
        }
        return nil
    }

    private func distance(_ point: CGPoint, to segment: (CGPoint, CGPoint)) -> CGFloat {
        let (a, b) = segment
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    private func stroke(_ a: CGPoint, _ b: CGPoint, selected: Bool = false, endpoint: PerspectiveGuideEndpoint? = nil, context: inout GraphicsContext) {
        var path = Path(); path.move(to: a); path.addLine(to: b)
        context.stroke(path, with: .color(.black.opacity(0.8)), lineWidth: 3)
        context.stroke(path, with: .color(selected ? Theme.accentSignal : .white), lineWidth: selected ? 2 : 1)
        for (index, point) in [a, b].enumerated() {
            let isEndpoint = index == 0 ? endpoint == .start : endpoint == .end
            let radius: CGFloat = isEndpoint ? 5 : selected ? 4 : 3
            context.fill(Path(ellipseIn: CGRect(x: point.x-radius, y: point.y-radius, width: radius*2, height: radius*2)), with: .color(selected ? Theme.accentSignal : .white))
        }
    }
}
