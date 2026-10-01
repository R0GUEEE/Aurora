import Foundation

/// The downloaded `.deb` files Aurora keeps so a reinstall or a retry does not
/// download again.
///
/// A jailbroken phone has very little room, so this is a first-class, visible
/// thing rather than an invisible directory that grows forever: the settings
/// screen shows what it costs and the CLI can empty it.
public struct PackageCache: Sendable {

    public struct Entry: Sendable, Hashable {
        public let name: String
        public let path: String
        public let bytes: Int64
        public let modified: Date?

        public var displaySize: String {
            let units = ["B", "kB", "MB", "GB"]
            var value = Double(bytes)
            var index = 0
            while value >= 1024, index < units.count - 1 {
                value /= 1024
                index += 1
            }
            return index == 0 ? "\(Int(value)) B" : String(format: "%.1f %@", value, units[index])
        }
    }

    public let directory: String

    public init(directory: String) {
        self.directory = directory
    }

    public init(environment: JailbreakEnvironment) {
        self.directory = environment.cacheDirectory + "/packages"
    }

    /// Every file in the cache that looks like a download.
    ///
    /// Partial downloads (`*.partial`) are included: they are exactly the thing a
    /// user wants to reclaim after a transfer was interrupted.
    public func entries() -> [Entry] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory) else { return [] }
        return names.compactMap { name -> Entry? in
            let path = (directory as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return nil
            }
            let attributes = try? manager.attributesOfItem(atPath: path)
            let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            return Entry(name: name, path: path, bytes: bytes, modified: attributes?[.modificationDate] as? Date)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    public func totalBytes() -> Int64 {
        entries().reduce(0) { $0 + $1.bytes }
    }

    public func humanTotalSize() -> String {
        let units = ["B", "kB", "MB", "GB"]
        var value = Double(totalBytes())
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return index == 0 ? "\(Int(value)) B" : String(format: "%.1f %@", value, units[index])
    }

    @discardableResult
    public func remove(_ entry: Entry) -> Int64 {
        try? FileManager.default.removeItem(atPath: entry.path)
        return FileManager.default.fileExists(atPath: entry.path) ? 0 : entry.bytes
    }

    /// Empties the cache and reports how many bytes were freed.
    @discardableResult
    public func clear() -> Int64 {
        let freed = totalBytes()
        try? FileManager.default.removeItem(atPath: directory)
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return freed
    }

    /// Removes entries for packages that are no longer installed *and* no longer
    /// queued, which is the part of the cache that is pure waste.
    @discardableResult
    public func removeEntries(notMentioning names: Set<String>) -> (removed: Int, freed: Int64) {
        var removed = 0
        var freed: Int64 = 0
        for entry in entries() {
            // Entries are named `<package>_<version>_<architecture>.deb`, so the
            // package name is everything before the first underscore — which
            // package names cannot contain.
            let packageName = entry.name.split(separator: "_").first.map(String.init) ?? entry.name
            guard !names.contains(packageName) else { continue }
            freed += remove(entry)
            removed += 1
        }
        return (removed, freed)
    }
}
