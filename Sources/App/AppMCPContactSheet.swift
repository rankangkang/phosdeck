import CoreGraphics
import CoreText
import MCP

struct MCPContactSheet: Sendable {
    static let defaultCount = 12
    static let maximumCount = 24

    let data: [String: Value]
    let cells: [[String: Value]]
    let png: String
    let unavailableCount: Int

    static func render(photos: [Photo], offset: Int, roots: [StorageRoot], thumbnails: ThumbnailService,
                       pipeline: ImagePipeline) async throws -> Self {
        let columns = min(4, photos.count)
        let rows = (photos.count + columns - 1) / columns
        let imageWidth = 192, imageHeight = 144, numberHeight = 24, spacing = 8
        let cellWidth = imageWidth + 2 * spacing, cellHeight = imageHeight + numberHeight + 2 * spacing
        let width = columns * cellWidth, height = rows * cellHeight
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: ImagePipeline.outputSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw MCPToolProblem.failed }
        let gray = PhotoMat.dark.gray
        context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.textMatrix = .identity
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, 15, nil)
        let foreground = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: foreground] as [CFString: Any]
        let rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        var cells: [[String: Value]] = []
        var unavailable = 0
        for (index, photo) in photos.enumerated() {
            try Task.checkCancellation()
            let number = offset + index + 1
            let x = index % columns * cellWidth, y = index / columns * cellHeight
            let cell = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
            let area = CGRect(x: x + spacing, y: y + spacing, width: imageWidth, height: imageHeight)
            let thumbnail = try await thumbnail(photo, root: rootsByID[photo.rootID], service: thumbnails, pipeline: pipeline)
            var imagePixels: Value = .null
            let label: String
            if let image = thumbnail.image {
                let scale = min(1, area.width / CGFloat(image.width), area.height / CGFloat(image.height))
                let width = max(1, (CGFloat(image.width) * scale).rounded(.down))
                let height = max(1, (CGFloat(image.height) * scale).rounded(.down))
                let bounds = CGRect(x: (area.midX - width / 2).rounded(.down), y: (area.midY - height / 2).rounded(.down),
                                    width: width, height: height)
                let destination = CGRect(x: bounds.minX, y: CGFloat(context.height) - bounds.maxY,
                                         width: bounds.width, height: bounds.height)
                context.draw(image, in: destination)
                imagePixels = MCPCanvasFields.pixelRectValue(bounds)
                label = String(number)
            } else {
                unavailable += 1
                label = String(number) + " ×"
            }
            let text = CFAttributedStringCreate(nil, label as CFString, attributes as CFDictionary)!
            context.textPosition = CGPoint(x: x + spacing, y: height - y - cellHeight + spacing)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            cells.append(["cell_pixels": MCPCanvasFields.pixelRectValue(cell), "image_pixels": imagePixels,
                          "thumbnail_status": .string(thumbnail.image == nil ? "unavailable" : "ready"),
                          "thumbnail_error": thumbnail.problem.map { .string($0.code) } ?? .null])
        }
        try Task.checkCancellation()
        guard let bitmap = context.makeImage() else { throw MCPToolProblem.failed }
        return Self(data: ["width": .int(width), "height": .int(height), "columns": .int(columns),
                           "rows": .int(rows), "coordinate_space": "pixels_top_left",
                           "unavailable_count": .int(unavailable)],
                    cells: cells, png: try MCPOutputImage.png(bitmap), unavailableCount: unavailable)
    }

    private static func thumbnail(_ photo: Photo, root: StorageRoot?, service: ThumbnailService, pipeline: ImagePipeline) async throws
        -> (image: CGImage?, problem: MCPToolProblem?) {
        guard photo.availability == "available", let root else { return (nil, .fileAccess) }
        do {
            let recipe = try photo.recipe.map { try MCPDevelopPhoto.decode($0, for: photo) }
            // Grid cache hits skip the source read. Sharing a photo still requires
            // the same saved identity and digest checks used by quality previews.
            let image = try await service.image(photo: photo, root: root)
            do { try pipeline.verifySource(.init(photo: photo, root: root, recipe: recipe)) }
            catch { return (nil, .fileAccess) }
            return (image, nil)
        } catch is CancellationError { throw CancellationError() }
        catch let problem as MCPToolProblem { return (nil, problem) }
        catch { return (nil, .failed) }
    }
}
