import Foundation

struct XMPPresetDraft: Equatable {
    var name: String
    var group: String
    var settings: XMPPresetSettings
    func record() throws -> AdjustmentPreset {
        let source = EditRecipe(sourceDigest: String(repeating: "0", count: 64), decoderVersion: "xmp-preset",
                                baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
        var options = settings.options
        options.importedXMP = settings
        return AdjustmentPreset(id: UUID().uuidString, name: name, recipe: try JSONEncoder().encode(source),
                                options: try JSONEncoder().encode(options), groupName: group)
    }
}

struct XMPPresetImportItem: Identifiable {
    let id = UUID()
    var filename: String
    var draft: XMPPresetDraft?
    var error: String?
    var canImport: Bool { draft?.settings.hasContent == true && error == nil }
    var title: String { draft?.name ?? filename }
    var issues: [String] { (draft?.settings.warnings ?? []) + [error].compactMap { $0 } }
}

enum XMPPresetReader {
    static let maximumBytes = 4 * 1024 * 1024
    static let maximumFiles = 128
    static let crsURI = "http://ns.adobe.com/camera-raw-settings/1.0/"
    static let rdfURI = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"

    static func read(_ url: URL) -> XMPPresetImportItem {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            guard url.pathExtension.lowercased() == "xmp" else { throw LRCError(L10n.text("app.onlyXmpPresetFilesAreSupported", defaultValue: "Only .xmp preset files are supported")) }
            guard try url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw LRCError(L10n.text("app.chooseARegularXMPFile", defaultValue: "Choose a regular XMP file")) }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
            let draft = try parse(data, filename: url.lastPathComponent)
            return XMPPresetImportItem(filename: url.lastPathComponent, draft: draft,
                                       error: draft.settings.hasContent ? nil : L10n.text("app.noImportableGlobalAdjustmentsNoPresetCreated", defaultValue: "No importable global adjustments. No preset created"))
        } catch { return XMPPresetImportItem(filename: url.lastPathComponent, error: error.localizedDescription) }
    }

    static func parse(_ data: Data, filename: String) throws -> XMPPresetDraft {
        guard data.count <= maximumBytes else { throw LRCError(L10n.text("app.theXMPFileExceedsThe4MiBLimit", defaultValue: "The XMP file exceeds the 4 MiB limit")) }
        guard let text = String(data: data, encoding: .utf8) else { throw LRCError(L10n.text("app.xmpMustUseUTF8Encoding", defaultValue: "XMP must use UTF-8 encoding")) }
        guard text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { throw LRCError(L10n.text("app.xmpCannotContainDTDOrEntityDeclarations", defaultValue: "XMP cannot contain DTD or entity declarations")) }
        let reader = PresetXMLReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = reader
        guard parser.parse(), reader.failure == nil else {
            throw LRCError(reader.failure ?? L10n.text("app.invalidXMPXMLLine", defaultValue: "Invalid XMP XML (line \(parser.lineNumber))"))
        }
        return try convert(reader.properties(), filename: filename)
    }

    static func convert(_ props: [String: [String]], filename: String) throws -> XMPPresetDraft {
        guard !props.isEmpty else { throw LRCError(L10n.text("app.noAdobeCRSAdjustmentsFoundChooseALightroomClassic", defaultValue: "No Adobe CRS adjustments found. Choose a Lightroom Classic XMP preset")) }
        func scalar(_ key: String) -> String? { props[key]?.first }
        if let applied = scalar("AlreadyApplied") {
            guard let flag = boolean(applied) else { throw LRCError(L10n.text("app.invalidCrsAlreadyAppliedBoolean", defaultValue: "Invalid crs:AlreadyApplied Boolean")) }
            if flag { throw LRCError(L10n.text("app.crsAlreadyAppliedTrueAdjustmentsAreBakedIntoThePixels", defaultValue: "crs:AlreadyApplied=True: adjustments are baked into the pixels and cannot be applied again as a preset")) }
        }
        if let kind = scalar("PresetType"), kind.lowercased() != "normal" {
            throw LRCError(L10n.text("app.crsPresetTypeOnlyGlobalDevelopmentPresetsAreSupportedThis", defaultValue: "crs:PresetType=\(kind): only global development presets are supported. This type was not imported"))
        }
        let name = scalar("Name").flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let group = scalar("Group").flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("app.lightroomImport", defaultValue: "Lightroom Import")
        guard (1...100).contains(name.count), group.count <= 100 else { throw LRCError(L10n.text("app.presetNamesAndGroupsMustBeWithin100Characters", defaultValue: "Preset names and groups must be within 100 characters")) }
        var settings = XMPPresetSettings()
        var handled = metadata
        func unsupported(_ key: String, _ reason: String) {
            let value = (props[key] ?? []).joined(separator: ", ")
            settings.unsupported.append("crs:\(key)\(value.isEmpty ? "" : " = " + String(value.prefix(160)))：\(reason)")
        }
        for (key, control) in XMPPresetSettings.controls where props[key] != nil {
            handled.insert(key)
            guard props[key]?.count == 1, let raw = scalar(key), let value = Double(raw), value.isFinite else {
                unsupported(key, L10n.text("app.invalidValueNotApplied", defaultValue: "Invalid value; not applied")); continue
            }
            let clamped = min(control.range.upperBound, max(control.range.lowerBound, value))
            settings.values[key] = clamped
            if value != clamped { settings.notes.append(L10n.text("app.crsOutsideTheSupportedRangeClampedTo", defaultValue: "crs:\(key) = \(raw): outside the supported range; clamped to \(clamped)")) }
        }
        if let raw = scalar("WhiteBalance") {
            handled.insert("WhiteBalance")
            switch raw.replacingOccurrences(of: " ", with: "").lowercased() {
            case "asshot": settings.whiteBalance = "asShot"
            case "custom":
                if settings.values["Temperature"] == nil && settings.values["Tint"] == nil { unsupported("WhiteBalance", L10n.text("app.validTemperatureOrTintMissingNotApplied", defaultValue: "Valid temperature or tint missing; not applied")) }
            default: unsupported("WhiteBalance", L10n.text("app.automaticOrNamedWhiteBalanceIsUnsupportedModeNot", defaultValue: "Automatic or named white balance is unsupported; mode not applied"))
                settings.values.removeValue(forKey: "Temperature"); settings.values.removeValue(forKey: "Tint")
            }
        }
        if settings.contains(.whiteBalance) { settings.notes.append(L10n.text("app.absoluteWhiteBalanceAppliesOnlyToRAWJPEGTIFF", defaultValue: "Absolute white balance applies only to RAW. JPEG/TIFF/PNG white balance is preserved. Temperature values do not guarantee the Adobe appearance.")) }
        if let raw = scalar("ConvertToGrayscale") {
            handled.insert("ConvertToGrayscale")
            if let flag = boolean(raw) { settings.blackAndWhite = flag }
            else { unsupported("ConvertToGrayscale", L10n.text("app.invalidBooleanNotApplied", defaultValue: "Invalid Boolean; not applied")) }
        }
        if let raw = scalar("PostCropVignetteStyle") {
            handled.insert("PostCropVignetteStyle")
            switch Int(raw) {
            case 1: settings.vignetteStyle = .highlightPriority
            case 2: settings.vignetteStyle = .colorPriority
            case 3: settings.vignetteStyle = .paintOverlay
            default: unsupported("PostCropVignetteStyle", L10n.text("app.unsupportedVignetteStyleTargetStylePreserved", defaultValue: "Unsupported vignette style. Target style preserved"))
            }
        }
        var parsedCurves: [String: [CurvePoint]] = [:]
        for key in XMPPresetSettings.curveFields where props[key] != nil {
            handled.insert(key)
            do { parsedCurves[key] = try curve(props[key] ?? []) }
            catch { unsupported(key, L10n.text("app.aCurveNeeds216OrderedControlPointsInput", defaultValue: "A curve needs 2–16 ordered control points, input endpoints 0/255, and coordinates within 0–255; not applied")) }
        }
        let master = XMPPresetSettings.curveFields[0]
        settings.curves[master] = parsedCurves[master]
        for key in XMPPresetSettings.curveFields.dropFirst() where parsedCurves[key] != nil {
            if parsedCurves.count == 4 { settings.curves[key] = parsedCurves[key] }
            else { unsupported(key, L10n.text("app.aValidMasterCurveAndAllThreeRGBChannel", defaultValue: "A valid master curve and all three RGB channel curves are required; not applied")) }
        }
        if settings.curves[master] != nil { settings.notes.append(L10n.text("app.theToneCurvePV2012MasterCurveIsInterpretedAsALuminance", defaultValue: "The ToneCurvePV2012 master curve is interpreted as a luminance curve. Interpolation and color response approximate Lightroom.")) }
        for key in props.keys.sorted() where !handled.contains(key) {
            let reason: String
            switch key {
            case "Look", "CameraProfile": reason = L10n.text("app.adobeCameraAndCreativeProfilesAreUnsupportedTargetAppearance", defaultValue: "Adobe, camera, and creative profiles are unsupported. Target appearance preserved")
            case "MaskGroupBasedCorrections", "GradientBasedCorrections", "CircularGradientBasedCorrections", "PaintBasedCorrections": reason = L10n.text("app.localMasksAndTheirAdjustmentsAreNotImported", defaultValue: "Local masks and their adjustments are not imported")
            case "RetouchAreas", "RetouchInfo": reason = L10n.text("app.spotRemovalPositionsAreNotImported", defaultValue: "Spot removal positions are not imported")
            default: reason = L10n.text("app.noCorrespondingConversionIsAvailableNotApplied", defaultValue: "No corresponding conversion is available; not applied")
            }
            unsupported(key, reason)
        }
        settings.unsupported.sort()
        settings.notes.sort()
        return XMPPresetDraft(name: name, group: group, settings: settings)
    }

    private static let metadata: Set<String> = [
        "Version", "ProcessVersion", "Name", "ShortName", "Group", "UUID", "PresetType", "AlreadyApplied", "HasSettings",
        "SupportsAmount", "SupportsAmount2", "SupportsColor", "SupportsMonochrome", "SupportsHighDynamicRange",
        "SupportsNormalDynamicRange", "SupportsSceneReferred", "SupportsOutputReferred", "Cluster", "SortName", "Description",
        "Copyright", "ContactInfo", "RawFileName", "CompatibleVersion"
    ]
    private static func boolean(_ raw: String) -> Bool? {
        switch raw.lowercased() { case "true", "1": true; case "false", "0": false; default: nil }
    }
    private static func curve(_ entries: [String]) throws -> [CurvePoint] {
        let points = try entries.map { entry -> CurvePoint in
            let parts = entry.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { throw LRCError(L10n.text("app.invalidCurvePoint", defaultValue: "Invalid curve point")) }
            return CurvePoint(x: x / 255, y: y / 255)
        }
        var test = ToneCurves(); test.channels[0] = points; try test.validate()
        return points
    }
}

/// Namespace URIs, rather than literal prefixes, identify Adobe and RDF properties.
private final class PresetXMLReader: NSObject, XMLParserDelegate {
    final class Node {
        var name: String; var uri: String; var text = ""
        var attributes: [String: String] = [:]; var children: [Node] = []
        init(_ name: String, _ uri: String) { self.name = name; self.uri = uri }
        var values: [String] {
            if let alt = children.first(where: { $0.uri == XMPPresetReader.rdfURI && $0.name == "Alt" }) {
                let item = alt.children.first { $0.attributes["http://www.w3.org/XML/1998/namespace|lang"] == "x-default" } ?? alt.children.first
                return item?.values ?? []
            }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return [value] }
            return attributes.keys.sorted().filter { $0.hasPrefix(XMPPresetReader.crsURI + "|") }.compactMap { attributes[$0] }
                + children.flatMap(\.values)
        }
    }
    var failure: String?
    private var stack: [Node] = []
    private var roots: [Node] = []
    private var bindings = ["xml": ["http://www.w3.org/XML/1998/namespace"]]
    private var count = 0
    private func fail(_ parser: XMLParser, _ message: String) { failure = message; parser.abortParsing() }
    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) { bindings[prefix, default: []].append(namespaceURI) }
    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) { _ = bindings[prefix]?.popLast() }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        count += 1
        guard stack.count < 32, count <= 10000 else { fail(parser, L10n.text("app.xmpNestingOrNodeCountExceedsTheLimit", defaultValue: "XMP nesting or node count exceeds the limit")); return }
        let node = Node(elementName, namespaceURI ?? "")
        for (key, value) in attributeDict {
            let parts = key.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let uri = bindings[String(parts[0])]?.last else { continue }
            let resolved = uri + "|" + parts[1]
            if node.attributes[resolved] != nil { fail(parser, L10n.text("app.xmpContainsDuplicateNamespaceAttributes", defaultValue: "XMP contains duplicate namespace attributes")); return }
            node.attributes[resolved] = value
        }
        if let parent = stack.last { parent.children.append(node) } else { roots.append(node) }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let node = stack.last else { return }
        guard node.text.utf8.count + string.utf8.count <= 65536 else { fail(parser, L10n.text("app.xmpAttributeTextExceedsThe64KiBLimit", defaultValue: "XMP attribute text exceeds the 64 KiB limit")); return }
        node.text += string
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else { fail(parser, L10n.text("app.invalidXMPTextEncoding", defaultValue: "Invalid XMP text encoding")); return }
        self.parser(parser, foundCharacters: text)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { _ = stack.popLast() }
    func properties() throws -> [String: [String]] {
        func rdfNodes(_ node: Node) -> [Node] {
            node.uri == XMPPresetReader.rdfURI && node.name == "RDF" ? [node] : node.children.flatMap(rdfNodes)
        }
        let rdf = roots.flatMap(rdfNodes)
        guard !rdf.isEmpty else { throw LRCError(L10n.text("app.xmpIsMissingRdfRDF", defaultValue: "XMP is missing rdf:RDF")) }
        var result: [String: [String]] = [:]
        func add(_ key: String, _ value: [String]) throws {
            if let old = result[key], old != value { throw LRCError(L10n.text("app.xmpContainsConflictingFieldsCrs", defaultValue: "XMP contains conflicting fields: crs:\(key)")) }
            result[key] = value
        }
        for description in rdf.flatMap(\.children) where description.uri == XMPPresetReader.rdfURI && description.name == "Description" {
            let prefix = XMPPresetReader.crsURI + "|"
            for (key, value) in description.attributes where key.hasPrefix(prefix) { try add(String(key.dropFirst(prefix.count)), [value.trimmingCharacters(in: .whitespacesAndNewlines)]) }
            for child in description.children where child.uri == XMPPresetReader.crsURI { try add(child.name, child.values) }
        }
        return result
    }
}
