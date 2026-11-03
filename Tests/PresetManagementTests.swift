import XCTest
import AppKit
import SwiftUI
@testable import Phosdeck

final class PresetManagementTests: XCTestCase {
    private func recipe(exposure: Double = 0) -> EditRecipe {
        var value = EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "preset-test",
                                baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0,
                                temperature: 5500, tint: 0)
        value.exposure = exposure
        return value
    }

    func testCatalogPresetUpdateFavoriteGroupAndRestoreAreAtomic() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try CatalogStore(directory: folder)
        let options = RecipePasteOptions()
        try catalog.savePreset(name: "夜景", recipe: recipe(exposure: 0.5), options: options, groupName: "外景")
        var preset = try XCTUnwrap(catalog.presets().first)
        XCTAssertEqual(preset.groupName, "外景")
        XCTAssertFalse(preset.favorite)

        let beforeUpdate = preset
        let returned = try catalog.updatePreset(id: preset.id, recipe: recipe(exposure: 1.25), options: options)
        XCTAssertEqual(returned, beforeUpdate)
        preset = try XCTUnwrap(catalog.presets().first)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: preset.recipe).exposure, 1.25)
        XCTAssertEqual(preset.groupName, "外景")

        let oldFavorite = try catalog.setPresetFavorite(id: preset.id, favorite: true)
        XCTAssertFalse(oldFavorite.favorite)
        let oldGroup = try catalog.setPresetGroup(id: preset.id, groupName: "客户／交付")
        XCTAssertEqual(oldGroup.groupName, "外景")
        XCTAssertTrue(try XCTUnwrap(catalog.presets().first).favorite)
        XCTAssertEqual(try XCTUnwrap(catalog.presets().first).groupName, "客户／交付")

        try catalog.restorePreset(beforeUpdate)
        let restored = try XCTUnwrap(catalog.presets().first)
        XCTAssertEqual(restored, beforeUpdate, "Undo must restore recipe, options, group and favorite together")
    }

    func testDeleteReturnsRowAndRestoreRecreatesIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try CatalogStore(directory: folder)
        try catalog.savePreset(name: "可删除", recipe: recipe(), options: RecipePasteOptions(), groupName: "测试")
        let original = try XCTUnwrap(catalog.presets().first)
        let deleted = try catalog.deletePreset(original.id)
        XCTAssertEqual(try XCTUnwrap(deleted), original)
        XCTAssertTrue(try catalog.presets().isEmpty)
        try catalog.restorePreset(original)
        XCTAssertEqual(try XCTUnwrap(catalog.presets().first), original)
    }

    func testUnicodeSearchFavoriteAndMultipleGroupsFilter() {
        let presets = [
            AdjustmentPreset(id: "1", name: "Café 夜景", recipe: Data(), options: Data(), groupName: "夜景", favorite: true),
            AdjustmentPreset(id: "2", name: "Café 人像", recipe: Data(), options: Data(), groupName: "人像", favorite: false),
            AdjustmentPreset(id: "3", name: "室内暖光", recipe: Data(), options: Data(), groupName: "室内", favorite: true)
        ]
        let found = PresetBrowser.filtered(presets, search: "café", groups: ["夜景", "人像"])
        XCTAssertEqual(Set(found.map(\.id)), Set(["1", "2"]), "Search is canonical-Unicode and group selection accepts more than one group")
        XCTAssertEqual(PresetBrowser.filtered(presets, search: "", groups: [], favoritesOnly: true).map(\.id), ["3", "1"], "Favorites keep the browser's localized group ordering")
        XCTAssertTrue(PresetBrowser.filtered(presets, search: "不存在", groups: []).isEmpty, "No-match state must be an explicit empty result")
    }

    @MainActor
    func testBrowserFitsNarrowInspectorAndHasNoUnboundedContentWidth() async throws {
        let presets = (0..<12).map {
            AdjustmentPreset(id: "\($0)", name: "预设 \($0)", recipe: Data(), options: Data(), groupName: $0.isMultiple(of: 2) ? "组 A" : "组 B", favorite: $0 == 2)
        }
        for width in [CGFloat(200), CGFloat(260)] {
            let view = PresetBrowser(presets: presets,
                                     onPreview: { _ in }, onEndPreview: { _ in }, onApply: { _ in },
                                     onUpdate: { _ in }, onFavorite: { _, _ in }, onGroup: { _, _ in })
                .frame(width: width, height: 360)
                .background(Theme.panel)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            try await Task.sleep(for: .milliseconds(60))
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, width + 1, "Preset browser width (width)")
            XCTAssertLessThanOrEqual(host.fittingSize.height, 361, "Preset browser height (width)")
            window.contentView = nil
        }
    }
}
