import Foundation

public enum ModelUsePolicy {
    public static func check(_ lease: ModelUse?, model: String) throws {
        guard let lease, !lease.matches(model) else { return }
        throw ARCPError.permissionDenied(permission: "model.use", resource: model)
    }

    public static func assertSubset(parent: ModelUse?, child: ModelUse?) throws {
        guard let child else { return }
        guard let parent else {
            throw ARCPError.leaseSubsetViolation(detail: "model.use \(child.patterns.first ?? "*") is not allowed")
        }
        if let violation = parent.subsetViolation(of: child) {
            throw ARCPError.leaseSubsetViolation(detail: "model.use \(violation) exceeds parent lease")
        }
    }
}
