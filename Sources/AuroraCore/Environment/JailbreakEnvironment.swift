import Foundation

/// Where the jailbreak lives and where its package-management tools are.
///
/// A jailbroken device can lay its filesystem out in two ways, and a client that
/// guesses wrong writes to paths that do not exist:
///
/// * **rootless** — the jailbreak is confined to `/var/jb` (Dopamine, palera1n
///   rootless, and everything built with the `rootless` Theos scheme). dpkg lives
///   at `/var/jb/usr/bin/dpkg`.
/// * **rootful** — the jailbreak owns the real filesystem (unc0ver, checkra1n,
///   palera1n `--force-enable-ssv` variants). dpkg is at `/usr/bin/dpkg`.
public struct JailbreakEnvironment: Sendable {

    public enum Layout: String, Sendable {
        case rootless
        case rootful
        case notJailbroken

        public var isJailbroken: Bool { self != .notJailbroken }
    }

    public let layout: Layout
    /// `/var/jb` for rootless, `/` for rootful.
    public let root: String
    public let architecture: String
    public let dpkgPath: String?
    public let statusFilePath: String

    public init(
        layout: Layout,
        root: String,
        architecture: String,
        dpkgPath: String?,
        statusFilePath: String
    ) {
        self.layout = layout
        self.root = root
        self.architecture = architecture
        self.dpkgPath = dpkgPath
        self.statusFilePath = statusFilePath
    }

    /// Maps a Debian-absolute path (`/usr/bin/foo`) into this layout. The moral
    /// equivalent of Theos' `ROOT_PATH_NS`.
    public func resolve(_ debianPath: String) -> String {
        guard layout == .rootless else { return debianPath }
        guard debianPath.hasPrefix("/") else { return "\(root)/\(debianPath)" }
        if debianPath == "/" { return root }
        // /var and /private/var stay outside the jailbreak root on rootless
        // systems, which is why packages install to /var/jb/var only for their
        // own database.
        return root + debianPath
    }

    public var dpkgDatabaseDirectory: String { resolve("/var/lib/dpkg") }
    public var aptSourcesListDirectory: String? { nil }

    /// Directories searched for binaries we shell out to.
    public var executableSearchPaths: [String] {
        layout == .rootless
            ? ["/var/jb/usr/bin", "/var/jb/usr/local/bin", "/var/jb/bin", "/var/jb/usr/sbin", "/usr/bin", "/bin"]
            : ["/usr/bin", "/usr/local/bin", "/bin", "/usr/sbin"]
    }

    /// Keyrings a signature verifier may trust. Aurora ships no keys of its own;
    /// it uses what the device already trusts plus keys the user pasted.
    public var trustedKeyringPaths: [String] {
        let candidates = [
            resolve("/var/lib/apt/lists"),
            resolve("/etc/apt/trusted.gpg.d"),
            resolve("/etc/apt/keyrings"),
            resolve("/usr/share/keyrings"),
            resolve("/etc/apt/trusted.gpg"),
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0) }
    }

    public var cacheDirectory: String {
        let base = resolve("/var/mobile/Library/Caches/com.r0gueee.aurora")
        return base
    }

    /// The layouts this client should fetch indexes for. `all` is added by the
    /// caller: it is a pseudo-architecture, not a dpkg one.
    public var compatibleArchitectures: [String] {
        switch layout {
        case .rootless: return ["iphoneos-arm64", "iphoneos-arm"]
        case .rootful: return [architecture, "iphoneos-arm", "iphoneos-arm64"]
        case .notJailbroken: return ["iphoneos-arm64", "iphoneos-arm"]
        }
    }

    // MARK: - Detection

    /// Inspects the filesystem once. Everything downstream takes this value, so
    /// there is exactly one place that decides what kind of system we are on.
    public static func detect(fileManager: FileManager = .default) -> JailbreakEnvironment {
        func exists(_ path: String) -> Bool { fileManager.fileExists(atPath: path) }
        func dpkg(in root: String) -> String? {
            let candidates = ["\(root)usr/bin/dpkg", "\(root)usr/local/bin/dpkg", "\(root)bin/dpkg"]
            return candidates.first(where: { exists($0) })
        }

        // Rootless is checked first: on Dopamine both /var/jb/usr/bin/dpkg and a
        // stub /usr/bin/dpkg can be present, and /var/jb is the one that works.
        if exists("/var/jb/var/lib/dpkg") || exists("/var/jb/usr/bin/dpkg") {
            return JailbreakEnvironment(
                layout: .rootless,
                root: "/var/jb",
                architecture: "iphoneos-arm64",
                dpkgPath: dpkg(in: "/var/jb/"),
                statusFilePath: "/var/jb/var/lib/dpkg/status"
            )
        }
        if exists("/var/lib/dpkg/status") || exists("/usr/bin/dpkg") {
            let arch = ProcessRunner.which("dpkg", searchPaths: ["/usr/bin", "/usr/local/bin", "/bin"])
                .flatMap { path -> String? in
                    let result = try? ProcessRunner.run(executable: path, arguments: ["--print-architecture"])
                    guard let result, result.succeeded else { return nil }
                    let trimmed = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
            return JailbreakEnvironment(
                layout: .rootful,
                root: "/",
                architecture: arch ?? "iphoneos-arm",
                dpkgPath: dpkg(in: "/"),
                statusFilePath: "/var/lib/dpkg/status"
            )
        }
        // No jailbreak: the app still runs (as a signed store-front / preview
        // build) but every privileged action is refused with a clear message.
        return JailbreakEnvironment(
            layout: .notJailbroken,
            root: "/",
            architecture: "iphoneos-arm64",
            dpkgPath: nil,
            statusFilePath: "/var/lib/dpkg/status"
        )
    }

    /// Free space at the jailbreak root, used to refuse a transaction that cannot
    /// possibly fit before downloading anything.
    public func freeSpace() -> Int64? {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: root)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    public var isUsable: Bool { layout.isJailbroken && dpkgPath != nil }
}
