// LLM-driven generator + reviewer stubs.

import ARCP

func propose(ticket: String, priorDenial: String?) async -> Patch {
    fatalError("elided: Anthropic call returns a candidate Patch")
}

func review(ticket: String, request: Envelope) async -> ReviewVerdict {
    fatalError("elided: reviewer LLM evaluates the proposed patch")
}

extension ARCPClient {
    static var placeholder: ARCPClient {
        get async { fatalError("elided: transport, identity, auth setup") }
    }
}
