import Foundation

/// One field of a Debian control paragraph, keeping the original spelling and the
/// original line structure of the value (continuation lines are folded back in).
public struct ControlField: Hashable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// A Debian control paragraph: the unit that `Packages`, `Release` and the dpkg
/// `status` file are made of.
///
/// The representation is lossless on purpose. When Aurora rewrites
/// `/var/lib/dpkg/status` after a transaction it must not drop fields it does not
/// understand (maintainer scripts rely on them, and dpkg itself preserves them),
/// so stanzas keep field order, field spelling and line structure, and can be
/// serialised back byte-for-byte.
public struct ControlStanza: Hashable, Sendable {

    /// Fields in their original order.
    public private(set) var fields: [ControlField]

    /// Lowercased name → index into `fields`. Debian field names are
    /// case-insensitive.
    private var lookup: [String: Int]

    public init(fields: [ControlField] = []) {
        self.fields = fields
        var lookup: [String: Int] = [:]
        lookup.reserveCapacity(fields.count)
        for (index, field) in fields.enumerated() where lookup[field.name.lowercased()] == nil {
            lookup[field.name.lowercased()] = index
        }
        self.lookup = lookup
    }

    public var isEmpty: Bool { fields.isEmpty }

    public subscript(name: String) -> String? {
        get {
            guard let index = lookup[name.lowercased()], index < fields.count else { return nil }
            return fields[index].value
        }
        set {
            let key = name.lowercased()
            if let value = newValue {
                if let index = lookup[key], index < fields.count {
                    fields[index].value = value
                } else {
                    lookup[key] = fields.count
                    fields.append(ControlField(name: name, value: value))
                }
            } else if let index = lookup[key], index < fields.count {
                fields.remove(at: index)
                rebuildLookup()
            }
        }
    }

    public func has(_ name: String) -> Bool { lookup[name.lowercased()] != nil }

    /// Appends a continuation line to the most recently added field.
    ///
    /// The parser needs this because `fields` is `private(set)`: a multi-line
    /// value is built by this type, not by rewriting the array from outside.
    mutating func appendContinuation(_ text: String) {
        guard !fields.isEmpty else { return }
        fields[fields.count - 1].value += "\n" + text
    }

    public func string(_ name: String) -> String? {
        guard let value = self[name], !value.isEmpty else { return nil }
        return value
    }

    public func int(_ name: String) -> Int? {
        guard let value = string(name) else { return nil }
        return Int(value.trimmingCharacters(in: .whitespaces))
    }

    public func bool(_ name: String) -> Bool {
        guard let value = string(name)?.lowercased() else { return false }
        return value == "yes" || value == "true"
    }

    /// Splits a comma-separated field such as `Tag` or `Suggests` without
    /// interpreting the individual elements.
    public func commaSeparated(_ name: String) -> [String] {
        guard let value = string(name) else { return [] }
        return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The conventional multi-line `Description`: first line is the synopsis,
    /// the rest is the extended body, with ` .` marking a blank line.
    public var descriptionParts: (synopsis: String, body: String?) {
        guard let value = string("Description") else { return ("", nil) }
        var lines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return ("", nil) }
        let synopsis = lines.removeFirst()
        guard !lines.isEmpty else { return (synopsis, nil) }
        let body = lines.map { $0 == "." ? "" : $0 }.joined(separator: "\n")
        return (synopsis, body)
    }

    /// Renders the stanza in control-file format, terminated by a blank line.
    ///
    /// An empty continuation line is written as a lone space, except inside
    /// `Description`, where the ` .` convention is what every other tool expects.
    /// Either way, re-parsing the output yields the same stanza, which is the
    /// property the dpkg status writer depends on.
    public var serialized: String {
        let isDescription = fields.contains { $0.name.lowercased() == "description" }
        var output = ""
        for field in fields {
            var lines = field.value.split(separator: "\n", omittingEmptySubsequences: false)
            let first = lines.isEmpty ? "" : String(lines.removeFirst())
            output += "\(field.name): \(first)\n"
            for line in lines {
                if line.isEmpty {
                    output += (isDescription && field.name.lowercased() == "description") ? " .\n" : " \n"
                } else {
                    output += " \(line)\n"
                }
            }
        }
        output += "\n"
        return output
    }

    private mutating func rebuildLookup() {
        var lookup: [String: Int] = [:]
        lookup.reserveCapacity(fields.count)
        for (index, field) in fields.enumerated() where lookup[field.name.lowercased()] == nil {
            lookup[field.name.lowercased()] = index
        }
        self.lookup = lookup
    }
}

/// Parser for the RFC822-style format used by `Packages`, `Sources`, `Release`
/// and the dpkg `status` file.
public enum ControlParser {

    /// Parses every paragraph in `text`, skipping blank runs and malformed lines
    /// (real repositories contain both, and refusing to load an index over one bad
    /// line would be worse than ignoring it).
    public static func parse(_ text: String) -> [ControlStanza] {
        // Swift treats "\r\n" as a *single* grapheme cluster, so
        // `firstIndex(of: "\n")` never matches a line ending in a CRLF file and
        // the whole document would parse as one field. Normalise first: it also
        // folds lone CRs, which is how files edited on classic Mac line endings
        // arrive. The byte-level check keeps the common LF-only case allocation
        // free, since package indexes are megabytes of text.
        let normalized: String
        if text.utf8.contains(13) {
            normalized = text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
        } else {
            normalized = text
        }

        var stanzas: [ControlStanza] = []
        var current = ControlStanza()
        var index = normalized.startIndex
        let end = normalized.endIndex

        while index < end {
            let lineEnd = normalized[index...].firstIndex(of: "\n") ?? end
            let line = normalized[index..<lineEnd]
            index = lineEnd == end ? end : normalized.index(after: lineEnd)

            if line.isEmpty {
                if !current.isEmpty {
                    stanzas.append(current)
                    current = ControlStanza()
                }
                continue
            }

            if line.first == " " || line.first == "\t" {
                // Continuation of the previous field: strip exactly one leading
                // space or tab, as dpkg does.
                current.appendContinuation(String(line.dropFirst()))
                continue
            }

            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon])
            var value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
            current[name] = value
        }

        if !current.isEmpty { stanzas.append(current) }
        return stanzas
    }

    public static func parse(_ data: Data) -> [ControlStanza] {
        parse(String(decoding: data, as: UTF8.self))
    }
}
