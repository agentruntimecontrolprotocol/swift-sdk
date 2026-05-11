// Capability-driven peer routing with ordered fallback + cost rollup.
//
// Marketplace fields ride alongside the standard `Capabilities` fields
// as `arcpx.market.*.v1` extensions; no extra round trip to learn cost.

import ARCP
import Foundation

let peers = ["anthropic-haiku", "anthropic-sonnet", "openai-4o", "groq-llama"]
let fallbackChains: [String: [String]] = [
    "cheap_fast": ["groq-llama", "anthropic-haiku", "openai-4o"],
    "balanced": ["anthropic-sonnet", "openai-4o", "anthropic-haiku"],
    "deep": ["anthropic-sonnet"],
]
let costCeiling = 8.0
let latencyCeiling = 800
let retryable: Set<ErrorCode> = [.resourceExhausted, .unavailable, .deadlineExceeded, .aborted]

struct Profile: Sendable {
    let costPerMTok: Double
    let p50LatencyMs: Int
    let modelClass: String
}

func profile(from caps: Capabilities) -> Profile {
    // Capabilities.extensions is a [String]; in production the marketplace
    // values would arrive in a parallel extras-style map keyed under
    // `arcpx.market.*.v1`. NOTE: §21 covers extension *messages* but not
    // extension *capability values* — load-bearing convention here.
    Profile(costPerMTok: 0, p50LatencyMs: 0, modelClass: "unknown")
}

func candidateChain(_ profiles: [String: Profile], requestClass: String) -> [String] {
    (fallbackChains[requestClass] ?? []).filter { name in
        guard let p = profiles[name] else { return false }
        return p.costPerMTok <= costCeiling && p.p50LatencyMs <= latencyCeiling
    }
}

func invokeWithFallback(
    clients: [String: ARCPClient], chain: [String],
    tool: String, arguments: JSONValue, traceId: TraceId
) async throws -> Envelope {
    var lastError: ARCPError?
    for name in chain {
        guard let c = clients[name] else { continue }
        let env = Envelope(
            sessionId: c.info.sessionId,
            traceId: traceId,
            extensions: ["arcpx.market.peer.v1": .string(name)],
            payload: .toolInvoke(ToolInvokePayload(tool: tool, arguments: arguments))
        )
        do {
            try await c.send(env)
            for await reply in c.unhandled where reply.correlationId == env.id {
                if case .toolError(let e) = reply.payload {
                    if retryable.contains(e.error.code) { break }
                    throw ARCPError.aborted(reason: e.error.message)
                }
                return reply
            }
        } catch let e as ARCPError {
            lastError = e
            continue
        }
    }
    throw lastError ?? ARCPError.unavailable(reason: "no peers available", retryAfter: nil)
}

actor Usage {
    var tokensIn = 0
    var tokensOut = 0
    var costUsd = 0.0
    var byPeer: [String: Double] = [:]
}

func consumeMetric(_ env: Envelope, totals: Usage) async {
    guard case .metric(let p) = env.payload else { return }
    if p.name == "tokens.used" {
        let kind = p.dims?["kind"]
        if case .string(let k) = kind {
            if k == "input" { await totals.add(tokensIn: Int(p.value)) }
            if k == "output" { await totals.add(tokensOut: Int(p.value)) }
        }
    } else if p.name == "cost.usd" {
        let peer =
            (p.dims?["peer"]).flatMap { v -> String? in
                if case .string(let s) = v { return s }
                return nil
            } ?? "unknown"
        await totals.add(cost: p.value, peer: peer)
    }
}

extension Usage {
    func add(tokensIn: Int = 0, tokensOut: Int = 0) {
        self.tokensIn += tokensIn
        self.tokensOut += tokensOut
    }
    func add(cost: Double, peer: String) {
        costUsd += cost
        byPeer[peer, default: 0] += cost
    }
}

@main
struct CapabilityNegotiationExample {
    static func main() async throws {
        var clients: [String: ARCPClient] = [:]
        var profiles: [String: Profile] = [:]
        for name in peers {
            let c: ARCPClient = await .placeholder
            clients[name] = c
            profiles[name] = profile(from: c.info.negotiatedCapabilities)
        }
        let totals = Usage()

        let drains = clients.values.map { c in
            Task { for await env in c.unhandled { await consumeMetric(env, totals: totals) } }
        }

        let chain = candidateChain(profiles, requestClass: "balanced")
        let reply = try await invokeWithFallback(
            clients: clients, chain: chain, tool: "chat.completion",
            arguments: .object(["prompt": .string("Hello"), "tenant": .string("acme-corp")]),
            traceId: TraceId("trace_\(UUID().uuidString.prefix(12))")
        )
        if case .string(let chosen) = reply.extensions?["arcpx.market.peer.v1"] ?? .null {
            print("chosen=\(chosen)")
        }
        print("usage cost=\(await totals.costUsd)")

        for d in drains { d.cancel() }
        for c in clients.values { await c.close() }
    }
}
