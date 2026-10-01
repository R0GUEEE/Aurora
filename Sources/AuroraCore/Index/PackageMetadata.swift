import Foundation

public extension PackageRecord {
    var changelogURL: String? {
        stanza.string("Changelog") ?? stanza.string("ChangeLog") ?? stanza.string("Changelog-URL")
    }
    var supportURL: String? {
        stanza.string("Support") ?? stanza.string("Support-URL") ?? stanza.string("Bug-Reports")
    }
    var depictionURL: String? { nativeDepiction ?? depiction }
    var minimumOSVersion: String? {
        stanza.string("Min-iOS") ?? stanza.string("Minimum-iOS") ?? stanza.string("MinimumFirmware")
    }
    var maximumOSVersion: String? {
        stanza.string("Max-iOS") ?? stanza.string("Maximum-iOS") ?? stanza.string("MaximumFirmware")
    }
    var commercial: Bool {
        stanza.bool("Commercial") || (stanza.string("Tag") ?? "").lowercased().contains("commercial")
    }
    var packageTags: Set<String> {
        Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
    }
}

public struct PackageCompatibility: Sendable, Hashable {
    public enum Level: String, Sendable, Hashable { case compatible, warning, incompatible }
    public let level: Level
    public let reasons: [String]

    public init(level: Level, reasons: [String] = []) {
        self.level = level
        self.reasons = reasons
    }

    public static func evaluate(
        _ record: PackageRecord,
        environment: JailbreakEnvironment,
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> PackageCompatibility {
        var hard: [String] = []
        var warnings: [String] = []
        let arch = record.architecture.lowercased()

        switch environment.layout {
        case .rootless:
            if arch != "all" && arch != "iphoneos-arm64" {
                hard.append("Architecture \(record.architecture) is not rootless-compatible.")
            }
        case .rootful:
            if arch != "all" && arch != environment.architecture.lowercased() && arch != "iphoneos-arm" {
                warnings.append("Package architecture is \(record.architecture); device architecture is \(environment.architecture).")
            }
        case .notJailbroken:
            warnings.append("No jailbreak environment is currently available.")
        }

        let current = VersionNumber(operatingSystemVersion)
        if let minimum = record.minimumOSVersion, let min = VersionNumber(minimum), current < min {
            hard.append("Requires iOS \(minimum) or newer.")
        }
        if let maximum = record.maximumOSVersion, let max = VersionNumber(maximum), current > max {
            hard.append("Supports up to iOS \(maximum).")
        }

        if !hard.isEmpty { return .init(level: .incompatible, reasons: hard + warnings) }
        if !warnings.isEmpty { return .init(level: .warning, reasons: warnings) }
        return .init(level: .compatible)
    }
}

private struct VersionNumber: Comparable {
    let parts: [Int]

    init?(_ raw: String) {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let parsed = cleaned.split(separator: ".").prefix(4).map { part -> Int in
            let digits = part.prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
        guard !parsed.isEmpty else { return nil }
        parts = parsed
    }

    init(_ version: OperatingSystemVersion) {
        parts = [version.majorVersion, version.minorVersion, version.patchVersion]
    }

    static func < (lhs: VersionNumber, rhs: VersionNumber) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let l = index < lhs.parts.count ? lhs.parts[index] : 0
            let r = index < rhs.parts.count ? rhs.parts[index] : 0
            if l != r { return l < r }
        }
        return false
    }
}

/// Import/export helpers compatible with URL lists, classic APT lines and Sileo's
/// deb822 `sileo.sources` format.
public enum SourceInterchange {
    public static func parse(_ text: String) -> [RepositorySource] {
        var result: [RepositorySource] = []
        var seen: Set<String> = []

        func append(_ source: RepositorySource) {
            guard source.isValid else { return }
            let key = "\(source.normalizedURL.lowercased())|\(source.suite)"
            if seen.insert(key).inserted { result.append(source) }
        }

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        for block in normalized.components(separatedBy: "\n\n") {
            let stanzas = ControlParser.parse(block)
            if let stanza = stanzas.first, let uris = stanza.string("URIs"),
               stanza.string("Types")?.split(whereSeparator: \.isWhitespace).contains(where: { $0.lowercased() == "deb" }) == true {
                let urls = uris.split(whereSeparator: \.isWhitespace).map(String.init)
                let suites = (stanza.string("Suites") ?? "./").split(whereSeparator: \.isWhitespace).map(String.init)
                let components = (stanza.string("Components") ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
                let architectures = (stanza.string("Architectures") ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
                let enabled = stanza.string("Enabled")?.lowercased() != "no"
                for url in urls {
                    for suite in suites {
                        append(RepositorySource(
                            name: hostName(url), url: url, suite: suite,
                            components: components, architectures: architectures,
                            isEnabled: enabled
                        ))
                    }
                }
                continue
            }

            for rawLine in block.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, !line.hasPrefix("#") else { continue }
                let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                let source: RepositorySource?

                if fields.first?.lowercased() == "deb", fields.count >= 2 {
                    let urlIndex = fields[1].hasPrefix("[")
                        ? (fields[1...].firstIndex(where: { $0.hasSuffix("]") }).map { $0 + 1 } ?? fields.count)
                        : 1
                    if urlIndex < fields.count {
                        let url = fields[urlIndex]
                        let suite = fields.count > urlIndex + 1 ? fields[urlIndex + 1] : "./"
                        let components = fields.count > urlIndex + 2 ? Array(fields.dropFirst(urlIndex + 2)) : []
                        let options = fields[1..<urlIndex].joined(separator: " ")
                        let architectures = options.split(whereSeparator: \.isWhitespace)
                            .first(where: { $0.hasPrefix("arch=") })
                            .map { String($0.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: "]"))
                                .split(separator: ",").map(String.init) } ?? []
                        source = RepositorySource(
                            name: hostName(url), url: url, suite: suite,
                            components: components, architectures: architectures
                        )
                    } else {
                        source = nil
                    }
                } else if line.hasPrefix("http://") || line.hasPrefix("https://") {
                    source = RepositorySource(name: hostName(line), url: line, suite: "./")
                } else {
                    source = nil
                }

                if let source { append(source) }
            }
        }
        return result
    }

    public static func export(_ sources: [RepositorySource]) -> String {
        sources.map { source in
            if source.isEnabled && source.architectures.isEmpty {
                if source.isFlat { return source.normalizedURL }
                return "deb \(source.normalizedURL) \(source.suite) \(source.components.joined(separator: " "))"
            }
            var fields = [
                "Types: deb",
                "URIs: \(source.normalizedURL)/",
                "Suites: \(source.suite.isEmpty ? "./" : source.suite)",
                "Components: \(source.components.joined(separator: " "))"
            ]
            if !source.architectures.isEmpty {
                fields.append("Architectures: \(source.architectures.joined(separator: " "))")
            }
            if !source.isEnabled { fields.append("Enabled: no") }
            return fields.joined(separator: "\n")
        }.joined(separator: "\n\n") + (sources.isEmpty ? "" : "\n")
    }

    private static func hostName(_ raw: String) -> String {
        URL(string: raw)?.host ?? raw
    }
}
