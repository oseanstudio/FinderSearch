import XCTest
@testable import FinderSearch

/// HOME: the native sidebar table's reorder math.
@MainActor
final class SidebarDropTests: XCTestCase {
    private func makeEntries(sections: [(SidebarSection, [String])]) -> [SidebarEntry] {
        var entries: [SidebarEntry] = []
        for (section, ids) in sections {
            entries.append(.header(section))
            for id in ids {
                entries.append(.item(SidebarItem(
                    id: id, section: section, route: id, title: id, symbol: "folder",
                    kind: .favorite(path: id))))
            }
        }
        return entries
    }

    func testItemInsertionIndexCountsOnlySectionItems() {
        let entries = makeEntries(sections: [
            (.favorites, ["a", "b", "c"]),
            (.locations, ["x", "y"]),
        ])
        // Gap above "b" (row 2: header=0, a=1, b=2): one favorites item above.
        XCTAssertEqual(
            SidebarTableCoordinator.itemInsertionIndex(
                entries: entries, section: .favorites, orderableIDs: ["a", "b", "c"],
                targetRow: 2),
            1)
        // Gap above the Locations header trails "c": end of favorites.
        XCTAssertEqual(
            SidebarTableCoordinator.itemInsertionIndex(
                entries: entries, section: .favorites, orderableIDs: ["a", "b", "c"],
                targetRow: 4),
            3)
        // A locations drop counts only locations items.
        XCTAssertEqual(
            SidebarTableCoordinator.itemInsertionIndex(
                entries: entries, section: .locations, orderableIDs: ["x", "y"],
                targetRow: 6),
            1)
    }

    func testDownwardMoveLandsBelowTheDropRow() {
        // [A,B,C]; drag A with the gap above C → [B,A,C]. The raw gap index
        // (2) includes the dragged row itself, so it shifts down by one after
        // removal.
        let entries = makeEntries(sections: [(.favorites, ["A", "B", "C"])])
        var ordered = ["A", "B", "C"]
        let source = ordered.firstIndex(of: "A")!
        var insert = SidebarTableCoordinator.itemInsertionIndex(
            entries: entries, section: .favorites, orderableIDs: ordered, targetRow: 3)
        if insert > source { insert -= 1 }
        ordered.remove(at: source)
        ordered.insert("A", at: insert)
        XCTAssertEqual(ordered, ["B", "A", "C"])
    }

    func testUpwardMoveLandsAboveTheDropRow() {
        // [A,B,C]; drag C with the gap above A → [C,A,B].
        let entries = makeEntries(sections: [(.favorites, ["A", "B", "C"])])
        var ordered = ["A", "B", "C"]
        let source = ordered.firstIndex(of: "C")!
        var insert = SidebarTableCoordinator.itemInsertionIndex(
            entries: entries, section: .favorites, orderableIDs: ordered, targetRow: 1)
        if insert > source { insert -= 1 }
        ordered.remove(at: source)
        ordered.insert("C", at: insert)
        XCTAssertEqual(ordered, ["C", "A", "B"])
    }

    func testNoOpMoveIsRejected() {
        // [A,B,C]; drag B with the gap above C: gap index 2 → source 1 → 1
        // after adjustment, a no-op.
        let entries = makeEntries(sections: [(.favorites, ["A", "B", "C"])])
        let ordered = ["A", "B", "C"]
        let source = ordered.firstIndex(of: "B")!
        var insert = SidebarTableCoordinator.itemInsertionIndex(
            entries: entries, section: .favorites, orderableIDs: ordered, targetRow: 3)
        if insert > source { insert -= 1 }
        XCTAssertEqual(insert, source)
    }

    func testSectionOrderMovesHeader() {
        // Favorites dropped onto the Tags header lands right before Tags.
        let entries = makeEntries(sections: [
            (.favorites, ["a"]), (.locations, ["x"]), (.tags, ["t"]),
        ])
        let result = SidebarTableCoordinator.sectionOrder(
            visible: [.favorites, .locations, .tags], dragged: .favorites, targetRow: 4,
            entries: entries)
        XCTAssertEqual(result, [.locations, .favorites, .tags])
    }

    func testSectionOrderAfterItemRow() {
        // Favorites dropped with a gap above "y" (Locations' last item) lands
        // after Locations.
        let entries = makeEntries(sections: [
            (.favorites, ["a"]), (.locations, ["x", "y"]),
        ])
        let result = SidebarTableCoordinator.sectionOrder(
            visible: [.favorites, .locations], dragged: .favorites, targetRow: 4,
            entries: entries)
        XCTAssertEqual(result, [.locations, .favorites])
    }

    func testSectionOrderAboveNextHeaderIsANoOp() {
        // Favorites dropped in the gap between its own last item and the
        // Locations header stays put.
        let entries = makeEntries(sections: [
            (.favorites, ["a"]), (.locations, ["x"]),
        ])
        let result = SidebarTableCoordinator.sectionOrder(
            visible: [.favorites, .locations], dragged: .favorites, targetRow: 2,
            entries: entries)
        XCTAssertEqual(result, [.favorites, .locations])
    }

    func testOrderedIDSMergesStoredAndNew() {
        var layout = SidebarLayout(sections: Array(SidebarSection.allCases), hidden: [])
        layout.setOrder(section: .favorites, ["c", "a"])
        // "b" is new (never ordered) and appends; unknown ids drop.
        XCTAssertEqual(
            layout.orderedIDs(section: .favorites, current: ["a", "b", "c"]), ["c", "a", "b"])
        XCTAssertEqual(
            layout.orderedIDs(section: .favorites, current: ["a", "z"]), ["a", "z"])
    }
}
