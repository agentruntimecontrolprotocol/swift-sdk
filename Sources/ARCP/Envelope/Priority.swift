/// Envelope priority. RFC §6.5.
public enum Priority: String, Sendable, Codable, CaseIterable, Hashable {
    case low
    case normal
    case high
    case critical

    /// Default priority when the field is omitted on the wire.
    public static let `default`: Priority = .normal

    /// Numeric ordering for scheduler comparisons. Higher value sorts first.
    public var rank: Int {
        switch self {
        case .low: return 0
        case .normal: return 1
        case .high: return 2
        case .critical: return 3
        }
    }
}
