# Delegation & Handoff

## Delegation (`agent.delegate`)

A running handler can spawn a sub-agent to handle part of the work
(RFC §14). The sub-agent receives a scoped `tool.invoke`, runs
independently, and reports back to the parent.

```swift
struct OrchestratorHandler: ToolHandler {
    let name = "orchestrate"

    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        // Delegate to a specialist
        let result = try await context.delegate(
            to: AgentRef(name: "specialist", version: "1.0"),
            tool: "analyse",
            arguments: invocation.arguments["data"] ?? .null,
            leaseConstraints: invocation.leaseConstraints   // forward the lease
        )
        return .value(result)
    }
}
```

`delegate(to:tool:arguments:)` creates a child `tool.invoke`, waits
for `job.completed` on the sub-agent, and returns the result. The child
job inherits the parent's `traceId` for end-to-end tracing.

See the [`Delegation` sample](../../Samples/Delegation).

## Handoff (`agent.handoff`)

A handoff transfers the conversation entirely to another agent. The
current agent packages its transcript as an artifact and declares the
next agent to run (RFC §14).

```swift
func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
    let transcriptRef = try await context.storeArtifact(
        data: encodeTranscript(),
        contentType: "application/json"
    )
    return try await context.handoff(
        to: AgentRef(name: "specialist", version: "2.0"),
        transcript: transcriptRef,
        reason: "needs specialist expertise"
    )
}
```

The runtime emits `agent.handoff`; the orchestrator creates a new
session with the target agent, forwarding the transcript artifact.

See the [`Handoff` sample](../../Samples/Handoff).

## Agent versions

When delegating, pin a specific version to avoid breaking changes:

```swift
let ref = AgentRef(name: "summariser", version: "1.2.0")
```

If the named version is not available, the runtime rejects the job
with `AGENT_VERSION_NOT_AVAILABLE`.

See the [`AgentVersions` sample](../../Samples/AgentVersions).

## Multi-agent tracing

Set a `traceId` on the initial `tool.invoke`. All child jobs (delegated
or handed-off) inherit it. W3C `traceparent` propagation is supported
via `TraceContext`.

See [Observability](observability.md) and the
[`Tracing` sample](../../Samples/Tracing).
