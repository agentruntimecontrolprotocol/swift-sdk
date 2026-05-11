// Fan `human.input.request` across channels; resolve on first.
//
// First responder wins. Losing channels get a `human.input.cancelled`
// so they can update their UI ("answered elsewhere").

import ARCP
import Foundation

let destinations = ["ntfy:phone", "email:oncall", "slack:ops"]

func fanOut(_ client: ARCPClient, request: Envelope) async throws {
    guard case .humanInputRequest(let payload) = request.payload else { return }
    let timeout = max(0, payload.expiresAt.timeIntervalSinceNow)

    actor First {
        var winner: (dest: String, value: JSONValue)?
        func tryClaim(_ dest: String, _ value: JSONValue) -> Bool {
            if winner == nil {
                winner = (dest, value)
                return true
            }
            return false
        }
    }
    let first = First()

    try await withThrowingTaskGroup(of: Void.self) { group in
        for dest in destinations {
            group.addTask {
                let value = await ask(dest: dest, prompt: payload.prompt, schema: payload.responseSchema)
                _ = await first.tryClaim(dest, value)
            }
        }
        group.addTask {
            try await Task.sleep(for: .seconds(Int(timeout)))
        }
        try await group.next()
        group.cancelAll()
    }

    guard let (dest, value) = await first.winner else {
        // Deadline elapsed; translate timeout into the cancelled-input
        // shape (RFC §12.4).
        try await client.send(
            Envelope(
                sessionId: client.info.sessionId, correlationId: request.id,
                payload: .humanInputCancelled(
                    HumanInputCancelledPayload(
                        code: .deadlineExceeded,
                        reason: "no channel responded before expires_at"
                    )
                )
            )
        )
        return
    }

    try await client.send(
        Envelope(
            sessionId: client.info.sessionId, correlationId: request.id,
            payload: .humanInputResponse(
                HumanInputResponsePayload(value: value, respondedBy: dest, respondedAt: Date())
            )
        )
    )
    // Tell the losing destinations the question is settled.
    let losers = destinations.filter { $0 != dest }
    if !losers.isEmpty {
        try await client.send(
            Envelope(
                sessionId: client.info.sessionId, correlationId: request.id,
                payload: .humanInputCancelled(
                    HumanInputCancelledPayload(code: .ok, reason: "answered elsewhere")
                )
            )
        )
    }
}

@main
struct HumanInputExample {
    static func main() async throws {
        let client: ARCPClient = await .placeholder
        try await withThrowingTaskGroup(of: Void.self) { group in
            for await env in client.unhandled {
                if case .humanInputRequest = env.payload {
                    group.addTask { try await fanOut(client, request: env) }
                }
            }
        }
        await client.close()
    }
}
