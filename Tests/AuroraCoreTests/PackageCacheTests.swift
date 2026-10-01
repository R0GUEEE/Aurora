import XCTest
@testable import AuroraCore

/// The package cache is small, visible and reclaimable on purpose: a jailbroken
/// phone has very little room, so "where did my storage go" must have an answer.
final class PackageCacheTests: XCTestCase {

    private var directory: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = NSTemporaryDirectory() + "aurora-cache-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: directory)
        try super.tearDownWithError()
    }

    private func write(_ name: String, bytes: Int) throws {
        let data = Data(repeating: 0x41, count: bytes)
        try data.write(to: URL(fileURLWithPath: (directory as NSString).appendingPathComponent(name)))
    }

    func testEntriesReportSizeAndAreSortedLargestFirst() throws {
        try write("small_1.0_iphoneos-arm64.deb", bytes: 100)
        try write("large_1.0_iphoneos-arm64.deb", bytes: 5000)
        try write("medium_1.0_iphoneos-arm64.deb.partial", bytes: 2000)

        let cache = PackageCache(directory: directory)
        let entries = cache.entries()
        XCTAssertEqual(entries.map(\.name), [
            "large_1.0_iphoneos-arm64.deb",
            "medium_1.0_iphoneos-arm64.deb.partial",
            "small_1.0_iphoneos-arm64.deb",
        ])
        XCTAssertEqual(cache.totalBytes(), 7100,
                       "interrupted downloads are the thing a user most wants to reclaim")
        XCTAssertEqual(entries.first?.displaySize, "4.9 kB")
    }

    func testRemovingOneEntryFreesItsBytes() throws {
        try write("keep_1.0_iphoneos-arm64.deb", bytes: 1000)
        try write("drop_1.0_iphoneos-arm64.deb", bytes: 2000)

        let cache = PackageCache(directory: directory)
        let target = try XCTUnwrap(cache.entries().first { $0.name.hasPrefix("drop_") })
        XCTAssertEqual(cache.remove(target), 2000)
        XCTAssertEqual(cache.entries().map(\.name), ["keep_1.0_iphoneos-arm64.deb"])
    }

    func testUnusedEntriesAreRemovedByPackageName() throws {
        // The cached name is `<package>_<version>_<architecture>.deb`, so the
        // package name is everything before the first underscore.
        try write("libfoo1_1.4.2-3_iphoneos-arm64.deb", bytes: 100)
        try write("oldapp_1.0-1_iphoneos-arm64.deb", bytes: 200)
        try write("oldapp_0.9-1_iphoneos-arm64.deb", bytes: 300)

        let cache = PackageCache(directory: directory)
        let result = cache.removeEntries(notMentioning: ["libfoo1"])

        XCTAssertEqual(result.removed, 2, "both versions of the removed package go")
        XCTAssertEqual(result.freed, 500)
        XCTAssertEqual(cache.entries().map(\.name), ["libfoo1_1.4.2-3_iphoneos-arm64.deb"])
    }

    func testClearEmptiesTheDirectoryAndKeepsItUsable() throws {
        try write("a_1.0_iphoneos-arm64.deb", bytes: 4096)
        let cache = PackageCache(directory: directory)
        XCTAssertEqual(cache.clear(), 4096)
        XCTAssertEqual(cache.totalBytes(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory),
                      "the cache directory must survive being emptied")
    }

    func testMissingDirectoryIsNotAnError() {
        let cache = PackageCache(directory: directory + "/does-not-exist")
        XCTAssertTrue(cache.entries().isEmpty)
        XCTAssertEqual(cache.totalBytes(), 0)
        XCTAssertEqual(cache.clear(), 0)
    }

    func testHumanTotalSizeUsesReadableUnits() throws {
        try write("big_1.0_iphoneos-arm64.deb", bytes: 3 * 1024 * 1024)
        XCTAssertEqual(PackageCache(directory: directory).humanTotalSize(), "3.0 MB")
    }
}
