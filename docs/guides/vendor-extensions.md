# Vendor Extensions

ARCP's extension mechanism lets you carry custom payloads on the wire
without modifying the core spec (RFC §21).

## Naming convention

Extension message types follow the pattern:

```
arcpx.<domain>.<name>.v<n>
```

Examples:
- `arcpx.acme.trace_span.v1`
- `arcpx.myco.webhook_event.v2`

The `<domain>` segment is your organisation's reverse-DNS prefix.

## Declaring extensions

Register your extension namespace with the runtime's `ExtensionRegistry`:

```swift
let registry = ExtensionRegistry(advertised: capabilities.extensions)
registry.register(namespace: "arcpx.acme", description: "Acme telemetry events")

let runtime = try ARCPRuntime(
    identity: IdentityBlock(name: "acme-agent", version: "1.0"),
    supportedCapabilities: Capabilities(extensions: ["arcpx.acme.v1"]),
    auth: auth,
    extensionRegistry: registry
)
```

During capability negotiation, the runtime advertises the registered
namespaces; the client can check `negotiatedCapabilities.extensions`
to confirm support.

## Sending an extension envelope

```swift
try await client.send(Envelope(
    payload: .unknown(
        typeName: "arcpx.acme.trace_span.v1",
        payload: try JSONEncoder().encode(mySpan)
    )
))
```

## Receiving an extension envelope

Unknown types arrive as `.unknown(typeName:payload:)` in the
`unhandled` stream:

```swift
for await envelope in client.unhandled {
    if case .unknown(let typeName, let data) = envelope.payload,
       typeName == "arcpx.acme.trace_span.v1" {
        let span = try JSONDecoder().decode(MySpan.self, from: data)
        processSpan(span)
    }
}
```

On the server side, register an extension handler:

```swift
runtime.extensionRegistry.register(
    typeName: "arcpx.acme.trace_span.v1"
) { envelope, sessionId in
    let span = try JSONDecoder().decode(MySpan.self, from: envelope.rawPayload)
    await myTelemetrySink.ingest(span)
}
```

## Unknown-type policy

Per RFC §21.3, the runtime rejects unknown envelopes that are not
registered and were sent by a non-optional caller with `UNIMPLEMENTED`.
Optional senders (subscribers, observers) receive `UNIMPLEMENTED` and
can gracefully degrade.

## Sample

The [`Extensions` sample](../../Samples/Extensions) implements a custom
`arcpx.sdr.*.v1` namespace with correct unknown-message handling and
demonstrates negotiation, encoding, and fallback paths.
