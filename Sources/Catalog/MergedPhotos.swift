import Foundation
import GRDB

extension CatalogStore {
    func mergeDestinationRoot(directory: URL,bookmark: Data) throws -> StorageRoot {
        let path = directory.path,roots = try roots()
        if let root = roots.first(where:{ path == $0.path || path.hasPrefix($0.path+"/") }) { return root }
        guard !roots.contains(where:{ $0.path.hasPrefix(path+"/") }) else { throw LRCError(L10n.text("app.theSelectedFolderOverlapsAnExistingRootRescanThe", defaultValue:"The selected folder overlaps an existing root. Rescan the existing root")) }
        return StorageRoot(id:UUID().uuidString,path:path,bookmark:bookmark,label:directory.lastPathComponent)
    }
    func validateMergeInputs(_ inputs: [ImageRequest]) throws {
        try database.read { db in try Self.validateMergeInputs(inputs,in:db) }
    }
    private static func validateMergeInputs(_ inputs: [ImageRequest],in db: Database) throws {
        for request in inputs {
            guard let current = try Photo.fetchOne(db,key:request.photo.id),current == request.photo,!current.deleted,
                  let root = try StorageRoot.fetchOne(db,key:request.root.id),root.path == request.root.path,root.bookmark == request.root.bookmark else { throw PhotoMergeEngine.sourceChanged }
        }
    }
    /// Source validation, root and master become visible together. Existing stacks,
    /// source edits and histories are never rewritten by a photo merge.
    func registerMergedPhoto(_ photo: Photo,root: StorageRoot,inputs: [ImageRequest]) throws -> Photo {
        try database.write { db in
            try Self.validateMergeInputs(inputs,in:db)
            if let existing = try StorageRoot.fetchOne(db,key:root.id) {
                guard existing.path == root.path,existing.bookmark == root.bookmark else { throw PhotoMergeEngine.sourceChanged }
            } else {
                let roots = try StorageRoot.fetchAll(db)
                guard !roots.contains(where:{ $0.path == root.path || $0.path.hasPrefix(root.path+"/") || root.path.hasPrefix($0.path+"/") }) else { throw PhotoMergeEngine.sourceChanged }
                try root.insert(db)
            }
            guard try Self.index(photo,in:db) else { throw PhotoMergeEngine.sourceChanged }
            guard let indexed = try Photo.fetchOne(db,key:photo.id) else { throw PhotoMergeEngine.sourceChanged }
            return indexed
        }
    }
}
