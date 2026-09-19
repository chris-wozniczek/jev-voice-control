import AppKit
import Combine
import JevVoiceCore

@MainActor
final class AppRegistry: ObservableObject {
    struct Entry: Identifiable {
        let name: String
        let bundleID: String?
        let url: URL
        let aliases: [String]

        var id: String { bundleID ?? url.path }
    }

    static let shared = AppRegistry()

    @Published private(set) var entries: [Entry] = []
    private var launchObserver: NSObjectProtocol?

    private init() {
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    deinit {
        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
        }
    }

    var names: [String] {
        entries.map(\.name).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    var aliases: [String: String] {
        var result = AppMatcher.builtInAliases
        for (alias, target) in Config.shared.appAliases {
            result[alias.lowercased()] = target
        }
        return result
    }

    var spokenVariants: [String] {
        Array(Set(names + aliases.keys)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }.prefix(300).map { $0 }
    }

    func refresh() {
        var urls = Set<URL>()
        let fm = FileManager.default
        for root in searchRoots() {
            collectApps(in: root, depth: 0, fileManager: fm, into: &urls)
        }
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular {
            if let url = app.bundleURL { urls.insert(url) }
        }

        var discovered: [String: (url: URL, displayName: String, aliases: Set<String>)] = [:]
        for url in urls {
            guard let bundle = Bundle(url: url) else { continue }
            let filename = url.deletingPathExtension().lastPathComponent
            let displayName = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? filename
            let bundleID = bundle.bundleIdentifier ?? url.path
            var aliasNames = Set<String>()
            if filename.caseInsensitiveCompare(displayName) != .orderedSame {
                aliasNames.insert(filename)
            }
            if let current = discovered[bundleID] {
                discovered[bundleID] = (
                    url: current.url,
                    displayName: current.displayName,
                    aliases: current.aliases.union(aliasNames)
                )
            } else {
                discovered[bundleID] = (url, displayName, aliasNames)
            }
        }

        let allAliases = AppMatcher.builtInAliases.merging(Config.shared.appAliases) {
            _, userValue in userValue
        }
        entries = discovered.map { bundleID, value in
            let matchingAliases = allAliases
                .filter { $0.value.caseInsensitiveCompare(value.displayName) == .orderedSame }
                .map { $0.key }
            return Entry(
                name: value.displayName,
                bundleID: bundleID == value.url.path ? nil : bundleID,
                url: value.url,
                aliases: Array(value.aliases.union(matchingAliases)).sorted()
            )
        }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func url(named name: String) -> URL? {
        if let entry = entries.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
                || $0.aliases.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
        }) {
            if let bundleID = entry.bundleID,
               let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return resolved
            }
            return entry.url
        }
        if let entry = entries.first(where: {
            $0.name.localizedCaseInsensitiveContains(name)
        }) {
            return entry.url
        }
        if let target = aliases[name.lowercased()],
           let entry = entries.first(where: {
               $0.name.caseInsensitiveCompare(target) == .orderedSame
           }) {
            return entry.url
        }
        if let bundleID = entries.first(where: {
            $0.bundleID?.caseInsensitiveCompare(name) == .orderedSame
        })?.bundleID {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        }
        return nil
    }

    private func searchRoots() -> [URL] {
        let fm = FileManager.default
        var roots: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        roots.append(contentsOf: fm.urls(for: .applicationDirectory, in: .allDomainsMask))
        return Array(Set(roots))
    }

    private func collectApps(
        in root: URL,
        depth: Int,
        fileManager: FileManager,
        into apps: inout Set<URL>
    ) {
        guard depth <= 3,
              let children = try? fileManager.contentsOfDirectory(
                  at: root,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else { return }
        for child in children {
            guard !child.lastPathComponent.hasPrefix(".") else { continue }
            if child.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                apps.insert(child)
            } else if depth < 3 {
                collectApps(in: child, depth: depth + 1, fileManager: fileManager, into: &apps)
            }
        }
    }
}

@MainActor
enum InstalledApps {
    static func all() -> [String] {
        Array(AppRegistry.shared.names.prefix(254))
    }

    static func appURL(named name: String) -> URL? {
        AppRegistry.shared.url(named: name)
    }
}
