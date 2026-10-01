import Foundation

/// A `.deb` the user supplied directly — downloaded in Safari, copied over from a
/// computer, or built on the device — rather than one from a repository.
///
/// This is the path a package manager needs when a repository is gone but its
/// packages are not, and it is also how a developer installs what they just built.
/// The record is synthesised from the archive's own control file, so the queue, the
/// dependency resolver and the installer treat it like any other package: its
/// dependencies are still resolved against the repositories, and its control file
/// is still compared against itself before dpkg runs.
public struct LocalPackage: Sendable {

    public let path: String
    public let record: PackageRecord
    public let archive: DebArchive
    public let maintainerScripts: [String: String]
    public let byteSize: Int64

    public var name: String { record.name }
    public var version: DebianVersion { record.version }
}

public enum LocalPackageError: Error, CustomStringConvertible {
    case notReadable(String, underlying: Error)
    case notAPackage(String)
    case missingControlField(String, field: String)
    case architectureMismatch(package: String, architecture: String, device: String)

    public var description: String {
        switch self {
        case .notReadable(let path, let underlying):
            return "\(path) could not be read: \(underlying)"
        case .notAPackage(let path):
            return "\(path) is not a Debian package"
        case .missingControlField(let path, let field):
            return "\(path) has no \(field) field in its control file"
        case .architectureMismatch(let package, let architecture, let device):
            return "\(package) is built for \(architecture) and this device is \(device)"
        }
    }
}

public enum LocalPackageLoader {

    /// Identity given to records that did not come from a repository.
    ///
    /// The installer recognises it and refuses to try to download anything for
    /// such a record: the file is already on disk, which is the whole point.
    public static let repositoryURL = "file:///local"

    public static func isLocalRecord(_ record: PackageRecord) -> Bool {
        record.origin?.url == repositoryURL
    }

    /// Reads a `.deb` from disk and turns it into something the queue can stage.
    public static func load(
        path: String,
        deviceArchitecture: String? = nil,
        requireCompatibleArchitecture: Bool = false
    ) throws -> LocalPackage {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        let archive: DebArchive
        do {
            archive = try DebArchive(path: path)
        } catch let error as DebArchive.Error {
            throw LocalPackageError.notAPackage("\(path) (\(error))")
        } catch {
            throw LocalPackageError.notReadable(path, underlying: error)
        }

        let stanza: ControlStanza
        do {
            stanza = try archive.controlStanza()
        } catch {
            throw LocalPackageError.notAPackage("\(path) (\(error))")
        }
        guard stanza.string("Package") != nil else {
            throw LocalPackageError.missingControlField(path, field: "Package")
        }
        guard stanza.string("Version") != nil else {
            throw LocalPackageError.missingControlField(path, field: "Version")
        }

        var recordStanza = stanza
        // Keep the archive where it is and say so: `Filename` is a path here, not
        // a repository-relative name.
        recordStanza["Filename"] = path
        recordStanza["Size"] = "\(size)"
        if recordStanza.string("Architecture") == nil {
            recordStanza["Architecture"] = deviceArchitecture ?? "all"
        }

        let record = PackageRecord(
            stanza: recordStanza,
            origin: RepositoryID(url: repositoryURL, suite: "local", component: "")
        )

        if requireCompatibleArchitecture, let device = deviceArchitecture,
           record.architecture != "all", record.architecture != device {
            throw LocalPackageError.architectureMismatch(
                package: record.name,
                architecture: record.architecture,
                device: device
            )
        }

        return LocalPackage(
            path: path,
            record: record,
            archive: archive,
            maintainerScripts: (try? archive.maintainerScripts()) ?? [:],
            byteSize: size
        )
    }

    /// Every `.deb` in a directory, for the "install everything in here" case.
    public static func loadAll(in directory: String, deviceArchitecture: String? = nil) -> [LocalPackage] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return names
            .filter { $0.hasSuffix(".deb") }
            .sorted()
            .compactMap { try? load(path: (directory as NSString).appendingPathComponent($0), deviceArchitecture: deviceArchitecture) }
    }
}
