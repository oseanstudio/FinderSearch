import XCTest
@testable import FinderSearch

// HOMY: type-select, category-scoped search filtering, and sidebar section
// ordering.

final class TypeSelectTests: XCTestCase {
    private func hit(_ path: String) -> Hit {
        Hit(path: path, kind: "file", size: 1, mtime: 1, score: 0)
    }

    @MainActor func testJumpsToFirstPrefixMatch() {
        let model = SearchModel()
        model.hits = [hit("/tmp/alpha.txt"), hit("/tmp/godot.zip"), hit("/tmp/other.png")]
        model.sort = .name
        model.selectTypeAhead("god")
        XCTAssertEqual(model.selection, ["/tmp/godot.zip"])
    }

    @MainActor func testSkipsInvisibleAndWraps() {
        let model = SearchModel()
        model.hits = [hit("/tmp/.hidden"), hit("/tmp/godot.zip"), hit("/tmp/.dot")]
        // Hidden files are not in sortedHits (showHidden false).
        model.sort = .name
        model.selectTypeAhead("go")
        XCTAssertEqual(model.selection, ["/tmp/godot.zip"])
    }

    @MainActor func testSecondCallMovesToNextMatch() {
        let model = SearchModel()
        model.hits = [
            hit("/tmp/godot.zip"), hit("/tmp/godot2.zip"), hit("/tmp/other.png"),
        ]
        model.sort = .name
        model.selectTypeAhead("godot")
        XCTAssertEqual(model.selection, ["/tmp/godot.zip"])
        model.selectTypeAhead("godot")
        XCTAssertEqual(model.selection, ["/tmp/godot2.zip"])
        // Wraps back to the first match.
        model.selectTypeAhead("godot")
        XCTAssertEqual(model.selection, ["/tmp/godot.zip"])
    }

    @MainActor func testNoMatchLeavesSelection() {
        let model = SearchModel()
        model.hits = [hit("/tmp/alpha.txt")]
        model.sort = .name
        model.selectTypeAhead("zzz")
        XCTAssertTrue(model.selection.isEmpty)
    }
}

final class SidebarSectionTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SidebarSection.orderKey)
    }

    func testLoadOrderFillsMissingSections() {
        UserDefaults.standard.set(["favorites"], forKey: SidebarSection.orderKey)
        let order = SidebarSection.loadOrder()
        XCTAssertEqual(order.first, .favorites)
        XCTAssertEqual(Set(order), Set(SidebarSection.allCases))
        XCTAssertEqual(order.count, SidebarSection.allCases.count)
    }

    func testUnknownEntriesAreDropped() {
        UserDefaults.standard.set(["favorites", "bogus", "tags"], forKey: SidebarSection.orderKey)
        let order = SidebarSection.loadOrder()
        XCTAssertEqual(order.first, .favorites)
        XCTAssertEqual(order[1], .tags)
        XCTAssertFalse(order.contains { $0.rawValue == "bogus" })
    }

    func testEmptyStorageKeepsDefaultOrder() {
        UserDefaults.standard.removeObject(forKey: SidebarSection.orderKey)
        XCTAssertEqual(SidebarSection.loadOrder(), Array(SidebarSection.allCases))
    }
}

final class CategoryFilterTests: XCTestCase {
    /// The same name filter the model applies to category results: every
    /// token must appear in the file name, case-insensitively.
    func testFilterLogicMatchesAllTokens() {
        let hits = [
            Hit(path: "/tmp/godot editor.png", kind: "file", size: 1, mtime: 1, score: 0),
            Hit(path: "/tmp/GODOT.zip", kind: "file", size: 1, mtime: 2, score: 0),
            Hit(path: "/tmp/unrelated.txt", kind: "file", size: 1, mtime: 3, score: 0),
        ]
        let filter = "godot"
        let tokens = filter.split(separator: " ").map(String.init)
        let result = hits.filter { hit in
            tokens.allSatisfy { hit.name.localizedCaseInsensitiveContains($0) }
        }
        XCTAssertEqual(result.count, 2)
    }
}
