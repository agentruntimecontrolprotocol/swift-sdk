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
`MemoryTransport.makePair()` returns two paired endpoints: whatever one
sends the other receives.

```swift
let (clientTransport, serverTransport) = MemoryTransport.makePair()

// Server side
Task { try await runtime.acceptSession(over: serverTransport) }

// Client side
let client = try await ARCPClient.open(
    transport: clientTransport,
    auth: AuthBlock(scheme: .bearer, token: "demo-token"),
    client: IdentityBlock(kind: "test-client", version: "0.0")
)
```

`MemoryTransport` is what every integration test in `ARCPTests` uses.

## StdioTransport

Reads NDJSON envelopes from `stdin` and writes them to `stdout`. Suitable
for subprocess-based agents and for running the `arcp serve` CLI.

```swift
import ARCP

let transport = StdioTransport()

// Client driving a child process's stdin/stdout
let client = try await ARCPClient.open(
    transport: transport,
    auth: AuthBlock(scheme: .bearer, token: "demo-token"),
    client: IdentityBlock(kind: "orchestrator", version: "1.0")
)
```

`StdioTransport` accepts `inbound:` and `outbound:` `FileHandle`s
(default: `.standardInput` / `.standardOutput`). Wire two in-process
endpoints with `Foundation.Pipe` pairs — see
[`Samples/Stdio`](../Samples/Stdio/Sources/Stdio/main.swift).

## WebSocketTransport

Client-side WebSocket transport built on
[WebSocketKit](https://github.com/vapor/websocket-kit). Sends each
envelope as a text frame (NDJSON) and delivers incoming frames as an
`AsyncStream<Envelope>`. Construct it via the `WebSocketClient.connect`
helper:

```swift
import ARCP
import NIOPosix

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let transport = try await WebSocketClient.connect(
    url: "ws://localhost:8080/arcp",
    eventLoopGroup: group
)

let client = try await ARCPClient.open(
    transport: transport,
    auth: AuthBlock(scheme: .bearer, token: "secret"),
    client: IdentityBlock(kind: "my-client", version: "1.0")
)
// ... use client ...
await client.close()
try await group.shutdownGracefully()
```

If you already hold a `WebSocketKit.WebSocket` from a custom connector,
wrap it directly with `WebSocketTransport(webSocket:)`.

### WebSocket server

A full server-side WebSocket transport is deferred to v0.2 — the blocker
is that `WebSocketKit.WebSocket`'s server-side initializer is internal to
the library. In the meantime, use `StdioTransport` or `MemoryTransport`
for server scenarios, or wrap NIO directly.

## Implementing a custom transport

```swift
import ARCP

final class MyTransport: Transport, @unchecked Sendable {
    private let continuation: AsyncStream<Envelope>.Continuation
    let receive: AsyncStream<Envelope>

    init() {
        var cont: AsyncStream<Envelope>.Continuation!
        receive = AsyncStream { cont = $0 }
        continuation = cont
    }

    func send(_ envelope: Envelope) async throws {
        let data = try envelope.toJSON()
        // write data to your channel ...
    }

    func close() async {
        continuation.finish()
        // close your channel ...
    }

    // Call from your receive loop:
    func deliver(_ envelope: Envelope) {
        continuation.yield(envelope)
    }
}
```

The only constraint is that `receive` must yield envelopes in arrival
order and complete when the channel closes.
