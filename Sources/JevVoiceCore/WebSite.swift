import Foundation

public struct WebSite: Codable, Equatable {
    public var host: String
    public var names: [String]

    public init(host: String, names: [String]) {
        self.host = host
        self.names = names
    }
}

public struct SiteResolver {
    private let sites: [WebSite]

    public init(sites: [WebSite]) {
        self.sites = sites
    }

    public func site(in clause: String) -> WebSite? {
        site(in: clause, installedApps: [])
    }

    public func site(in clause: String, installedApps: [String]) -> WebSite? {
        let installed = Set(installedApps.map { $0.lowercased() })
        let lowered = clause.lowercased()
        let orderedSites = sites.sorted { $0.names.joined().count > $1.names.joined().count }
        for site in orderedSites {
            for name in site.names.sorted(by: { $0.count > $1.count }) {
                let normalizedName = name.lowercased()
                guard !installed.contains(normalizedName),
                      wordBoundaryMatch(lowered, phrase: normalizedName) else {
                    continue
                }
                return site
            }
        }
        let hostPattern = #"\b[a-z0-9-]+(?:\.[a-z0-9-]+)+\b"#
        guard let regex = try? NSRegularExpression(pattern: hostPattern),
              let match = regex.firstMatch(
                in: lowered,
                range: NSRange(location: 0, length: (lowered as NSString).length)
              ),
              let range = Range(match.range, in: lowered) else {
            return nil
        }
        let host = String(lowered[range])
        return WebSite(host: host, names: [host])
    }

    private func wordBoundaryMatch(_ text: String, phrase: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        return text.range(
            of: "\\b" + escaped + "\\b",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    public static let defaultSites: [WebSite] = [
        WebSite(host: "x.com", names: ["x", "x.com", "x dot com", "twitter"]),
        WebSite(host: "github.com", names: ["github"]),
        WebSite(host: "youtube.com", names: ["youtube"]),
        WebSite(host: "mail.google.com", names: ["gmail"]),
        WebSite(host: "linkedin.com", names: ["linkedin"]),
        WebSite(host: "reddit.com", names: ["reddit"]),
        WebSite(host: "chatgpt.com", names: ["chatgpt", "chat gpt"]),
        WebSite(host: "grok.com", names: ["grok"]),
    ]
}
