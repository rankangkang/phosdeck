import CoreGraphics
import Foundation
import MCP

enum MCPCanvasFields {
    static let unit = MCPDevelopParameters.numberSchema(0...1)
    static let pointSchema: Value = ["type": "object", "properties": ["x": unit, "y": unit],
                                     "required": ["x", "y"], "additionalProperties": false]
    static let pathSchema: Value = ["type": "array", "minItems": 1, "maxItems": 4096, "items": pointSchema]
    static let gradientPointSchema: Value = {
        let value = MCPDevelopParameters.numberSchema(MaskPoint.gradientRange)
        return ["type": "object", "properties": ["x": value, "y": value],
                "required": ["x", "y"], "additionalProperties": false]
    }()
    static let rectSchema: Value = ["type": "object", "properties": ["x": unit, "y": unit, "width": unit, "height": unit],
                                    "required": ["x", "y", "width", "height"], "additionalProperties": false]
    static let pixelRectSchema: Value = {
        let edge = Int(PhotoGeometry.maximumDimension)
        let origin = MCPOutputSchema.integer(0...edge), size = MCPOutputSchema.integer(1...edge)
        return ["type": "object", "properties": ["x": origin, "y": origin, "width": size, "height": size],
                "required": ["x", "y", "width", "height"], "additionalProperties": false]
    }()
    static let histogramRegions = ["blacks", "shadows", "exposure", "highlights", "whites"]
    static let perspectiveSchema = patch([
        "horizontal": MCPDevelopParameters.numberSchema(-100...100), "vertical": MCPDevelopParameters.numberSchema(-100...100),
        "aspect": MCPDevelopParameters.numberSchema(-100...100), "constrain_crop": ["type": "boolean"]
    ])
    private static let pointColorFields: [String: WritableKeyPath<PointColor, Double>] = [
        "hue_shift": \.hueShift, "saturation_shift": \.saturationShift, "luminance_shift": \.luminanceShift,
        "variance": \.variance, "range": \.range, "hue_range": \.hueRange,
        "saturation_range": \.saturationRange, "luminance_range": \.luminanceRange
    ]
    static let pointColorSchema = patch(Dictionary(uniqueKeysWithValues: pointColorFields.keys.map { name in
        (name, MCPDevelopParameters.numberSchema(name.contains("range") ? 0...100 : -100...100))
    }))

    static func patch(_ properties: [String: Value]) -> Value {
        ["type": "object", "minProperties": 1, "additionalProperties": false, "properties": .object(properties)]
    }
    static func point(_ value: Value) -> CGPoint? { point(value, range: 0...1) }
    static func point(_ value: Value, range: ClosedRange<Double>) -> CGPoint? {
        guard let object = value.objectValue, object.count == 2, let x = object["x"]?.number, let y = object["y"]?.number,
              range.contains(x), range.contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }
    static func rect(_ value: Value) -> CGRect? {
        guard let object = value.objectValue, object.count == 4, let x = object["x"]?.number, let y = object["y"]?.number,
              let width = object["width"]?.number, let height = object["height"]?.number,
              (0...1).contains(x), (0...1).contains(y), width > 0, height > 0,
              x + width <= 1, y + height <= 1 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
    static func rectValue(_ rect: CGRect) -> Value {
        ["x": .double(rect.minX), "y": .double(rect.minY), "width": .double(rect.width), "height": .double(rect.height)]
    }
    static func pixelRect(_ value: Value) -> CGRect? {
        let limit = Int(PhotoGeometry.maximumDimension)
        guard let fields = value.objectValue, fields.count == 4,
              let x = fields["x"]?.intValue, (0...limit).contains(x),
              let y = fields["y"]?.intValue, (0...limit).contains(y),
              let width = fields["width"]?.intValue, (1...limit).contains(width),
              let height = fields["height"]?.intValue, (1...limit).contains(height) else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
    static func pixelRectValue(_ rect: CGRect) -> Value {
        ["x": .int(Int(rect.minX)), "y": .int(Int(rect.minY)), "width": .int(Int(rect.width)), "height": .int(Int(rect.height))]
    }
    static func pointValue(_ point: MaskPoint) -> Value { ["x": .double(point.x), "y": .double(1 - point.y)] }

    static func geometry(_ recipe: EditRecipe, size: CGSize? = nil) -> Value {
        func box(_ crop: Crop) -> Value {
            rectValue(CGRect(x: crop.x, y: 1 - crop.y - crop.height, width: crop.width, height: crop.height))
        }
        return ["quarter_turns": .int(recipe.quarterTurns), "straighten": .double(recipe.straightenDegrees),
                "flip_horizontal": .bool(recipe.flipHorizontal), "flip_vertical": .bool(recipe.flipVertical),
                "rect": box(recipe.cropInDisplay), "aspect_ratio": recipe.cropAspectRatio.map(Value.double) ?? .null,
                "effective_rect": size.flatMap { recipe.effectiveCropInDisplay(size: $0) }.map(box) ?? .null,
                "perspective": ["horizontal": .double(recipe.perspective.horizontal), "vertical": .double(recipe.perspective.vertical),
                                "aspect": .double(recipe.perspective.aspect), "constrain_crop": .bool(recipe.perspective.constrainCrop)]]
    }
    static func pointColor(_ sample: PointColor) -> Value {
        var data = pointColorFields.mapValues { Value.double(sample[keyPath: $0]) }
        data["sample_id"] = .string(sample.id.uuidString)
        data["lightness"] = .double(sample.lightness)
        data["chroma"] = .double(sample.chroma)
        data["hue"] = .double(sample.hue)
        return .object(data)
    }
    static func applyPointColor(_ fields: [String: Value], to sample: inout PointColor) {
        for (name, key) in pointColorFields {
            if let value = fields[name]?.number { sample[keyPath: key] = value }
        }
    }
}

struct MCPNativePreviewRegion {
    static let maximumEdge = 2048
    static let maximumPixels = 1024 * 1024
    let canvas: CGSize
    let pixels: CGRect

    static func resolve(canvas: CGSize, region: CGRect?, pixelRegion: CGRect?) throws -> Self {
        let frame = CGRect(origin: .zero, size: canvas)
        let pixels = pixelRegion ?? region.map {
            $0.applying(CGAffineTransform(scaleX: canvas.width, y: canvas.height)).integral.intersection(frame)
        } ?? frame
        guard !pixels.isEmpty, frame.contains(pixels) else {
            throw MCPToolProblem(code: "preview_region_outside_canvas", summary: "The pixel region extends outside the edited frame.",
                                 next: "Choose a region within the reported canvas dimensions.",
                                 details: ["canvas_width": .int(Int(canvas.width)), "canvas_height": .int(Int(canvas.height))])
        }
        return Self(canvas: canvas, pixels: pixels)
    }

    var normalized: CGRect {
        pixels.applying(CGAffineTransform(scaleX: 1 / canvas.width, y: 1 / canvas.height))
    }
    var fits: Bool {
        max(pixels.width, pixels.height) <= Double(Self.maximumEdge) && pixels.width * pixels.height <= Double(Self.maximumPixels)
    }
    var data: [String: Value] {
        var result: [String: Value] = [
            "resolution": "native", "canvas_width": .int(Int(canvas.width)), "canvas_height": .int(Int(canvas.height)),
            "width": .int(Int(pixels.width)), "height": .int(Int(pixels.height)), "region": MCPCanvasFields.rectValue(normalized),
            "region_pixels": MCPCanvasFields.pixelRectValue(pixels), "fits": .bool(fits),
            "max_long_edge": .int(Self.maximumEdge), "max_pixels": .int(Self.maximumPixels)
        ]
        if !fits {
            let scale = min(Double(Self.maximumEdge) / max(pixels.width, pixels.height),
                            sqrt(Double(Self.maximumPixels) / (pixels.width * pixels.height)))
            let width = max(1, floor(pixels.width * scale)), height = max(1, floor(pixels.height * scale))
            let suggestion = CGRect(x: floor(pixels.midX - width / 2), y: floor(pixels.midY - height / 2),
                                    width: width, height: height)
            result["suggested_region_pixels"] = MCPCanvasFields.pixelRectValue(suggestion)
        }
        return result
    }
}

struct MCPCanvasPreview: Sendable {
    let id = UUID().uuidString
    let photoID: String
    let sourceRevision: Int
    let recipeRevision: Int
    let sourceSize: CGSize
    let variant: String?
    let region: CGRect
    let width: Int
    let height: Int
    let sampler: DisplayPixelSampler
    let spotOffsets: [UUID: MaskPoint]
    let draft: MCPPhotoDraft.Reference?

    init(photo: Photo, image: CGImage, region: CGRect, sourceSize: CGSize, variant: String?, spotOffsets: [UUID: MaskPoint],
         draft: MCPPhotoDraft.Reference? = nil) {
        photoID = photo.id
        sourceRevision = photo.revision
        recipeRevision = photo.recipeRevision
        self.sourceSize = sourceSize
        self.variant = variant
        self.region = region
        width = image.width
        height = image.height
        sampler = DisplayPixelSampler(image: image)
        self.spotOffsets = spotOffsets
        self.draft = draft
    }

    func matches(_ photo: Photo) -> Bool {
        photo.id == photoID && photo.revision == sourceRevision && photo.recipeRevision == recipeRevision
    }
    func outputPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: region.minX + point.x * region.width, y: 1 - region.minY - point.y * region.height)
    }
    func sourcePoint(_ point: CGPoint, recipe: EditRecipe, allowOutside: Bool = false) throws -> MaskPoint {
        var recipe = recipe
        if variant == "crop_canvas" { recipe.crop = Crop(); recipe.perspective.constrainCrop = false }
        guard let mapped = MaskGeometry.sourcePoint(outputPoint(point), size: sourceSize, recipe: recipe, allowOutside: allowOutside) else {
            throw MCPToolProblem.outsideCanvas
        }
        return mapped
    }
    func outputRect(_ rect: CGRect) -> CGRect {
        CGRect(x: region.minX + rect.minX * region.width, y: region.minY + rect.minY * region.height,
               width: rect.width * region.width, height: rect.height * region.height)
    }
    static func detail(_ image: CGImage, region: CGRect?) throws -> (CGImage, CGRect) {
        guard let region else { return (image, CGRect(x: 0, y: 0, width: 1, height: 1)) }
        let width = Double(image.width), height = Double(image.height)
        let x = floor(region.minX * width), y = floor(region.minY * height)
        let w = ceil(region.maxX * width) - x, h = ceil(region.maxY * height) - y
        guard let cropped = image.cropping(to: CGRect(x: x, y: y, width: w, height: h)) else { throw MCPToolProblem.outsideCanvas }
        return (cropped, CGRect(x: x / width, y: y / height, width: w / width, height: h / height))
    }
}

extension MCPToolProblem {
    static let staleCanvasPreview = Self(code: "stale_preview", summary: "This preview is no longer valid for the requested photo or action.",
                                         next: "Render a fresh preview of the same saved or draft version with the current revisions and canvas variant.")
    static let outsideCanvas = Self(code: "invalid_canvas_point", summary: "The coordinates do not map to a valid point on the photo.",
                                    next: "Use normalized top-left coordinates within the specified preview.")
    static let noCanvasSample = Self(code: "no_canvas_sample", summary: "The selected position did not produce a usable sample.",
                                      next: "Check that the pixel is visible and suitable for this adjustment.")
}

extension AppMCPTool {
    var canvasDescription: (String, String)? {
        switch self {
        case .setCrop:
            ("Set a normalized top-left rect on a crop_canvas preview, set or unlock/lock the aspect ratio, rotate its aspect, or reset crop. Poll get_job for the effective geometry.", "job_id, then item result with crop and revision")
        case .photoGeometry:
            ("Patch visible rotation in quarter turns, straighten in degrees, final horizontal/vertical flips, or perspective settings. Rotation precedes explicit flip changes.", "job_id, then item result with effective geometry")
        case .solvePerspective:
            ("Run the native automatic perspective solver in auto, level, vertical or full mode on an explicit photo version.", "job_id, then solver status and resulting geometry")
        case .perspectiveGuides:
            ("Edit the native guide session on the active crop canvas. Begin in straighten or perspective mode. Add or move endpoints on a current crop_canvas preview, select/delete by zero-based point_index, clear, finish, or cancel the active guide tool.", "canvas guide state, photo revisions, operation_id and commit_state")
        case .canvasGuides:
            ("Set display-only crop guide pattern and spot-guide visibility in the native workspace.", "crop_guide and spot_guides")
        case .samplePreview:
            ("Read the exact preview pixel's sRGB and clipping flags, or sample its native luminance zone with action=zone on a current editable canvas.", "pixel, rgba, clipping, or zone and ev")
        case .adjustPreview:
            ("Apply a native adjustment bound to a current saved preview. White balance uses a point; histogram uses histogram_region and delta. Color and curve targets use point and delta, and curve needs a channel. Purple/green defringe supports a point with optional amount delta.", "job_id, then sample result, revision and operation_id")
        case .pointColor:
            ("Add a sample using a current saved preview and point. Set offsets/ranges, reset or delete by sample_id. Select a sample or display its affected range on the active Develop canvas.", "job_id or native point-color state")
        case .spotRepairs:
            ("Page through clone, heal and remove repairs for this photo version. Supply spot_id for the full path and a current preview_id to read a rendered automatic source.", "items, next_offset, selected_spot_id and photo revisions")
        case .editSpot:
            ("Add a point or path, move a target, or set a source_point on a current editable preview. Supply source_preview_id to pick the source from a different preview of the same saved or draft version. Edit brush settings, select in the native workspace, refresh an alternative source, return to automatic source, or delete by spot_id.", "job_id or native spot selection")
        default: nil
        }
    }
}

extension AppMCPTools {
    static func canvasState(_ model: AppModel) -> [String: Value] {
        let guides: Value = .array(model.perspectiveGuides.enumerated().map { index, guide in
            ["point_index": .int(index), "source_start": MCPCanvasFields.pointValue(guide.start),
             "source_end": MCPCanvasFields.pointValue(guide.end), "vertical": .bool(guide.vertical)]
        })
        return ["crop_guide": .string(model.cropGuide.rawValue), "spot_guides": .bool(model.showSpotGuides),
                "perspective_guides": guides,
                "guide_mode": model.perspectiveGuideTool.map { $0 == .straighten ? "straighten" : "perspective" } ?? .null,
                "selected_guide_index": model.selectedPerspectiveGuideIndex.map(Value.int) ?? .null,
                "guide_status": .string(model.perspectiveMessage),
                "selected_spot_id": model.recipe?.repairs.first(where: { $0.id == model.selectedSpotID }).map { .string($0.id.uuidString) } ?? .null,
                "selected_point_color_id": model.selectedPointColorID.map { .string($0.uuidString) } ?? .null,
                "point_color_affected_range": .bool(model.showPointColorRange)]
    }

    func sampleCanvas(_ args: [String: Value], model: AppModel, catalog: CatalogStore, session: String) async throws -> MCPToolResult {
        let draft = try requestedDraft(args)
        let preview = try canvasPreview(args["preview_id"], catalog: catalog, draft: draft?.reference)
        var data = draft?.fields ?? [:]
        data["preview_id"] = .string(preview.id)
        let point = MCPCanvasFields.point(args["point"]!)!
        if args["action"] == "zone" {
            guard preview.variant == "saved", let photo = try catalog.photo(preview.photoID),
                  let root = model.roots.first(where: { $0.id == photo.rootID }) else { throw MCPToolProblem.staleCanvasPreview }
            let pipeline = model.pipeline
            let worker = Task.detached {
                let recipe = if let draft { draft.recipe } else { try await MCPDevelopPhoto.recipe(for: photo, root: root, pipeline: pipeline) }
                _ = try preview.sourcePoint(point, recipe: recipe)
                return try await pipeline.sampleZone(.init(photo: photo, root: root, recipe: recipe), at: preview.outputPoint(point))
            }
            guard let sample = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            else { throw MCPToolProblem.noCanvasSample }
            try verifyCanvasRead(session, model: model)
            _ = try canvasPreview(args["preview_id"], catalog: catalog, draft: draft?.reference)
            data["zone"] = .int(ToneZones.nearest(to: sample))
            data["ev"] = .double(sample)
            return .init("Read the native luminance zone.", data: data)
        }
        guard let sample = preview.sampler.sample(topLeftX: point.x, y: point.y) else { throw MCPToolProblem.noCanvasSample }
        let codes = [sample.red, sample.green, sample.blue]
        data["pixel"] = ["x": .int(sample.x), "y": .int(preview.height - 1 - sample.y)]
        data["rgba"] = .array((codes + [sample.alpha]).map { .int(Int($0)) })
        data["clipping"] = ["highlights": .bool(sample.alpha != 0 && codes.contains(255)),
                            "shadows": .bool(sample.alpha != 0 && codes.contains(0))]
        return .init("Read an sRGB pixel from the preview.", data: data)
    }

    func writeCanvas(_ tool: AppMCPTool, args: [String: Value], model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        if tool == .canvasGuides {
            let crop = args["crop_guide"]?.stringValue.flatMap(CropGuide.init(rawValue:))
            let spots = args["spot_guides"]?.boolValue
            guard crop != nil || spots != nil else { throw MCPToolProblem.invalid("Supply a crop guide or spot guide visibility.") }
            if let crop { model.cropGuide = crop }
            if let spots { model.showSpotGuides = spots }
            return .init("Updated the canvas guide display.", data: Self.canvasState(model))
        }
        let photo = try MCPDevelopPhoto.current(args, catalog: catalog)
        switch tool {
        case .setCrop: return try writeCrop(tool, args: args, photo: photo, model: model, catalog: catalog)
        case .photoGeometry:
            let keys = ["turns", "straighten", "flip_horizontal", "flip_vertical", "perspective"]
            guard keys.contains(where: { args[$0] != nil }) else { throw MCPToolProblem.invalid("Specify a geometry change.") }
            return startCanvasEdit(tool, model: model, catalog: catalog, photo: photo, title: L10n.text("app.adjustPhoto", defaultValue: "Adjust Photo")) { request, original, pipeline in
                var value = original
                if let turns = args["turns"]?.intValue { value.rotateCanvas(by: turns) }
                if let straighten = args["straighten"]?.number { value.straightenDegrees = straighten }
                if let horizontal = args["flip_horizontal"]?.boolValue { value.flipHorizontal = horizontal }
                if let vertical = args["flip_vertical"]?.boolValue { value.flipVertical = vertical }
                if let settings = args["perspective"]?.objectValue {
                    if let h = settings["horizontal"]?.number { value.perspective.horizontal = h }
                    if let v = settings["vertical"]?.number { value.perspective.vertical = v }
                    if let aspect = settings["aspect"]?.number { value.perspective.aspect = aspect }
                    if let constrain = settings["constrain_crop"]?.boolValue { value.perspective.constrainCrop = constrain }
                }
                let size = try await pipeline.geometrySourceSize(request)
                return (value, ["geometry": MCPCanvasFields.geometry(value, size: size)])
            }
        case .solvePerspective:
            let mode = UprightMode(rawValue: args["mode"]!.stringValue!)!
            let detect = model.detectPerspectiveLines
            return startCanvasEdit(tool, model: model, catalog: catalog, photo: photo, title: mode.title) { request, original, pipeline in
                let size = try await pipeline.geometrySourceSize(request)
                let detected = try await detect(request)
                let lines = detected.compactMap { UprightCorrection.classified(start: $0.start, end: $0.end, weight: $0.weight, size: size, recipe: original) }
                let result = UprightCorrection.automatic(mode, lines: lines, size: size, recipe: original)
                let value = result ?? original
                return (value, ["solution": result == nil ? "no_agreement" : "solved",
                                "line_count": .int(lines.count), "geometry": MCPCanvasFields.geometry(value, size: size)])
            }
        case .perspectiveGuides: return try writeGuides(args, photo: photo, model: model, catalog: catalog)
        case .adjustPreview: return try writeCanvasAdjustment(tool, args: args, photo: photo, model: model, catalog: catalog)
        case .pointColor: return try writePointColor(tool, args: args, photo: photo, model: model, catalog: catalog)
        case .editSpot: return try writeSpot(tool, args: args, photo: photo, model: model, catalog: catalog)
        default: throw MCPToolProblem.failed
        }
    }

    private func writeCrop(_ tool: AppMCPTool, args: [String: Value], photo: Photo, model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        let action = args["action"]!.stringValue!
        let rect = args["rect"].flatMap(MCPCanvasFields.rect)
        let aspect = args["aspect_ratio"]?.number
        guard (action == "set") == (rect != nil), (action == "set_aspect") == (aspect != nil),
              (action == "set") == (args["preview_id"] != nil) else { throw MCPToolProblem.invalid("Supply the rectangle and crop preview, or the ratio, for this crop action.") }
        let preview = try rect.map { _ in try canvasPreview(args["preview_id"], catalog: catalog, photo: photo, variant: "crop_canvas") }
        return startCanvasEdit(tool, model: model, catalog: catalog, photo: photo, title: L10n.text("app.cropAndStraighten", defaultValue: "Crop and Straighten"),
                               preview: preview) { request, original, pipeline in
            let size = if let preview { preview.sourceSize } else { try await pipeline.geometrySourceSize(request) }
            var value = original
            let w = value.quarterTurns % 2 == 0 ? size.width : size.height
            let h = value.quarterTurns % 2 == 0 ? size.height : size.width
            let currentAspect = w * value.crop.width / (h * value.crop.height)
            switch action {
            case "set":
                let box = preview!.outputRect(rect!)
                if let lock = value.cropAspectRatio, abs(w * box.width / (h * box.height) - lock) > 0.00001 {
                    throw MCPToolProblem.invalid("The rectangle does not fit the current aspect lock.")
                }
                value.crop = value.cropFromDisplay(Crop(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
            case "set_aspect", "rotate_aspect":
                let ratio = aspect ?? 1 / (value.cropAspectRatio ?? currentAspect)
                guard (0.1...10).contains(ratio) else { throw MCPToolProblem.invalid("The resulting aspect ratio is out of range.") }
                value.cropAspectRatio = ratio
                value.crop = .centered(aspectRatio: ratio, orientedCanvas: size, quarterTurns: value.quarterTurns)
            case "lock":
                guard (0.1...10).contains(currentAspect) else { throw MCPToolProblem.invalid("The current aspect ratio is out of range.") }
                if value.cropAspectRatio == nil { value.cropAspectRatio = currentAspect }
            case "unlock": value.cropAspectRatio = nil
            default: value.crop = Crop(); value.cropAspectRatio = nil
            }
            return (value, ["geometry": MCPCanvasFields.geometry(value, size: size)])
        }
    }

    private func writeGuides(_ args: [String: Value], photo: Photo, model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        guard model.activeID == photo.id, model.active?.recipeRevision == photo.recipeRevision, model.cropMode, model.canEdit,
              let recipe = model.recipe else { throw MCPToolProblem.developUnavailable }
        let action = args["action"]!.stringValue!
        let index = args["point_index"]?.intValue
        let endpoint = args["endpoint"]?.stringValue.map { $0 == "start" ? PerspectiveGuideEndpoint.start : .end }
        let usesPoints = action == "add" || action == "move_endpoint"
        let supplied = Set(["guide_mode", "point_index", "endpoint", "preview_id", "start", "end", "point"].filter { args[$0] != nil })
        let valid: Bool = switch action {
        case "begin": supplied == ["guide_mode"]
        case "add": supplied == ["preview_id", "start", "end"]
        case "move_endpoint": supplied == ["point_index", "endpoint", "preview_id", "point"]
        case "select": supplied.isSubset(of: ["point_index", "endpoint"]) && (endpoint == nil || index != nil)
        case "delete": supplied.isSubset(of: ["point_index"])
        default: supplied.isEmpty
        }
        guard valid else { throw MCPToolProblem.invalid("Supply the fields for the requested guide action.") }
        let preview = try usesPoints ? canvasPreview(args["preview_id"], catalog: catalog, photo: photo, variant: "crop_canvas") : nil
        if let preview, model.orientedSourceSize != preview.sourceSize { throw MCPToolProblem.developUnavailable }
        if action != "begin", !["finish", "cancel"].contains(action), model.perspectiveGuideTool == nil {
            throw MCPToolProblem.invalid("Begin the native guide session first.")
        }
        switch action {
        case "begin":
            guard let mode = args["guide_mode"]?.stringValue else { throw MCPToolProblem.invalid("Specify guide_mode.") }
            let tool: PerspectiveGuideTool = mode == "straighten" ? .straighten : .perspective
            if model.perspectiveGuideTool != tool { model.beginPerspectiveGuides(tool) }
        case "clear": model.clearPerspectiveGuides()
        case "finish": model.finishPerspectiveGuides()
        case "cancel": model.cancelPerspectiveGuideInteraction()
        case "select":
            guard model.selectPerspectiveGuide(index: index, endpoint: endpoint) else { throw MCPToolProblem.invalid("Select an existing guide.") }
        default:
            var perform: () -> Void
            if action == "add" {
                guard let a = args["start"].flatMap(MCPCanvasFields.point), let b = args["end"].flatMap(MCPCanvasFields.point), let preview else {
                    throw MCPToolProblem.invalid("Provide start and end points on the crop canvas.")
                }
                let start = try preview.sourcePoint(a, recipe: recipe), end = try preview.sourcePoint(b, recipe: recipe)
                perform = { model.addPerspectiveGuide(start: start, end: end) }
            } else if action == "move_endpoint" {
                guard let index, model.perspectiveGuides.indices.contains(index), let endpoint,
                      let point = args["point"].flatMap(MCPCanvasFields.point), let preview else {
                    throw MCPToolProblem.invalid("Provide an existing guide index, endpoint and point.")
                }
                let source = try preview.sourcePoint(point, recipe: recipe)
                perform = {
                    if model.updatePerspectiveGuide(index: index, endpoint: endpoint, point: source) { _ = model.endPerspectiveGuideDrag() }
                }
            } else {
                guard let index = index ?? model.selectedPerspectiveGuideIndex, model.selectPerspectiveGuide(index: index) else {
                    throw MCPToolProblem.invalid("Select an existing guide before deleting it.")
                }
                perform = { _ = model.deleteSelectedPerspectiveGuide() }
            }
            withCanvasUndo(model, perform)
        }
        guard let saved = try catalog.photo(photo.id) else { return .init(.failed, commitState: "unknown") }
        let changed = saved.recipeRevision != photo.recipeRevision
        var data = MCPDevelopPhoto.revisions(saved)
        data.merge(Self.canvasState(model)) { _, value in value }
        if let recipe = model.recipe { data["geometry"] = MCPCanvasFields.geometry(recipe, size: model.orientedSourceSize) }
        data["commit_state"] = changed ? "committed" : "not_committed"
        data["operation_id"] = changed ? recordRecipeUndo(before: [photo], after: [saved]) : .null
        return .init("Read the resulting native perspective guides.", data: data, warning: model.dirty)
    }

    func withCanvasUndo(_ model: AppModel, _ perform: () -> Void) {
        let groupsByEvent = model.undo.groupsByEvent
        model.undo.groupsByEvent = false
        model.undo.beginUndoGrouping()
        perform()
        model.undo.endUndoGrouping()
        model.undo.groupsByEvent = groupsByEvent
    }

    private func writeCanvasAdjustment(_ tool: AppMCPTool, args: [String: Value], photo: Photo, model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        let preview = try canvasPreview(args["preview_id"], catalog: catalog, photo: photo, variant: "saved")
        let action = args["action"]!.stringValue!
        let point = args["point"].flatMap(MCPCanvasFields.point)
        let delta = args["delta"]?.number
        guard (action == "histogram") == (args["histogram_region"] != nil),
              (action == "curve") == (args["channel"] != nil),
              (action != "histogram") == (point != nil),
              action == "white_balance" ? delta == nil : (action.hasPrefix("defringe_") || delta != nil) else {
            throw MCPToolProblem.invalid("Supply the point, channel or histogram region and delta appropriate to the adjustment.")
        }
        return startCanvasEdit(tool, model: model, catalog: catalog, photo: photo, title: L10n.text("app.adjustPhoto", defaultValue: "Adjust Photo"),
                               preview: preview) { request, original, pipeline in
            var value = original
            if action == "histogram" {
                let index = MCPCanvasFields.histogramRegions.firstIndex(of: args["histogram_region"]!.stringValue!)!
                let region = HistogramRegion(rawValue: index)!
                let raw = region.value(in: value) + delta!
                let new = min(region.range.upperBound, max(region.range.lowerBound, (raw / region.step).rounded() * region.step))
                region.set(new, in: &value)
                return (value, ["value": .double(new)])
            }
            let output = preview.outputPoint(point!)
            _ = try preview.sourcePoint(point!, recipe: original)
            if action == "white_balance" {
                let white = try await pipeline.sampledWhiteBalance(request, at: output)
                value.asShotWhiteBalance = false; value.temperature = white.temperature; value.tint = white.tint
                return (value, ["temperature": .double(white.temperature), "tint": .double(white.tint)])
            }
            let target: TargetedAdjustment = switch action {
            case "hue": .hue
            case "saturation": .saturation
            case "luminance": .luminance
            case "black_white": .blackWhite
            case "defringe_purple": .defringePurple
            case "defringe_green": .defringeGreen
            default: .curve(MCPDevelopParameters.channels.firstIndex(of: args["channel"]!.stringValue!)!)
            }
            guard target.available(in: original) else { throw MCPToolProblem.invalidEdit }
            let reference = try await pipeline.pointColorReference(.init(photo: request.photo, root: request.root, recipe: target.referenceRecipe(original)),
                                                                   longEdge: target.isDefringe ? 2048 : 1024, nativeDecode: target.isDefringe)
            guard let rgb = reference.linearRGB(at: output, radius: target.isDefringe ? 0 : 1),
                  let sample = target.sample(rgb: rgb, recipe: original) else { throw MCPToolProblem.noCanvasSample }
            value = try sample.applying(delta: delta ?? 0, to: original)
            return (value, ["weights": .array(sample.weights.map(Value.double)), "curve_input": sample.curveInput.map(Value.double) ?? .null,
                            "fringe_hue": sample.fringeHue.map(Value.double) ?? .null])
        }
    }

    private func writePointColor(_ tool: AppMCPTool, args: [String: Value], photo: Photo, model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        let action = args["action"]!.stringValue!
        let id = args["sample_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let point = args["point"].flatMap(MCPCanvasFields.point)
        guard (action == "add") == (point != nil), (action == "add") == (args["preview_id"] != nil),
              (action == "set") == (args["adjustments"] != nil), (action == "display") == (args["affected_range"] != nil),
              (action == "add" ? args["sample_id"] == nil : action == "display" && args["sample_id"] == nil || id != nil) else {
            throw MCPToolProblem.invalid("Supply a position on a saved preview, a sample ID, or display settings for the chosen action.")
        }
        if action == "select" || action == "display" {
            guard model.activeID == photo.id, model.active?.recipeRevision == photo.recipeRevision, model.canEdit,
                  model.editMode, model.developTool == .adjust, let recipe = model.recipe else { throw MCPToolProblem.developUnavailable }
            let show = args["affected_range"]?.boolValue
            guard show != true || !recipe.develop.pointColors.isEmpty else {
                throw MCPToolProblem.invalid("Save a point-color sample before showing its affected range.")
            }
            if let id {
                guard recipe.develop.pointColors.contains(where: { $0.id == id }) else { throw MCPToolProblem.invalid("This point-color sample is unavailable.") }
                model.selectedPointColorID = id
            }
            if let show { model.showPointColorRange = show } else { model.refreshPointColorTools() }
            return .init("Updated point-color display.", data: Self.canvasState(model))
        }
        let preview = try action == "add" ? canvasPreview(args["preview_id"], catalog: catalog, photo: photo, variant: "saved") : nil
        return startCanvasEdit(tool, model: model, catalog: catalog, photo: photo, title: L10n.text("app.pointColorAdjustment", defaultValue: "Point Color Adjustment"),
                               preview: preview) { request, original, pipeline in
            var value = original
            if let preview, let point {
                guard original.pipelineVersion == 2, !original.develop.blackAndWhite, original.develop.pointColors.count < 8 else {
                    throw MCPToolProblem.invalidEdit
                }
                _ = try preview.sourcePoint(point, recipe: original)
                let reference = try await pipeline.pointColorReference(request)
                guard let sample = reference.sample(at: preview.outputPoint(point)) else { throw MCPToolProblem.noCanvasSample }
                value.develop.pointColors.append(sample)
                return (value, ["sample": MCPCanvasFields.pointColor(sample)])
            }
            guard let index = value.develop.pointColors.firstIndex(where: { $0.id == id }) else {
                throw MCPToolProblem.invalid("This point-color sample is unavailable.")
            }
            if action == "delete" { value.develop.pointColors.remove(at: index) }
            else if action == "reset" { value.develop.pointColors[index].resetAdjustments() }
            else { MCPCanvasFields.applyPointColor(args["adjustments"]!.objectValue!, to: &value.develop.pointColors[index]) }
            return (value, ["point_colors": .array(value.develop.pointColors.map(MCPCanvasFields.pointColor))])
        }
    }
}
