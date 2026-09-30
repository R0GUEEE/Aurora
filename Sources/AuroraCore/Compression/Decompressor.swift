import Foundation
#if canImport(Compression)
import Compression
#endif

/// Compression containers Debian repositories publish package indexes in.
///
/// `Packages` ships in several of these at once and a client is expected to pick
/// whichever it can handle; Aurora prefers the smallest one it can actually
/// decode (xz, then gzip, then plain).
public enum CompressionFormat: String, CaseIterable, Hashable, Sendable {
    case plain
    case gzip
    case xz
    case lzma
    case bzip2
    case zstd

    public var pathExtension: String {
        switch self {
        case .plain: return "Packages"
        case .gzip: return "Packages.gz"
        case .xz: return "Packages.xz"
        case .lzma: return "Packages.lzma"
        case .bzip2: return "Packages.bz2"
        case .zstd: return "Packages.zst"
        }
    }

    /// Detects the container from the first bytes of a file. Magic numbers are
    /// used rather than the server's content type, which repositories get wrong
    /// all the time.
    public static func detect(magic bytes: [UInt8]) -> CompressionFormat? {
        if bytes.count >= 2, bytes[0] == 0x1f, bytes[1] == 0x8b { return .gzip }
        if bytes.count >= 6, bytes[0...5].elementsEqual([0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]) { return .xz }
        if bytes.count >= 4, bytes[0...3].elementsEqual([0x28, 0xb5, 0x2f, 0xfd]) { return .zstd }
        if bytes.count >= 3, bytes[0...2].elementsEqual([0x42, 0x5a, 0x68]) { return .bzip2 }
        // LZMA alone header: properties byte 0x5d then a 4-byte dictionary size.
        if bytes.count >= 13, bytes[0] == 0x5d, bytes[1] == 0x00, bytes[2] == 0x00 { return .lzma }
        return nil
    }

    /// Guess from a file name, used when the magic bytes are inconclusive.
    public static func detect(fileName: String) -> CompressionFormat? {
        let lowered = fileName.lowercased()
        if lowered.hasSuffix(".gz") { return .gzip }
        if lowered.hasSuffix(".xz") { return .xz }
        if lowered.hasSuffix(".lzma") { return .lzma }
        if lowered.hasSuffix(".bz2") || lowered.hasSuffix(".bzip2") { return .bzip2 }
        if lowered.hasSuffix(".zst") || lowered.hasSuffix(".zstd") { return .zstd }
        return nil
    }
}

public enum DecompressionError: Error, CustomStringConvertible {
    case unsupported(CompressionFormat, hint: String)
    case corrupt(CompressionFormat, reason: String)
    case exceedsLimit(Int)

    public var description: String {
        switch self {
        case .unsupported(let format, let hint):
            return "\(format.rawValue) indexes cannot be read here: \(hint)"
        case .corrupt(let format, let reason):
            return "damaged \(format.rawValue) data: \(reason)"
        case .exceedsLimit(let limit):
            return "the decompressed index is larger than the \(limit / (1 << 20)) MB safety limit"
        }
    }
}

/// Decompresses the containers a Debian index uses.
///
/// Design note: nothing is vendored. gzip goes through the system zlib, and the
/// LZMA family goes through Apple's `Compression` framework, which decodes the
/// xz container. zstd and bzip2 are handled by a helper binary when a jailbroken
/// device happens to have one, and otherwise fail with a message that says so
/// instead of pretending the repository is broken.
public enum Decompressor {

    /// Refuses to materialise an index bigger than this. A corrupt or hostile
    /// file should not be able to exhaust the memory of the device.
    public static let maximumOutputSize = 512 * (1 << 20)

    /// Directories a jailbroken device keeps helper binaries in, most specific
    /// first. Mirrors `JailbreakEnvironment.executableSearchPaths` but kept here
    /// so decompression works without an environment (macOS test runs).
    public static var helperSearchPaths: [String] = [
        "/var/jb/usr/bin", "/var/jb/usr/local/bin", "/var/jb/bin",
        "/usr/bin", "/usr/local/bin", "/bin",
    ]

    public static func decompress(_ data: Data, capacityHint: Int? = nil) throws -> Data {
        let magic = [UInt8](data.prefix(16))
        guard let format = CompressionFormat.detect(magic: magic) else { return data }
        return try decompress(data, format: format, capacityHint: capacityHint)
    }

    public static func decompress(_ data: Data, format: CompressionFormat, capacityHint: Int? = nil) throws -> Data {
        switch format {
        case .plain:
            return data

        case .gzip:
            do {
                return try ZlibBridge.inflate(data)
            } catch {
                throw DecompressionError.corrupt(.gzip, reason: "\(error)")
            }

        case .xz, .lzma:
            #if canImport(Compression)
            do {
                return try decodeWithAppleCompression(data, hint: capacityHint)
            } catch {
                // A headerless LZMA stream is what a `.lzma` file is after its
                // 13-byte alone header; Apple's decoder sometimes wants it raw.
                if format == .lzma, data.count > 13 {
                    let body = data.subdata(in: 13..<data.count)
                    if let decoded = try? decodeWithAppleCompression(body, hint: capacityHint) {
                        return decoded
                    }
                }
                // Last resort on a device that has the xz tools installed.
                if let external = try? runHelper(["xz", "unxz"], format: format, input: data) { return external }
                throw DecompressionError.corrupt(format, reason: "\(error)")
            }
            #else
            if let external = try? runHelper(["xz", "unxz"], format: format, input: data) { return external }
            throw DecompressionError.unsupported(format, hint: "no LZMA decoder is available on this platform")
            #endif

        case .bzip2:
            if let external = try? runHelper(["bunzip2"], format: .bzip2, input: data) { return external }
            throw DecompressionError.unsupported(.bzip2, hint: "no bzip2 decoder is installed on this device")

        case .zstd:
            if let external = try? runHelper(["unzstd", "zstd"], format: .zstd, input: data, extraArguments: ["-d", "-c"]) {
                return external
            }
            throw DecompressionError.unsupported(.zstd, hint: "no zstd decoder is installed on this device")
        }
    }

    public static func decompressFile(at path: String, format: CompressionFormat? = nil) throws -> Data {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        } catch {
            throw DecompressionError.corrupt(format ?? .plain, reason: "cannot read \(path): \(error)")
        }
        let resolved = format ?? CompressionFormat.detect(magic: [UInt8](data.prefix(16))) ?? .plain
        return try decompress(data, format: resolved)
    }

    // MARK: - Platform decoders

    #if canImport(Compression)
    /// Apple's `Compression` framework only decodes into a buffer whose size is
    /// known up front, so grow the destination until the stream fits. The attempt
    /// count is bounded: a corrupt file must fail quickly instead of allocating
    /// half a gigabyte on the way to its own error message.
    private static func decodeWithAppleCompression(_ data: Data, hint: Int?) throws -> Data {
        guard !data.isEmpty else { return Data() }

        var capacity = max(hint ?? 0, 1 << 18)
        var attempts = 0
        while attempts < 12, capacity <= maximumOutputSize {
            attempts += 1
            var destination = [UInt8](repeating: 0, count: capacity)
            let produced = data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let base = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return destination.withUnsafeMutableBufferPointer { output -> Int in
                    compression_decode_buffer(
                        output.baseAddress!, capacity,
                        base, source.count,
                        nil, COMPRESSION_LZMA
                    )
                }
            }
            if produced > 0 {
                return Data(destination[0..<produced])
            }
            capacity *= 2
        }
        throw DecompressionError.corrupt(
            .xz,
            reason: "Apple's LZMA decoder returned nothing for \(data.count) bytes"
        )
    }
    #endif

    /// Runs `tool -dc` over `input`, if the tool exists.
    private static func runHelper(
        _ names: [String],
        format: CompressionFormat,
        input: Data,
        extraArguments: [String] = []
    ) throws -> Data {
        for name in names {
            guard let path = ProcessRunner.which(name, searchPaths: helperSearchPaths) else { continue }
            let arguments = extraArguments.isEmpty ? ["-dc"] : extraArguments
            guard let result = try? ProcessRunner.run(
                executable: path,
                arguments: arguments,
                standardInput: input
            ), result.succeeded, !result.stdout.isEmpty else { continue }
            return result.stdout
        }
        throw DecompressionError.unsupported(
            format,
            hint: "no \(names.joined(separator: "/")) helper is installed in \(helperSearchPaths.prefix(3).joined(separator: ":"))"
        )
    }
}
