import XCTest
@testable import AuroraCore

/// `Release` parsing, container detection and decompression. The decompression
/// test is the one that proves the LZMA path in ``Decompressor`` actually works on
/// the machine running the suite: the fixture was compressed by the real `xz`.
final class ReleaseAndDecompressionTests: XCTestCase {

    private func releaseFixture() throws -> ReleaseFile {
        let stanzas = ControlParser.parse(try Fixture.text(Fixture.release))
        return ReleaseFile(stanza: try XCTUnwrap(stanzas.first, "the Release fixture should hold one stanza"))
    }

    // MARK: - ReleaseFile

    func testParsesTheReleaseFile() throws {
        let release = try releaseFixture()
        XCTAssertEqual(release.origin, "Aurora Test Fixtures")
        XCTAssertEqual(release.label, "Aurora")
        XCTAssertEqual(release.suite, "stable")
        XCTAssertEqual(release.codename, "stable")
        XCTAssertEqual(release.version, "1.0")
        XCTAssertEqual(release.architectures, ["iphoneos-arm64", "iphoneos-arm"])
        XCTAssertEqual(release.components, ["main"])
        XCTAssertEqual(release.checksums.count, 6, "three paths, SHA256 and MD5Sum")
    }

    func testParsesTheReleaseDatesAsUTC() throws {
        let release = try releaseFixture()
        let date = try XCTUnwrap(release.date, "Date: Fri, 26 Sep 2026 12:00:00 UTC should parse")
        let validUntil = try XCTUnwrap(release.validUntil,
                                       "Valid-Until: Fri, 26 Sep 2031 12:00:00 UTC should parse")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute],
                                                 from: date)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 9)
        XCTAssertEqual(components.day, 26)
        XCTAssertEqual(components.hour, 12)
        XCTAssertEqual(components.minute, 0)

        let expiry = calendar.dateComponents([.year, .month, .day], from: validUntil)
        XCTAssertEqual(expiry.year, 2031)
        XCTAssertEqual(expiry.month, 9)
        XCTAssertEqual(expiry.day, 26)

        XCTAssertFalse(release.isExpired, "Valid-Until is in 2031")
        XCTAssertTrue(validUntil > date)
    }

    func testExpiryAndStalenessFlags() {
        let expired = ReleaseFile(stanza: ControlStanza(fields: [
            ControlField(name: "Suite", value: "old"),
            ControlField(name: "Date", value: "Fri, 26 Sep 2020 12:00:00 UTC"),
            ControlField(name: "Valid-Until", value: "Fri, 26 Sep 2021 12:00:00 UTC"),
        ]))
        XCTAssertTrue(expired.isExpired)
        XCTAssertTrue(expired.isStale, "a six-year-old index is stale")

        let withoutDates = ReleaseFile(stanza: ControlStanza(fields: [ControlField(name: "Suite", value: "flat")]))
        XCTAssertNil(withoutDates.date)
        XCTAssertNil(withoutDates.validUntil)
        XCTAssertFalse(withoutDates.isExpired, "no Valid-Until means no expiry")
        XCTAssertFalse(withoutDates.isStale, "no Date means we cannot call it stale")
    }

    func testChecksumLookupPrefersSHA256AndMatchesTheRecordedSizes() throws {
        let release = try releaseFixture()

        let plain = try XCTUnwrap(release.checksum(forPath: "main/binary-iphoneos-arm64/Packages"))
        XCTAssertEqual(plain.algorithm, .sha256, "SHA256 must win over the MD5Sum block")
        XCTAssertEqual(plain.size, 6329)
        XCTAssertEqual(plain.hex, "b268e2b9bd7be179ad7e8b2cc22aad4841e3f0bafde8986bdc1186093d052b5b")
        XCTAssertEqual(plain.path, "main/binary-iphoneos-arm64/Packages")

        XCTAssertEqual(release.checksum(forPath: "main/binary-iphoneos-arm64/Packages.gz")?.size, 2147)
        XCTAssertEqual(release.checksum(forPath: "main/binary-iphoneos-arm64/Packages.gz")?.algorithm, .sha256)
        XCTAssertEqual(release.checksum(forPath: "main/binary-iphoneos-arm64/Packages.xz")?.size, 2096)

        // Repositories are inconsistent about the leading slash.
        XCTAssertEqual(release.checksum(forPath: "/main/binary-iphoneos-arm64/Packages")?.algorithm, .sha256)
        XCTAssertEqual(release.checksum(forPath: "/main/binary-iphoneos-arm64/Packages")?.size, 6329)

        XCTAssertNil(release.checksum(forPath: "main/binary-iphoneos-arm64/Packages.zst"))
        XCTAssertNil(release.checksum(forPath: "main/binary-iphonesos-arm64/Packages"))

        XCTAssertEqual(release.checksums.filter { $0.algorithm == .md5 }.count, 3)
        XCTAssertTrue(release.checksums.filter { $0.algorithm == .md5 }
            .allSatisfy { $0.hex.count == 32 })
        XCTAssertTrue(release.checksums.filter { $0.algorithm == .sha256 }
            .allSatisfy { $0.hex.count == 64 })
    }

    /// Cross-checks the fixture's own digest against the file it describes, so a
    /// fixture that drifts from its `Release` file fails loudly.
    func testTheRecordedDigestMatchesTheFixtureOnDisk() throws {
        #if canImport(CryptoKit)
        let release = try releaseFixture()
        let plain = try Fixture.data(Fixture.packagesIndex)
        let checksum = try XCTUnwrap(release.checksum(forPath: "main/binary-iphoneos-arm64/Packages"))
        XCTAssertEqual(checksum.size, plain.count)
        XCTAssertEqual(try Hashing.hexDigest(of: plain, using: .sha256), checksum.hex)
        XCTAssertTrue(Hashing.matches(checksum.hex.uppercased(), checksum.hex),
                      "Hashing.matches is case-insensitive")
        #endif
    }

    // MARK: - Container detection

    func testMagicDetection() throws {
        let gzip = try Fixture.data(Fixture.packagesIndexGzip)
        let xz = try Fixture.data(Fixture.packagesIndexXz)
        let plain = try Fixture.data(Fixture.packagesIndex)

        XCTAssertEqual(CompressionFormat.detect(magic: [UInt8](gzip.prefix(16))), .gzip)
        XCTAssertEqual(CompressionFormat.detect(magic: [UInt8](xz.prefix(16))), .xz)
        XCTAssertNil(CompressionFormat.detect(magic: [UInt8](plain.prefix(16))),
                     "a plain index has no magic number")

        XCTAssertNil(CompressionFormat.detect(magic: [0x1f]), "a one-byte file is not a gzip stream")
        XCTAssertNil(CompressionFormat.detect(magic: []))
        XCTAssertNil(CompressionFormat.detect(magic: Array("plain text file".utf8)))

        XCTAssertEqual(CompressionFormat.detect(magic: [0x28, 0xb5, 0x2f, 0xfd]), .zstd)
        XCTAssertEqual(CompressionFormat.detect(magic: Array("BZh9".utf8)), .bzip2)
        XCTAssertEqual(CompressionFormat.detect(magic: [0x5d, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                                                        0x00, 0x00, 0x00, 0x00, 0x00, 0x00]), .lzma)

        XCTAssertEqual(CompressionFormat.gzip.pathExtension, "Packages.gz")
        XCTAssertEqual(CompressionFormat.xz.pathExtension, "Packages.xz")
        XCTAssertEqual(CompressionFormat.plain.pathExtension, "Packages")
    }

    func testFileNameDetection() {
        XCTAssertEqual(CompressionFormat.detect(fileName: "control.tar.gz"), .gzip)
        XCTAssertEqual(CompressionFormat.detect(fileName: "data.tar.xz"), .xz)
        XCTAssertEqual(CompressionFormat.detect(fileName: "Packages.lzma"), .lzma)
        XCTAssertEqual(CompressionFormat.detect(fileName: "Packages.bz2"), .bzip2)
        XCTAssertEqual(CompressionFormat.detect(fileName: "Packages.zst"), .zstd)
        XCTAssertNil(CompressionFormat.detect(fileName: "Packages"))
        XCTAssertNil(CompressionFormat.detect(fileName: "Packages.txt"))
    }

    // MARK: - Decompression

    func testDecompressingTheFixtureIndexesReproducesThePlainOne() throws {
        let plain = try Fixture.data(Fixture.packagesIndex)

        let fromGzip = try Decompressor.decompress(try Fixture.data(Fixture.packagesIndexGzip))
        XCTAssertEqual(fromGzip, plain, "the gzip path (zlib) must round-trip")

        let fromXz = try Decompressor.decompress(try Fixture.data(Fixture.packagesIndexXz))
        XCTAssertEqual(fromXz, plain, "the xz/LZMA path must round-trip")

        // Detection is what `decompress(_:)` uses when no format is given, so the
        // explicit-format calls have to agree with it.
        XCTAssertEqual(try Decompressor.decompress(try Fixture.data(Fixture.packagesIndexGzip), format: .gzip),
                       plain)
        XCTAssertEqual(try Decompressor.decompress(try Fixture.data(Fixture.packagesIndexXz), format: .xz),
                       plain)
        XCTAssertEqual(try Decompressor.decompress(plain), plain,
                       "data with no magic number is passed through untouched")
        XCTAssertEqual(try Decompressor.decompress(plain, format: .plain), plain)

        XCTAssertGreaterThan(Decompressor.maximumOutputSize, plain.count)
        XCTAssertFalse(Decompressor.helperSearchPaths.isEmpty)
    }

    func testCorruptGzipFailsInsteadOfReturningRubbish() throws {
        var gzip = try Fixture.data(Fixture.packagesIndexGzip)
        XCTAssertGreaterThan(gzip.count, 20)
        // 0xff starts a deflate block whose type is reserved, so zlib must report
        // damaged data rather than a short (or empty) index.
        gzip.replaceSubrange(10..<20, with: [UInt8](repeating: 0xff, count: 10))
        XCTAssertThrowsError(try Decompressor.decompress(gzip, format: .gzip))

        // A *truncated* gzip stream must fail rather than return a short index:
        // a repository without a Release file has no checksum to catch that, so
        // integrity has to come from the decompressor too.
        let truncated = Data(try Fixture.data(Fixture.packagesIndexGzip).prefix(40))
        XCTAssertThrowsError(try Decompressor.decompress(truncated, format: .gzip),
                             "half a gzip stream is corruption, not a smaller index")
    }

    func testGzipExpansionStopsAtTheConfiguredOutputLimit() throws {
        let gzip = try Fixture.data(Fixture.packagesIndexGzip)
        XCTAssertThrowsError(try Decompressor.decompress(gzip, format: .gzip, maximumOutputBytes: 16)) { error in
            guard case DecompressionError.exceedsLimit = error else {
                return XCTFail("expected output-limit error, got \(error)")
            }
        }
    }

    // MARK: - InRelease

    func testClearsignedMessageUnescapesAndStripsHeaders() throws {
        let data = try Fixture.data(Fixture.inReleaseSample)
        let message = try XCTUnwrap(ClearsignedMessage.parse(data),
                                    "InRelease-sample should parse as a clearsigned document")

        XCTAssertEqual(message.hashAlgorithm, "SHA256")
        let payload = String(decoding: message.payload, as: UTF8.self)
        XCTAssertEqual(payload, """
        Origin: Aurora Test Fixtures
        Label: Aurora
        Suite: stable
        - this line was dash-escaped by the signer
        SHA256:
         aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 100 main/binary-iphoneos-arm64/Packages
        """)
        XCTAssertEqual(payload.split(separator: "\n", omittingEmptySubsequences: false).count, 6)
        XCTAssertFalse(payload.contains("Hash:"), "the armor header is not part of the payload")
        XCTAssertFalse(payload.contains("BEGIN PGP"))

        let signature = String(decoding: message.signature, as: UTF8.self)
        XCTAssertTrue(signature.hasPrefix(ClearsignedMessage.signatureMarker))
        XCTAssertTrue(signature.contains("-----END PGP SIGNATURE-----"))
        XCTAssertEqual(ClearsignedMessage.beginMarker, "-----BEGIN PGP SIGNED MESSAGE-----")

        // The unescaped payload has to be parseable as the control file it is.
        let stanzas = ControlParser.parse(message.payload)
        XCTAssertEqual(stanzas.count, 1)
        XCTAssertEqual(stanzas.first?["Origin"], "Aurora Test Fixtures")
        XCTAssertEqual(stanzas.first?["SHA256"],
                       "\naaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 100 main/binary-iphoneos-arm64/Packages")
        XCTAssertNotNil(ReleaseFile(stanza: try XCTUnwrap(stanzas.first))
            .checksum(forPath: "main/binary-iphoneos-arm64/Packages"))
    }

    func testClearsignedMessageRejectsDocumentsThatAreNotClearsigned() {
        XCTAssertNil(ClearsignedMessage.parse(Data("Package: x\n".utf8)))
        XCTAssertNil(ClearsignedMessage.parse(Data()))
        XCTAssertNil(ClearsignedMessage.parse(Data("-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA256\n\nx\n".utf8)),
                     "a document without a signature block is not a clearsigned message")
    }
}
