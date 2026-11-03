import XCTest
import AppKit
@testable import Phosdeck

final class LocalizationTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var store: LanguagePackStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("phosdeck-language-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "phosdeck-language-" + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        store = try LanguagePackStore(directory: root.appendingPathComponent("Installed"), defaults: defaults)
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }

    private func pack(strings: [String: String] = ["app.importPhotos": "Импорт фотографий…"], plurals: [String: Any] = [:], language: String = "ru", extra: [String: Any] = [:]) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + ".bundle")
        let resources = url.appendingPathComponent("Contents/Resources/" + language + ".lproj")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundlePackageType": "BNDL", "CFBundleIdentifier": "org.example.language." + UUID().uuidString,
            "CFBundleDevelopmentRegion": language, "CFBundleVersion": "1", "OMLRCFormatVersion": 1,
            "OMLRCPackIdentifier": "org.example.russian", "OMLRCLanguage": language, "OMLRCName": "Русский", "OMLRCAuthor": "Synthetic Test"]
        info.merge(extra) { _, value in value }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        try PropertyListSerialization.data(fromPropertyList: strings, format: .binary, options: 0).write(to: resources.appendingPathComponent("Localizable.strings"))
        if !plurals.isEmpty {
            try PropertyListSerialization.data(fromPropertyList: plurals, format: .xml, options: 0).write(to: resources.appendingPathComponent("Localizable.stringsdict"))
        }
        return url
    }

    private func plural(_ forms: [String: String], type: String = "lld") -> [String: Any] {
        var value = forms
        value["NSStringFormatSpecTypeKey"] = "NSStringPluralRuleType"
        value["NSStringFormatValueTypeKey"] = type
        return ["NSStringLocalizedFormatKey": "%#@count@", "count": value]
    }

    func testOfficialEnglishAndChineseResourcesAndNativePlurals() throws {
        XCTAssertEqual(Set(Bundle.main.localizations.filter { $0 != "Base" }), ["en", "zh-Hans"])
        let english = Localization(language: "en"), chinese = Localization(language: "zh-Hans")
        XCTAssertEqual(english.text("app.importPhotos", defaultValue: "Import Photos…"), "Import Photos…")
        XCTAssertEqual(chinese.text("app.importPhotos", defaultValue: "Import Photos…"), "导入照片…")
        XCTAssertEqual(chinese.text("app.develop", defaultValue: "Develop"), "编辑")
        XCTAssertEqual(english.text("app.develop", defaultValue: "Develop"), "Develop")
        XCTAssertEqual(chinese.text("app.developD", defaultValue: "Develop (D)"), "编辑（D）")
        for count in [1, 2, 21] {
            XCTAssertEqual(english.text("app.photos", defaultValue: "\(count) photos"), "\(count) " + (count == 1 ? "photo" : "photos"))
            XCTAssertEqual(chinese.text("app.photos", defaultValue: "\(count) photos"), "\(count) 张")
        }
    }

    func testAllAppTextKeysHaveBothOfficialTranslations() throws {
        func keys(_ language: String) throws -> Set<String> {
            var keys = Set<String>()
            for ext in ["strings", "stringsdict"] {
                guard let url = Bundle.main.url(forResource: "Localizable", withExtension: ext, subdirectory: nil, localization: language) else { continue }
                let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
                keys.formUnion(try XCTUnwrap(object as? [String: Any]).keys)
                if language == "en" {
                    let text = String(describing: object)
                    XCTAssertNil(text.range(of: #"[\p{Han}]"#, options: .regularExpression), "English resources must not contain untranslated Chinese")
                }
            }
            return keys
        }
        let english = try keys("en")
        XCTAssertEqual(english, try keys("zh-Hans"))
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let expression = try NSRegularExpression(pattern: #"L10n\.text\("([^"]+)""#)
        for case let url as URL in files where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8), text = source as NSString
            for match in expression.matches(in: source, range: NSRange(location: 0, length: text.length)) {
                XCTAssertTrue(english.contains(text.substring(with: match.range(at: 1))), "Missing translation in \(url.lastPathComponent)")
            }
        }
    }

    func testInstallCopiesResourcesAndLeavesOriginalAndSelectionUntouched() throws {
        let source = try pack(), before = try SafeFileWriter.sha256(source.appendingPathComponent("Contents/Info.plist"))
        defaults.set("previous-selection", forKey: LanguagePackStore.selectionKey)
        let installed = try store.install(from: source)
        XCTAssertNotEqual(installed.bundle.bundleURL, source)
        XCTAssertEqual(try SafeFileWriter.sha256(source.appendingPathComponent("Contents/Info.plist")), before)
        XCTAssertEqual(defaults.string(forKey: LanguagePackStore.selectionKey), "previous-selection")
        XCTAssertEqual(try store.installed().map(\.id), [installed.id])
        XCTAssertNil(installed.bundle.executableURL)
        XCTAssertFalse(installed.bundle.isLoaded)
        XCTAssertEqual(Localization(language: "zh-Hans", pack: installed).text("app.importPhotos", defaultValue: "Import Photos…"), "Импорт фотографий…")
    }

    @MainActor func testPickerCanSelectGeneratedResourceBundle() throws {
        let source = try pack()
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey])
        XCTAssertEqual(values.isDirectory, true)
        XCTAssertEqual(values.isPackage, true)
        let type = try XCTUnwrap(values.contentType)
        let panel = LanguagePackSettings.makeOpenPanel()
        XCTAssertTrue(panel.allowedContentTypes.contains { type.conforms(to: $0) })
        XCTAssertTrue(panel.canChooseFiles, "The open panel must allow selecting resource packages as files")
        XCTAssertFalse(panel.canChooseDirectories, "Ordinary directories must not be selectable as language packs")
        XCTAssertFalse(panel.treatsFilePackagesAsDirectories, "The bundle must be presented as a single selectable item")
    }

    func testRussianPluralRulesAndEnglishFallbackUseTheirOwnLocales() throws {
        let source = try pack(plurals: ["app.photos": plural(["one": "%lld фотография", "few": "%lld фотографии", "many": "%lld фотографий", "other": "%lld фотографии"])])
        let snapshot = Localization(language: "zh-Hans", pack: try store.install(from: source))
        for (count, expected) in [(1, "1 фотография"), (2, "2 фотографии"), (5, "5 фотографий"), (21, "21 фотография")] {
            XCTAssertEqual(snapshot.text("app.photos", defaultValue: "\(count) photos"), expected)
        }
        for count in [1, 2] {
            XCTAssertEqual(snapshot.text("app.exportPhotos", defaultValue: "Export \(count) Photos"), "Export \(count) " + (count == 1 ? "Photo" : "Photos"))
        }
    }

    func testUntranslatedCompilerPlaceholdersAndUnknownKeysAreNotEnabled() throws {
        let source = try pack(strings: ["app.importPhotos": "Импорт фотографий…", "app.photos": "app.photos", "unknown.key": "Unknown"])
        let installed = try store.install(from: source)
        XCTAssertEqual(installed.keys, ["app.importPhotos"])
        let count = 1
        XCTAssertEqual(Localization(language: "zh-Hans", pack: installed).text("app.photos", defaultValue: "\(count) photos"), "1 photo")
    }

    func testPositionalArgumentsPreserveUserTextVerbatim() throws {
        let key = "app.createdFromCurrentAdjustmentsWerePreserved"
        let source = try pack(strings: [key: "%2$@ → %1$@"])
        let snapshot = Localization(language: "en", pack: try store.install(from: source))
        let name = "私人名称 %42 色温", kind = "copy"
        XCTAssertEqual(snapshot.text("app.createdFromCurrentAdjustmentsWerePreserved", defaultValue: "Created \(kind) from “\(name)”. Current adjustments were preserved"), name + " → " + kind)
    }

    func testWrongTypesDangerousSpecifiersAndMissingArgumentsRejectInstallation() throws {
        for text in ["%@", "%n", "%s", "%2$lld", "%10000000lld", "%lld %lld"] {
            let source = try pack(strings: ["app.photos": text])
            XCTAssertThrowsError(try store.install(from: source), text)
        }
        for text in ["%n", "%s", "% p", "%lld"] {
            XCTAssertThrowsError(try store.install(from: pack(strings: ["app.importPhotos": text])))
        }
        XCTAssertTrue(try store.installed().isEmpty)
    }

    func testMalformedPluralBranchesAreRejectedBeforeNativeFormatting() throws {
        for value in [plural(["one": "%@", "other": "%lld"]), plural(["one": "%lld"]), plural(["other": "%lld"], type: "s")] {
            XCTAssertThrowsError(try store.install(from: pack(plurals: ["app.photos": value])))
        }
    }

    func testUnsupportedFormatAndOfficialLanguageOverridesAreRejected() throws {
        XCTAssertThrowsError(try store.install(from: pack(extra: ["OMLRCFormatVersion": 2])))
        for language in ["en", "zh-Hans", "en-GB", "../ru"] {
            XCTAssertThrowsError(try store.install(from: pack(language: language)))
        }
    }

    func testExecutableAndSymbolicLinksAreRejected() throws {
        XCTAssertThrowsError(try store.install(from: pack(extra: ["CFBundleExecutable": "run"])))
        let source = try pack(), path = source.appendingPathComponent("Contents/Resources/ru.lproj/Localizable.strings")
        let copied = root.appendingPathComponent("source.strings")
        try FileManager.default.moveItem(at: path, to: copied)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: copied)
        XCTAssertThrowsError(try store.install(from: source))
    }

    func testFailedReplacementPreservesInstalledBundleAndPreference() throws {
        let original = try store.install(from: pack())
        defaults.set(original.id, forKey: LanguagePackStore.selectionKey)
        XCTAssertThrowsError(try store.install(from: pack(extra: ["OMLRCFormatVersion": 0])))
        XCTAssertEqual(defaults.string(forKey: LanguagePackStore.selectionKey), original.id)
        XCTAssertEqual(try store.installed().map(\.id), [original.id])
        XCTAssertEqual(try store.read(id: original.id).keys, original.keys)
    }

    func testActiveRemovalIsDeferredUntilTheNextLaunch() throws {
        let original = try store.install(from: pack())
        defaults.set(original.id, forKey: LanguagePackStore.selectionKey)
        let running = L10n.load(store)
        try store.remove(id: original.id, activeID: original.id)
        XCTAssertNil(defaults.string(forKey: LanguagePackStore.selectionKey))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.bundle.bundlePath))
        XCTAssertTrue(try store.installed().isEmpty)
        XCTAssertEqual(running.text("app.importPhotos", defaultValue: "Import Photos…"), "Импорт фотографий…")
        let restarted = L10n.load(store)
        XCTAssertNil(restarted.pack)
        XCTAssertFalse(restarted.loadFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.bundle.bundlePath))
    }

    func testStartupFallsBackForMissingAndUnsupportedInstalledPacks() throws {
        defaults.set(UUID().uuidString, forKey: LanguagePackStore.selectionKey)
        XCTAssertTrue(L10n.load(store).loadFailed)
        let original = try store.install(from: pack())
        let metadata = original.bundle.bundleURL.appendingPathComponent("Contents/Info.plist")
        var object = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: metadata), format: nil) as? [String: Any])
        object["OMLRCFormatVersion"] = 2
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0).write(to: metadata)
        defaults.set(original.id, forKey: LanguagePackStore.selectionKey)
        let result = L10n.load(store)
        XCTAssertTrue(result.loadFailed)
        XCTAssertNil(result.pack)
        XCTAssertEqual(result.text("app.importPhotos", defaultValue: "Import Photos…"), L10n.text("app.importPhotos", defaultValue: "Import Photos…"))
        XCTAssertEqual(defaults.string(forKey: LanguagePackStore.selectionKey), original.id)
        try FileManager.default.removeItem(at: metadata)
        XCTAssertTrue(L10n.load(store).loadFailed)
    }

    func testSelectionCannotEscapeTheOwnedDirectory() throws {
        XCTAssertThrowsError(try store.read(id: "../outside"))
        XCTAssertThrowsError(try store.remove(id: "../outside", activeID: nil))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testInstallerNormalizesTablesBeforePublication() throws {
        let installed = try store.install(from: pack(strings: ["app.importPhotos": "Импорт фотографий…", "unknown": "Ignored"]))
        let data = try Data(contentsOf: installed.bundle.bundleURL.appendingPathComponent("Contents/Resources/ru.lproj/Localizable.strings"))
        let table = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        XCTAssertEqual(table, ["app.importPhotos": "Импорт фотографий…"])
        let pending = try FileManager.default.contentsOfDirectory(atPath: store.directory.path).filter { $0.hasPrefix(".install-") }
        XCTAssertTrue(pending.isEmpty)
    }
}
