import Foundation
import XCTest
@testable import AuroraCore

final class SourceStoreTests: XCTestCase {
    func testSavingPreservesArchitecturesAndSourceState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SourceStore(path: directory.appendingPathComponent("sileo.sources").path)
        let source = RepositorySource(
            name: "Custom Architecture", url: "https://repo.example.test",
            suite: "stable", components: ["main"],
            architectures: ["iphoneos-arm64", "iphoneos-arm"], isEnabled: false
        )
        try store.save(RepositoryList(sources: [source]))
        let savedText = try String(contentsOfFile: store.path, encoding: .utf8)
        XCTAssertTrue(savedText.contains("Architectures: iphoneos-arm64 iphoneos-arm"))
        XCTAssertTrue(savedText.contains("Enabled: no"))

        let loaded = try XCTUnwrap(store.load().list.sources.first)
        XCTAssertEqual(loaded.id, source.id)
        XCTAssertEqual(loaded.architectures, source.architectures)
        XCTAssertFalse(loaded.isEnabled)
    }


    func testSavingPreservesArchitectureModifiers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SourceStore(path: directory.appendingPathComponent("sileo.sources").path)
        let source = RepositorySource(
            name: "Architecture Modifiers",
            url: "https://repo.example.test",
            suite: "stable",
            components: ["main"],
            architectureAdditions: ["all"],
            architectureRemovals: ["iphoneos-arm"]
        )

        try store.save(RepositoryList(sources: [source]))
        let savedText = try String(contentsOfFile: store.path, encoding: .utf8)
        XCTAssertTrue(savedText.contains("Architectures-Add: all"))
        XCTAssertTrue(savedText.contains("Architectures-Remove: iphoneos-arm"))

        let loaded = try XCTUnwrap(store.load().list.sources.first)
        XCTAssertEqual(loaded.architectureAdditions ?? [], ["all"])
        XCTAssertEqual(loaded.architectureRemovals ?? [], ["iphoneos-arm"])
        XCTAssertEqual(
            loaded.effectiveArchitectures(defaults: ["iphoneos-arm64", "iphoneos-arm"]),
            ["iphoneos-arm64", "all"]
        )
    }

    func testLoadingExternalSileoSourcesExpandsURIsAndSuites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SourceStore(path: directory.appendingPathComponent("sileo.sources").path)
        try """
        Types: deb
        URIs: https://one.example/ https://two.example/
        Suites: stable testing
        Components: main
        Enabled: no
        """.write(toFile: store.path, atomically: true, encoding: .utf8)

        let loaded = store.load()
        XCTAssertNil(loaded.failure)
        XCTAssertEqual(loaded.list.sources.count, 4)
        XCTAssertTrue(loaded.list.sources.allSatisfy { !$0.isEnabled && $0.components == ["main"] })
    }
}
