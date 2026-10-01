import Foundation

/// Outcome of checking the signature on repository metadata.
public enum SignatureStatus: Sendable, Equatable {
    case verified(fingerprint: String?)
    case unsigned
    /// The metadata is signed, but the signing key is not in Aurora/device trust stores.
    case untrusted(reason: String)
    /// The signature is present but cryptographically invalid or malformed.
    case rejected(reason: String)
    /// No verifier or no keyring is available on this device.
    case unavailable(reason: String)

    public var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }

    public var isTrustworthy: Bool { isVerified }

    public var shortDescription: String {
        switch self {
        case .verified(let fingerprint): return fingerprint.map { "Signed by \($0)" } ?? "Signed"
        case .unsigned: return "Unsigned"
        case .untrusted(let reason): return "Untrusted signing key: \(reason)"
        case .rejected(let reason): return "Signature rejected: \(reason)"
        case .unavailable(let reason): return "Signature not checked: \(reason)"
        }
    }
}

/// An OpenPGP clearsigned document, which is what `InRelease` is.
public struct ClearsignedMessage: Sendable {

    public let payload: Data
    /// The armor block, fed to the verifier as a signature file.
    public let signature: Data
    public let hashAlgorithm: String?

    public static let beginMarker = "-----BEGIN PGP SIGNED MESSAGE-----"
    public static let signatureMarker = "-----BEGIN PGP SIGNATURE-----"

    /// Splits the document without verifying anything.
    ///
    /// Dash-escaping must be undone before the payload is parsed as a control
    /// file: a line in the signed text that starts with `- ` was escaped by the
    /// signer, and `Hash:`-style headers are not part of the payload.
    public static func parse(_ data: Data) -> ClearsignedMessage? {
        let text = String(decoding: data, as: UTF8.self)
        guard let beginRange = text.range(of: beginMarker),
              let signatureRange = text.range(of: signatureMarker) else { return nil }

        var body = text[beginRange.upperBound..<signatureRange.lowerBound]
        var hashAlgorithm: String?
        if let blankLine = body.range(of: "\n\n") {
            let headers = body[body.startIndex..<blankLine.lowerBound]
            for line in headers.split(separator: "\n") {
                if line.lowercased().hasPrefix("hash:") {
                    hashAlgorithm = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                }
            }
            body = body[blankLine.upperBound...]
        }

        var unescaped: [String] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            unescaped.append(line.hasPrefix("- ") ? String(line.dropFirst(2)) : String(line))
        }
        // The signature marker sits on its own line, so the payload ends with the
        // newline that preceded it; trailing empties are an artefact of splitting.
        while let last = unescaped.last, last.isEmpty { unescaped.removeLast() }

        let signature = String(text[signatureRange.lowerBound...])
        return ClearsignedMessage(
            payload: Data(unescaped.joined(separator: "\n").utf8),
            signature: Data(signature.utf8),
            hashAlgorithm: hashAlgorithm
        )
    }
}

/// Verifies repository metadata with whatever OpenPGP tool the device has.
///
/// Aurora ships no cryptographic implementation of its own and no keys. It uses
/// the keyrings the jailbreak already trusts (procursus/ellekit install them) plus
/// keys the user pasted into a source. When neither `gpgv` nor `sqv` is present
/// the result is ``SignatureStatus/unavailable`` — never "verified", and never a
/// hard failure unless the caller asked for signatures to be required.
public struct SignatureVerifier: Sendable {

    public let environment: JailbreakEnvironment
    private let additionalArmoredKeys: [String]

    public init(environment: JailbreakEnvironment, additionalArmoredKeys: [String] = []) {
        self.environment = environment
        self.additionalArmoredKeys = additionalArmoredKeys
    }

    private enum Tool {
        case gpgv(String)
        case sqv(String)
    }

    private var tool: Tool? {
        if let path = ProcessRunner.which("gpgv", searchPaths: environment.executableSearchPaths) {
            return .gpgv(path)
        }
        if let path = ProcessRunner.which("sqv", searchPaths: environment.executableSearchPaths) {
            return .sqv(path)
        }
        return nil
    }

    /// Verifies a clearsigned document and returns its payload on success.
    public func verify(clearsigned data: Data) -> (status: SignatureStatus, payload: Data?) {
        guard let message = ClearsignedMessage.parse(data) else {
            return (.rejected(reason: "not a clearsigned document"), nil)
        }
        let status = verifyDetached(signature: message.signature, payload: message.payload)
        return (status, message.payload)
    }

    public func verifyDetached(signature: Data, payload: Data) -> SignatureStatus {
        guard let tool else {
            return .unavailable(reason: "no gpgv or sqv binary on this device")
        }

        let workspace = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("aurora-verify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: workspace) }
        do {
            try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
            let signaturePath = (workspace as NSString).appendingPathComponent("signature.asc")
            let payloadPath = (workspace as NSString).appendingPathComponent("payload")
            try signature.write(to: URL(fileURLWithPath: signaturePath))
            try payload.write(to: URL(fileURLWithPath: payloadPath))

            let keyrings = try prepareKeyrings(in: workspace)
            guard !keyrings.isEmpty else {
                return .unavailable(reason: "no trusted keyring was found on this device")
            }

            let result: ProcessResult
            switch tool {
            case .gpgv(let path):
                var arguments: [String] = []
                for keyring in keyrings { arguments += ["--keyring", keyring] }
                arguments += [signaturePath, payloadPath]
                result = try ProcessRunner.run(executable: path, arguments: arguments, environment: childEnvironment)
            case .sqv(let path):
                var arguments: [String] = ["--keyring", keyrings[0]]
                for keyring in keyrings.dropFirst() { arguments += ["--keyring", keyring] }
                arguments += [signaturePath, payloadPath]
                result = try ProcessRunner.run(executable: path, arguments: arguments, environment: childEnvironment)
            }

            let output = result.combinedOutput
            if result.succeeded {
                return .verified(fingerprint: fingerprint(in: output))
            }
            return Self.failedVerificationStatus(output)
        } catch {
            return .unavailable(reason: "\(error)")
        }
    }

    /// Converts verifier diagnostics into a trust state. Invalid-signature
    /// evidence always wins over unknown-key evidence so a multi-signature file
    /// cannot hide a bad signature behind another signature whose key is missing.
    static func failedVerificationStatus(_ output: String) -> SignatureStatus {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = trimmed.split(separator: "\n").last.map(String.init) ?? "unknown error"
        let lower = output.lowercased()

        let runtimeFailureMarkers = [
            "dyld",
            "library not loaded",
            "symbol not found",
            "expected in:",
            "image not found",
            "incompatible library version",
            "reason: tried:",
            "code signature invalid",
            "mach-o",
        ]
        if runtimeFailureMarkers.contains(where: { lower.contains($0) }) {
            return .unavailable(reason: reason)
        }

        let invalidMarkers = [
            "bad signature",
            "invalid signature",
            "signature verification failed",
            "malformed signature",
            "malformed openpgp",
            "invalid openpgp",
            "no valid openpgp data",
            "invalid packet",
            "corrupt signature",
            "corrupted signature",
        ]
        if invalidMarkers.contains(where: { lower.contains($0) }) {
            return .rejected(reason: reason)
        }

        let unknownKeyMarkers = [
            "no public key",
            "can't check signature",
            "cannot check signature",
            "unknown public key",
            "unknown signing key",
            "public key not found",
            "key not found",
            "missing public key",
            "missing key",
            "no matching key",
            "no suitable key",
        ]
        if unknownKeyMarkers.contains(where: { lower.contains($0) }) {
            return .untrusted(reason: reason)
        }

        return .rejected(reason: reason)
    }

    private var childEnvironment: [String: String] {
        [
            "PATH": environment.executableSearchPaths.joined(separator: ":"),
            "HOME": "/var/mobile",
            "LC_ALL": "C",
        ]
    }

    /// Keyrings to hand to the verifier: the device's own, plus one built from the
    /// keys the user added to the source.
    private func prepareKeyrings(in workspace: String) throws -> [String] {
        var keyrings = environment.trustedKeyringPaths.filter { path in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            return exists && !isDirectory.boolValue
        }
        // Directories of keyrings (e.g. /etc/apt/trusted.gpg.d) are expanded.
        for directory in environment.trustedKeyringPaths {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue,
                  let contents = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for entry in contents where entry.hasSuffix(".gpg") || entry.hasSuffix(".asc") || entry.hasSuffix(".key") {
                keyrings.append((directory as NSString).appendingPathComponent(entry))
            }
        }

        if !additionalArmoredKeys.isEmpty {
            let armored = (workspace as NSString).appendingPathComponent("aurora-keys.asc")
            try additionalArmoredKeys.joined(separator: "\n").write(toFile: armored, atomically: true, encoding: .utf8)
            if let gpg = ProcessRunner.which("gpg", searchPaths: environment.executableSearchPaths) {
                let keyring = (workspace as NSString).appendingPathComponent("aurora-keys.gpg")
                let result = try ProcessRunner.run(
                    executable: gpg,
                    arguments: ["--batch", "--yes", "--dearmor", "-o", keyring, armored],
                    environment: childEnvironment
                )
                if result.succeeded { keyrings.append(keyring) }
            }
        }
        return keyrings
    }

    private func fingerprint(in output: String) -> String? {
        for line in output.split(separator: "\n") {
            if let range = line.range(of: "using ") {
                let tail = line[range.upperBound...]
                let identifier = tail.split(separator: " ").first.map(String.init) ?? ""
                if !identifier.isEmpty { return identifier }
            }
        }
        return nil
    }
}
