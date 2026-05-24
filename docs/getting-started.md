# Getting Started

## Requirements

- Swift 6.1 toolchain or later
- macOS 14+

## Add to your Swift package

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/agentruntimecontrolprotocol/swift-sdk.git",
             from: "1.1.0"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "ARCP", package: "swift-sdk"),
        ]
    ),
]
```

## In-process session (five minutes)

The fastest way to get a session running is `MemoryTransport`, which
connects a client and a runtime in the same process with no I/O.

```swift
import ARCP

// 1. Define a tool
struct EchoHandler: ToolHandler {
    let name = "echo"
    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        return .value(invocation.arguments)
    }
}

// 2. Build the runtime
let runtime = try ARCPRuntime(
    identity: IdentityBlock(kind: "demo-agent", version: "1.0"),
    supportedCapabilities: Capabilities(),
    auth: BearerAuthValidator(subjectsByToken: ["demo-token": "demo"])
)
await runtime.register(EchoHandler())

// 3. Pair a MemoryTransport
let (clientTransport, serverTransport) = MemoryTransport.makePair()

// 4. Accept a session on the server side (non-blocking)
Task { try await runtime.acceptSession(over: serverTransport) }

// 5. Connect the client
let client = try await ARCPClient.open(
    transport: clientTransport,
    auth: AuthBlock(scheme: .bearer, token: "demo-token"),
    client: IdentityBlock(kind: "my-client", version: "1.0")
)

// 6. Invoke a tool
let invocation = try await client.invoke(
    tool: "echo",
    arguments: .object(["msg": .string("hello")])
)
if case .completed(let payload) = invocation.outcome {
    print(payload.result ?? .null)   // {"msg":"hello"}
}

// 7. Close
await client.close()
```

## WebSocket session

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
    auth: AuthBlock(scheme: .bearer, token: "my-token"),
    client: IdentityBlock(kind: "my-client", version: "1.0"),
    capabilities: Capabilities()
)

let invocation = try await client.invoke(
    tool: "summarise",
    arguments: .object(["text": .string(input)])
)
await client.close()
try await group.shutdownGracefully()
```

## Stdio session

Run an agent over `stdin` / `stdout` (NDJSON framing):

```bash
swift run arcp serve
```

From your own process, drive it with `StdioTransport`:

```swift
import ARCP

let transport = StdioTransport()
let client = try await ARCPClient.open(
    transport: transport,
    auth: AuthBlock(scheme: .bearer, token: "demo-token"),
    client: IdentityBlock(kind: "orchestrator", version: "1.0")
)
```

See [Transports](transports.md) and the [`Stdio` sample](../Samples/Stdio)
for full details.

## Samples

The `Samples/` directory contains 27 self-contained examples — each is its
own `Package.swift` with a single executable target:

```bash
cd Samples/SubmitAndStream && swift run
cd Samples/Resumability     && swift run   # actually crashes and resumes
cd Samples/MCP              && swift run   # ARCP fronting an MCP server
```

See [`Samples/README.md`](../Samples/README.md) for the full list and
recommended reading order.
