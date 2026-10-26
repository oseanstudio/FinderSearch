import XCTest
@testable import FinderSearch

// HOMY: user-defined content — smart-rule query compilation and collection
// merging.

final class FullDiskAccessTests: XCTestCase {
    // HOMY: the Full Disk Access pane lists only Applications-folder apps,
    // so the enable flow must tell dist-built Hearth apart.
    func testApplicationsPathDetection() {
        XCTAssertTrue(FullDiskAccess.isInApplications("/Applications/Hearth.app"))
        XCTAssertTrue(
            FullDiskAccess.isInApplications(NSHomeDirectory() + "/Applications/Hearth.app"))
        XCTAssertFalse(
            FullDiskAccess.isInApplications(
                NSHomeDirectory() + "/Documents/Github/findersearch-fork/dist/Hearth.app"))
        XCTAssertFalse(FullDiskAccess.isInApplications("/System/Applications/X.app"))
    }
}

final class SmartRuleTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: HomySmartRules.key)
    }

    private func rule(
        kind: String = "", minSizeMB: Int? = nil, days: Int? = nil,
        olderNotNewer: Bool = true, namePattern: String = "", source: String? = nil
    ) -> HomySmartRule {
        HomySmartRule(
            id: UUID(), name: "test", kind: kind, minSizeMB: minSizeMB, days: days,
            olderNotNewer: olderNotNewer, namePattern: namePattern, source: source)
    }

    @MainActor func testQueryCompilation() {
        XCTAssertEqual(HomySmartRules.query(for: rule()), "kind:file")
        XCTAssertEqual(
            HomySmartRules.query(for: rule(kind: "image", minSizeMB: 50, days: 30)),
            "type:image kind:file size:>50mb mtime:>30d")
        XCTAssertEqual(
            HomySmartRules.query(for: rule(days: 7, olderNotNewer: false)),
            "kind:file mtime:<7d")
        XCTAssertEqual(
            HomySmartRules.query(for: rule(kind: "screenshot")),
            "Screenshot kind:file")
        XCTAssertEqual(
            HomySmartRules.query(for: rule(kind: "screenshot", namePattern: "dock")),
            "dock Screenshot kind:file")
        XCTAssertEqual(
            HomySmartRules.query(for: rule(namePattern: "invoice", source: "gmail")),
            "invoice kind:file")
    }

    @MainActor func testPersistenceRoundTrip() throws {
        let original = rule(kind: "video", minSizeMB: 500, days: 90, source: "github")
        HomySmartRules.shared.add(original)
        // A fresh instance reads the same defaults key.
        let reloaded = HomySmartRules()
        XCTAssertEqual(reloaded.items.count, 1)
        XCTAssertEqual(reloaded.items[0].kind, "video")
        XCTAssertEqual(reloaded.items[0].minSizeMB, 500)
        XCTAssertEqual(reloaded.items[0].source, "github")
    }
}

final class HomyCollectionTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: HomyCollections.key)
    }

    @MainActor func testAddAndPersist() {
        let collection = HomyCollections.shared.add(name: "Work")
        HomyCollections.shared.addFolders(
            [URL(fileURLWithPath: "/tmp/one"), URL(fileURLWithPath: "/tmp/one"), URL(fileURLWithPath: "/tmp/two")],
            to: collection.id)
        let reloaded = HomyCollections()
        XCTAssertEqual(reloaded.items.count, 1)
        XCTAssertEqual(reloaded.items[0].name, "Work")
        XCTAssertEqual(reloaded.items[0].folders, ["/tmp/one", "/tmp/two"], "duplicates skipped")
    }

    @MainActor func testRouteParsingAndFiltering() {
        let collection = HomyCollections.shared.add(name: "Work")
        let route = HomyRoute("col:" + collection.id.uuidString)
        XCTAssertEqual(route?.title, "Work")
        XCTAssertTrue(route?.searchFiltersSelf ?? false)
        XCTAssertNil(HomyRoute("col:not-a-uuid"))
        // Rules with a source expose it for where-from filtering.
        let smart = HomySmartRule(
            id: UUID(), name: "r", kind: "", minSizeMB: nil, days: nil,
            olderNotNewer: true, namePattern: "", source: "github")
        let ruleRoute = HomyRoute("rule:" + smart.id.uuidString)
        XCTAssertNotNil(ruleRoute)
    }
}
