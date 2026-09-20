import Foundation
import JevVoiceCore

struct WebSiteRegistry {
    static let shared = WebSiteRegistry()

    let sites: [WebSite]

    init() {
        sites = Self.load()
    }

    var resolver: SiteResolver {
        SiteResolver(sites: sites)
    }

    private static func load() -> [WebSite] {
        let bundled: [WebSite]
        if let data = resourceData(),
           let file = try? JSONDecoder().decode(File.self, from: data) {
            bundled = file.sites
        } else {
            bundled = SiteResolver.defaultSites
        }
        let userURL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
            .appendingPathComponent("Jev Voice", isDirectory: true)
            .appendingPathComponent("web-sites.json")
        guard let data = try? Data(contentsOf: userURL),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            return bundled
        }
        var merged = Dictionary(uniqueKeysWithValues: bundled.map { ($0.host.lowercased(), $0) })
        for site in file.sites {
            merged[site.host.lowercased()] = site
        }
        return merged.values.sorted { $0.host < $1.host }
    }

    private static func resourceData() -> Data? {
        var bundles = [Bundle.main]
        if let url = Bundle.main.url(
            forResource: "JevVoice_JevVoice",
            withExtension: "bundle"
        ), let bundle = Bundle(url: url) {
            bundles.append(bundle)
        }
        #if DEBUG
        bundles.append(Bundle.module)
        #endif
        return bundles.lazy.compactMap {
            guard let url = $0.url(forResource: "web-sites", withExtension: "json") else {
                return nil
            }
            return try? Data(contentsOf: url)
        }.first
    }

    private struct File: Codable {
        let sites: [WebSite]
    }
}
