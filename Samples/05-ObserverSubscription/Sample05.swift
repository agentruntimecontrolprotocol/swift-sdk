import ARCP
import Foundation

/// Sample 05 — open a session, subscribe to log + progress events, run a tool,
/// and observe events arriving on the unhandled stream.
@main
struct Sample05ObserverSubscription {
    static func main() async throws {
        print("Sample 05 — observer subscription (wire \(ARCPVersion.wire))")
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "sample-runtime", version: ARCPVersion.sdk),
            supportedCapabilities: Capabilities(
                streaming: true,
                durableJobs: true,
                subscriptions: true
            ),
            auth: BearerAuthValidator(subjectsByToken: ["demo": "alice"])
        )
        await runtime.register(ChattyTool())
        let serverTask = Task { try await runtime.acceptSession(over: pair.server) }

        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "demo"),
            client: IdentityBlock(kind: "sample-client", version: ARCPVersion.sdk),
            capabilities: Capabilities(streaming: true, durableJobs: true, subscriptions: true)
        )

        try await client.send(
            Envelope(
                sessionId: client.info.sessionId,
                payload: .subscribe(
                    SubscribePayload(
                        filter: SubscriptionFilter(types: ["log", "job.progress", "job.completed"])
                    )
                )
            )
        )

        let observer = Task {
            for await env in client.unhandled {
                if case .subscribeEvent(let payload) = env.payload {
                    print("event: \(payload.event)")
                }
            }
        }

        _ = try await client.invoke(tool: "chat", arguments: .null)

        try await Task.sleep(for: .milliseconds(50))
        await client.close()
        observer.cancel()
        _ = try await serverTask.value
    }
}

private struct ChattyTool: ToolHandler {
    let name = "chat"
    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        try await context.log(level: .info, message: "starting", attributes: nil)
        try await context.reportProgress(percent: 50, message: "halfway", attributes: nil)
        try await context.log(level: .info, message: "done", attributes: nil)
        return .value(.string("ok"))
    }
}
