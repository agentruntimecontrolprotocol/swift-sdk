// Per-step body stub. Production version dispatches to plan / gather /
// synthesize / critique / finalize implementations.

import ARCP

func runStep(
    _ client: ARCPClient, jobId: JobId, step: String, inputs: JSONValue
) async throws -> JSONValue {
    fatalError("elided: actual step body — LLM call, tool, etc.")
}

extension ARCPClient {
    static var placeholder: ARCPClient {
        get async { fatalError("elided: transport, identity, auth setup") }
    }
}
