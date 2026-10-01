import Foundation
import CZlib

/// Thin wrapper over zlib.
///
/// gzip is the one compressor guaranteed to be present on every jailbroken
/// device — `/usr/lib/libz.1.dylib` ships with iOS and is in the shared cache —
/// so the gzip family does not need a vendored C dependency, unlike xz or zstd.
public enum ZlibBridge {

    public enum Error: Swift.Error, CustomStringConvertible {
        case initFailed(Int32)
        case inflateFailed(Int32)
        /// The input ran out before the stream ended. This must be an error and
        /// not a short result: a truncated `Packages.gz` would otherwise parse as
        /// a smaller index, and a repository without a `Release` file has no
        /// checksum to catch that.
        case truncatedStream(produced: Int)
        case outputTooLarge(limit: Int)

        public var description: String {
            switch self {
            case .initFailed(let code): return "zlib could not initialise the stream (code \(code))"
            case .inflateFailed(let code): return "zlib could not decompress the data (code \(code))"
            case .truncatedStream(let produced):
                return "the compressed data ends in the middle of the stream (got \(produced) bytes)"
            case .outputTooLarge(let limit):
                return "the decompressed output exceeds the \(limit)-byte limit"
            }
        }
    }

    /// Inflates a zlib *or* gzip stream.
    ///
    /// Named `decompress` rather than `inflate` on purpose: a member called
    /// `inflate` would shadow the C function of the same name inside this type,
    /// and Swift resolves the name to the member first.
    ///
    /// `windowBits` 47 (`15 + 32`) asks zlib to detect the container from the
    /// first bytes, so one code path handles both a `.gz` index and a bare zlib
    /// stream. Use ``decompressRaw(_:)`` for headerless deflate.
    public static func decompress(
        _ data: Data,
        windowBits: Int32 = 47,
        maximumOutputBytes: Int = Int.max
    ) throws -> Data {
        guard !data.isEmpty else { return Data() }
        let outputLimit = max(0, maximumOutputBytes)

        var stream = z_stream()
        var status = inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw Error.initFailed(status) }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = 256 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws in
            let input = raw.bindMemory(to: UInt8.self)
            stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress)
            stream.avail_in = uInt(input.count)

            while true {
                let produced: Int = try chunk.withUnsafeMutableBufferPointer { buffer throws -> Int in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = inflate(&stream, Z_NO_FLUSH)
                    if status != Z_OK && status != Z_STREAM_END && status != Z_BUF_ERROR {
                        throw Error.inflateFailed(status)
                    }
                    return chunkSize - Int(stream.avail_out)
                }
                if produced > 0 {
                    guard produced <= outputLimit, output.count <= outputLimit - produced else {
                        throw Error.outputTooLarge(limit: outputLimit)
                    }
                    output.append(contentsOf: chunk[0..<produced])
                }
                if status == Z_STREAM_END || produced == 0 { break }
            }
        }

        // Only a complete stream is a success. `Z_OK`/`Z_BUF_ERROR` here mean the
        // input ended early, which is corruption, not a shorter file.
        guard status == Z_STREAM_END else {
            throw Error.truncatedStream(produced: output.count)
        }
        return output
    }

    /// Inflates headerless (raw) deflate data.
    public static func decompressRaw(_ data: Data, maximumOutputBytes: Int = Int.max) throws -> Data {
        try decompress(data, windowBits: -15, maximumOutputBytes: maximumOutputBytes)
    }
}
