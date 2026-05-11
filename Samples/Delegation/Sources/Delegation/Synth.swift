// Final synthesis stub — production code calls an LLM with all peer outputs.

import ARCP

func synthesize(request: String, jobs: [DelegatedJob]) -> String {
    fatalError("elided: combine peer outputs into one answer")
}

extension ARCPClient {
    static var placeholder: ARCPClient {
        get async { fatalError("elided: transport, identity, auth setup") }
    }
}
