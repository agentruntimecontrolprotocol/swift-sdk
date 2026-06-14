import Foundation

/// `model.use` lease capability (ARCP v1.1 §9.7).
///
/// Patterns are case-sensitive and support `*` as a glob wildcard.
public struct ModelUse: Sendable, Codable, Hashable {
    public var patterns: [String]

    public init(patterns: [String]) {
        self.patterns = patterns
    }

    public func matches(_ model: String) -> Bool {
        patterns.contains { Self.matches(pattern: $0, value: model) }
    }

    /// Returns the first child pattern not covered by this parent set, where
    /// "covers" means every concrete model name the child pattern can match
    /// is also matched by some parent pattern.
    public func subsetViolation(of child: ModelUse) -> String? {
        for childPattern in child.patterns where !covers(childPattern) {
            return childPattern
        }
        return nil
    }

    private func covers(_ childPattern: String) -> Bool {
        patterns.contains { Self.patternCovers(parent: $0, child: childPattern) }
    }

    /// Returns `true` when every model string matched by `child` is also
    /// matched by `parent`. The check is conservative: it returns `false`
    /// when it cannot prove subset.
    static func patternCovers(parent: String, child: String) -> Bool {
        if parent == "*" { return true }
        if parent == child { return true }
        // A literal-only parent (no wildcard) cannot cover a wildcard child:
        // the child expands to strings the literal parent does not match
        // (e.g. parent "abc" vs child "abc*abc"). Reject to avoid a subset
        // false positive that would let a capability expand.
        if !parent.contains("*") && child.contains("*") { return false }
        // If child has no wildcards, defer to literal matching.
        if !child.contains("*") {
            return matches(pattern: parent, value: child)
        }
        // Both contain wildcards. Decompose into literal segments and check
        // whether every concrete instantiation of `child` is matchable by
        // `parent`. We do this by computing the constraints `child`'s
        // segments impose and ensuring `parent`'s segments are at least as
        // permissive (prefix and suffix) and that every parent middle segment
        // can be located inside the child's segment sequence.
        let parentSegs = split(parent)
        let childSegs = split(child)

        // Prefix constraint: parent's first literal must be a prefix of
        // child's first literal (parent allows at least the strings that
        // start with parent.first; child's strings start with child.first).
        let parentFirst = parentSegs.first ?? ""
        let childFirst = childSegs.first ?? ""
        if !childFirst.hasPrefix(parentFirst) { return false }

        // Suffix constraint: the last segment (after the final `*` for
        // patterns containing one) anchors the suffix. If parent ends with a
        // literal (i.e. does NOT end with `*`), child must also end with a
        // literal that has parent's suffix as a suffix.
        let parentEndsWithWildcard = parent.hasSuffix("*")
        let childEndsWithWildcard = child.hasSuffix("*")
        let parentLast = parentSegs.last ?? ""
        let childLast = childSegs.last ?? ""
        if !parentEndsWithWildcard {
            if childEndsWithWildcard { return false }
            if !childLast.hasSuffix(parentLast) { return false }
        }

        // Middle constraint: every interior literal of parent must appear in
        // some interior literal of child, in order. We do not try to fold a
        // parent middle into the child's anchored prefix/suffix segments — a
        // wildcard in the child between two literals would otherwise let the
        // child match a string the parent cannot.
        let parentMiddle = Array(parentSegs.dropFirst().dropLast())
        let childMiddle = Array(childSegs.dropFirst().dropLast())
        var cursor = 0
        for needle in parentMiddle where !needle.isEmpty {
            var found = false
            while cursor < childMiddle.count {
                if childMiddle[cursor].contains(needle) {
                    found = true
                    cursor += 1
                    break
                }
                cursor += 1
            }
            if !found { return false }
        }
        return true
    }

    private static func split(_ pattern: String) -> [String] {
        pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
    }

    private static func matches(pattern: String, value: String) -> Bool {
        let parts = split(pattern)
        if parts.count == 1 { return pattern == value }

        var cursor = value.startIndex
        for (index, part) in parts.enumerated() where !part.isEmpty {
            if index == 0 {
                guard value[cursor...].hasPrefix(part) else { return false }
                cursor = value.index(cursor, offsetBy: part.count)
                continue
            }
            guard let range = value[cursor...].range(of: part) else { return false }
            cursor = range.upperBound
        }
        if let last = parts.last, !last.isEmpty, !value.hasSuffix(last) {
            return false
        }
        return true
    }
}
