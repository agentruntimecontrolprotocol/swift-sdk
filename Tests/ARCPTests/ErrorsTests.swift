import Foundation
import Testing

@testable import ARCP

@Suite("ARCPError (RFC §18)")
struct ErrorsTests {
    @Test("Each case maps to its canonical error code")
    func codeMapping() {
        #expect(ARCPError.cancelled(operation: "x", reason: "y").code == .cancelled)
        #expect(ARCPError.invalidArgument(field: "x", detail: "y").code == .invalidArgument)
        #expect(ARCPError.outOfRange(field: "x", detail: "y").code == .invalidArgument)
        #expect(ARCPError.deadlineExceeded(operation: "x").code == .deadlineExceeded)
        #expect(ARCPError.notFound(kind: "k", id: "i").code == .notFound)
        #expect(ARCPError.alreadyExists(kind: "k", id: "i").code == .alreadyExists)
        #expect(ARCPError.permissionDenied(permission: "p", resource: "r").code == .permissionDenied)
        #expect(ARCPError.resourceExhausted(reason: "x", retryAfter: nil).code == .resourceExhausted)
        #expect(ARCPError.failedPrecondition(detail: "x").code == .failedPrecondition)
        #expect(ARCPError.aborted(reason: "x").code == .aborted)
        #expect(ARCPError.unimplemented(section: "§1", detail: "x").code == .unimplemented)
        #expect(ARCPError.internal(detail: "x", cause: nil).code == .internal)
        #expect(ARCPError.unavailable(reason: "x", retryAfter: nil).code == .unavailable)
        #expect(ARCPError.dataLoss(detail: "x").code == .dataLoss)
        #expect(ARCPError.unauthenticated(detail: "x").code == .unauthenticated)
        #expect(ARCPError.heartbeatLost(jobId: JobId("job_x"), missed: 2).code == .heartbeatLost)
        let date = Date()
        #expect(ARCPError.leaseExpired(leaseId: LeaseId("lease_x"), expiredAt: date).code == .leaseExpired)
        #expect(ARCPError.leaseRevoked(leaseId: LeaseId("lease_x"), reason: "x").code == .leaseRevoked)
        #expect(
            ARCPError.backpressureOverflow(streamOrSubscription: "x", dropped: 1).code
                == .backpressureOverflow)
        #expect(ARCPError.budgetExhausted(detail: "x").code == .budgetExhausted)
        #expect(
            ARCPError.agentVersionNotAvailable(agent: "a", version: "1.0.0").code
                == .agentVersionNotAvailable)
        #expect(ARCPError.unknown(message: "x").code == .unknown)
    }

    @Test("v1.1 error codes serialize to canonical wire strings (§12)")
    func v11WireStrings() throws {
        #expect(ErrorCode.budgetExhausted.rawValue == "BUDGET_EXHAUSTED")
        #expect(ErrorCode.leaseExpired.rawValue == "LEASE_EXPIRED")
        #expect(ErrorCode.agentVersionNotAvailable.rawValue == "AGENT_VERSION_NOT_AVAILABLE")

        let encoder = Envelope.makeEncoder()
        let decoder = Envelope.makeDecoder()
        for code in [
            ErrorCode.budgetExhausted, .leaseExpired, .agentVersionNotAvailable,
        ] {
            let data = try encoder.encode(code)
            let decoded = try decoder.decode(ErrorCode.self, from: data)
            #expect(decoded == code)
        }

        let budgetData = "\"BUDGET_EXHAUSTED\"".data(using: .utf8)!
        #expect(try decoder.decode(ErrorCode.self, from: budgetData) == .budgetExhausted)
        let agentData = "\"AGENT_VERSION_NOT_AVAILABLE\"".data(using: .utf8)!
        #expect(try decoder.decode(ErrorCode.self, from: agentData) == .agentVersionNotAvailable)
    }

    @Test("§12 taxonomy contains the full code set with canonical wire strings")
    func section12Taxonomy() throws {
        #expect(ErrorCode.invalidArgument.rawValue == "INVALID_REQUEST")
        #expect(ErrorCode.internal.rawValue == "INTERNAL_ERROR")
        #expect(ErrorCode.timeout.rawValue == "TIMEOUT")
        #expect(ErrorCode.duplicateKey.rawValue == "DUPLICATE_KEY")
        #expect(ErrorCode.agentNotAvailable.rawValue == "AGENT_NOT_AVAILABLE")
        #expect(ErrorCode.jobNotFound.rawValue == "JOB_NOT_FOUND")
        #expect(ErrorCode.resumeWindowExpired.rawValue == "RESUME_WINDOW_EXPIRED")

        // Legacy/gRPC wire strings still decode to their §12 equivalents.
        let decoder = Envelope.makeDecoder()
        #expect(
            try decoder.decode(ErrorCode.self, from: "\"INVALID_ARGUMENT\"".data(using: .utf8)!)
                == .invalidArgument)
        #expect(
            try decoder.decode(ErrorCode.self, from: "\"INTERNAL\"".data(using: .utf8)!)
                == .internal)

        #expect(ARCPError.timeout(jobId: JobId("job_x"), maxRuntimeSec: 5).code == .timeout)
        #expect(ARCPError.jobNotFound(id: "job_x").code == .jobNotFound)
        #expect(ARCPError.duplicateKey(key: "idem_x", detail: "differs").code == .duplicateKey)
        #expect(ARCPError.agentNotAvailable(agent: "a").code == .agentNotAvailable)
        #expect(ARCPError.resumeWindowExpired(detail: "x").code == .resumeWindowExpired)
    }

    @Test("v1.1 ARCPError variants are non-retryable by default")
    func v11RetrySemantics() {
        #expect(ARCPError.budgetExhausted(detail: "USD <= 0").isRetryable == false)
        #expect(
            ARCPError.agentVersionNotAvailable(agent: "summarizer", version: "2.3.0").isRetryable
                == false)
    }

    @Test("AgentVersionNotAvailable details carry agent + version")
    func agentVersionDetails() {
        let err = ARCPError.agentVersionNotAvailable(agent: "summarizer", version: "2.3.0")
        let details = err.details
        #expect(details["agent"] == .string("summarizer"))
        #expect(details["version"] == .string("2.3.0"))
    }

    @Test("Retry semantics align with RFC §18.3")
    func retrySemantics() {
        #expect(ARCPError.resourceExhausted(reason: "x", retryAfter: nil).isRetryable == true)
        #expect(ARCPError.unavailable(reason: "x", retryAfter: nil).isRetryable == true)
        #expect(ARCPError.deadlineExceeded(operation: "x").isRetryable == true)
        #expect(ARCPError.aborted(reason: "x").isRetryable == true)
        #expect(ARCPError.internal(detail: "x", cause: nil).isRetryable == true)
        #expect(ARCPError.invalidArgument(field: "x", detail: "y").isRetryable == false)
        #expect(ARCPError.notFound(kind: "k", id: "i").isRetryable == false)
        #expect(ARCPError.permissionDenied(permission: "p", resource: "r").isRetryable == false)
        #expect(ARCPError.unauthenticated(detail: "x").isRetryable == false)
        #expect(ARCPError.unimplemented(section: "§1", detail: "x").isRetryable == false)
    }

    @Test("`RATE_LIMITED` decodes as RESOURCE_EXHAUSTED (RFC §18.2 alias)")
    func rateLimitedAlias() throws {
        let json = "\"RATE_LIMITED\"".data(using: .utf8)!
        let decoded = try Envelope.makeDecoder().decode(ErrorCode.self, from: json)
        #expect(decoded == .resourceExhausted)
    }

    @Test("ErrorCode round-trips canonical wire form")
    func wireRoundTrip() throws {
        let codes: [ErrorCode] = ErrorCode.allCases
        for code in codes {
            let data = try Envelope.makeEncoder().encode(code)
            let decoded = try Envelope.makeDecoder().decode(ErrorCode.self, from: data)
            #expect(decoded == code)
        }
    }

    @Test("Error envelope conversion preserves message + code")
    func toEnvelope() {
        let err = ARCPError.permissionDenied(permission: "fs.write", resource: "/etc/hosts")
        let envelope = err.toEnvelope()
        #expect(envelope.code == .permissionDenied)
        #expect(envelope.message.contains("fs.write"))
    }

    @Test("Heartbeat lost details include job id and missed count")
    func heartbeatDetails() {
        let err = ARCPError.heartbeatLost(jobId: JobId("job_42"), missed: 3)
        guard case .object(let object) = JSONValue.object(err.details) else {
            Issue.record("expected object details")
            return
        }
        #expect(object["job_id"] == .string("job_42"))
        #expect(object["missed"] == .int(3))
    }
}
