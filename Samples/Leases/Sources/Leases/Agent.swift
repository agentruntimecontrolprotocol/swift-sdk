// Stub for the LLM-driven step generator. Production code calls Anthropic.

import ARCP
import Foundation

struct ToolCall: Sendable {
    let argv: [String]
    let reason: String
}

struct LLMStep: Sendable {
    let thought: String
    let toolCall: ToolCall?
    let final: String?
}

func llmLoop(prompt: String) -> AsyncThrowingStream<LLMStep, any Error> {
    AsyncThrowingStream { _ in
        fatalError("elided: bind to your LLM provider")
    }
}

extension ARCPClient {
    static var placeholder: ARCPClient {
        get async { fatalError("elided: transport, identity (constrained), auth setup") }
    }
}
