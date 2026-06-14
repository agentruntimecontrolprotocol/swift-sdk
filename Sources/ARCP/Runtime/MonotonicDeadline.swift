import Foundation

/// A lease deadline evaluated against a monotonic clock (ARCP v1.1 §14,
/// "Lease expiration clock").
///
/// The wire `expires_at` is a wall-clock instant, but §14 requires runtimes
/// to evaluate expiry against a monotonic, NTP-disciplined source so that a
/// backward clock step cannot cause premature (or a forward step delayed)
/// expiration. We anchor the wall-clock deadline to a `ContinuousClock`
/// reading captured at construction and measure elapsed time monotonically
/// from there, applying a small bounded grace per §14.
public struct MonotonicDeadline: Sendable, Hashable {
    /// The wall-clock `expires_at` (used only for wire timestamps / errors).
    public let wallDeadline: Date
    private let referenceWall: Date
    private let referenceMono: ContinuousClock.Instant

    /// Bounded grace allowed past the computed deadline before a lease is
    /// considered expired (§14 "SHOULD allow a small bounded grace"). Kept
    /// small so leases stay responsive while tolerating minor clock skew.
    public static let grace: Duration = .milliseconds(250)

    public init(wallDeadline: Date, now: Date = Date(), monoNow: ContinuousClock.Instant = ContinuousClock.now) {
        self.wallDeadline = wallDeadline
        self.referenceWall = now
        self.referenceMono = monoNow
    }

    /// Seconds remaining at the reference instant.
    private var remainingAtReference: Double {
        wallDeadline.timeIntervalSince(referenceWall)
    }

    /// True once the monotonic elapsed time exceeds the remaining budget plus
    /// the bounded grace.
    public func isExpired(monoNow: ContinuousClock.Instant = ContinuousClock.now) -> Bool {
        let elapsed = referenceMono.duration(to: monoNow).timeInterval
        return elapsed > remainingAtReference + Self.grace.timeInterval
    }

    public static func == (lhs: MonotonicDeadline, rhs: MonotonicDeadline) -> Bool {
        lhs.wallDeadline == rhs.wallDeadline
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(wallDeadline)
    }
}
