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

        public var description: String {
            switch self {
            case .initFailed(let code): return "zlib could not initialise the stream (code \(code))"
            case .inflateFailed(let code): return "zlib could not decompress the data (code \(code))"
            }
        }
    }

    /// Inflates a zlib *or* gzip stream.
    ///
    /// `windowBits` 47 (`15 + 32`) asks zlib to detect the container from the
    /// first bytes, so one code path handles both a `.gz` index and a bare zlib
    /// stream. Use ``inflateRaw`` for headerless deflate.
    public static func inflate(_ data: Data, windowBits: Int32 = 47) throws -> Data {
        guard !data.isEmpty else { return Data() }

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
                if produced > 0 { output.append(contentsOf: chunk[0..<produced]) }
                if status == Z_STREAM_END || produced == 0 { break }
            }
        }

        return output
    }

    /// Inflates headerless (raw) deflate data.
    public static func inflateRaw(_ data: Data) throws -> Data {
        try inflate(data, windowBits: -15)
    }
}
