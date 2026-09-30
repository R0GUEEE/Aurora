import Foundation

/// A single package name inside a dependency clause, with the optional
/// version relation and architecture qualifier.
///
/// `libfoo:any (>= 1.2) | libbar` produces a clause with two terms: the first is
/// `libfoo` with `:any` and a `>= 1.2` constraint, the second is `libbar`.
public struct DependencyTerm: Hashable, Sendable, CustomStringConvertible {
    public let name: String
    /// An architecture qualifier such as `any`, `native` or `iphoneos-arm64`.
    public let architectureQualifier: String?
    public let constraint: DebianVersionConstraint?

    public init(name: String, architectureQualifier: String? = nil, constraint: DebianVersionConstraint? = nil) {
        self.name = name
        self.architectureQualifier = architectureQualifier
        self.constraint = constraint
    }

    /// `:any` means "satisfied by any architecture", which the resolver treats as
    /// allowing a foreign-architecture provider.
    public var isArchitectureAny: Bool { architectureQualifier?.lowercased() == "any" }

    public var description: String {
        var text = name
        if let architectureQualifier { text += ":\(architectureQualifier)" }
        if let constraint { text += " \(constraint)" }
        return text
    }

    /// Parses one alternative of a clause, tolerating the architecture
    /// restrictions (`[amd64]`) and build profiles (`<!nocheck>`) that appear in
    /// binary package fields from time to time.
    public static func parse(_ text: Substring) -> DependencyTerm? {
        var body = text.trimmingCharacters(in: .whitespaces)
        // Drop architecture restrictions and build profiles: they are a
        // build-time concept and meaningless for a binary install.
        for (opener, closer) in [("[", "]"), ("<", ">")] as [(Character, Character)] {
            while let start = body.firstIndex(of: opener),
                  let stop = body[start...].firstIndex(of: closer) {
                body.removeSubrange(start...stop)
            }
        }
        body = body.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }

        var name = body
        var constraint: DebianVersionConstraint?
        if let paren = body.firstIndex(of: "(") {
            name = String(body[body.startIndex..<paren]).trimmingCharacters(in: .whitespaces)
            if let close = body[paren...].firstIndex(of: ")") {
                let inner = body[body.index(after: paren)..<close].trimmingCharacters(in: .whitespaces)
                constraint = parseConstraint(inner)
            }
        }

        var architectureQualifier: String?
        if let colon = name.firstIndex(of: ":") {
            architectureQualifier = String(name[name.index(after: colon)...])
            name = String(name[name.startIndex..<colon])
        }

        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return DependencyTerm(name: name, architectureQualifier: architectureQualifier, constraint: constraint)
    }

    static func parseConstraint(_ text: String) -> DebianVersionConstraint? {
        // Longest operator wins: `<<` must not be read as `<` followed by `<`.
        for candidate in [">=", "<=", "<<", ">>", "=", "<", ">"] {
            if text.hasPrefix(candidate) {
                let versionText = text.dropFirst(candidate.count).trimmingCharacters(in: .whitespaces)
                guard !versionText.isEmpty,
                      let relation = DebianVersionConstraint.Relation(rawOperator: candidate) else { return nil }
                return DebianVersionConstraint(relation: relation, version: DebianVersion(versionText))
            }
        }
        return nil
    }
}

/// One clause: a set of alternatives, any one of which satisfies the dependency.
public struct DependencyClause: Hashable, Sendable, CustomStringConvertible {
    public let alternatives: [DependencyTerm]

    public init(alternatives: [DependencyTerm]) {
        self.alternatives = alternatives
    }

    public var description: String {
        alternatives.map(\.description).joined(separator: " | ")
    }
}

/// A whole dependency field: an AND of clauses.
public struct DependencyList: Hashable, Sendable, CustomStringConvertible {
    public let clauses: [DependencyClause]

    public init(clauses: [DependencyClause]) {
        self.clauses = clauses
    }

    public var isEmpty: Bool { clauses.isEmpty }

    /// Every alternative mentioned anywhere, for dependency-graph previews.
    public var allTerms: [DependencyTerm] { clauses.flatMap(\.alternatives) }

    public var description: String { clauses.map(\.description).joined(separator: ", ") }

    public static func parse(_ text: String) -> DependencyList {
        var clauses: [DependencyClause] = []
        for rawClause in text.split(separator: ",") {
            let alternatives = rawClause
                .split(separator: "|")
                .compactMap { DependencyTerm.parse($0) }
            if !alternatives.isEmpty {
                clauses.append(DependencyClause(alternatives: alternatives))
            }
        }
        return DependencyList(clauses: clauses)
    }
}

/// The relation fields a resolver needs, resolved once per package instead of
/// re-parsing strings every time a candidate is considered.
public struct PackageRelations: Hashable, Sendable {
    public var depends: DependencyList
    public var preDepends: DependencyList
    public var recommends: DependencyList
    public var suggests: DependencyList
    public var conflicts: DependencyList
    public var breaks: DependencyList
    public var replaces: DependencyList
    public var provides: [ProvidedName]

    /// A virtual name offered by this package.
    ///
    /// `Provides: mail-transport-agent (= 1.0)` carries a version, and only a
    /// versioned `Provides` may satisfy a versioned dependency on the virtual
    /// name — an unversioned one satisfies only unversioned dependencies. Getting
    /// this wrong silently installs packages that will not run.
    public struct ProvidedName: Hashable, Sendable, CustomStringConvertible {
        public let name: String
        public let version: DebianVersion?
        public var description: String { version.map { "\(name) (= \($0.raw))" } ?? name }
    }

    public init(stanza: ControlStanza) {
        self.depends = DependencyList.parse(stanza.string("Depends") ?? "")
        self.preDepends = DependencyList.parse(stanza.string("Pre-Depends") ?? "")
        self.recommends = DependencyList.parse(stanza.string("Recommends") ?? "")
        self.suggests = DependencyList.parse(stanza.string("Suggests") ?? "")
        self.conflicts = DependencyList.parse(stanza.string("Conflicts") ?? "")
        self.breaks = DependencyList.parse(stanza.string("Breaks") ?? "")
        self.replaces = DependencyList.parse(stanza.string("Replaces") ?? "")
        self.provides = Self.parseProvides(stanza.string("Provides") ?? "")
    }

    static func parseProvides(_ text: String) -> [ProvidedName] {
        text.split(separator: ",").compactMap { raw in
            let term = DependencyTerm.parse(raw)
            guard let term else { return nil }
            // `Provides` may carry `(= x)` constraints only; `>=` is not valid there.
            return ProvidedName(name: term.name, version: term.constraint?.version)
        }
    }
}
