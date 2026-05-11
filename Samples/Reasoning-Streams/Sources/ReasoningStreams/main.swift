// Primary emits reasoning; mirror peer subscribes, critiques back.
//
// The mirror is a peer runtime (`agentHandoff: true`,
// `subscriptions: true`, `trustLevel: trusted`), not an Observer — it
// both reads and writes back into the primary's session.

import ARCP
import Foundation

let maxDepth = 3
let tokenBudget = 8_000

// Primary side -----------------------------------------------------------

func runPrimary(
    _ client: ARCPClient, request: String,
    inboundCritiques: AsyncStream<JSONValue>
) async throws -> String {
    let streamId = StreamId("str_\(UUID().uuidString.prefix(10))")
    try await client.send(
        Envelope(
            sessionId: client.info.sessionId, streamId: streamId,
            payload: .streamOpen(StreamOpenPayload(kind: .thought))
        )
    )

    var iterator = inboundCritiques.makeAsyncIterator()
    var last: JSONValue?
    var answer = ""
    for step in 0..<maxDepth {
        answer = await primaryStep(request, prior: last)
        try await client.send(
            Envelope(
                sessionId: client.info.sessionId, streamId: streamId,
                payload: .streamChunk(
                    StreamChunkPayload(sequence: step, content: answer, role: "assistant_thought")
                )
            )
        )
        last = await withTimeout(seconds: 5) { await iterator.next() }
        if case .object(let o) = last ?? .null, case .string(let sev) = o["severity"] ?? .null,
            sev == "halt"
        {
            break
        }
    }
    return answer
}

// Mirror side ------------------------------------------------------------

func subscribeThoughts(
    _ mirror: ARCPClient, target: SessionId
) async throws -> SubscriptionId {
    let req = Envelope(
        sessionId: mirror.info.sessionId,
        payload: .subscribe(
            SubscribePayload(
                filter: SubscriptionFilter(sessionIds: [target], types: ["stream.chunk"])
            )
        )
    )
    try await mirror.send(req)
    for await reply in mirror.unhandled where reply.correlationId == req.id {
        if case .subscribeAccepted(let p) = reply.payload { return p.subscriptionId }
        break
    }
    throw ARCPError.aborted(reason: "subscribe failed")
}

func runMirror(_ mirror: ARCPClient, target: SessionId) async throws {
    let subId = try await subscribeThoughts(mirror, target: target)
    var spent = 0
    for await env in mirror.unhandled {
        guard case .subscribeEvent(let payload) = env.payload else { continue }
        // The wrapped event carries kind=thought from the primary's stream.
        guard case .object(let inner) = payload.event,
            case .string(let typeName) = inner["type"] ?? .null,
            typeName == "stream.chunk"
        else { continue }

        if spent >= tokenBudget {
            try await mirror.send(
                Envelope(
                    sessionId: mirror.info.sessionId,
                    payload: .unsubscribe(UnsubscribePayload(subscriptionId: subId))
                )
            )
            return
        }

        let content: String
        if case .object(let p) = inner["payload"] ?? .null,
            case .string(let s) = p["content"] ?? .null
        {
            content = s
        } else {
            content = ""
        }
        let (severity, summary, suggestion, consumed) = await critiqueThought(content)
        spent += consumed
        try await mirror.send(
            Envelope(
                sessionId: mirror.info.sessionId,
                target: target.rawValue,
                payload: .unknown(
                    typeName: "agent.delegate",
                    payload: .object([
                        "target": .string("primary"),
                        "task": .string("consume_critique"),
                        "context": .object([
                            "critique": .object([
                                "severity": .string(severity),
                                "summary": .string(summary),
                                "suggestion": .string(suggestion),
                                "consumed_tokens": .number(Double(consumed)),
                            ])
                        ]),
                    ])
                )
            )
        )
    }
}

@main
struct ReasoningStreamsExample {
    static func main() async throws {
        let primary: ARCPClient = await .placeholder
        let mirror: ARCPClient = await .placeholder
        let (inbound, cont) = AsyncStream<JSONValue>.makeStream()

        let route = Task {
            for await env in primary.unhandled {
                if case .unknown(let t, let p) = env.payload, t == "agent.delegate",
                    case .object(let o) = p, case .object(let ctx) = o["context"] ?? .null,
                    let critique = ctx["critique"]
                {
                    cont.yield(critique)
                }
            }
        }
        let mirrorTask = Task { try await runMirror(mirror, target: primary.info.sessionId) }

        let answer = try await runPrimary(
            primary,
            request: "Argue both sides: serializable vs snapshot iso?",
            inboundCritiques: inbound
        )
        print(answer)

        route.cancel()
        mirrorTask.cancel()
        await primary.close()
        await mirror.close()
    }
}
