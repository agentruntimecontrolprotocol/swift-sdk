# Vendor Extensions

ARCP's extension mechanism lets you carry custom payloads on the wire
without modifying the core spec (RFC §21).

## Naming convention

Extension message types follow either form (RFC §21.1):

```
arcpx.<vendor>.<name>.v<n>
<reverse-dns>.<name>.v<n>
```

Examples:
- `arcpx.acme.trace_span.v1`
- `com.acme.workflow_event.v2`

The bare `x-` prefix is reserved for transport-internal experiments
and `ExtensionRegistry.validateNamespace` rejects it.

## Advertising extensions

Register the namespaces you advertise on `Capabilities.extensions`:

```swift
let caps = Capabilities(
    streaming: true,
    extensions: ["arcpx.acme.v1"]
)

let runtime = try ARCPRuntime(
    identity: IdentityBlock(kind: "acme-agent", version: "1.0"),
    supportedCapabilities: caps,
    auth: auth
)
```

During capability negotiation, the runtime advertises the registered
namespaces and the negotiator stores the intersection. The client
can inspect `client.info.negotiatedCapabilities.extensions` to confirm
support. Internally `ExtensionRegistry` is updated with the negotiated
set via `setAdvertised(_:)`.

You can also construct the registry yourself and inject it:

```swift
let registry = ExtensionRegistry(advertised: ["arcpx.acme.v1"])
let runtime = try ARCPRuntime(
    identity: identity,
    supportedCapabilities: caps,
    auth: auth,
    extensionRegistry: registry
)
```

## Sending an extension envelope

`MessageType.unknown` carries the type name plus a `JSONValue`
payload:

```swift
let span: JSONValue = .object([
    "name": .string("compute.embedding"),
    "duration_ms": .double(42.0),
])

try await client.send(
    Envelope(
        sessionId: client.info.sessionId,
        payload: .unknown(typeName: "arcpx.acme.trace_span.v1", payload: span)
    )
)
```

If you want the peer to drop the envelope when the namespace is not
advertised (instead of `nack`-ing it), set `extensions["optional"]` on
the envelope to `.bool(true)`. The dispatch path consults that flag in
`ExtensionRegistry.disposition(forUnknown:optional:)`.

## Receiving an extension envelope

Unknown types arrive as `.unknown(typeName:payload:)` on the
`unhandled` stream:

```swift
for await envelope in client.unhandled {
    guard case .unknown(let typeName, let payload) = envelope.payload,
          typeName == "arcpx.acme.trace_span.v1" else { continue }
    // payload is a JSONValue
    handleSpan(payload)
}
```

There is no per-type registration hook in v0.1; the runtime's
`ExtensionRegistry` only decides whether to accept, drop, or `nack` an
unknown envelope. Handlers process accepted extension types by reading
them off the runtime-side equivalent of `unhandled` (sample-specific
plumbing).

## Unknown-type policy

Per RFC §21.3 (implemented in `ExtensionRegistry.disposition`):

- Unknown core types (anything in `session.`, `job.`, `tool.`, ...): `nack` with `UNIMPLEMENTED`.
- Unknown extension types in an advertised namespace: `accept`.
- Unknown extension types in an *unknown* namespace, with `extensions["optional"] == true`: `drop`.
- Otherwise: `nack` with `UNIMPLEMENTED`.

## Sample

The [`Extensions` sample](../../Samples/Extensions) implements a
custom `arcpx.sdr.*.v1` namespace and demonstrates negotiation,
encoding, and fallback paths.
