import Foundation
import XCTest

/// Locates the files copied into the test bundle by the target's
/// `resources: [.copy("Fixtures")]` declaration.
///
/// Nothing here force-unwraps: a missing or unreadable fixture must fail the test
/// that needed it, with the path it looked in, rather than trap.
enum Fixture {

    struct MissingFixture: Error, CustomStringConvertible {
        let path: String
        let lookedIn: String
        var description: String {
            "missing fixture \(path) (looked in \(lookedIn))"
        }
    }

    /// `Bundle.module`'s `Fixtures` directory, or nil when the resource bundle is
    /// not there at all.
    static func rootDirectory() -> URL? {
        guard let resourceURL = Bundle.module.resourceURL else { return nil }
        let candidate = resourceURL.appendingPathComponent("Fixtures", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return candidate
    }

    /// URL of a fixture, relative to `Fixtures/`.
    static func url(_ relativePath: String,
                    file: StaticString = #filePath,
                    line: UInt = #line) throws -> URL {
        guard let root = rootDirectory() else {
            XCTFail("Bundle.module has no Fixtures directory; the test target's "
                    + "`resources: [.copy(\"Fixtures\")]` resource did not build?",
                    file: file, line: line)
            throw MissingFixture(path: relativePath, lookedIn: "<no resource bundle>")
        }
        let fixtureURL = root.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            XCTFail("missing fixture Fixtures/\(relativePath); looked in \(root.path)",
                    file: file, line: line)
            throw MissingFixture(path: relativePath, lookedIn: root.path)
        }
        return fixtureURL
    }

    static func data(_ relativePath: String,
                     file: StaticString = #filePath,
                     line: UInt = #line) throws -> Data {
        try Data(contentsOf: try url(relativePath, file: file, line: line))
    }

    static func text(_ relativePath: String,
                     file: StaticString = #filePath,
                     line: UInt = #line) throws -> String {
        String(decoding: try data(relativePath, file: file, line: line), as: UTF8.self)
    }

    // MARK: - The fixtures this suite uses

    /// The 16-stanza repository index.
    static let packagesIndex = "packages/Packages"
    /// The same index, gzip-compressed by the real `gzip`.
    static let packagesIndexGzip = "packages/Packages.gz"
    /// The same index, xz-compressed by the real `xz`.
    static let packagesIndexXz = "packages/Packages.xz"
    /// The dpkg status file.
    static let status = "packages/status"
    /// The repository's `Release` manifest.
    static let release = "packages/Release"
    /// A hand-written clearsigned `InRelease`-shaped document.
    static let inReleaseSample = "packages/InRelease-sample"
    /// A real `.deb` built by `dpkg-deb`.
    static let deb = "packages/aurora-fixture_1.2.3-1_iphoneos-arm64.deb"
    /// `left <relation> right` lines produced by fuzzing against dpkg.
    static let versionVectors = "version-vectors.tsv"
}

extension PackageRelations {

    /// Builds the relations of a stanza written inline as a dictionary.
    ///
    /// Test-only on purpose: the engine's `PackageRelations.init(stanza:)` takes a
    /// real `ControlStanza` so that field order and unknown fields survive, which
    /// is the property the dpkg status writer depends on. A dictionary has no
    /// order, so keys are sorted to keep these tests deterministic.
    init(stanza fields: [String: String]) {
        let ordered = fields
            .sorted { $0.key < $1.key }
            .map { ControlField(name: $0.key, value: $0.value) }
        self.init(stanza: ControlStanza(fields: ordered))
    }
}
