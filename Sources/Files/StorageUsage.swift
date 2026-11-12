import Foundation
import GRDB
import Darwin

struct StorageUsage {
    var catalog: Int64 = 0
    var staging: Int64 = 0
    var recovery: Int64 = 0
    var inaccessible = 0
}
actor StorageInspector {
    func measure(_ catalog: CatalogStore) throws -> StorageUsage {
        var usage = StorageUsage()
        for url in [catalog.fileURL, URL(fileURLWithPath: catalog.fileURL.path + "-journal")] {
            if let identity = try? FileIdentity.read(url) { usage.catalog += identity.size }
        }
        var counted = Set<String>()
        func count(_ url: URL?, recovery: Bool) {
            guard let url, counted.insert(url.path).inserted else { return }
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                if errno != ENOENT { usage.inaccessible += 1 }
                return
            }
            guard info.st_mode & S_IFMT == S_IFREG else { usage.inaccessible += 1; return }
            if recovery { usage.recovery += info.st_size } else { usage.staging += info.st_size }
        }
        for plan in try CopyImporter.savedPlans(catalog: catalog) {
            try Task.checkCancellation()
            do {
                let lease = try AccessLease(bookmark: plan.targetBookmark)
                defer { withExtendedLifetime(lease) {} }
                for member in plan.groups.flatMap(\.members) {
                    count(member.staging, recovery: false)
                    if member.recoveryState != "deleted" { count(member.recovery, recovery: true) }
                }
            } catch { usage.inaccessible += 1 }
        }
        let exports = try ExportService.history(catalog: catalog)
        usage.inaccessible += exports.rejected.count
        for log in exports.logs {
            try Task.checkCancellation()
            do {
                let lease = try AccessLease(bookmark: log.snapshot.targetBookmark)
                defer { withExtendedLifetime(lease) {} }
                let staging = try catalog.database.read { try String.fetchOne($0, sql: "SELECT staging FROM exportItem WHERE id=?", arguments: [log.id]) }
                count(staging.map { URL(fileURLWithPath: $0) }, recovery: false)
                for url in log.snapshot.retainedStaging ?? [] { count(url, recovery: false) }
            } catch { usage.inaccessible += 1 }
        }
        return usage
    }
}
