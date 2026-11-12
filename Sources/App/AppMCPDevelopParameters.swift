import Foundation
import MCP

enum MCPRecipeGroups {
    private static let fields: [String: WritableKeyPath<RecipePasteOptions, Bool>] = [
        "tone": \.tone, "white_balance": \.whiteBalance, "color": \.color, "geometry": \.geometry,
        "raw_detail": \.details, "general_detail": \.generalDetails, "curves": \.curves, "zones": \.zones
    ]
    static var keys: [String] { fields.keys.sorted() }
    static func names(_ options: RecipePasteOptions) -> Value {
        .array(keys.filter { options[keyPath: fields[$0]!] }.map(Value.string))
    }
    static func options(_ argument: Value?, defaults: RecipePasteOptions? = nil) throws -> RecipePasteOptions {
        guard argument != nil || defaults != nil else { throw MCPToolProblem.invalid("Specify the adjustment groups.") }
        var options = defaults ?? RecipePasteOptions()
        if let names = argument?.arrayValue {
            let selected = Set(names.compactMap(\.stringValue))
            let available = defaults
            for (name, keyPath) in fields {
                options[keyPath: keyPath] = selected.contains(name) && (available?[keyPath: keyPath] ?? true)
            }
            guard options.hasSelection, selected.count == names.count,
                  selected.allSatisfy({ name in fields[name].map { options[keyPath: $0] } == true }) else {
                throw MCPToolProblem.invalid("Choose groups included in the source preset.")
            }
        }
        return options
    }
}

enum MCPDevelopParameters {
    private typealias Numbers<T> = [String: (WritableKeyPath<T, Double>, ClosedRange<Double>)]
    private static let signed = -100.0...100.0, percent = 0.0...100.0, unit = 0.0...1.0
    static let channels = ["luminance", "red", "green", "blue"]
    private static let bands = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]
    static let groups = DevelopGroup.adjustmentCases.filter { $0 != .pointColor }
    static let localGroups: [DevelopGroup] = [.basic, .curves, .zones, .mixer, .blackWhite, .grading]
    private static let global: Numbers<EditRecipe> = [
        "exposure": (\.exposure, -5...5), "contrast": (\.contrast, 0...2), "saturation": (\.saturation, 0...2),
        "temperature": (\.temperature, 2000...50000), "tint": (\.tint, -150...150),
        "highlights": (\.develop.highlights, signed), "shadows": (\.develop.shadows, signed),
        "whites": (\.develop.whites, signed), "blacks": (\.develop.blacks, signed),
        "texture": (\.develop.texture, signed), "clarity": (\.develop.clarity, signed),
        "dehaze": (\.develop.dehaze, signed), "vibrance": (\.develop.vibrance, signed)
    ]
    private static let detail: Numbers<EditRecipe> = [
        "sharpening_amount": (\.sharpening.amount, 0...150), "sharpening_radius": (\.sharpening.radius, 0.5...3),
        "sharpening_protection": (\.sharpening.protection, percent), "denoise_luminance": (\.noiseReduction.luminance, percent),
        "denoise_color": (\.noiseReduction.color, percent),
        "purple_amount": (\.manualDefringe.purpleAmount, percent), "purple_lower": (\.manualDefringe.purpleLower, 200...360),
        "purple_upper": (\.manualDefringe.purpleUpper, 200...360),
        "green_amount": (\.manualDefringe.greenAmount, percent), "green_lower": (\.manualDefringe.greenLower, 40...200),
        "green_upper": (\.manualDefringe.greenUpper, 40...200)
    ]
    private static let raw: [String: WritableKeyPath<RAWDetailSettings, Double?>] = [
        "raw_luminance_noise_reduction": \.luminanceNoiseReduction, "raw_color_noise_reduction": \.colorNoiseReduction,
        "raw_sharpness": \.sharpness
    ]
    private static let effects: Numbers<EditRecipe> = [
        "vignette_amount": (\.vignette.amount, signed), "vignette_midpoint": (\.vignette.midpoint, percent),
        "vignette_roundness": (\.vignette.roundness, signed), "vignette_feather": (\.vignette.feather, percent),
        "vignette_highlights": (\.vignette.highlights, percent), "grain_amount": (\.grain.amount, percent),
        "grain_size": (\.grain.size, percent), "grain_roughness": (\.grain.roughness, percent)
    ]
    private static let hsl: Numbers<HSLBand> = ["hue": (\.hue, signed), "saturation": (\.saturation, signed), "luminance": (\.luminance, signed)]
    private static let tone: Numbers<GradingTone> = ["hue": (\.hue, 0...360), "saturation": (\.saturation, percent), "luminance": (\.luminance, signed)]
    private static let grading: Numbers<ColorGrading> = ["blending": (\.blending, percent), "balance": (\.balance, signed)]
    private static let gradingRanges: [String: WritableKeyPath<ColorGrading, GradingTone>] = [
        "shadows": \.shadows, "midtones": \.midtones, "highlights": \.highlights, "global": \.global
    ]

    static func numberSchema(_ range: ClosedRange<Double>) -> Value {
        ["type": "number", "minimum": .double(range.lowerBound), "maximum": .double(range.upperBound)]
    }
    private static func objectSchema(_ properties: [String: Value]) -> Value {
        ["type": "object", "minProperties": 1, "additionalProperties": false, "properties": .object(properties)]
    }
    private static func numberSchemas<T>(_ fields: Numbers<T>) -> [String: Value] {
        fields.mapValues { numberSchema($0.1) }
    }
    private static func read<T>(_ value: T, _ fields: Numbers<T>) -> [String: Value] {
        fields.mapValues { .double(value[keyPath: $0.0]) }
    }
    private static func apply<T>(_ values: [String: Value], _ fields: Numbers<T>, to result: inout T) {
        for (name, field) in fields {
            if let value = values[name]?.number { result[keyPath: field.0] = value }
        }
    }

    static func schema(_ tool: AppMCPTool) -> Value {
        switch tool {
        case .globalAdjustments:
            var props = numberSchemas(global)
            props["as_shot_white_balance"] = ["type": "boolean"]
            props["black_and_white"] = ["type": "boolean"]
            props["pipeline_version"] = numberSchema(2...2)
            return objectSchema(props)
        case .detailAdjustments:
            var props = numberSchemas(detail)
            for name in raw.keys { props[name] = ["anyOf": [numberSchema(unit), ["type": "null"]]] }
            props["raw_lens_correction"] = ["type": ["boolean", "null"]]
            return objectSchema(props)
        case .effects:
            var props = numberSchemas(effects)
            props["vignette_style"] = ["type": "string", "enum": .array(CreativeVignetteStyle.allCases.map { .string($0.rawValue) })]
            return objectSchema(props)
        case .colorAdjustments:
            var ranges = numberSchemas(grading)
            for key in gradingRanges.keys { ranges[key] = objectSchema(numberSchemas(tone)) }
            return objectSchema([
                "hsl": objectSchema(Dictionary(uniqueKeysWithValues: bands.map { ($0, objectSchema(numberSchemas(hsl))) })),
                "black_white_mixer": objectSchema(Dictionary(uniqueKeysWithValues: bands.map { ($0, numberSchema(signed)) })),
                "grading": objectSchema(ranges)
            ])
        case .localAdjustments:
            var basic = schema(.globalAdjustments).objectValue!["properties"]!.objectValue!
            basic.removeValue(forKey: "pipeline_version")
            return objectSchema(["basic": objectSchema(basic), "color": schema(.colorAdjustments), "zone_gains": gainsSchema,
                                 "curves": objectSchema(Dictionary(uniqueKeysWithValues: channels.map { ($0, pointsSchema) }))])
        default: preconditionFailure("Only adjustment patches have a parameter schema.")
        }
    }
    static func accepts(_ value: Value, for tool: AppMCPTool) -> Bool {
        accepts(value, schema: schema(tool))
    }
    static func accepts(_ value: Value, schema: Value) -> Bool {
        let fields = schema.objectValue ?? [:]
        if let choices = fields["anyOf"]?.arrayValue { return choices.contains { accepts(value, schema: $0) } }
        if let types = fields["type"]?.arrayValue { return types.contains { accepts(value, schema: ["type": $0]) } }
        switch fields["type"]?.stringValue {
        case "object":
            guard let properties = fields["properties"]?.objectValue, let values = value.objectValue, !values.isEmpty else { return false }
            return values.allSatisfy { name, item in properties[name].map { accepts(item, schema: $0) } ?? false }
        case "number":
            guard let number = value.number, let lower = fields["minimum"]?.number, let upper = fields["maximum"]?.number else { return false }
            return (lower...upper).contains(number)
        case "integer":
            guard let number = value.intValue else { return false }
            if let choices = fields["enum"]?.arrayValue { return choices.contains(.int(number)) }
            let lower = fields["minimum"]?.intValue ?? Int.min, upper = fields["maximum"]?.intValue ?? Int.max
            return (lower...upper).contains(number)
        case "array":
            if schema == pointsSchema { return (try? points(value)) != nil }
            if schema == gainsSchema { return (try? gains(value)) != nil }
            return false
        case "boolean": return value.boolValue != nil
        case "null": return value == .null
        case "string":
            if let choices = fields["enum"]?.arrayValue { return choices.contains(value) }
            guard let string = value.stringValue, !string.contains("\0") else { return false }
            return ((fields["minLength"]?.intValue ?? 0)...(fields["maxLength"]?.intValue ?? Int.max)).contains(string.utf8.count)
        default: return false
        }
    }

    static let pointsSchema: Value = [
        "type": "array", "minItems": 2, "maxItems": .int(ToneCurves.maxPoints),
        "items": ["type": "object", "required": ["x", "y"], "additionalProperties": false,
                  "properties": ["x": numberSchema(unit), "y": numberSchema(unit)]]
    ]
    static let gainsSchema: Value = ["type": "array", "minItems": 5, "maxItems": 5, "items": numberSchema(-1...1)]

    static func points(_ value: Value) throws -> [CurvePoint] {
        guard let items = value.arrayValue, (2...ToneCurves.maxPoints).contains(items.count) else {
            throw MCPToolProblem.invalid("Supply two to sixteen curve points.")
        }
        let points = try items.map {
            guard let item = $0.objectValue, item.count == 2, let x = item["x"]?.number, let y = item["y"]?.number,
                  unit.contains(x), unit.contains(y) else { throw MCPToolProblem.invalid("Curve points need normalized x and y values.") }
            return CurvePoint(x: x, y: y)
        }
        var curves = ToneCurves()
        curves.channels[0] = points
        try curves.validate()
        return points
    }
    static func gains(_ value: Value) throws -> ToneZones {
        guard let items = value.arrayValue, items.count == 5 else { throw MCPToolProblem.invalid("Supply five zone gains in EV.") }
        let result = ToneZones(gains: items.compactMap(\.number))
        try result.validate()
        return result
    }
    private static func curvePoints(_ points: [CurvePoint]) -> Value {
        .array(points.map { ["x": .double($0.x), "y": .double($0.y)] })
    }

    static func describe(_ recipe: EditRecipe, rawDefaults: RAWDetailSettings? = nil) -> [String: Value] {
        var basic = read(recipe, global)
        basic["as_shot_white_balance"] = .bool(recipe.asShotWhiteBalance)
        basic["black_and_white"] = .bool(recipe.develop.blackAndWhite)
        var details = read(recipe, detail)
        var available: [String: Value] = [:]
        if !recipe.isRaster {
            for (name, keyPath) in raw {
                details[name] = recipe.rawDetails[keyPath: keyPath].map(Value.double) ?? .null
                available[name] = rawDefaults?[keyPath: keyPath].map(Value.double) ?? .null
            }
            details["raw_lens_correction"] = recipe.rawDetails.lensCorrection.map(Value.bool) ?? .null
            available["raw_lens_correction"] = rawDefaults?.lensCorrection.map(Value.bool) ?? .null
        }
        var effects = read(recipe, effects)
        effects["vignette_style"] = .string(recipe.vignette.style.rawValue)
        var grading = read(recipe.develop.grading, grading)
        for (name, key) in gradingRanges { grading[name] = .object(read(recipe.develop.grading[keyPath: key], tone)) }
        return [
            "global": .object(basic), "detail": .object(details), "effects": .object(effects),
            "curves": .object(Dictionary(uniqueKeysWithValues: zip(channels, (recipe.develop.curves ?? ToneCurves()).channels.map(curvePoints)))),
            "zone_gains": .array((recipe.develop.zones ?? ToneZones()).gains.map(Value.double)),
            "color": [
                "hsl": .object(Dictionary(uniqueKeysWithValues: zip(bands, recipe.develop.mixer.map { .object(read($0, hsl)) }))),
                "black_white_mixer": .object(Dictionary(uniqueKeysWithValues: zip(bands, recipe.develop.blackWhiteMixer.map(Value.double)))),
                "grading": .object(grading)
            ],
            "baseline": ["exposure": .double(recipe.baselineExposure), "temperature": .double(recipe.baselineTemperature), "tint": .double(recipe.baselineTint)],
            "pipeline_version": .int(recipe.pipelineVersion), "raw": .bool(!recipe.isRaster),
            "geometry": MCPCanvasFields.geometry(recipe), "point_colors": .array(recipe.develop.pointColors.map(MCPCanvasFields.pointColor)),
            "raw_defaults": rawDefaults == nil ? .null : .object(available)
        ]
    }

    static func describeLocal(_ group: LocalAdjustment, source: EditRecipe) -> Value {
        let data = describe(group.editingRecipe(from: source))
        return ["basic": data["global"]!, "color": data["color"]!, "curves": data["curves"]!, "zone_gains": data["zone_gains"]!]
    }

    static func changeLocal(_ args: [String: Value], source: EditRecipe, group: inout LocalAdjustment) throws {
        let action = args["action"]!.stringValue!
        var local = group.editingRecipe(from: source)
        if action == "reset" {
            let groups = args["group"]?.stringValue.flatMap(DevelopGroup.init(rawValue:)).map { [$0] } ?? localGroups
            for section in groups { local = section.previewRecipe(in: local) }
        } else {
            let values = args["adjustments"]?.objectValue ?? [:]
            if let basic = values["basic"] { try change(.globalAdjustments, args: ["adjustments": basic], recipe: &local) }
            if let color = values["color"] { try change(.colorAdjustments, args: ["adjustments": color], recipe: &local) }
            if let gains = values["zone_gains"] { try change(.zoneLighting, args: ["gains": gains], recipe: &local) }
            for channel in channels {
                if let points = values["curves"]?.objectValue?[channel] {
                    try changeCurve(["action": "set", "channel": .string(channel), "points": points], recipe: &local)
                }
            }
        }
        group.updateDevelop(local)
        if let amount = args["amount"]?.number { group.amount = amount }
    }

    static func change(_ tool: AppMCPTool, args: [String: Value], recipe: inout EditRecipe) throws {
        let values = args["adjustments"]?.objectValue ?? [:]
        switch tool {
        case .globalAdjustments:
            let asShot = values["as_shot_white_balance"]?.boolValue
            let custom = values["temperature"] != nil || values["tint"] != nil
            guard asShot != true || !custom else { throw MCPToolProblem.invalid("Choose as-shot or custom white balance.") }
            if values["pipeline_version"] != nil { recipe.pipelineVersion = 2 }
            apply(values, global, to: &recipe)
            if custom || asShot == false { recipe.asShotWhiteBalance = false }
            if asShot == true {
                recipe.asShotWhiteBalance = true
                recipe.temperature = recipe.baselineTemperature
                recipe.tint = recipe.baselineTint
            }
            if let monochrome = values["black_and_white"]?.boolValue { recipe.develop.blackAndWhite = monochrome }
        case .detailAdjustments:
            if recipe.isRaster, values.keys.contains(where: { $0.hasPrefix("raw_") }) {
                throw MCPToolProblem.invalid("RAW detail controls require a RAW photo.")
            }
            if recipe.pipelineVersion != 2, values.keys.contains(where: { $0.hasPrefix("purple_") || $0.hasPrefix("green_") }) {
                throw MCPToolProblem.invalid("Manual defringe requires the current development pipeline.")
            }
            apply(values, detail, to: &recipe)
            for (name, keyPath) in raw where values[name] != nil { recipe.rawDetails[keyPath: keyPath] = values[name]?.number }
            if let lens = values["raw_lens_correction"] { recipe.rawDetails.lensCorrection = lens.boolValue }
        case .effects:
            let hadGrain = recipe.grain.isActive
            apply(values, effects, to: &recipe)
            if !hadGrain, recipe.grain.isActive { recipe.grain.ensureSeed() }
            if let style = values["vignette_style"]?.stringValue { recipe.vignette.style = CreativeVignetteStyle(rawValue: style)! }
        case .colorAdjustments:
            let hueBands = values["hsl"]?.objectValue ?? [:], monoBands = values["black_white_mixer"]?.objectValue ?? [:]
            for (index, band) in bands.enumerated() {
                if let fields = hueBands[band]?.objectValue { apply(fields, hsl, to: &recipe.develop.mixer[index]) }
                if let value = monoBands[band]?.number { recipe.develop.blackWhiteMixer[index] = value }
            }
            if !monoBands.isEmpty { recipe.pipelineVersion = 2 }
            if let values = values["grading"]?.objectValue {
                apply(values, grading, to: &recipe.develop.grading)
                for (name, keyPath) in gradingRanges {
                    if let fields = values[name]?.objectValue { apply(fields, tone, to: &recipe.develop.grading[keyPath: keyPath]) }
                }
            }
        case .toneCurve:
            try changeCurve(args, recipe: &recipe)
        case .zoneLighting:
            let zones = try gains(args["gains"]!)
            recipe.develop.zones = zones.isNeutral ? nil : zones
            recipe.pipelineVersion = 2
        case .resetAdjustments:
            let group = args["group"]!.stringValue!
            if group == "all" { recipe = recipe.resetForCurrentPipeline() }
            else {
                let section = DevelopGroup(rawValue: group)!
                guard section != .rawDetails || !recipe.isRaster else { throw MCPToolProblem.invalid("RAW detail controls require a RAW photo.") }
                recipe = section.previewRecipe(in: recipe)
                if section == .curves { recipe.pipelineVersion = 2 }
                if section == .grain { recipe.grain = FilmGrain() }
            }
        default: preconditionFailure("Only parameter tools edit these fields.")
        }
    }

    private static func changeCurve(_ args: [String: Value], recipe: inout EditRecipe) throws {
        let channel = channels.firstIndex(of: args["channel"]!.stringValue!)!
        var curves = recipe.develop.curves ?? ToneCurves()
        let action = args["action"]!.stringValue!
        let index = args["point_index"]?.intValue
        let x = args["x"]?.number, y = args["y"]?.number
        let fields = Set(["points", "point_index", "x", "y"].filter { args[$0] != nil })
        switch action {
        case "set" where fields == ["points"]:
            curves.channels[channel] = try points(args["points"]!)
        case "insert" where fields == ["x", "y"]:
            guard curves.insert(channel: channel, x: x!, y: y!) != nil else { throw MCPToolProblem.invalid("The channel has reached its point limit.") }
        case "move" where fields == ["point_index", "x", "y"]:
            guard let index, curves.channels[channel].indices.contains(index) else { throw MCPToolProblem.invalid("Read the current curve point indices.") }
            curves.move(channel: channel, point: index, x: x!, y: y!)
        case "remove" where fields == ["point_index"]:
            guard let index, curves.remove(channel: channel, point: index) else { throw MCPToolProblem.invalid("Only an existing interior point can be removed.") }
        case "reset" where fields.isEmpty:
            curves.channels[channel] = ToneCurves.identity
        default: throw MCPToolProblem.invalid("Supply the curve fields for the requested action.")
        }
        recipe.develop.curves = curves
        recipe.pipelineVersion = 2
    }
}
