import Foundation
import Testing

@testable import ARCP

@Suite("LeaseManager validation (issue #48)")
struct LeaseManagerTests {
    @Test("grant rejects zero seconds with invalidArgument")
    func grantRejectsZero() async {
        let manager = LeaseManager(sessionId: SessionId.random(), send: { _ in })
        await #expect(throws: ARCPError.self) {
            try await manager.grant(
                permission: "fs.read",
                resource: "/tmp",
                operation: "read",
                seconds: 0
            )
        }
    }

    @Test("grant rejects negative seconds")
    func grantRejectsNegative() async {
        let manager = LeaseManager(sessionId: SessionId.random(), send: { _ in })
        await #expect(throws: ARCPError.self) {
            try await manager.grant(
                permission: "fs.read",
                resource: "/tmp",
                operation: "read",
                seconds: -5
            )
        }
    }

    @Test("refresh rejects nonpositive seconds")
    func refreshRejectsNonpositive() async throws {
        let manager = LeaseManager(sessionId: SessionId.random(), send: { _ in })
        let leaseId = try await manager.grant(
            permission: "fs.read",
            resource: "/tmp",
            operation: "read",
            seconds: 60
        )
        await #expect(throws: ARCPError.self) {
            try await manager.refresh(leaseId: leaseId, seconds: 0)
        }
        await #expect(throws: ARCPError.self) {
            try await manager.refresh(leaseId: leaseId, seconds: -10)
        }
    }

    @Test("grant accepts positive seconds")
    func grantPositive() async throws {
        let manager = LeaseManager(sessionId: SessionId.random(), send: { _ in })
        let id = try await manager.grant(
            permission: "fs.read",
            resource: "/tmp",
            operation: "read",
            seconds: 60
        )
        let status = await manager.status(id)
        #expect(status == .active)
    }
}
