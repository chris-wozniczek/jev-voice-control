import Foundation

struct SnapshotDiff: Equatable {
    let added: Set<String>
    let removed: Set<String>

    static func between(old: CuaSnapshot, new: CuaSnapshot) -> SnapshotDiff {
        let oldLabels = Set(old.elements.map(\.label))
        let newLabels = Set(new.elements.map(\.label))
        return SnapshotDiff(
            added: newLabels.subtracting(oldLabels),
            removed: oldLabels.subtracting(newLabels)
        )
    }

    var isEmpty: Bool {
        added.isEmpty && removed.isEmpty
    }

    var compactDescription: String {
        let addedText = added.sorted().joined(separator: ",")
        let removedText = removed.sorted().joined(separator: ",")
        return "changes: +[\(addedText)] -[\(removedText)]"
    }
}
