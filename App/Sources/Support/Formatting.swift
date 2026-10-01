import Foundation
import AuroraCore

/// Small shared helpers. Nothing here is clever: they exist so the views do not
/// each invent their own formatting.
enum AuroraFormat {

    /// The most useful thing we can say about an error.
    ///
    /// `AuroraCore`'s error types are all `CustomStringConvertible` and explain
    /// themselves ("no dpkg was found (system detected as rootless)"), so prefer
    /// that over `localizedDescription`, which for a plain Swift error is the
    /// useless "The operation couldn't be completed."
    static func message(for error: Error) -> String {
        if let described = error as? CustomStringConvertible {
            let text = described.description
            if !text.isEmpty { return text }
        }
        let localized = error.localizedDescription
        return localized.isEmpty ? "\(error)" : localized
    }

    /// A byte count, for download sizes.
    static func bytes(_ count: Int?) -> String {
        guard let count, count > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    /// `Installed-Size` is in kibibytes, as dpkg documents it.
    static func kibibytes(_ count: Int?) -> String {
        guard let count, count > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(count) * 1024, countStyle: .file)
    }

    /// A relative date ("3 minutes ago") for the last-refresh column.
    static func relative(_ date: Date?) -> String {
        guard let date else { return "never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// A short duration, for the transaction result.
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "less than a second" }
        if seconds < 60 { return String(format: "%.1f seconds", seconds) }
        let minutes = Int(seconds / 60)
        let remainder = Int(seconds.truncatingRemainder(dividingBy: 60))
        return "\(minutes)m \(remainder)s"
    }
}

/// The app's own version, read from the bundle so the About screen cannot drift
/// away from `Resources/Info.plist`.
enum AuroraBuildInfo {
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }

    static var build: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
    }

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.r0gueee.aurora"
    }
}
