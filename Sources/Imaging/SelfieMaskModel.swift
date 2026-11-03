import Foundation
import CLiteRT

/// The one fixed six-class model, owned by the serialized smart-mask worker.
final class SelfieMaskModel {
    private var environment: LiteRtEnvironment?
    private var model: LiteRtModel?
    private var options: LiteRtOptions?
    private var compiled: LiteRtCompiledModel?
    private var input: LiteRtTensorBuffer?
    private var output: LiteRtTensorBuffer?
    private static func check(_ status: LiteRtStatus) throws {
        guard status == kLiteRtStatusOk else { throw LRCError(L10n.text("app.bodyPartInferenceFailedLiteRT", defaultValue: "Body part inference failed (LiteRT \(status.rawValue))")) }
    }
    init(url: URL) throws {
        try Self.check(LiteRtCreateEnvironment(0, nil, &environment))
        try Self.check(LiteRtCreateOptions(&options))
        try Self.check(LiteRtSetOptionsHardwareAccelerators(options, Int32(kLiteRtHwAcceleratorCpu.rawValue)))
        try Self.check(LiteRtCreateModelFromFile(environment, url.path, &model))
        try Self.check(LiteRtCreateCompiledModel(environment, model, options, &compiled))
        input = try buffer(input: true, channels: 3)
        output = try buffer(input: false, channels: 6)
    }
    deinit {
        if let input { LiteRtDestroyTensorBuffer(input) }
        if let output { LiteRtDestroyTensorBuffer(output) }
        if let compiled { LiteRtDestroyCompiledModel(compiled) }
        if let model { LiteRtDestroyModel(model) }
        if let options { LiteRtDestroyOptions(options) }
        if let environment { LiteRtDestroyEnvironment(environment) }
    }
    private func buffer(input: Bool, channels: Int32) throws -> LiteRtTensorBuffer {
        var subgraph: LiteRtSubgraph?, tensor: LiteRtTensor?
        try Self.check(LiteRtGetModelSubgraph(model, 0, &subgraph))
        try Self.check(input ? LiteRtGetSubgraphInput(subgraph, 0, &tensor) : LiteRtGetSubgraphOutput(subgraph, 0, &tensor))
        var type = LiteRtRankedTensorType()
        try Self.check(LiteRtGetRankedTensorType(tensor, &type))
        let rank = withUnsafeBytes(of: type.layout) { Int($0[0] & 0x7f) }
        let dims = type.layout.dimensions
        guard type.element_type == kLiteRtElementTypeFloat32, rank == 4,
              dims.0 == 1, dims.1 == 256, dims.2 == 256, dims.3 == channels else { throw LRCError(L10n.text("app.bodyPartModelDimensionsOrTypeMismatch", defaultValue: "Body part model dimensions or type mismatch")) }
        var requirements: LiteRtTensorBufferRequirements?, buffer: LiteRtTensorBuffer?
        try Self.check(input ? LiteRtGetCompiledModelInputBufferRequirements(compiled, 0, 0, &requirements)
                            : LiteRtGetCompiledModelOutputBufferRequirements(compiled, 0, 0, &requirements))
        try Self.check(LiteRtCreateManagedTensorBufferFromRequirements(environment, &type, requirements, &buffer))
        guard let buffer else { throw LRCError(L10n.text("app.couldNotCreateTheBodyPartBuffer", defaultValue: "Could not create the body part buffer")) }
        return buffer
    }
    func predict(rgb: [Float]) throws -> [Float] {
        guard rgb.count == 256 * 256 * 3, rgb.allSatisfy(\.isFinite) else { throw LRCError(L10n.text("app.invalidBodyPartInput", defaultValue: "Invalid body part input")) }
        try Task.checkCancellation()
        var address: UnsafeMutableRawPointer?
        try Self.check(LiteRtLockTensorBuffer(input, &address, kLiteRtTensorBufferLockModeWrite))
        if let address {
            rgb.withUnsafeBytes { address.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        } else {
            LiteRtUnlockTensorBuffer(input)
            throw LRCError(L10n.text("app.bodyPartInputIsNotReady", defaultValue: "Body part input is not ready"))
        }
        try Self.check(LiteRtUnlockTensorBuffer(input))
        try Self.check(LiteRtRunCompiledModel(compiled, 0, 1, &input, 1, &output))
        var resultAddress: UnsafeMutableRawPointer?
        try Self.check(LiteRtLockTensorBuffer(output, &resultAddress, kLiteRtTensorBufferLockModeRead))
        defer { LiteRtUnlockTensorBuffer(output) }
        guard let resultAddress else { throw LRCError(L10n.text("app.bodyPartOutputIsNotReady", defaultValue: "Body part output is not ready")) }
        let result = Array(UnsafeBufferPointer(start: resultAddress.assumingMemoryBound(to: Float.self), count: 256 * 256 * 6))
        try Task.checkCancellation()
        guard result.allSatisfy(\.isFinite) else { throw LRCError(L10n.text("app.bodyPartOutputContainsInvalidNumbers", defaultValue: "Body part output contains invalid numbers")) }
        return result
    }
}
