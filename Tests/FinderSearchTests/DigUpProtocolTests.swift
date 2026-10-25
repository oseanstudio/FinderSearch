import XCTest
@testable import FinderSearch

// DIGUP: protocol parsing and version comparison for the DigUp integration
// and the update center.

final class DigUpHitTests: XCTestCase {
    /// One hit row exactly as `digup search-service` and `digup search --json`
    /// emit it (SearchService.swift's hitFields), plus a DigUp-added field the
    /// decoder must ignore.
    func testDecodesHitRowTolerantly() throws {
        let row = """
        {"path": "/Users/me/Notes/lease.pdf", "kind": "pdf", "segment": "page",
         "segment_id": 4127, "score": 1.42, "modified": 1760000000, "size": 891234,
         "info": "page 7 text", "z": 3.1, "cosine": 0.62, "keyword_rank": null,
         "loc": 7, "loc_end": 7, "focus": null, "excerpt": "pets allowed with deposit",
         "future_field": {"nested": true}}
        """
        let hit = try JSONDecoder().decode(DigUpHit.self, from: Data(row.utf8))
        XCTAssertEqual(hit.path, "/Users/me/Notes/lease.pdf")
        XCTAssertEqual(hit.kind, "pdf")
        XCTAssertEqual(hit.segment, "page")
        XCTAssertEqual(hit.segmentID, 4127)
        XCTAssertEqual(hit.loc, 7)
        XCTAssertEqual(hit.excerpt, "pets allowed with deposit")
        XCTAssertEqual(hit.locationLabel, "p. 7")
        XCTAssertEqual(hit.name, "lease.pdf")
        XCTAssertEqual(hit.asHit.size, 891234)
        XCTAssertEqual(hit.info.label, "page 7 text")
    }

    /// Live `search-service` output carries `info` as a dictionary on some
    /// segments (measured against DigUp 0.6.2 on this machine).
    func testDecodesDictionaryInfo() throws {
        let row = """
        {"cosine": 0.69, "excerpt": "beach day", "info": {"chars": "79", "chunks": "1"},
         "kind": "doc", "loc": 1, "modified": 1590477628, "path": "/tmp/note.txt",
         "score": 6.9, "segment": "chunk", "segment_id": 131309, "size": 84, "z": 4.9}
        """
        let hit = try JSONDecoder().decode(DigUpHit.self, from: Data(row.utf8))
        XCTAssertEqual(hit.info, .fields(["chars": "79", "chunks": "1"]))
        XCTAssertTrue(hit.info.label.contains("chars: 79"))
        XCTAssertEqual(hit.locationLabel, "part 1")
    }

    func testDecodesNumericDictionaryInfo() throws {
        let row = """
        {"cosine": 0.70, "info": {"height": 1000, "width": 680},
         "kind": "image", "modified": 1789126640, "path": "/tmp/folder.jpg",
         "score": 5.75, "segment": "image", "segment_id": 93012, "size": 211870, "z": 4.75}
        """
        let hit = try JSONDecoder().decode(DigUpHit.self, from: Data(row.utf8))
        XCTAssertEqual(hit.info, .fields(["height": "1000", "width": "680"]))
    }

    func testLocationLabels() {
        func hit(_ segment: String, loc: Double? = nil, end: Double? = nil) -> DigUpHit {
            DigUpHit(
                path: "/tmp/x", kind: "image", segment: segment, segmentID: nil, score: 0,
                modified: 0, size: 0, info: .text(""), z: nil, cosine: nil, keywordRank: nil,
                loc: loc, locEnd: end, focus: nil, excerpt: nil)
        }
        XCTAssertEqual(hit("audio", loc: 95).locationLabel, "at 1:35 (sound)")
        XCTAssertEqual(hit("frame", loc: 3725).locationLabel, "at 1:02:05")
        XCTAssertEqual(hit("chunk", loc: 2).locationLabel, "part 2")
        XCTAssertEqual(hit("lines", loc: 10, end: 14).locationLabel, "lines 10–14")
        XCTAssertEqual(hit("cells", loc: 3, end: 3).locationLabel, "cells 3–3")
        XCTAssertEqual(hit("ocr").locationLabel, "text in image")
        XCTAssertEqual(hit("unknown").locationLabel, "")
    }

    /// Missing optional fields (an older DigUp index) decode as nil.
    func testDecodesMinimalRow() throws {
        let row = #"{"path": "/tmp/a.png", "kind": "screenshot", "segment": "ocr", "score": 0, "modified": 0, "size": 10, "info": ""}"#
        let hit = try JSONDecoder().decode(DigUpHit.self, from: Data(row.utf8))
        XCTAssertNil(hit.loc)
        XCTAssertNil(hit.excerpt)
        XCTAssertEqual(hit.kindLabel, "Screenshot")
    }
}

final class VersionCompareTests: XCTestCase {
    func testOrdering() {
        XCTAssertEqual(compareVersions("0.6.2", "0.4.9"), .orderedDescending)
        XCTAssertEqual(compareVersions("0.4.9", "0.4.9"), .orderedSame)
        XCTAssertEqual(compareVersions("0.4.9", "0.10.0"), .orderedAscending)
        XCTAssertEqual(compareVersions("1.0", "1.0.0"), .orderedSame)
        XCTAssertEqual(compareVersions("0.5", "0.4.9"), .orderedDescending)
    }

    func testStripsV() {
        // The Release model strips "v" before comparing; verify the helper on
        // bare numbers only, as call sites do.
        XCTAssertEqual(compareVersions("6.2", "5.10"), .orderedDescending)
    }
}

final class ReleaseDecodingTests: XCTestCase {
    func testDecodesDigUpRelease() throws {
        let payload = """
        {"tag_name": "v0.6.2", "name": "DigUp 0.6.2", "body": "## Fixes\\n- faster indexing",
         "html_url": "https://github.com/ARahim3/DigUp/releases/tag/v0.6.2",
         "published_at": "2026-10-01T12:00:00Z",
         "assets": [{"name": "DigUp-0.6.2.dmg", "size": 8910941,
                     "browser_download_url": "https://github.com/ARahim3/DigUp/releases/download/v0.6.2/DigUp-0.6.2.dmg"}]}
        """
        let release = try JSONDecoder.standard.decode(
            GitHubReleases.Release.self, from: Data(payload.utf8))
        XCTAssertEqual(release.version, "0.6.2")
        XCTAssertEqual(release.assets.count, 1)
        XCTAssertEqual(release.assets[0].name, "DigUp-0.6.2.dmg")
        XCTAssertEqual(release.assets[0].browserDownloadURL.host, "github.com")
    }

    func testToleratesMissingFields() throws {
        let payload = #"{"tag_name": "v1.0"}"#
        let release = try JSONDecoder.standard.decode(
            GitHubReleases.Release.self, from: Data(payload.utf8))
        XCTAssertEqual(release.version, "1.0")
        XCTAssertTrue(release.assets.isEmpty)
        XCTAssertNil(release.htmlURL)
    }
}

final class DigUpPathsTests: XCTestCase {
    /// An override in the environment wins, so a dev CLI can be pinned.
    func testLocatorHonorsOverride() {
        let temporary = NSTemporaryDirectory() + "digup-cli-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: temporary, contents: Data("#!/bin/sh\n".utf8))
        defer { try? FileManager.default.removeItem(atPath: temporary) }
        // createFile makes 0644; a candidate only counts when executable.
        chmod(temporary, 0o755)
        let original = getenv("DIGUP_CLI").map { String(cString: $0) }
        setenv("DIGUP_CLI", temporary, 1)
        defer {
            if let original { setenv("DIGUP_CLI", original, 1) } else { unsetenv("DIGUP_CLI") }
        }
        XCTAssertEqual(DigUpPaths.locateCLI()?.path, temporary)
    }

    func testModelAndIndexChecksTolerateMissingFolders() {
        // Runs against whatever this machine really has (some have DigUp
        // installed, some not); the point is the checks never throw and
        // agree with a plain directory listing.
        let expected =
            ((try? FileManager.default.contentsOfDirectory(
                at: DigUpPaths.models, includingPropertiesForKeys: nil)) ?? [])
            .contains { $0.pathExtension.lowercased() == "gguf" }
        XCTAssertEqual(DigUpPaths.modelPresent, expected)
    }
}
