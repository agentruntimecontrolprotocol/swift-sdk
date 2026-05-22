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

    /// Returns the first child pattern not covered by this parent set.
    public func subsetViolation(of child: ModelUse) -> String? {
        for childPattern in child.patterns where !covers(childPattern) {
            return childPattern
        }
        return nil
    }

    private func covers(_ childPattern: String) -> Bool {
        patterns.contains { parent in
            parent == "*"
                || parent == childPattern
                || Self.literalPrefix(parent).map { childPattern.hasPrefix($0) } == true
        }
    }

    private static func literalPrefix(_ pattern: String) -> String? {
        guard let star = pattern.firstIndex(of: "*") else { return nil }
        return String(pattern[..<star])
    }

    private static func matches(pattern: String, value: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
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
