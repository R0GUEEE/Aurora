import XCTest
@testable import AuroraCore

final class RepositorySecurityTests: XCTestCase {
    private func record(filename: String) -> PackageRecord {
        PackageRecord(stanza: ControlStanza(fields: [
            ControlField(name: "Package", value: "demo"),
            ControlField(name: "Version", value: "1.0"),
            ControlField(name: "Architecture", value: "iphoneos-arm64"),
            ControlField(name: "Filename", value: filename),
        ]))
    }

    private let source = RepositorySource(name: "Test", url: "https://repo.example.test/apt", suite: "./")

    func testPackageURLRejectsAbsoluteCrossOriginURL() {
        XCTAssertNil(RepositoryClient.packageURL(record(filename: "https://attacker.example/payload.deb"), in: source))
    }

    func testPackageURLRejectsProtocolRelativeCrossOriginURL() {
        XCTAssertNil(RepositoryClient.packageURL(record(filename: "//attacker.example/payload.deb"), in: source))
    }

    func testPackageURLAcceptsSameOriginAbsoluteAndRelativePaths() throws {
        XCTAssertEqual(
            RepositoryClient.packageURL(record(filename: "https://repo.example.test/apt/pool/demo.deb"), in: source)?.absoluteString,
            "https://repo.example.test/apt/pool/demo.deb"
        )
        XCTAssertEqual(
            RepositoryClient.packageURL(record(filename: "pool/demo.deb"), in: source)?.absoluteString,
            "https://repo.example.test/apt/pool/demo.deb"
        )
    }


    func testPackageURLAllowsHTTPSCDNWhenStrongDigestIsPublished() throws {
        let cdnRecord = PackageRecord(stanza: ControlStanza(fields: [
            ControlField(name: "Package", value: "demo"),
            ControlField(name: "Version", value: "1.0"),
            ControlField(name: "Architecture", value: "iphoneos-arm64"),
            ControlField(name: "Filename", value: "https://cdn.example.test/demo.deb"),
            ControlField(name: "SHA256", value: String(repeating: "a", count: 64)),
        ]))
        XCTAssertEqual(
            RepositoryClient.packageURL(cdnRecord, in: source)?.absoluteString,
            "https://cdn.example.test/demo.deb"
        )
    }


    func testPackageURLRejectsCrossOriginWithMalformedStrongDigest() {
        let malformed = PackageRecord(stanza: ControlStanza(fields: [
            ControlField(name: "Package", value: "demo"),
            ControlField(name: "Version", value: "1.0"),
            ControlField(name: "Architecture", value: "iphoneos-arm64"),
            ControlField(name: "Filename", value: "https://cdn.example.test/demo.deb"),
            ControlField(name: "SHA256", value: "not-a-valid-digest"),
        ]))
        XCTAssertNil(RepositoryClient.packageURL(malformed, in: source))
    }

    func testPackageURLRejectsCrossOriginWithoutStrongDigest() {
        XCTAssertNil(RepositoryClient.packageURL(
            record(filename: "https://cdn.example.test/demo.deb"),
            in: source
        ))
    }

    func testPackageDigestIsRequiredByDefault() {
        XCTAssertTrue(RepositoryPolicy.default.requirePackageDigest)
        XCTAssertTrue(RepositoryPolicy.default.requireSignature)
    }

    func testRejectedSignatureCannotBeIgnored() {
        let compatibilityPolicy = RepositoryPolicy(requireSignature: false)
        XCTAssertNotNil(compatibilityPolicy.signatureRejection(for: .rejected(reason: "bad signature")))
        XCTAssertNil(compatibilityPolicy.signatureRejection(for: .unsigned))
    }

    func testUntrustedSigningKeyCanBeIgnoredInCompatibilityMode() {
        let compatibilityPolicy = RepositoryPolicy(requireSignature: false)
        XCTAssertNil(compatibilityPolicy.signatureRejection(for: .untrusted(reason: "No public key")))
    }

    func testStrictPolicyRejectsUntrustedSigningKey() {
        let strictPolicy = RepositoryPolicy(requireSignature: true)
        XCTAssertNotNil(strictPolicy.signatureRejection(for: .untrusted(reason: "No public key")))
    }

    func testBrokenDynamicLoaderIsVerificationUnavailable() {
        let status = SignatureVerifier.failedVerificationStatus(
            """
            dyld[123]: Library not loaded: @rpath/libgcrypt.20.dylib
              Referenced from: /var/jb/usr/bin/gpgv
              Expected in: /var/jb/usr/lib/libgpg-error.0.dylib
            """
        )
        guard case .unavailable = status else {
            return XCTFail("Expected verifier runtime failure to be unavailable, got \(status)")
        }
    }

    func testBadSignatureTakesPrecedenceOverRuntimeFailure() {
        let status = SignatureVerifier.failedVerificationStatus(
            "gpgv: BAD signature from \"dyld\"\ndyld: Library not loaded: libgcrypt.20.dylib"
        )
        guard case .rejected = status else {
            return XCTFail("Expected bad signature to remain rejected, got \(status)")
        }
    }

    func testBrokenVerifierRuntimeCanBeIgnoredInCompatibilityMode() {
        let status = SignatureVerifier.failedVerificationStatus(
            "dyld: Symbol not found: _gpg_error_check_version\nExpected in: /var/jb/usr/lib/libgpg-error.0.dylib"
        )
        let compatibilityPolicy = RepositoryPolicy(requireSignature: false)
        XCTAssertNil(compatibilityPolicy.signatureRejection(for: status))
    }

    func testUnknownKeyOnlyVerifierFailureIsUntrusted() {
        let status = SignatureVerifier.failedVerificationStatus(
            "gpgv: Signature made today\ngpgv: Can't check signature: No public key"
        )
        XCTAssertEqual(status, .untrusted(reason: "gpgv: Can't check signature: No public key"))
    }

    func testBadSignatureTakesPrecedenceOverUnknownKey() {
        let status = SignatureVerifier.failedVerificationStatus(
            "gpgv: BAD signature from \"Repo Signer\"\ngpgv: Can't check signature: No public key"
        )
        XCTAssertEqual(status, .rejected(reason: "gpgv: Can't check signature: No public key"))
    }

    func testRequiredSignatureRejectsUnsignedMetadataAndFlatSources() {
        let strictPolicy = RepositoryPolicy(requireSignature: true, allowFlatUnsigned: false)
        XCTAssertNotNil(strictPolicy.signatureRejection(for: .unsigned))
        XCTAssertNotNil(strictPolicy.flatRepositoryRejection)
    }

    func testDefaultPolicyAllowsFlatSourcesWithoutReleaseFiles() {
        XCTAssertTrue(RepositoryPolicy.default.requireSignature)
        XCTAssertNil(RepositoryPolicy.default.flatRepositoryRejection)
    }

    func testIndexResponseMustContainPackageRecords() throws {
        let origin = RepositoryID(url: "https://repo.example.test", suite: "./", component: "")
        XCTAssertTrue(RepositoryClient.packageRecords(
            in: Data("<html><body>Repository home</body></html>".utf8),
            origin: origin
        ).isEmpty)

        let packages = try Fixture.data(Fixture.packagesIndex)
        XCTAssertFalse(RepositoryClient.packageRecords(in: packages, origin: origin).isEmpty)
    }

    func testNoIndexErrorShowsAllFormatsAndFailureDetails() {
        let error = RepositoryError.noPackageIndex(
            source: "Test",
            tried: ["Packages.zst", "Packages.xz", "Packages.lzma", "Packages.bz2", "Packages.gz", "Packages"],
            details: ["Packages.zst: no zstd decoder is installed", "Packages.xz: response did not contain package records"]
        ).description
        XCTAssertTrue(error.contains("Packages.gz, Packages"))
        XCTAssertTrue(error.contains("no zstd decoder is installed"))
    }
}
