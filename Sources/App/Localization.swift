import Foundation

/// A process keeps one language snapshot so menus, errors and task messages agree.
struct Localization {
    let language: String
    private let official: Bundle
    private let english: Bundle
    private let locale: Locale
    private let englishLocale = Locale(identifier: "en")
    let pack: LanguagePack?
    let loadFailed: Bool

    init(language: String, source: Bundle = .main, pack: LanguagePack? = nil, loadFailed: Bool = false) {
        self.language = language; self.pack = pack; self.loadFailed = loadFailed
        self.locale = Locale(identifier: pack?.language ?? language)
        // String's locale controls formatting; a language-specific bundle also fixes lookup.
        self.official = source.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)) ?? source
        self.english = source.url(forResource: "en", withExtension: "lproj").flatMap(Bundle.init(url:)) ?? source
    }

    func text(_ key: StaticString, defaultValue: String.LocalizationValue) -> String {
        let translated = pack?.keys.contains(key.description) == true
        let bundle = translated ? pack!.bundle : pack == nil ? official : english
        return String(localized: key, defaultValue: defaultValue, bundle: bundle, locale: pack != nil && !translated ? englishLocale : locale)
    }
}

enum L10n {
    static let current: Localization = {
        let language = Bundle.main.preferredLocalizations.first(where: { ["zh-Hans", "en"].contains($0) }) ?? "en"
        // Unit tests exercise isolated stores and never activate an installed user language pack.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return Localization(language: language) }
        do { return load(try LanguagePackStore()) }
        catch { return Localization(language: language, loadFailed: true) }
    }()

    static func load(_ store: LanguagePackStore) -> Localization {
        let language = store.source.preferredLocalizations.first(where: { ["zh-Hans", "en"].contains($0) }) ?? "en"
        do {
            try store.cleanPendingRemovals()
            let id = store.defaults.string(forKey: LanguagePackStore.selectionKey) ?? ""
            guard !id.isEmpty else { return Localization(language: language, source: store.source) }
            return Localization(language: language, source: store.source, pack: try store.read(id: id))
        } catch { return Localization(language: language, source: store.source, loadFailed: true) }
    }

    static func text(_ key: StaticString, defaultValue: String.LocalizationValue) -> String {
        current.text(key, defaultValue: defaultValue)
    }
}

struct LanguagePack {
    let id: String
    let identifier: String
    let language: String
    let name: String
    let author: String
    let version: String
    let bundle: Bundle
    let keys: Set<String>
    let tables: [String: Data]
}

enum LanguagePackError: LocalizedError {
    case invalid, unsupported, arguments, unsafeFile
    var errorDescription: String? {
        switch self {
        case .invalid: L10n.text("languagePack.invalid", defaultValue: "The language pack is damaged or incomplete.")
        case .unsupported: L10n.text("languagePack.unsupported", defaultValue: "Unsupported language pack format or language. Official English and Simplified Chinese cannot be replaced.")
        case .arguments: L10n.text("languagePack.arguments", defaultValue: "Translation arguments do not match the official text. The language pack was not installed.")
        case .unsafeFile: L10n.text("languagePack.unsafeFile", defaultValue: "Language packs must contain regular resource files without symbolic links or executable code.")
        }
    }
}

/// Native printf argument types are checked before Foundation sees community format strings.
enum LocalizationFormat {
    struct Signature {
        var arguments: [Int: String] = [:]
        var variables: [String: Int] = [:]
    }
    private static let token = try! NSRegularExpression(pattern: #"%(?:([1-9][0-9]*)\$)?(?:#@([A-Za-z_][A-Za-z_0-9]*)@|[-+#0]*([0-9]*)(?:\.([0-9]+))?(hh|ll|h|l|z|t|j|L)?([@diuoxXfFeEgGaA])|(%))"#)

    static func signature(_ format: String, variables: [String: String] = [:], start: Int = 1, literalPercent: Bool = false) throws -> Signature {
        let string = format as NSString
        var offset = 0, next = start, result = Signature()
        while offset < string.length {
            let range = string.range(of: "%", range: NSRange(location: offset, length: string.length - offset))
            if range.location == NSNotFound { break }
            guard let match = token.firstMatch(in: format, range: NSRange(location: range.location, length: string.length - range.location)), match.range.location == range.location else {
                if literalPercent { offset = range.location + 1; continue }
                throw LanguagePackError.arguments
            }
            func part(_ index: Int) -> String? { match.range(at: index).location == NSNotFound ? nil : string.substring(with: match.range(at: index)) }
            offset = NSMaxRange(match.range)
            if part(7) != nil { continue }
            guard (Int(part(3) ?? "") ?? 0) <= 1000, (Int(part(4) ?? "") ?? 0) <= 20 else { throw LanguagePackError.arguments }
            let index = part(1).flatMap(Int.init) ?? next
            guard (1...64).contains(index) else { throw LanguagePackError.arguments }
            if part(1) == nil { next += 1 }
            let type: String
            if let variable = part(2) {
                guard let value = variables[variable] else { throw LanguagePackError.arguments }
                type = value; result.variables[variable] = index
            } else { type = (part(5) ?? "") + (part(6) ?? "") }
            guard result.arguments[index] == nil || result.arguments[index] == type else { throw LanguagePackError.arguments }
            result.arguments[index] = type
        }
        return result
    }

    static func validate(_ value: Any, against reference: Any) throws {
        let expected = try analyze(reference, literalPercent: true).root.arguments
        if expected.isEmpty, let text = value as? String {
            let unescaped = text.replacingOccurrences(of: "%%", with: "")
            guard unescaped.range(of: #"%(?:[1-9][0-9]*\$)?[-+ #0']*(?:[0-9]+|\*)?(?:\.(?:[0-9]+|\*))?(?:hh|ll|h|l|z|t|j|L)?[nsSp]"#, options: .regularExpression) == nil,
                  try signature(text, literalPercent: true).arguments.isEmpty else { throw LanguagePackError.arguments }
            return
        }
        let actual = try analyze(value)
        guard actual.root.arguments == expected else { throw LanguagePackError.arguments }
        for (format, start) in actual.branches {
            let branch = try signature(format, start: start).arguments
            guard branch.allSatisfy({ expected[$0.key] == $0.value }) else { throw LanguagePackError.arguments }
        }
    }

    private static func analyze(_ value: Any, literalPercent: Bool = false) throws -> (root: Signature, branches: [(String, Int)]) {
        if let text = value as? String { return (try signature(text, literalPercent: literalPercent), []) }
        guard let dictionary = value as? [String: Any], let format = dictionary["NSStringLocalizedFormatKey"] as? String else { throw LanguagePackError.invalid }
        var types: [String: String] = [:]
        for (key, value) in dictionary where key != "NSStringLocalizedFormatKey" {
            guard let variation = value as? [String: String], variation["NSStringFormatSpecTypeKey"] == "NSStringPluralRuleType",
                  let type = variation["NSStringFormatValueTypeKey"], ["d", "ld", "lld", "u", "lu", "llu"].contains(type), variation["other"] != nil else { throw LanguagePackError.invalid }
            types[key] = type
        }
        let root = try signature(format, variables: types)
        guard Set(root.variables.keys) == Set(types.keys) else { throw LanguagePackError.invalid }
        var branches: [(String, Int)] = []
        for (key, value) in dictionary where key != "NSStringLocalizedFormatKey" {
            let variation = value as! [String: String]
            for (form, text) in variation where !form.hasPrefix("NSString") {
                guard ["zero", "one", "two", "few", "many", "other"].contains(form) else { throw LanguagePackError.invalid }
                branches.append((text, root.variables[key]!))
            }
        }
        return (root, branches)
    }
}

final class LanguagePackStore {
    static let selectionKey = "communityLanguagePack"
    static let installedPacksChanged = Notification.Name("PhosdeckInstalledLanguagePacksChanged")
    private static let removalsKey = "removedCommunityLanguagePacks"
    let directory: URL
    let defaults: UserDefaults
    let source: Bundle

    init(directory: URL? = nil, defaults: UserDefaults = .standard, source: Bundle = .main) throws {
        self.directory = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("OhMyLRC/LanguagePacks", isDirectory: true)
        self.defaults = defaults; self.source = source
    }

    private func location(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw LanguagePackError.invalid }
        return directory.appendingPathComponent(id + ".bundle", isDirectory: true)
    }

    func read(id: String) throws -> LanguagePack { try read(at: location(id), id: id) }

    func installed() throws -> [LanguagePack] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let removed = Set(defaults.stringArray(forKey: Self.removalsKey) ?? [])
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "bundle" && !removed.contains($0.deletingPathExtension().lastPathComponent) }
            .compactMap { try? read(id: $0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func install(from url: URL) throws -> LanguagePack {
        let pack = try read(at: url, id: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".install-" + UUID().uuidString, isDirectory: true)
        let resources = staging.appendingPathComponent("Contents/Resources/" + pack.language + ".lproj", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundlePackageType": "BNDL", "CFBundleIdentifier": "dev.cmkk.oh-my-lrc.language." + pack.id,
            "CFBundleDevelopmentRegion": pack.language, "CFBundleVersion": pack.version, "OMLRCFormatVersion": 1,
            "OMLRCPackIdentifier": pack.identifier, "OMLRCLanguage": pack.language, "OMLRCName": pack.name, "OMLRCAuthor": pack.author]
        try SafeFileWriter.write(PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0), to: staging.appendingPathComponent("Contents/Info.plist"))
        for (name, data) in pack.tables { try SafeFileWriter.write(data, to: resources.appendingPathComponent(name)) }
        _ = try read(at: staging, id: pack.id)
        try SafeFileWriter.publish(staging, to: location(pack.id))
        return try read(id: pack.id)
    }

    func remove(id: String, activeID: String?) throws {
        let url = try location(id)
        if activeID == id {
            var pending = Set(defaults.stringArray(forKey: Self.removalsKey) ?? [])
            pending.insert(id); defaults.set(pending.sorted(), forKey: Self.removalsKey)
        } else { try FileManager.default.removeItem(at: url) }
        if defaults.string(forKey: Self.selectionKey) == id { defaults.removeObject(forKey: Self.selectionKey) }
    }

    func select(id: String?) throws {
        if let id {
            guard defaults.stringArray(forKey: Self.removalsKey)?.contains(id) != true else { throw LanguagePackError.invalid }
            _ = try read(id: id)
            defaults.set(id, forKey: Self.selectionKey)
        } else {
            defaults.removeObject(forKey: Self.selectionKey)
        }
    }

    func cleanPendingRemovals() throws {
        let selected = defaults.string(forKey: Self.selectionKey)
        for id in defaults.stringArray(forKey: Self.removalsKey) ?? [] where id != selected {
            let url = try location(id)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        defaults.removeObject(forKey: Self.removalsKey)
    }

    private func read(at url: URL, id: String) throws -> LanguagePack {
        let fm = FileManager.default
        func requireDirectory(_ path: URL) throws {
            let values = try path.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw LanguagePackError.unsafeFile }
        }
        func readFile(_ path: URL) throws -> Data {
            // Startup validation cannot call file helpers whose errors initialize L10n.current.
            let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LanguagePackError.unsafeFile }
            guard let size = values.fileSize, size > 0, size <= 8 * 1024 * 1024 else { throw LanguagePackError.invalid }
            return try Data(contentsOf: path, options: [.mappedIfSafe])
        }
        func table(_ data: Data) throws -> [String: Any] {
            guard let result = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { throw LanguagePackError.invalid }
            return result
        }
        try requireDirectory(url)
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try requireDirectory(contents)
        let info = try table(readFile(contents.appendingPathComponent("Info.plist")))
        guard info["OMLRCFormatVersion"] as? Int == 1, let language = info["OMLRCLanguage"] as? String,
              language.range(of: #"^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil,
              !["en", "zh-Hans"].contains(language), !language.hasPrefix("en-") else { throw LanguagePackError.unsupported }
        guard info["CFBundleExecutable"] == nil, !fm.fileExists(atPath: contents.appendingPathComponent("MacOS").path) else { throw LanguagePackError.unsafeFile }
        func field(_ key: String) throws -> String {
            guard let text = info[key] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 200,
                  text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw LanguagePackError.invalid }
            return text
        }
        let identifier = try field("OMLRCPackIdentifier"), name = try field("OMLRCName"), author = try field("OMLRCAuthor"), version = try field("CFBundleVersion")
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try requireDirectory(resources)
        let languageURL = resources.appendingPathComponent(language + ".lproj", isDirectory: true)
        try requireDirectory(languageURL)
        var reference: [String: Any] = [:]
        for ext in ["strings", "stringsdict"] {
            if let path = source.url(forResource: "Localizable", withExtension: ext, subdirectory: nil, localization: "en") {
                reference.merge(try table(readFile(path))) { _, new in new }
            }
        }
        guard !reference.isEmpty else { throw LanguagePackError.invalid }
        var keys = Set<String>(), tables: [String: Data] = [:]
        for ext in ["strings", "stringsdict"] {
            let filename = "Localizable." + ext, path = languageURL.appendingPathComponent("Localizable." + ext)
            guard fm.fileExists(atPath: path.path) else { continue }
            var values = try table(readFile(path))
            for (key, value) in values {
                // Xcode may emit key = key for untranslated catalog entries.
                guard let original = reference[key], (value as? String).map({ !$0.isEmpty && $0 != key }) ?? true else { values.removeValue(forKey: key); continue }
                if ext == "strings", !(value is String) { throw LanguagePackError.invalid }
                if ext == "stringsdict", !(value is [String: Any]) { throw LanguagePackError.invalid }
                try LocalizationFormat.validate(value, against: original)
                keys.insert(key)
            }
            tables[filename] = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        }
        guard !keys.isEmpty, let bundle = Bundle(url: url) else { throw LanguagePackError.invalid }
        return LanguagePack(id: id, identifier: identifier, language: language, name: name, author: author, version: version, bundle: bundle, keys: keys, tables: tables)
    }
}
