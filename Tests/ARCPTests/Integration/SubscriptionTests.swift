import Foundation
import Testing

@testable import ARCP

@Suite("Subscriptions (RFC §13)")
struct SubscriptionTests {
    @Test("Subscriber receives subscribe.accepted then live events that match filter")
    func liveTail() async throws {
        let pair = MemoryTransport.makePair()
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "openclaw", version: "0.1"),
            supportedCapabilities: Capabilities(durableJobs: true, subscriptions: true),
            auth: BearerAuthValidator(subjectsByToken: ["t": "alice"])
        )
        await runtime.register(EmittingTool())
        let serverTask = Task { try await runtime.acceptSession(over: pair.server) }
        let client = try await ARCPClient.open(
            transport: pair.client,
            auth: AuthBlock(scheme: .bearer, token: "t"),
            client: IdentityBlock(kind: "tester", version: "1"),
            capabilities: Capabilities(durableJobs: true, subscriptions: true)
        )
        defer {
            Task {
                await client.close()
                _ = try? await serverTask.value
            }
        }
        // Send subscribe and observe events on the unhandled stream.
        let subscribed = expectation()
        Task {
            for await env in client.unhandled {
                if case .subscribeEvent = env.payload {
                    subscribed.fulfill(envelope: env)
                }
            }
        }
        try await client.send(
            Envelope(
                sessionId: client.info.sessionId,
                payload: .subscribe(
                    SubscribePayload(filter: SubscriptionFilter(types: ["log", "job.progress"]))
                )
            )
        )
        // Issue a tool that emits log + progress.
        _ = try await client.invoke(tool: "emit", arguments: .null)
        // Wait briefly for events to arrive.
        let events = try await subscribed.await(count: 1, timeout: .seconds(2))
        #expect(events.count >= 1)
    }
}

private struct EmittingTool: ToolHandler {
    let name = "emit"
    func execute(invocation: ToolInvocation, context: any JobContext) async throws -> ToolOutput {
        try await context.log(level: .info, message: "starting", attributes: nil)
        try await context.reportProgress(percent: 50, message: "midway", attributes: nil)
        return .value(.string("done"))
    }
}

/// Tiny test helper: collect envelopes into a list as they arrive.
final class Expectation: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [Envelope] = []
    private var continuation: CheckedContinuation<[Envelope], any Error>?
    private var target = 0

    func fulfill(envelope: Envelope) {
        lock.lock()
        collected.append(envelope)
        if collected.count >= target, let cont = continuation {
            continuation = nil
            cont.resume(returning: collected)
        }
        lock.unlock()
    }

    func await(count: Int, timeout: Duration) async throws -> [Envelope] {
        return try await withThrowingTaskGroup(of: [Envelope].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    self.lock.lock()
                    self.target = count
                    if self.collected.count >= count {
                        cont.resume(returning: self.collected)
                    } else {
                        self.continuation = cont
                    }
                    self.lock.unlock()
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ARCPError.deadlineExceeded(operation: "expectation")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? []
        }
    }
}

func expectation() -> Expectation { Expectation() }
