// Boot three Observer clients on a single producing session.
//
// Each observer subscribes with a different filter and routes incoming
// `subscribe.event` envelopes to a sink. None of them ever issue a command.

import ARCP
import Foundation

let stdoutTypes: [String] = [
    "log", "job.started", "job.progress", "job.completed", "job.failed", "tool.error",
]
let otlpTypes: [String] = ["metric", "trace.span"]

func subscribe(
    _ client: ARCPClient,
    target: SessionId,
    types: [String]?
) async throws {
    let filter = SubscriptionFilter(sessionIds: [target], types: types)
    try await client.send(
        Envelope(
            sessionId: client.info.sessionId,
            payload: .subscribe(SubscribePayload(filter: filter))
        )
    )
}

func unwrapEvent(_ env: Envelope) -> JSONValue? {
    if case .subscribeEvent(let payload) = env.payload { return payload.event }
    return nil
}

func attach(target: SessionId, types: [String]?, sink: any EventSink) async throws {
    let client: ARCPClient = await .placeholder  // transport, identity, auth elided
    try await subscribe(client, target: target, types: types)
    for await env in client.unhandled {
        if let inner = unwrapEvent(env) {
            await sink.handle(inner)
        }
    }
    await client.close()
}

@main
struct SubscriptionsExample {
    static func main() async throws {
        let target = SessionId("ses_target")
        let stdout = StdoutSink()
        let sqlite = SQLiteSink(path: "replay.sqlite")
        let otlp = OTLPSink(endpoint: "https://otlp.example/v1/traces")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await attach(target: target, types: stdoutTypes, sink: stdout) }
            group.addTask { try await attach(target: target, types: nil, sink: sqlite) }
            group.addTask { try await attach(target: target, types: otlpTypes, sink: otlp) }
            try await group.waitForAll()
        }
    }
}
