import AppKit
import Combine
import Foundation
import JevVoiceCore

struct StoredLearnedTool: Codable, Equatable, Identifiable {
    let tool: LearnedTool
    var enabled: Bool
    var createdAt: Date
    var useCount: Int
    var source: String

    var id: String { tool.name }
}

@MainActor
final class LearnedToolStore: ObservableObject {
    static let shared = LearnedToolStore(url: defaultURL)

    @Published private(set) var revision = 0
    private let url: URL
    private var loaded = false
    private var learned: [String: StoredLearnedTool] = [:]

    init(url: URL) {
        self.url = url
    }

    var folderURL: URL { url.deletingLastPathComponent() }

    func records() -> [StoredLearnedTool] {
        loadIfNeeded()
        let seeds = Self.seedTools().map {
            StoredLearnedTool(
                tool: $0,
                enabled: learned[$0.name]?.enabled ?? true,
                createdAt: Date.distantPast,
                useCount: learned[$0.name]?.useCount ?? 0,
                source: learned[$0.name]?.source ?? "seed"
            )
        }
        let seedNames = Set(seeds.map(\.id))
        let extra = learned.values.filter { !seedNames.contains($0.id) }
        return (seeds + extra).sorted {
            $0.tool.description.localizedCaseInsensitiveCompare($1.tool.description) == .orderedAscending
        }
    }

    func enabledTools() -> [StoredLearnedTool] {
        records().filter(\.enabled)
    }

    func save(_ tool: LearnedTool) {
        loadIfNeeded()
        let old = learned[tool.name]
        let isSeed = Self.seedTools().contains { $0.name == tool.name }
        learned[tool.name] = StoredLearnedTool(
            tool: tool,
            enabled: old?.enabled ?? true,
            createdAt: old?.createdAt ?? (isSeed ? .distantPast : Date()),
            useCount: (old?.useCount ?? 0) + 1,
            source: old?.source ?? (isSeed ? "seed" : "learned")
        )
        persist()
    }

    func recordUse(of tool: LearnedTool) {
        loadIfNeeded()
        guard var record = learned[tool.name] else {
            save(tool)
            return
        }
        record.useCount += 1
        learned[tool.name] = record
        persist()
    }

    func setEnabled(_ enabled: Bool, for name: String) {
        loadIfNeeded()
        guard var record = learned[name] ?? records().first(where: { $0.id == name }) else { return }
        record.enabled = enabled
        learned[name] = record
        persist()
    }

    func delete(_ name: String) {
        loadIfNeeded()
        learned.removeValue(forKey: name)
        persist()
    }

    func revealFolder() {
        try? FileManager.default.createDirectory(
            at: folderURL,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.activateFileViewerSelecting([folderURL])
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: folderURL,
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(Array(learned.values))
            try data.write(to: url, options: .atomic)
        } catch {
            Log.agent.info("learned tools save failed error=\(error.localizedDescription, privacy: .public)")
        }
        revision += 1
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([StoredLearnedTool].self, from: data) else {
            return
        }
        learned = Dictionary(uniqueKeysWithValues: decoded.map { ($0.tool.name, $0) })
    }

    private static func seedTools() -> [LearnedTool] {
        guard let url = Bundle.module.url(forResource: "seed-tools", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let tools = try? JSONDecoder().decode([LearnedTool].self, from: data) else {
            return []
        }
        return tools
    }

    private static var defaultURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Jev Voice/tools/tools.json")
    }
}
