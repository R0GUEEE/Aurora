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

    func testLoadsEveryListAndSourcesFileLikeSileo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let managed = directory.appendingPathComponent("sileo.sources")
        let procursus = directory.appendingPathComponent("procursus.sources")
        let legacy = directory.appendingPathComponent("legacy.list")

        try """
        Types: deb
        URIs: https://managed.example/
        Suites: ./
        Components:
        """.write(to: managed, atomically: true, encoding: .utf8)

        try """
        Types: deb
        URIs: https://apt.procurs.us/
        Suites: iphoneos-arm64/1800
        Components: main
        """.write(to: procursus, atomically: true, encoding: .utf8)

        try "deb https://legacy.example/ ./\n"
            .write(to: legacy, atomically: true, encoding: .utf8)

        let store = SourceStore(path: managed.path)
        let loaded = store.load()
        XCTAssertNil(loaded.failure)
        XCTAssertEqual(Set(loaded.list.sources.map(\.normalizedURL)), [
            "https://managed.example",
            "https://apt.procurs.us",
            "https://legacy.example",
        ])

        XCTAssertEqual(
            loaded.list.sources.first { $0.normalizedURL == "https://managed.example" }?.sourceFile,
            managed.path
        )
        XCTAssertEqual(
            loaded.list.sources.first { $0.normalizedURL == "https://apt.procurs.us" }?.sourceFile,
            procursus.path
        )
        XCTAssertEqual(
            loaded.list.sources.first { $0.normalizedURL == "https://legacy.example" }?.sourceFile,
            legacy.path
        )
    }

    func testSaveOnlyRewritesSileoSourcesAndPreservesSiblingFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let managed = directory.appendingPathComponent("sileo.sources")
        let external = directory.appendingPathComponent("procursus.sources")
        let externalText = """
        Types: deb
        URIs: https://apt.procurs.us/
        Suites: iphoneos-arm64/1800
        Components: main
        """
        try externalText.write(to: external, atomically: true, encoding: .utf8)

        var externalSource = RepositorySource(
            name: "Procursus",
            url: "https://apt.procurs.us",
            suite: "iphoneos-arm64/1800",
            components: ["main"]
        )
        externalSource.sourceFile = external.path

        let managedSource = RepositorySource(
            name: "Managed",
            url: "https://managed.example",
            suite: "./",
            components: []
        )

        let store = SourceStore(path: managed.path)
        try store.save(RepositoryList(sources: [externalSource, managedSource]))

        XCTAssertEqual(
            try String(contentsOf: external, encoding: .utf8),
            externalText,
            "Aurora must not rewrite source files owned by the bootstrap or another package manager"
        )

        let managedText = try String(contentsOf: managed, encoding: .utf8)
        XCTAssertTrue(managedText.contains("https://managed.example/"))
        XCTAssertFalse(managedText.contains("apt.procurs.us"))
    }

    func testJailbreakEnvironmentResolvesAPTSourceDirectory() {
        let rootless = JailbreakEnvironment(
            layout: .rootless,
            root: "/var/jb",
            architecture: "iphoneos-arm64",
            dpkgPath: "/var/jb/usr/bin/dpkg",
            statusFilePath: "/var/jb/var/lib/dpkg/status"
        )
        XCTAssertEqual(rootless.aptSourcesListDirectory, "/var/jb/etc/apt/sources.list.d")

        let rootful = JailbreakEnvironment(
            layout: .rootful,
            root: "/",
            architecture: "iphoneos-arm",
            dpkgPath: "/usr/bin/dpkg",
            statusFilePath: "/var/lib/dpkg/status"
        )
        XCTAssertEqual(rootful.aptSourcesListDirectory, "/etc/apt/sources.list.d")
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
