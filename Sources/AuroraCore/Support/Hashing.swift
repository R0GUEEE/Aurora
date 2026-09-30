import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The digest algorithms Debian repository metadata uses.
///
/// The raw values are the field names in a `Release` file, so an enum value can be
/// used directly to look a section up in a parsed stanza.
public enum HashAlgorithm: String, CaseIterable, Hashable, Sendable {
    case md5 = "MD5Sum"
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"

    /// Strongest first: repositories publish several and we want the best one.
    public static let byStrength: [HashAlgorithm] = [.sha512, .sha256, .sha1, .md5]

    public var isBroken: Bool { self == .md5 || self == .sha1 }

    public var fieldName: String { rawValue }
}

public enum HashingError: Error, CustomStringConvertible {
    case algorithmUnavailable(HashAlgorithm)
    case unreadableFile(String, underlying: Error)

    public var description: String {
        switch self {
        case .algorithmUnavailable(let algorithm):
            return "\(algorithm.rawValue) is not available on this platform"
        case .unreadableFile(let path, let underlying):
            return "cannot read \(path): \(underlying)"
        }
    }
}

/// Digest helpers.
///
/// Downloads are hashed in chunks rather than loaded whole: a `.deb` can be
/// hundreds of megabytes and a jailbroken device has no memory to spare.
public enum Hashing {

    public static func hexDigest(of data: Data, using algorithm: HashAlgorithm) throws -> String {
        switch algorithm {
        case .md5:
            #if canImport(CryptoKit)
            return Insecure.MD5.hash(data: data).hexString
            #else
            throw HashingError.algorithmUnavailable(algorithm)
            #endif
        case .sha1:
            #if canImport(CryptoKit)
            return Insecure.SHA1.hash(data: data).hexString
            #else
            throw HashingError.algorithmUnavailable(algorithm)
            #endif
        case .sha256:
            #if canImport(CryptoKit)
            return SHA256.hash(data: data).hexString
            #else
            throw HashingError.algorithmUnavailable(algorithm)
            #endif
        case .sha512:
            #if canImport(CryptoKit)
            return SHA512.hash(data: data).hexString
            #else
            throw HashingError.algorithmUnavailable(algorithm)
            #endif
        }
    }

    /// Hashes a file without loading it into memory.
    public static func hexDigest(ofFileAt path: String, using algorithm: HashAlgorithm) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        } catch {
            throw HashingError.unreadableFile(path, underlying: error)
        }
        defer { try? handle.close() }

        #if canImport(CryptoKit)
        switch algorithm {
        case .md5:
            var hasher = Insecure.MD5()
            try pump(handle, into: { hasher.update(data: $0) })
            return hasher.finalize().hexString
        case .sha1:
            var hasher = Insecure.SHA1()
            try pump(handle, into: { hasher.update(data: $0) })
            return hasher.finalize().hexString
        case .sha256:
            var hasher = SHA256()
            try pump(handle, into: { hasher.update(data: $0) })
            return hasher.finalize().hexString
        case .sha512:
            var hasher = SHA512()
            try pump(handle, into: { hasher.update(data: $0) })
            return hasher.finalize().hexString
        }
        #else
        throw HashingError.algorithmUnavailable(algorithm)
        #endif
    }

    #if canImport(CryptoKit)
    private static func pump(_ handle: FileHandle, into update: (Data) -> Void) throws {
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            update(chunk)
        }
    }
    #endif

    /// Case-insensitive comparison, as used for the `SHA256` column of a
    /// `Packages` file.
    public static func matches(_ digest: String, _ expected: String) -> Bool {
        digest.trimmingCharacters(in: .whitespaces).lowercased()
            == expected.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

#if canImport(CryptoKit)
extension Digest {
    /// Lowercase hex, the encoding every Debian index uses.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
#endif
