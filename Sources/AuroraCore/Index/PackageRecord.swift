import Foundation

/// Identifies which repository (and which index file) a record came from.
///
/// Aurora keeps every candidate in one pool and needs to tell a user which repo a
/// version came from — and needs to know which repo to refresh when a package
/// index changes.
public struct RepositoryID: Hashable, Sendable, CustomStringConvertible {
    public let url: String
    public let suite: String
    public let component: String

    public init(url: String, suite: String, component: String) {
        self.url = url
        self.suite = suite
        self.component = component
    }

    public var description: String {
        component.isEmpty ? "\(url) \(suite)" : "\(url) \(suite)/\(component)"
    }
}

/// One package as it appears in a repository index.
///
/// This is a *view* over the parsed stanza rather than a copy of every field:
/// repositories publish fields Aurora does not understand, and the queue, the
/// detail screen and the installer all need to round-trip them.
public struct PackageRecord: Hashable, Sendable, Identifiable {

    public var stanza: ControlStanza
    public let origin: RepositoryID?
    public let relations: PackageRelations
    public let version: DebianVersion

    public init(stanza: ControlStanza, origin: RepositoryID? = nil) {
        self.stanza = stanza
        self.origin = origin
        self.relations = PackageRelations(stanza: stanza)
        self.version = DebianVersion(stanza.string("Version") ?? "0")
    }

    public var id: String { "\(name):\(architecture)=\(version.raw)" }

    public var name: String { stanza.string("Package") ?? stanza.string("Name") ?? "" }

    /// The name to show in a list: repositories sometimes ship a prettier `Name`.
    public var displayName: String { stanza.string("Name") ?? name }

    public var architecture: String { stanza.string("Architecture") ?? "all" }

    public var section: String { stanza.string("Section") ?? "" }
    public var priority: String { stanza.string("Priority") ?? "optional" }
    public var maintainer: String { stanza.string("Maintainer") ?? stanza.string("Author") ?? "" }
    public var homepage: String? { stanza.string("Homepage") }
    public var author: String? { stanza.string("Author") }
    public var depiction: String? { stanza.string("Depiction") }
    public var nativeDepiction: String? { stanza.string("SileoDepiction") ?? stanza.string("ModernDepiction") }
    public var icon: String? { stanza.string("Icon") }
    public var tags: [String] { stanza.commaSeparated("Tag") }

    /// `Installed-Size` is in kibibytes, as dpkg documents it.
    public var installedSize: Int? { stanza.int("Installed-Size") }
    public var downloadSize: Int? { stanza.int("Size") }

    public var filename: String? { stanza.string("Filename") }
    public var sha256: String? { stanza.string("SHA256") }
    public var sha512: String? { stanza.string("SHA512") }
    public var md5: String? { stanza.string("MD5sum") }

    public var isEssential: Bool { stanza.bool("Essential") }
    public var isRequiredPriority: Bool { priority.lowercased() == "required" }
    /// Packages dpkg refuses to remove without `--force-remove-essential`.
    public var isProtected: Bool { isEssential || isRequiredPriority }

    public var multiArch: String? { stanza.string("Multi-Arch") }
    /// Installed once per architecture, and every instance must be the same
    /// version — a mismatched set is something dpkg refuses to configure.
    public var isMultiArchSame: Bool { multiArch?.lowercased() == "same" }
    /// Interface does not depend on the architecture, so any instance satisfies a
    /// dependency (this is what lets an `arm` CLI tool satisfy an `arm64` package).
    public var isMultiArchForeign: Bool { multiArch?.lowercased() == "foreign" }
    /// The instance is architecture-independent.
    public var isArchitectureIndependent: Bool { architecture == "all" }

    /// Identifies one *instance* of a package: a co-installable package gets one
    /// entry per architecture, everything else one entry per name.
    public var instanceKey: String {
        isArchitectureIndependent ? name : "\(name):\(architecture)"
    }

    public var synopsis: String { stanza.descriptionParts.synopsis }
    public var extendedDescription: String? { stanza.descriptionParts.body }

    /// The strongest digest the record carries, with its algorithm.
    public var bestDigest: (algorithm: HashAlgorithm, hex: String)? {
        for algorithm in HashAlgorithm.byStrength {
            let value: String?
            switch algorithm {
            case .sha256: value = sha256
            case .sha512: value = sha512
            case .md5: value = md5
            case .sha1: value = stanza.string("SHA1")
            }
            if let value, !value.isEmpty { return (algorithm, value) }
        }
        return nil
    }

    /// dpkg-style qualified name (`libfoo:iphoneos-arm64`), used for status writes.
    public var qualifiedName: String {
        architecture == "all" ? name : "\(name):\(architecture)"
    }

    public var description: String { "\(name) \(version.raw) [\(architecture)]" }
}
