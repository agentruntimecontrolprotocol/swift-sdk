# Authentication

ARCP supports three auth schemes (RFC §8.2): `bearer`, `signed_jwt`, and
`none`. The scheme is declared by the client in `session.open`; the
runtime validates it before sending `session.accepted`.

## Bearer tokens

The simplest scheme. Configure `BearerAuthValidator` with a token → subject
map:

```swift
let runtime = try ARCPRuntime(
    identity: IdentityBlock(name: "my-agent", version: "1.0"),
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
    client: IdentityBlock(name: "orchestrator", version: "1.0")
)
```

For custom trust levels supply the full `[String: AuthenticatedPrincipal]`
form:

```swift
BearerAuthValidator([
    "admin-token": AuthenticatedPrincipal(subject: "admin", trustLevel: .elevated),
    "read-token":  AuthenticatedPrincipal(subject: "reader", trustLevel: .trusted),
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
    identity: IdentityBlock(name: "my-agent", version: "1.0"),
    supportedCapabilities: Capabilities(),
    auth: JWTAuthValidator(keys: keys, audience: "my-agent")
)
```

The client passes the JWT string as the token:

```swift
let client = try await ARCPClient.open(
    transport: transport,
    auth: AuthBlock(scheme: .signedJwt, token: jwt),
    client: IdentityBlock(name: "caller", version: "1.0")
)
```

### Required JWT claims

| Claim | Type | Notes |
|-------|------|-------|
| `sub` | String | Becomes `AuthenticatedPrincipal.subject` |
| `aud` | String or `[String]` | Must match the runtime identity name |
| `exp` | NumericDate | Validated by `JWTAuthValidator` |

### Challenge–response nonce

When `challengeRequired: true`, the runtime sends `session.challenge`
before accepting auth. The nonce is passed to `AuthValidator.validate`:

```swift
public protocol AuthValidator: Sendable {
    func supports(_ scheme: AuthScheme) -> Bool
    func validate(auth: AuthBlock, challenge nonce: String?) async throws -> AuthenticatedPrincipal
}
```

Sign the nonce into the JWT or include it as a claim to prevent replay.

## No auth (`none`)

For local tests or trusted environments:

```swift
let runtime = try ARCPRuntime(
    identity: IdentityBlock(name: "dev-agent", version: "0.0"),
    supportedCapabilities: Capabilities(),
    auth: AnonymousAuthValidator()
)

let client = try await ARCPClient.open(
    transport: transport,
    auth: AuthBlock(scheme: .none),
    client: IdentityBlock(name: "test-client", version: "0.0")
)
```

Never use `AnonymousAuthValidator` in production.

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

## Trust levels

`AuthenticatedPrincipal.trustLevel` is one of:

| Level | Use |
|-------|-----|
| `.trusted` | Standard authenticated caller |
| `.elevated` | May request elevated permission grants |

The trust level is available on `JobContext` as
`context.principal?.trustLevel` and can gate access to sensitive tools.
