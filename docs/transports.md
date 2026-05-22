# Transports

All ARCP communication happens over a `Transport` — a bidirectional,
`Sendable` channel that delivers `Envelope` values (RFC §22).

```swift
public protocol Transport: Sendable {
    func send(_ envelope: Envelope) async throws
    var receive: AsyncStream<Envelope> { get }
    func close() async
}
```

## MemoryTransport

An in-process, channel-backed transport for tests and samples.
`MemoryTransport.pipe()` returns two paired endpoints: whatever one sends
the other receives.

```swift
let (serverTransport, clientTransport) = MemoryTransport.pipe()

// Server side
Task { try await runtime.acceptSession(over: serverTransport) }

// Client side
let client = try await ARCPClient.open(
    transport: clientTransport,
    auth: AuthBlock(scheme: .none),
    client: IdentityBlock(name: "test-client", version: "0.0")
)
```

`MemoryTransport` is what all integration tests in `ARCPTests` use.

## StdioTransport

Reads NDJSON envelopes from `stdin` and writes them to `stdout`. Suitable
for subprocess-based agents and for running the `arcp serve` CLI.

```swift
import ARCP

let transport = try StdioTransport()

// Client driving a child process's stdin/stdout
let client = try await ARCPClient.open(
    transport: transport,
    auth: AuthBlock(scheme: .none),
    client: IdentityBlock(name: "orchestrator", version: "1.0")
)
```

Use `Foundation.Pipe` pairs to wire two in-process `StdioTransport`s —
see [`Samples/Stdio`](../Samples/Stdio/Sources/Stdio/main.swift).

## WebSocketTransport

Client-side WebSocket transport built on
[WebSocketKit](https://github.com/vapor/websocket-kit). Sends each
envelope as a text frame (NDJSON) and delivers incoming frames as an
`AsyncStream<Envelope>`.

```swift
import ARCP

let transport = WebSocketTransport(url: URL(string: "ws://localhost:8080/arcp")!)
try await transport.connect()

let client = try await ARCPClient.open(
    transport: transport,
    auth: AuthBlock(scheme: .bearer, token: "secret"),
    client: IdentityBlock(name: "my-client", version: "1.0")
)
// … use client …
try await client.close()
// transport is closed automatically when the session ends
```

### Connection options

`WebSocketTransport` accepts an optional `maxFrameSize` (default 1 MiB)
and TLS options forwarded to the underlying NIO channel. Pass a custom
`NIOSSLContext` via `tlsContext` to use mTLS or a custom certificate chain.

### WebSocket server

A full server-side WebSocket transport is partially implemented; the
blocking issue is that `WebSocketKit.WebSocket`'s server-side initializer
is internal to the library. A complete server transport will land in v0.2.
In the meantime, use `StdioTransport` or `MemoryTransport` for server
scenarios, or wrap NIO directly.

## Implementing a custom transport

```swift
import ARCP

final class MyTransport: Transport {
    private let continuation: AsyncStream<Envelope>.Continuation
    let receive: AsyncStream<Envelope>

    init() {
        var cont: AsyncStream<Envelope>.Continuation!
        receive = AsyncStream { cont = $0 }
        continuation = cont
    }

    func send(_ envelope: Envelope) async throws {
        let data = try JSONEncoder().encode(envelope)
        // write data to your channel …
    }

    func close() async {
        continuation.finish()
        // close your channel …
    }

    // Call from your receive loop:
    func deliver(_ envelope: Envelope) {
        continuation.yield(envelope)
    }
}
```

The only constraint is that `receive` must yield envelopes in arrival
order and complete when the channel closes.
