import SwiftUI

struct FolderNode: Identifiable {
    let rootID: String
    let relativePath: String
    let name: String
    var children: [FolderNode]?
    var id: String { "folder:\(rootID):\(relativePath)" }
    static func build(root: StorageRoot, photos: [Photo]) -> [FolderNode] {
        build(root: root, directories: photos.filter { $0.rootID == root.id }.map { $0.relativePath.split(separator: "/").dropLast().joined(separator: "/") })
    }
    static func build(root: StorageRoot, directories: [String]) -> [FolderNode] {
        let paths = directories.map { $0.split(separator: "/").map(String.init) }
        func nodes(_ paths: [[String]], prefix: String) -> [FolderNode] {
            let names = Set(paths.compactMap(\.first)).sorted()
            return names.map { name in
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                let descendants = paths.filter { $0.first == name }.map { Array($0.dropFirst()) }
                let child = nodes(descendants, prefix: relative)
                return FolderNode(rootID: root.id, relativePath: relative, name: name, children: child.isEmpty ? nil : child)
            }
        }
        return nodes(paths, prefix: "")
    }
}
