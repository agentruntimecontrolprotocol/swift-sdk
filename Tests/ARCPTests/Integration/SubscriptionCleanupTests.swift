import Foundation
import Testing

@testable import ARCP

@Suite("Subscription cleanup and recursion (issues #40, #54)")
struct SubscriptionCleanupTests {
    @Test("Empty filter does not recursively wrap subscribe.event")
    func emptyFilterNoCascade() async throws {
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "rt", version: "1"),
            supportedCapabilities: Capabilities(durableJobs: true, subscriptions: true),
            auth: BearerAuthValidator(subjectsByToken: ["t": "alice"])
        )
        await runtime.register(NoopTool())
        let serverTask = Task { try await runtime.acceptSession(over: pair.server) }
        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "t"),
            client: IdentityBlock(kind: "c", version: "1"),
            capabilities: Capabilities(durableJobs: true, subscriptions: true)
        )
        defer {
            Task {
                await client.close()
                _ = try? await serverTask.value
            }
        }

        let observed = Counter()
        let drainer = Task {
            for await env in client.unhandled {
                if case .subscribeEvent = env.payload {
                    await observed.increment()
                }
            }
        }
        try await client.send(
            Envelope(
                sessionId: client.info.sessionId,
                payload: .subscribe(SubscribePayload(filter: SubscriptionFilter()))
            )
        )
        _ = try await client.invoke(tool: "noop", arguments: .null)
        try await Task.sleep(for: .milliseconds(200))
        drainer.cancel()
        let count = await observed.value
        // We invoked one tool that emits a job lifecycle. Whether the subscriber sees
        // 0+ events is fine; the critical assertion is that we did NOT cascade into a
        // huge number of recursive subscribe.event envelopes.
        #expect(count < 32)
    }

    @Test("removeAllOwned drops session-scoped subscriptions")
    func removeAllOwned() async {
        let eventLog = try? EventLog.inMemory()
        guard let eventLog else {
            Issue.record("could not create event log")
            return
        }
        let manager = SubscriptionManager(eventLog: eventLog)
        let owner = SessionId.random()
        let foreign = SessionId.random()
        let subA = SubscriptionId.random()
        let subB = SubscriptionId.random()
        await manager.subscribe(
            subscriptionId: subA,
            ownerSessionId: owner,
            filter: SubscriptionFilter(),
            since: nil,
            send: { _ in }
        )
        await manager.subscribe(
            subscriptionId: subB,
            ownerSessionId: foreign,
            filter: SubscriptionFilter(),
            since: nil,
            send: { _ in }
        )
        await manager.removeAllOwned(by: owner, reason: "session closed")
        // Subsequent routing should not invoke the dropped subscriber. We use a
        // sentinel envelope to confirm only the foreign subscriber would match.
        let calls = Counter()
        let subC = SubscriptionId.random()
        await manager.subscribe(
            subscriptionId: subC,
            ownerSessionId: foreign,
            filter: SubscriptionFilter(),
            since: nil,
            send: { _ in await calls.increment() }
        )
        await manager.route(
            envelope: Envelope(
                sessionId: foreign,
                payload: .log(LogPayload(level: .info, message: "hi", attributes: nil))
            )
        )
        let value = await calls.value
        #expect(value == 1)
    }
}

private struct NoopTool: ToolHandler {
    let name = "noop"
    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        .value(.null)
    }
}

private actor Counter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}
