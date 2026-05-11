// Cheap-tier LLM call stub. Production version returns a real (answer, confidence).

import ARCP

func attempt(request: String) async -> (String, Double) {
    fatalError("elided: cheap-tier model call returns answer + confidence")
}

extension ARCPClient {
    static var placeholder: ARCPClient {
        get async { fatalError("elided: pinned WebSocket transport, identity, auth") }
    }
}
