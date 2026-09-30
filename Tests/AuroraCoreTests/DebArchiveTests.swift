import XCTest
@testable import AuroraCore

/// The `.deb` reader: `ar` headers, the compressed tar members inside them and the
/// control metadata a repository index is not trusted for.
final class DebArchiveTests: XCTestCase {

    private func fixtureArchive() throws -> DebArchive {
        try DebArchive(path: try Fixture.url(Fixture.deb).path)
    }

    /// Builds a minimal `ar` archive, so the reader can be pointed at shapes the
    /// fixture does not have (a damaged tar, a plain `control.tar`, …).
    private func makeArchive(_ members: [(name: String, payload: Data)]) throws -> URL {
        var data = Data("!<arch>\n".utf8)
        for member in members {
            let name = member.name.padding(toLength: 16, withPad: " ", startingAt: 0)
            let size = "\(member.payload.count)".padding(toLength: 10, withPad: " ", startingAt: 0)
            let header = name + "0           " + "0     " + "0     " + "100644  " + size + "`\n"
            XCTAssertEqual(header.count, 60, "an ar header is 60 bytes")
            data.append(Data(header.utf8))
            data.append(member.payload)
            if member.payload.count % 2 == 1 { data.append(0x0a) }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurora-deb-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    // MARK: - Members

    func testReadsTheArMemberTable() throws {
        let archive = try fixtureArchive()
        XCTAssertEqual(archive.path, try Fixture.url(Fixture.deb).path)
        XCTAssertEqual(archive.members.map(\.name), ["debian-binary", "control.tar.xz", "data.tar.xz"])
        XCTAssertEqual(archive.controlMember?.name, "control.tar.xz")
        XCTAssertEqual(archive.payloadMember?.name, "data.tar.xz")
        XCTAssertNil(archive.member(named: "control.tar.zst"))
        XCTAssertNil(archive.member(named: "data.tar.zst"))

        // The first member starts right after the 8-byte magic and one header.
        XCTAssertEqual(archive.members[0].offset, 68)
        XCTAssertEqual(archive.members[0].size, 4)
        XCTAssertGreaterThan(archive.members[1].offset, archive.members[0].offset + archive.members[0].size)
        XCTAssertGreaterThan(archive.members[2].offset, archive.members[1].offset + archive.members[1].size)
    }

    func testBinaryVersionAndMemberContents() throws {
        let archive = try fixtureArchive()
        XCTAssertEqual(archive.binaryVersion, "2.0", "trimmed")
        XCTAssertEqual(String(decoding: try archive.read(try XCTUnwrap(archive.member(named: "debian-binary"))),
                              as: UTF8.self),
                       "2.0\n", "the member on disk keeps its trailing newline")

        let controlMember = try XCTUnwrap(archive.controlMember)
        let controlData = try archive.read(controlMember)
        XCTAssertEqual(controlData.count, Int(controlMember.size))
        XCTAssertEqual(CompressionFormat.detect(fileName: controlMember.name), .xz)
        XCTAssertEqual([UInt8](controlData.prefix(6)), [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00],
                       "control.tar.xz really is an xz stream")
        XCTAssertEqual(try Decompressor.decompress(controlData, format: .xz).count % 512, 0,
                       "a tar stream is a whole number of 512-byte blocks")
    }

    // MARK: - Control metadata

    func testControlStanza() throws {
        let control = try fixtureArchive().controlStanza()
        XCTAssertEqual(control["Package"], "aurora-fixture")
        XCTAssertEqual(control["Version"], "1.2.3-1")
        XCTAssertEqual(control["Architecture"], "iphoneos-arm64")
        XCTAssertEqual(control["Maintainer"], "Aurora Test <test@example.invalid>")
        XCTAssertEqual(control["Section"], "utils")
        XCTAssertEqual(control["Priority"], "optional")
        XCTAssertEqual(control["Depends"], "bash")
        XCTAssertEqual(control.int("Installed-Size"), 12)
        XCTAssertEqual(control.descriptionParts.synopsis, "A tiny package used to test the .deb reader")
        XCTAssertEqual(control.descriptionParts.body,
                       "It has a payload, a maintainer script and a conffile.")
        XCTAssertEqual(control.fields.first?.name, "Package")

        let record = PackageRecord(stanza: control)
        XCTAssertEqual(record.name, "aurora-fixture")
        XCTAssertEqual(record.version.raw, "1.2.3-1")
        XCTAssertEqual(record.relations.depends.clauses.map { $0.alternatives[0].name }, ["bash"])
    }

    func testMaintainerScripts() throws {
        let scripts = try fixtureArchive().maintainerScripts()
        XCTAssertEqual(Set(scripts.keys), ["postinst", "conffiles"])
        let postinst = try XCTUnwrap(scripts["postinst"])
        XCTAssertTrue(postinst.contains("aurora-fixture configured"))
        XCTAssertTrue(postinst.hasPrefix("#!/bin/sh"))
        XCTAssertEqual(scripts["conffiles"], "/etc/aurora-fixture.conf\n")
        XCTAssertNil(scripts["preinst"])
        XCTAssertNil(scripts["prerm"])
    }

    func testPayloadSummaryCountsRegularFilesAndTheirBytes() throws {
        let summary = try fixtureArchive().payloadSummary()
        XCTAssertEqual(summary.files, 3,
                       "usr/bin/aurora-fixture, usr/share/aurora/data.txt, etc/aurora-fixture.conf")
        XCTAssertEqual(summary.bytes, 310, "22 + 260 + 28 bytes of payload")

        // Those three files are the only non-directory entries in data.tar.
        let archive = try fixtureArchive()
        let payloadMember = try XCTUnwrap(archive.payloadMember)
        let tar = try Decompressor.decompress(try archive.read(payloadMember),
                                              format: CompressionFormat.detect(fileName: payloadMember.name) ?? .plain)
        XCTAssertEqual(try TarReader.entries(in: tar).filter { $0.type == .regular }.count, summary.files)
        XCTAssertEqual(Array(try TarReader.entries(in: tar).map(\.name).prefix(2)), [".", "./etc"])
    }

    // MARK: - Damage

    func testOpeningSomethingThatIsNotAnArchiveThrows() throws {
        let textFile = try Fixture.url(Fixture.packagesIndex).path
        XCTAssertThrowsError(try DebArchive(path: textFile)) { error in
            guard let archiveError = error as? DebArchive.Error else {
                XCTFail("expected a DebArchive.Error, got \(error)")
                return
            }
            guard case .notAnArchive = archiveError else {
                XCTFail("expected notAnArchive, got \(archiveError)")
                return
            }
            XCTAssertEqual(archiveError.description, "\(textFile) is not a Debian package (bad ar magic)")
        }

        XCTAssertThrowsError(try DebArchive(path: "/nonexistent/does-not-exist.deb")) { error in
            guard let archiveError = error as? DebArchive.Error else {
                XCTFail("expected a DebArchive.Error, got \(error)")
                return
            }
            guard case .unreadable = archiveError else {
                XCTFail("expected unreadable, got \(archiveError)")
                return
            }
        }
    }

    func testTruncatedArchiveThrows() throws {
        let url = try makeArchive([("debian-binary", Data("2.0\n".utf8)),
                                   ("control.tar.xz", Data(repeating: 0, count: 512))])
        defer { try? FileManager.default.removeItem(at: url) }

        let whole = try Data(contentsOf: url)
        let truncated = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurora-truncated-\(UUID().uuidString)")
        try whole.prefix(whole.count - 100).write(to: truncated)
        defer { try? FileManager.default.removeItem(at: truncated) }

        XCTAssertThrowsError(try DebArchive(path: truncated.path)) { error in
            guard let archiveError = error as? DebArchive.Error else {
                XCTFail("expected a DebArchive.Error, got \(error)")
                return
            }
            switch archiveError {
            case .truncated, .notAnArchive: break
            default: XCTFail("expected truncated/notAnArchive, got \(archiveError)")
            }
        }
    }

    func testDamagedTarMemberThrowsBadTar() throws {
        let url = try makeArchive([("debian-binary", Data("2.0\n".utf8)),
                                   ("control.tar", Data(repeating: 0x58, count: 512)),
                                   ("data.tar", Data(repeating: 0x58, count: 512))])
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try DebArchive(path: url.path)
        XCTAssertEqual(archive.members.map(\.name), ["debian-binary", "control.tar", "data.tar"])
        XCTAssertEqual(archive.binaryVersion, "2.0")
        XCTAssertEqual(CompressionFormat.detect(fileName: "control.tar"), nil,
                       "an uncompressed member has no container")

        XCTAssertThrowsError(try archive.controlStanza()) { error in
            guard let archiveError = error as? DebArchive.Error else {
                XCTFail("expected a DebArchive.Error, got \(error)")
                return
            }
            guard case .badTar = archiveError else {
                XCTFail("expected badTar, got \(archiveError)")
                return
            }
        }
        XCTAssertThrowsError(try archive.payloadSummary()) { error in
            guard case DebArchive.Error.badTar? = error as? DebArchive.Error else {
                XCTFail("expected badTar, got \(error)")
                return
            }
        }
    }

    func testAnArchiveWithoutAControlMemberReportsAMissingMember() throws {
        let url = try makeArchive([("debian-binary", Data("2.0\n".utf8)),
                                   ("data.tar", Data(repeating: 0, count: 1024))])
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try DebArchive(path: url.path)
        XCTAssertNil(archive.controlMember)
        XCTAssertNotNil(archive.payloadMember)
        XCTAssertThrowsError(try archive.controlStanza()) { error in
            guard let archiveError = error as? DebArchive.Error else {
                XCTFail("expected a DebArchive.Error, got \(error)")
                return
            }
            guard case .missingMember(let name) = archiveError else {
                XCTFail("expected missingMember(\"control.tar\"), got \(archiveError)")
                return
            }
            XCTAssertEqual(name, "control.tar")
        }
        XCTAssertEqual(try archive.maintainerScripts(), [:],
                       "no control member means no maintainer scripts, not an error")
    }
}
