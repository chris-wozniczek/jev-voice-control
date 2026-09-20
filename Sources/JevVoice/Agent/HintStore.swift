import Foundation

struct ActionHint: Codable, Equatable {
    let app: String
    let goalKey: String
    let role: String
    let label: String
    var uses: Int
    var updated: Date
}

final class HintStore {
    static let shared = HintStore(url: HintStore.defaultURL)

    private let url: URL
    private var loaded = false
    private var entries: [ActionHint] = []

    init(url: URL) {
        self.url = url
    }

    var count: Int {
        loadIfNeeded()
        return entries.count
    }

    static func goalKey(_ goal: String) -> String {
        let stopWords: Set<String> = [
            "a", "an", "the", "in", "on", "to", "please", "now",
            "and", "then", "my", "me",
        ]
        return goal.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !stopWords.contains($0) }
            .joined(separator: " ")
    }

    func hints(app: String, goal: String) -> [ActionHint] {
        loadIfNeeded()
        let key = Self.goalKey(goal)
        let words = Set(key.split(separator: " ").map(String.init))
        let matching = entries.filter { entry in
            guard entry.app.caseInsensitiveCompare(app) == .orderedSame else { return false }
            if entry.goalKey == key { return true }
            return Set(entry.goalKey.split(separator: " ").map(String.init))
                .intersection(words).count >= 2
        }
        let exact = matching.filter { $0.goalKey == key }
        let related = matching.filter { $0.goalKey != key }
        let sorted: [ActionHint] = (exact + related).sorted {
            if ($0.goalKey == key) != ($1.goalKey == key) {
                return $0.goalKey == key
            }
            if $0.uses != $1.uses { return $0.uses > $1.uses }
            if $0.updated != $1.updated { return $0.updated > $1.updated }
            return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
        return Array(sorted.prefix(5))
    }

    func record(app: String, goal: String, role: String, label: String) {
        loadIfNeeded()
        let goalKey = Self.goalKey(goal)
        guard !app.isEmpty, !goalKey.isEmpty, !label.isEmpty else { return }
        if let index = entries.firstIndex(where: {
            $0.app.caseInsensitiveCompare(app) == .orderedSame
                && $0.goalKey == goalKey
                && $0.role == role
                && $0.label == label
        }) {
            entries[index].uses += 1
            entries[index].updated = Date()
        } else {
            entries.append(ActionHint(
                app: app,
                goalKey: goalKey,
                role: role,
                label: label,
                uses: 1,
                updated: Date()
            ))
        }
    }

    func save() {
        loadIfNeeded()
        entries.sort {
            if $0.uses != $1.uses { return $0.uses > $1.uses }
            return $0.updated > $1.updated
        }
        if entries.count > 500 {
            entries = Array(entries.prefix(500))
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.agent.info("hint save failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func clear() {
        loaded = true
        entries = []
        try? FileManager.default.removeItem(at: url)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ActionHint].self, from: data) else {
            return
        }
        entries = decoded
    }

    private static var defaultURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Jev Voice/hints.json")
    }
}
