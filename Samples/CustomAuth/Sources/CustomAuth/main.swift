// ARCP v1.1 §6.1 / §8.2 — pluggable authentication with a custom validator.
//
// ARCP is auth-scheme-agnostic: the runtime delegates validation to any
// `AuthValidator` conformance. This sample implements a toy HMAC-signed
// bearer token whose structure is:
//
//   <subject>.<expEpoch>.<hmac-hex>
//
// where hmac = HMAC-SHA256(key, "<subject>.<expEpoch>").
//
// What the sample shows:
//   - Implementing `AuthValidator` (supports + validate)
//   - A valid token → authenticated session
//   - A forged token → `ARCPError.unauthenticated` propagated as a
//     `session.close` with code UNAUTHENTICATED (RFC §8.2)
//
// In production swap in JWT+JWKS, mTLS, or OAuth2; the protocol surface
// is identical.

import ARCP
import CommonCrypto
import Foundation

// ---------------------------------------------------------------------------
// Custom HMAC-signed bearer validator
// ---------------------------------------------------------------------------

struct HMACBearerValidator: AuthValidator {
    private let signingKey: Data

    init(key: String) {
        self.signingKey = Data(key.utf8)
    }

    func supports(_ scheme: AuthScheme) -> Bool { scheme == .bearer }

    func validate(auth: AuthBlock, challenge _: String?) async throws -> AuthenticatedPrincipal {
        guard auth.scheme == .bearer, let token = auth.token, !token.isEmpty else {
            throw ARCPError.unauthenticated(detail: "bearer token missing")
        }

        // Format: subject.expEpoch.hmacHex
        let parts = token.split(separator: ".", maxSplits: 2).map(String.init)
        guard parts.count == 3 else {
            throw ARCPError.unauthenticated(detail: "malformed token: expected 3 parts")
        }
        let (subject, expStr, givenHmac) = (parts[0], parts[1], parts[2])

        // Expiry check.
        guard let expEpoch = TimeInterval(expStr), Date().timeIntervalSince1970 < expEpoch else {
            throw ARCPError.unauthenticated(detail: "token expired")
        }

        // Signature check.
        let message = "\(subject).\(expStr)"
        let expected = hmacSHA256(key: signingKey, message: Data(message.utf8))
        guard expected == givenHmac else {
            throw ARCPError.unauthenticated(detail: "invalid token signature")
        }

        return AuthenticatedPrincipal(subject: subject, trustLevel: .trusted)
    }

    // Tiny HMAC-SHA256 over CommonCrypto — no external deps needed.
    private func hmacSHA256(key: Data, message: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { keyPtr in
            message.withUnsafeBytes { msgPtr in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA256),
                    keyPtr.baseAddress, key.count,
                    msgPtr.baseAddress, message.count,
                    &digest
                )
            }
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Mint a signed token valid for `ttlSeconds`.
    func mint(subject: String, ttlSeconds: TimeInterval = 3600) -> String {
        let exp = Int(Date().timeIntervalSince1970 + ttlSeconds)
        let message = "\(subject).\(exp)"
        let sig = hmacSHA256(key: signingKey, message: Data(message.utf8))
        return "\(message).\(sig)"
    }
}

// ---------------------------------------------------------------------------
// A simple echo agent
// ---------------------------------------------------------------------------

struct EchoAgent: ToolHandler {
    let name = "echo"

    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        let msg = invocation.arguments["message"]?.stringValue ?? "(empty)"
        return .value(.string("echo: \(msg)"))
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

@main
struct CustomAuthExample {
    static func main() async throws {
        let validator = HMACBearerValidator(key: "super-secret-key-not-for-production")

        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "custom-auth-demo", version: "1.0.0"),
            supportedCapabilities: Capabilities(),
            auth: validator
        )
        await runtime.register(EchoAgent())
        let server = Task { try await runtime.acceptSession(over: pair.server) }

        // ── Scenario A: valid HMAC token. ──
        print("── Scenario A: valid signed token ──")
        let goodToken = validator.mint(subject: "alice")
        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: goodToken),
            client: IdentityBlock(kind: "custom-auth-client", version: "1.0.0"),
            capabilities: Capabilities()
        )

        let invoke = Envelope(
            sessionId: client.info.sessionId,
            payload: .toolInvoke(
                ToolInvokePayload(
                    tool: "echo",
                    arguments: .object(["message": "hello from alice"])
                )
            )
        )
        try await client.send(invoke)

        for await env in client.unhandled {
            switch env.payload {
            case .jobAccepted(let p):
                print("← job.accepted  job_id=\(p.jobId.rawValue.prefix(8))")
            case .jobCompleted(let p):
                print("← job.completed result=\(p.result?.stringValue ?? "(nil)")")
                break
            case .jobFailed(let p):
                print("← job.failed    \(p.error.message)")
                break
            default: break
            }
            if case .jobCompleted = env.payload { break }
            if case .jobFailed    = env.payload { break }
        }
        await client.close()
        _ = try? await server.value

        // ── Scenario B: forged token is rejected at handshake. ──
        print("\n── Scenario B: forged token ──")
        let forgedToken = "bob.9999999999.deadbeefdeadbeef"
        let pair2 = MemoryTransport.makePair()
        let runtime2 = try ARCPRuntime(
            identity: IdentityBlock(kind: "custom-auth-demo", version: "1.0.0"),
            supportedCapabilities: Capabilities(),
            auth: validator
        )
        await runtime2.register(EchoAgent())
        let server2 = Task { try await runtime2.acceptSession(over: pair2.server) }

        do {
            _ = try await ARCPClient.open(
                transport: pair2.client,
                auth: AuthBlock(scheme: .bearer, token: forgedToken),
                client: IdentityBlock(kind: "custom-auth-client", version: "1.0.0"),
                capabilities: Capabilities()
            )
            print("unexpected: handshake succeeded with forged token")
        } catch let e as ARCPError {
            print("← handshake rejected  \(e)")
        }
        _ = try? await server2.value

        print("done")
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

extension JSONValue {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    subscript(key: String) -> JSONValue? {
        if case .object(let d) = self { return d[key] }
        return nil
    }
}
