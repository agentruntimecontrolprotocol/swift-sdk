// Worker payload stub. Production version runs the actual job.

import ARCP

func doWork(payload: MessageType) async throws -> JSONValue {
    fatalError("elided: bind to your worker (CrewAI / framework / native code)")
}

extension ARCPClient {
    static var placeholder: ARCPClient {
        get async { fatalError("elided: transport, identity (privileged), auth setup") }
    }
}
