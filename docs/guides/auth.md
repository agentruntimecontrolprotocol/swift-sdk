# Authentication

ARCP defines five auth schemes on the wire (RFC §8.2): `bearer`,
`signed_jwt`, `mtls`, `oauth2`, and `none`. This SDK implements
`bearer`, `signed_jwt`, and `none`; `mtls` and `oauth2` are deferred
to v0.2 (see [Conformance](../conformance.md)). The scheme is declared
by the client in `session.open`; the runtime validates it before
sending `session.accepted`.

## Bearer tokens

The simplest scheme. Configure `BearerAuthValidator` with a token →
subject map:

```swift
let runtime = try ARCPRuntime(
    identity: IdentityBlock(kind: "my-agent", version: "1.0"),
    supportedCapabilities: Capabilities(),
    auth: BearerAuthValidator(subjectsByToken: [
        "prod-token-abc": "orchestrator",
        "ci-token-xyz":   "ci-runner",
    ])
)
```

The client sends the token in `session.open`:

```swift
let client = try await ARCPClient.open(
    transport: transport,
    auth: AuthBlock(scheme: .bearer, token: "prod-token-abc"),
    client: IdentityBlock(kind: "orchestrator", version: "1.0")
)
```

To set a custom trust level (defaults to `.trusted`) supply the full
`[String: AuthenticatedPrincipal]` form:

```swift
BearerAuthValidator([
    "admin-token": AuthenticatedPrincipal(subject: "admin", trustLevel: .privileged),
    "read-token":  AuthenticatedPrincipal(subject: "reader", trustLevel: .constrained),
])
```

## Signed JWT

Use `JWTAuthValidator` when the issuer already mints JWTs. The validator
checks the signature, `exp`, and `aud` claims.

```swift
import JWTKit
import ARCP

// Build the key collection (HMAC example)
let keys = JWTKeyCollection()
await keys.add(hmac: "my-shared-secret", digestAlgorithm: .sha256)

let runtime = try ARCPRuntime(
    identity: IdentityBlock(kind: "my-agent", version: "1.0"),
    supportedCapabilities: Capabilities(),
    auth: JWTAuthValidator(keys: keys, audience: "my-agent")
)
```

The client passes the JWT string as the token:

```swift
let client = try await ARCPClient.open(
    transport: transport,
    auth: AuthBlock(scheme: .signedJwt, token: jwt),
    client: IdentityBlock(kind: "caller", version: "1.0")
)
```

### Required JWT claims

| Claim | Type | Notes |
|-------|------|-------|
| `sub` | String | Becomes `AuthenticatedPrincipal.subject` |
| `aud` | String or `[String]` | Must include the runtime audience passed to `JWTAuthValidator(audience:)` |
| `exp` | NumericDate | Validated by `JWTAuthValidator` |
| `iat`, `iss` | optional | Decoded but not enforced by the validator |

### Challenge–response nonce

When `challengeRequired: true` is passed to `ARCPRuntime.init`, the
runtime sends `session.challenge` before validating auth. The nonce is
passed to `AuthValidator.validate(auth:challenge:)`:

```swift
public protocol AuthValidator: Sendable {
    func supports(_ scheme: AuthScheme) -> Bool
    func validate(auth: AuthBlock, challenge nonce: String?) async throws -> AuthenticatedPrincipal
}
```

Sign the nonce into the JWT or include it as a claim to prevent replay.

## No auth (`none`)

The `none` scheme bypasses the validator entirely, but the runtime only
accepts it when both peers advertise the `anonymous` capability. No
special validator type is required — any `AuthValidator` will do.

```swift
let runtime = try ARCPRuntime(
    identity: IdentityBlock(kind: "dev-agent", version: "0.0"),
    supportedCapabilities: Capabilities(anonymous: true),
    auth: BearerAuthValidator(subjectsByToken: [:])  // never consulted
)

let client = try await ARCPClient.open(
    transport: transport,
    auth: AuthBlock(scheme: .none),
    client: IdentityBlock(kind: "test-client", version: "0.0"),
    capabilities: Capabilities(anonymous: true)
)
```

The resulting principal has `subject == "anonymous"` and
`trustLevel == .untrusted`. Don't use anonymous sessions in production.

## Custom validator

Implement `AuthValidator` to validate HMAC signatures, API keys, or any
other scheme:

```swift
struct HMACValidator: AuthValidator {
    let secret: String

    func supports(_ scheme: AuthScheme) -> Bool { scheme == .bearer }

    func validate(auth: AuthBlock, challenge nonce: String?) async throws -> AuthenticatedPrincipal {
        guard let token = auth.token else {
            throw ARCPError.unauthenticated(detail: "token missing")
        }
        // verify HMAC(secret, nonce ?? "") == token
        guard verify(token: token, secret: secret, nonce: nonce) else {
            throw ARCPError.unauthenticated(detail: "HMAC mismatch")
        }
        return AuthenticatedPrincipal(subject: "verified-caller", trustLevel: .trusted)
    }
}
```

See the [`CustomAuth` sample](../../Samples/CustomAuth) for a complete
HMAC-SHA256 example.

To accept several schemes in one runtime, wrap them in
`CompositeAuthValidator`:

```swift
let auth = CompositeAuthValidator([
    BearerAuthValidator(subjectsByToken: tokens),
    JWTAuthValidator(keys: keys, audience: "my-agent"),
])
```

## Trust levels

`AuthenticatedPrincipal.trustLevel` is one of (RFC §15.3):

| Level | Meaning |
|-------|---------|
| `.untrusted` | Anonymous or unverified caller |
| `.constrained` | Authenticated but limited (e.g. read-only API tokens) |
| `.trusted` | Standard authenticated caller (default for the bundled validators) |
| `.privileged` | May elevate authority or grant new leases |

The trust level rides on `SessionInfo.principal.trustLevel` and is
exposed inside a handler via the session's `JobContext` callbacks.
