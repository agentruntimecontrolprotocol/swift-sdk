# CustomAuth

**ARCP v1.1 §6.1 / §8.2 — pluggable authentication with a custom validator**

ARCP is auth-scheme-agnostic: the runtime delegates validation to any
`AuthValidator` conformance. This sample implements a toy HMAC-SHA256-signed
bearer token using only `CommonCrypto` (no external dependencies).

Token structure: `<subject>.<expEpoch>.<hmac-hex>`

## What it shows

| Feature | RFC section |
|---------|-------------|
| `AuthValidator` conformance (`supports` + `validate`) | §6.1 |
| Valid HMAC token → authenticated session | §6.1 |
| Forged token → `ARCPError.unauthenticated` at handshake | §8.2 |
| `session.close` with code `UNAUTHENTICATED` | §8.2 |

## Swap-in targets

Replace `HMACBearerValidator` with JWT+JWKS, mTLS, or OAuth2 — the protocol
surface (`AuthValidator`) is identical.

## Running

```bash
swift run
```

## Expected output

```
── Scenario A: valid signed token ──
← job.accepted  job_id=xxxxxxxx
← job.completed result=echo: hello from alice

── Scenario B: forged token ──
← handshake rejected  unauthenticated: invalid token signature
done
```
