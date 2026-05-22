# Troubleshooting

## Handshake errors

### `unauthenticated: bearer token not recognized`

The token in `AuthBlock` is not in the `BearerAuthValidator` map.
Check for leading/trailing whitespace, quote marks, or environment
variable interpolation issues.

### `unauthenticated: JWT validation failed`

Common causes:
- `aud` claim does not match the runtime identity name passed to `JWTAuthValidator`.
- JWT is expired (`exp` in the past).
- Wrong signing key — check that the same key collection is used to
  issue and validate tokens.

### `failedPrecondition: provisioned_credentials advertised without credential provisioner`

`Capabilities.provisionedCredentials = true` but no `credentialProvisioner`
was passed to `ARCPRuntime`. Either supply a provisioner or remove the
capability flag.

## Job errors

### `HEARTBEAT_LOST`

The handler stopped sending heartbeats within the configured window.
Make sure long-running handlers call `context.heartbeat()` (or
equivalent) on each loop iteration. If the handler is CPU-bound,
insert a `Task.yield()` periodically.

### `LEASE_EXPIRED`

The job's `lease_constraints.expires_at` elapsed before the handler
finished. Call `try context.checkLeaseExpiration()` at the start of
each authority-bearing step to get a clear `LEASE_EXPIRED` error
rather than a partial operation.

### `BUDGET_EXHAUSTED`

A `cost.budget` counter reached its limit. Reduce work per invocation,
or request a higher budget from the orchestrator.

### `BACKPRESSURE_OVERFLOW`

The stream buffer is full — the subscriber is not keeping up with
the producer. Either slow down the producer (`try await handle.sendText(…)`
will block on backpressure) or increase the stream buffer size.

### `PERMISSION_DENIED` on `tool.invoke`

The client does not hold a valid lease for the requested resource /
operation pair. Check that `permission.grant` was issued before the
job was submitted.

## Build errors

### `error: 'WebSocket' initializer is inaccessible`

You are trying to use `WebSocketTransport` as a server-side transport.
The server-side initializer is internal to WebSocketKit. Use
`MemoryTransport` or `StdioTransport` for server scenarios until
v0.2.

### `error: cannot convert value of type 'X' to expected argument type 'any Sendable'`

Swift 6 strict concurrency requires all values crossing actor boundaries
to be `Sendable`. Mark your custom payload types with `Sendable` or use
`@unchecked Sendable` as a temporary escape hatch.

### `warning: non-sendable type 'Y' in implicitly asynchronous access`

Same root cause. Audit conformances or isolate access to a single actor.

## Tests

### Tests fail with `address already in use`

Two test suites are binding the same port concurrently. Ensure that
each test uses `MemoryTransport` (no ports) or that WebSocket tests
each use a unique port number.

### `swift test` takes much longer than expected

Run with `--parallel` to use all cores:

```bash
swift test --parallel --enable-code-coverage
```

## Still stuck?

Open an issue at
[`agentruntimecontrolprotocol/swift-sdk`](https://github.com/agentruntimecontrolprotocol/swift-sdk/issues)
with the error message, Swift version (`swift --version`), and platform.
