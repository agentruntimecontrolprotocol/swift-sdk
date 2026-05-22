# Getting Started

## Requirements

- Swift 6.0 toolchain or later (validated against 6.3.1)
- macOS 14+ or Linux (Ubuntu 22.04+)

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
    identity: IdentityBlock(name: "demo-agent", version: "1.0"),
    supportedCapabilities: Capabilities(),
    auth: AnonymousAuthValidator()
)
runtime.register(EchoHandler())

// 3. Pair a MemoryTransport
let (serverTransport, clientTransport) = MemoryTransport.pipe()

// 4. Accept a session on the server side (non-blocking)
Task { try await runtime.acceptSession(over: serverTransport) }

// 5. Connect the client
let client = try await ARCPClient.open(
    transport: clientTransport,
    auth: AuthBlock(scheme: .none),
    client: IdentityBlock(name: "my-client", version: "1.0")
)

// 6. Invoke a tool
let (outcome, _) = try await client.invoke(tool: "echo", arguments: .object(["msg": .string("hello")]))
if case .completed(let result) = outcome {
    print(result.result ?? "no result")   // {"msg":"hello"}
}

// 7. Close
try await client.close()
```

## WebSocket session

```swift
import ARCP

let transport = WebSocketTransport(url: URL(string: "ws://localhost:8080/arcp")!)
try await transport.connect()

let client = try await ARCPClient.open(
    transport: transport,
    auth: AuthBlock(scheme: .bearer, token: "my-token"),
    client: IdentityBlock(name: "my-client", version: "1.0"),
    capabilities: Capabilities()
)

let (outcome, _) = try await client.invoke(tool: "summarise", arguments: .object(["text": .string(input)]))
try await client.close()
```

## Stdio session

Run an agent over `stdin` / `stdout` (NDJSON framing):

```bash
swift run arcp serve
```

From your own process, drive it with `StdioTransport`:

```swift
import ARCP

let transport = try StdioTransport()
let client = try await ARCPClient.open(
    transport: transport,
    auth: AuthBlock(scheme: .none),
    client: IdentityBlock(name: "orchestrator", version: "1.0")
)
```

See [Transports](transports.md) and the [`Stdio` sample](../Samples/Stdio)
for full details.

## Samples

The `Samples/` directory contains 21 self-contained examples — each is its
own `Package.swift` with a single executable target:

```bash
cd Samples/SubmitAndStream && swift run
cd Samples/Resumability     && swift run   # actually crashes and resumes
cd Samples/MCP              && swift run   # ARCP fronting an MCP server
```

See [`Samples/README.md`](../Samples/README.md) for the full list and
recommended reading order.
