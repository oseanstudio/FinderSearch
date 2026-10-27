import XCTest
@testable import FinderSearch

// HOME: type-select, category-scoped search filtering, and sidebar section
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

final class SidebarLayoutTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SidebarLayout.key)
    }

    private func stored(_ sections: [String], hidden: [String] = []) {
        let data = try! JSONEncoder().encode(
            ["sections": sections, "hidden": hidden] as [String: [String]])
        UserDefaults.standard.set(data, forKey: SidebarLayout.key)
    }

    func testLoadFillsMissingSectionsAndDropsUnknown() {
        stored(["favorites", "bogus", "tags"])
        let layout = SidebarLayout.load()
        XCTAssertEqual(layout.sections.first, .favorites)
        XCTAssertEqual(layout.sections[1], .tags)
        XCTAssertFalse(layout.sections.contains { $0.rawValue == "bogus" })
        XCTAssertEqual(Set(layout.sections), Set(SidebarSection.allCases))
    }

    func testEmptyStorageKeepsDefaultOrder() {
        UserDefaults.standard.removeObject(forKey: SidebarLayout.key)
        let layout = SidebarLayout.load()
        XCTAssertEqual(layout.sections, Array(SidebarSection.allCases))
        XCTAssertTrue(layout.hidden.isEmpty)
    }

    func testHiddenRoundTripAndVisibility() {
        stored(Array(SidebarSection.allCases.map(\.rawValue)), hidden: ["sec:tags", "row:recents"])
        let layout = SidebarLayout.load()
        XCTAssertTrue(layout.isHidden("sec:tags"))
        XCTAssertTrue(layout.isHidden("row:recents"))
        XCTAssertFalse(layout.visibleSections.contains(.tags))
        XCTAssertEqual(layout.visibleSections.count, SidebarSection.allCases.count - 1)
    }

    func testMoveKeepsHiddenSectionsPresent() {
        stored(Array(SidebarSection.allCases.map(\.rawValue)), hidden: ["sec:tags"])
        var layout = SidebarLayout.load()
        // Simulate the drag coordinator: favorites moved to the front.
        var ordered = layout.visibleSections.filter { $0 != .favorites }
        ordered.insert(.favorites, at: 0)
        layout.sections = ordered + layout.sections.filter { !ordered.contains($0) }
        layout.save()
        let reloaded = SidebarLayout.load()
        XCTAssertEqual(reloaded.sections.first, .favorites)
        XCTAssertTrue(reloaded.isHidden("sec:tags"), "hidden sections survive a drag")
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
