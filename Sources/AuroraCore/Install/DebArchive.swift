import Foundation

/// A `.deb`: a `ar` archive holding `debian-binary`, `control.tar.*` and
/// `data.tar.*`.
///
/// Aurora opens the archive before installing anything, for two reasons: the
/// queue shows the real control metadata (a repository index can lie about
/// `Installed-Size`), and a truncated download must be caught before `dpkg` is
/// handed a corrupt file.
///
/// Only the `ar` headers are read up front, so inspecting a 500 MB package costs
/// a few hundred bytes of I/O; member contents are read on demand.
public struct DebArchive: Sendable {

    public struct Member: Hashable, Sendable {
        public let name: String
        public let offset: Int64
        public let size: Int64
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case unreadable(String, underlying: Swift.Error)
        case notAnArchive(String)
        case truncated(String)
        case missingMember(String)
        case badTar(String)

        public var description: String {
            switch self {
            case .unreadable(let path, let underlying): return "cannot read \(path): \(underlying)"
            case .notAnArchive(let path): return "\(path) is not a Debian package (bad ar magic)"
            case .truncated(let what): return "the package is truncated: \(what)"
            case .missingMember(let name): return "the package has no \(name)"
            case .badTar(let reason): return "damaged tar member: \(reason)"
            }
        }
    }

    public let path: String
    public let members: [Member]

    public init(path: String) throws {
        self.path = path
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        } catch {
            throw Error.unreadable(path, underlying: error)
        }
        defer { try? handle.close() }

        let magic: Data
        do {
            magic = try handle.read(upToCount: 8) ?? Data()
        } catch {
            throw Error.unreadable(path, underlying: error)
        }
        guard magic.count == 8, String(decoding: magic, as: UTF8.self) == "!<arch>\n" else {
            throw Error.notAnArchive(path)
        }

        var offset: Int64 = 8
        var members: [Member] = []
        while true {
            let header: Data
            do {
                header = try handle.read(upToCount: 60) ?? Data()
            } catch {
                throw Error.unreadable(path, underlying: error)
            }
            if header.isEmpty { break }
            guard header.count == 60 else { throw Error.truncated("ar header at offset \(offset)") }
            let bytes = [UInt8](header)
            guard bytes[58] == UInt8(ascii: "`"), bytes[59] == UInt8(ascii: "\n") else {
                throw Error.notAnArchive(path)
            }

            var name = String(decoding: bytes[0..<16], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            let sizeText = String(decoding: bytes[48..<58], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            guard var size = Int64(sizeText) else { throw Error.truncated("ar size field for \(name)") }

            var dataOffset = offset + 60
            // BSD-style extended name: the real name lives in the data area.
            if name.hasPrefix("#1/") {
                guard let nameLength = Int(name.dropFirst(3)), nameLength > 0, Int64(nameLength) <= size else {
                    throw Error.notAnArchive(path)
                }
                let nameData: Data
                do {
                    nameData = try handle.read(upToCount: nameLength) ?? Data()
                } catch {
                    throw Error.unreadable(path, underlying: error)
                }
                name = String(decoding: nameData, as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                dataOffset += Int64(nameLength)
                size -= Int64(nameLength)
            } else {
                name = String(name.split(separator: "/").first ?? "")
            }

            // Static, not an instance method: this runs inside `init` before every
            // stored property has a value, and `self` is not usable until then.
            guard size >= 0, dataOffset + size <= Self.fileSize(of: handle) else {
                throw Error.truncated("member \(name)")
            }
            members.append(Member(name: name, offset: dataOffset, size: size))
            // Members are padded to an even offset.
            offset = dataOffset + size + (size % 2)
            do {
                try handle.seek(toOffset: UInt64(offset))
            } catch {
                break
            }
        }

        self.members = members
    }

    private static func fileSize(of handle: FileHandle) -> Int64 {
        let current = (try? handle.offset()) ?? 0
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: current)
        return Int64(end)
    }

    public func member(named name: String) -> Member? {
        members.first { $0.name == name }
    }

    public var controlMember: Member? { members.first { $0.name.hasPrefix("control.tar") } }
    public var payloadMember: Member? { members.first { $0.name.hasPrefix("data.tar") } }
    public var binaryVersion: String? {
        guard let member = member(named: "debian-binary") else { return nil }
        return String(decoding: (try? read(member)) ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func read(_ member: Member) throws -> Data {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        } catch {
            throw Error.unreadable(path, underlying: error)
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(member.offset))
            return try handle.read(upToCount: Int(member.size)) ?? Data()
        } catch {
            throw Error.unreadable(path, underlying: error)
        }
    }

    /// The `control` stanza of a package, read from inside the archive.
    public func controlStanza() throws -> ControlStanza {
        guard let member = controlMember else { throw Error.missingMember("control.tar") }
        let format = CompressionFormat.detect(fileName: member.name) ?? .plain
        let tarData = try Decompressor.decompress(try read(member), format: format)
        let entries = try TarReader.entries(in: tarData)
        guard let control = entries.first(where: { $0.name == "./control" || $0.name == "control" }) else {
            throw Error.missingMember("control file")
        }
        let text = String(decoding: control.contents, as: UTF8.self)
        guard let stanza = ControlParser.parse(text).first else {
            throw Error.badTar("empty control file")
        }
        return stanza
    }

    /// The maintainer scripts (`postinst`, `prerm`, …). Aurora shows them before
    /// an install: a modern client does not run a stranger's shell script silently.
    public func maintainerScripts() throws -> [String: String] {
        guard let member = controlMember else { return [:] }
        let format = CompressionFormat.detect(fileName: member.name) ?? .plain
        let tarData = try Decompressor.decompress(try read(member), format: format)
        let entries = try TarReader.entries(in: tarData)
        var scripts: [String: String] = [:]
        for entry in entries where entry.type == .regular {
            let name = entry.name.hasPrefix("./") ? String(entry.name.dropFirst(2)) : entry.name
            if ["preinst", "postinst", "prerm", "postrm", "triggers", "conffiles"].contains(name) {
                scripts[name] = String(decoding: entry.contents, as: UTF8.self)
            }
        }
        return scripts
    }

    /// Summarises the payload without extracting it.
    public func payloadSummary() throws -> (files: Int, bytes: Int64) {
        guard let member = payloadMember else { throw Error.missingMember("data.tar") }
        let format = CompressionFormat.detect(fileName: member.name) ?? .plain
        let tarData = try Decompressor.decompress(try read(member), format: format)
        let entries = try TarReader.entries(in: tarData)
        let files = entries.filter { $0.type == .regular }.count
        let bytes = entries.reduce(Int64(0)) { $0 + ($1.type == .regular ? Int64($1.contents.count) : 0) }
        return (files, bytes)
    }
}

/// A minimal tar reader: enough of `ustar` for `.deb` members, including GNU long
/// names and pax headers, because both appear in packages built with modern dpkg.
public enum TarReader {

    public enum EntryType: Hashable, Sendable {
        case regular
        case directory
        case symbolicLink
        case other(UInt8)
    }

    public struct Entry: Hashable, Sendable {
        public let name: String
        public let size: Int64
        public let mode: Int
        public let type: EntryType
        public let linkTarget: String?
        public let contents: Data
    }

    static func entries(in data: Data) throws -> [Entry] {
        var entries: [Entry] = []
        var offset = 0
        let bytes = [UInt8](data)
        var pendingLongName: String?
        var pendingPaxOverrides: [String: String] = [:]
        let blockSize = 512

        while offset + blockSize <= bytes.count {
            // Copy the 512-byte block so the field offsets below are zero-based:
            // slicing `bytes` directly would keep the file offsets as indices and
            // every field read would be off by `offset`.
            let block = Array(bytes[offset..<(offset + blockSize)])
            if block.allSatisfy({ $0 == 0 }) { break }

            let rawName = Self.string(block[0..<100])
            let sizeField = Self.number(block[124..<136])
            let typeFlag = block[156]
            let magic = Self.string(block[257..<263])
            guard magic.hasPrefix("ustar") else {
                throw DebArchive.Error.badTar("missing ustar magic at offset \(offset)")
            }
            var name = pendingPaxOverrides["path"] ?? rawName
            if let entrySize = sizeField, entrySize < 0 {
                throw DebArchive.Error.badTar("negative entry size for \(name)")
            }
            let size = sizeField ?? 0
            let dataStart = offset + blockSize
            let dataEnd = dataStart + Int(size)
            guard dataEnd <= bytes.count else {
                throw DebArchive.Error.truncated("tar entry \(name)")
            }
            let contents = size > 0 ? Data(bytes[dataStart..<dataEnd]) : Data()

            switch typeFlag {
            case UInt8(ascii: "L"):
                // GNU long name: the payload is the name of the *next* entry.
                pendingLongName = String(decoding: contents, as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            case UInt8(ascii: "x"), UInt8(ascii: "g"):
                pendingPaxOverrides = Self.parsePax(contents)
            default:
                if let long = pendingLongName {
                    name = long
                    pendingLongName = nil
                }
                let prefix = Self.string(block[345..<500])
                if !prefix.isEmpty { name = "\(prefix)/\(name)" }
                if let overridden = pendingPaxOverrides["path"] { name = overridden }
                pendingPaxOverrides = [:]

                let type: EntryType
                switch typeFlag {
                case UInt8(ascii: "0"), 0: type = .regular
                case UInt8(ascii: "5"): type = .directory
                case UInt8(ascii: "2"): type = .symbolicLink
                default: type = .other(typeFlag)
                }
                entries.append(Entry(
                    name: name,
                    size: size,
                    mode: Int(Self.number(block[100..<108]) ?? 0o644),
                    type: type,
                    linkTarget: type == .symbolicLink ? Self.string(block[157..<257]) : nil,
                    contents: contents
                ))
            }

            // Entries are padded to a 512-byte boundary.
            offset = dataEnd + ((blockSize - (Int(size) % blockSize)) % blockSize)
        }
        return entries
    }

    private static func string(_ slice: ArraySlice<UInt8>) -> String {
        var bytes = Array(slice)
        if let zero = bytes.firstIndex(of: 0) { bytes = Array(bytes[0..<zero]) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Octal ASCII, or GNU base-256 for values that do not fit (large packages
    /// have payloads over 8 GB, which octal cannot express).
    static func number(_ slice: ArraySlice<UInt8>) -> Int64? {
        let bytes = Array(slice)
        guard let first = bytes.first else { return nil }
        if first & 0x80 != 0 {
            var value: Int64 = Int64(first & 0x7f)
            for byte in bytes.dropFirst() { value = (value << 8) | Int64(byte) }
            return value
        }
        let text = string(slice).trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        guard !text.isEmpty else { return 0 }
        return Int64(text, radix: 8)
    }

    /// pax extended records: `<length> <key>=<value>\n`.
    private static func parsePax(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let record = line[line.index(after: space)...]
            guard let equals = record.firstIndex(of: "=") else { continue }
            result[String(record[record.startIndex..<equals])] = String(record[record.index(after: equals)...])
        }
        return result
    }
}
