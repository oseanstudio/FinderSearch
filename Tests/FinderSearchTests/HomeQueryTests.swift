import XCTest
@testable import FinderSearch

/// Home fork: natural-language query parsing compiles to engine filters.
final class HomeQueryTests: XCTestCase {
    private func engineQuery(_ raw: String) -> String {
        HomeQuery.translate(raw)
    }

    func testParsesTypeDateAndSize() {
        XCTAssertEqual(
            engineQuery("pdfs from last week over 5 mb"),
            "type:pdf mtime:<7d size:>5mb")
    }

    func testParsesTodayAndUnder() {
        XCTAssertEqual(engineQuery("images from today under 2mb"), "type:image mtime:<1d size:<2mb")
    }

    func testParsesPastNUnits() {
        XCTAssertEqual(engineQuery("videos from past 3 months"), "type:video mtime:<90d")
        XCTAssertEqual(engineQuery("docs 2 weeks ago"), "type:doc mtime:<14d")
    }

    func testParsesSourceAndContents() {
        let parsed = HomeQuery.parse("pdfs from gmail containing invoice")
        XCTAssertEqual(parsed.type, "pdf")
        XCTAssertEqual(parsed.source, "gmail")
        XCTAssertEqual(parsed.grep, "invoice")
    }

    func testFoldersMapToKind() {
        XCTAssertEqual(engineQuery("folders from yesterday"), "kind:dir mtime:<2d")
    }

    func testBareTextPassesThroughUntouched() {
        XCTAssertEqual(engineQuery("quarterly report"), "quarterly report")
        XCTAssertEqual(engineQuery("screenplay final draft v2"), "screenplay final draft v2")
    }

    func testRawFsearchSyntaxPassesThrough() {
        XCTAssertEqual(
            engineQuery("ext:pdf mtime:<7d size:>5mb"), "ext:pdf mtime:<7d size:>5mb")
    }

    func testRemainingWordsBecomeFuzzyText() {
        XCTAssertEqual(
            engineQuery("budget spreadsheets from this month"),
            "budget type:xlsx mtime:<30d")
    }

    func testScreenshotsKeepNameHint() {
        let parsed = HomeQuery.parse("screenshots from yesterday")
        XCTAssertEqual(parsed.mtime, "<2d")
        XCTAssertEqual(parsed.text, "screenshot")
    }
}

/// Home fork: route parsing round-trips every sidebar destination.
final class HomeRouteTests: XCTestCase {
    @MainActor func testRoundTripsAllRoutes() {
        for route in HomeRoute.allCases {
            XCTAssertEqual(HomeRoute(route.route), route)
        }
    }

    @MainActor func testRejectsOrdinaryPaths() {
        XCTAssertNil(HomeRoute("/Users/example/Documents"))
        XCTAssertNil(HomeRoute("recents"))
        XCTAssertNil(HomeRoute("tag:Red"))
        XCTAssertNil(HomeRoute("cat:unknown"))
    }

    @MainActor func testTitlesAndQueries() {
        XCTAssertEqual(HomeRoute("cat:images")?.title, "Images")
        XCTAssertEqual(HomeRoute("smart:large")?.engineQuery, "size:>100mb kind:file")
        XCTAssertNil(HomeRoute("home")?.engineQuery)
    }
}
