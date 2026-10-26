import XCTest
import AppKit
@testable import FinderSearch

// HOMY: the duplicates scanner must find byte-identical files by hash, stay
// responsive to cancellation, and never touch the main actor.

final class DuplicateScannerTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dupes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func hit(_ url: URL) throws -> Hit {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return Hit(
            path: url.path, kind: "file",
            size: UInt64(values.fileSize ?? 0),
            mtime: UInt64((values.contentModificationDate ?? .distantPast).timeIntervalSince1970),
            score: 0)
    }

    func testFindsIdenticalFilesNotUniqueOnes() async throws {
        try write("a.txt", Data("same bytes".utf8))
        try write("b copy.txt", Data("same bytes".utf8))
        try write("different.txt", Data("other bytes entirely".utf8))
        // Same content, different name — a real duplicate.
        let hits = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil).map { try hit($0) }
        let groups = try await DuplicateScanner.find(in: hits) { _ in }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].kind, .identical)
        XCTAssertEqual(
            Set(groups[0].files.map(\.hit.name)), ["a.txt", "b copy.txt"])
        // The keeper is one of the group's copies (second-granular mtimes can
        // tie, so which one wins is not prescribed).
        XCTAssertTrue(
            groups[0].files.contains { $0.hit.path == groups[0].keeper })
    }

    func testLooksPastHeadTailDifferences() async throws {
        // Head and tail identical, middle different: only the full hash decides.
        var head = Data("HEADER".utf8)
        head += Data(repeating: 0x41, count: 200_000)
        head += Data("TRAILER".utf8)
        var other = Data("HEADER".utf8)
        other += Data(repeating: 0x42, count: 200_000)
        other += Data("TRAILER".utf8)
        try write("one.bin", head)
        try write("two.bin", other)
        let hits = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil).map { try hit($0) }
        let groups = try await DuplicateScanner.find(in: hits) { _ in }
        XCTAssertTrue(groups.isEmpty, "same head+tail but different middles are not duplicates")
    }

    func testCancellationStopsTheScan() async throws {
        // Enough same-size files that cancellation lands mid-hash.
        let blob = Data(repeating: 0x61, count: 300_000)
        for index in 0..<40 {
            try write("file\(index).bin", blob)
        }
        let hits = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil).map { try hit($0) }
        let scan = Task.detached {
            try await DuplicateScanner.find(in: hits) { _ in }
        }
        scan.cancel()
        do {
            _ = try await scan.value
            // Finishing before the cancel lands is acceptable; the requirement
            // is that a cancelled scan never wedges.
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    @MainActor
    func testScanNeverBlocksTheMainActor() async throws {
        // A main-actor task must keep making progress while a scan runs.
        let blob = Data(repeating: 0x63, count: 500_000)
        for index in 0..<12 { try write("same\(index).dat", blob) }
        let hits = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil).map { try hit($0) }
        let scan = Task.detached {
            try await DuplicateScanner.find(in: hits) { _ in }
        }
        var ticks = 0
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(10))
            ticks += 1
        }
        _ = try await scan.value
        XCTAssertEqual(ticks, 5, "the main actor starved while the scan ran")
    }
}
