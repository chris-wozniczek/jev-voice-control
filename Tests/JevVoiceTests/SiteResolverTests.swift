import XCTest
@testable import JevVoiceCore

final class SiteResolverTests: XCTestCase {
    private let resolver = SiteResolver(sites: SiteResolver.defaultSites)

    func testResolvesX() {
        XCTAssertEqual(
            resolver.site(in: "compose a post on X about cats")?.host,
            "x.com"
        )
    }

    func testResolvesKnownSiteWhenNoMatchingAppIsInstalled() {
        XCTAssertEqual(resolver.site(in: "open github")?.host, "github.com")
    }

    func testInstalledAppWinsOverSiteName() {
        XCTAssertNil(resolver.site(in: "on grok", installedApps: ["Grok"]))
    }

    func testSynthesizesUnknownHost() {
        XCTAssertEqual(resolver.site(in: "go to example.org")?.host, "example.org")
    }
}
