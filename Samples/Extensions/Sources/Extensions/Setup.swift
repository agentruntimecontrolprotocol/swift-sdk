// Setup elision — production code wires WebSocket transport to a runtime
// that advertises `capabilities.extensions = allExtensions`.

import ARCP

extension ARCPClient {
    static var placeholder: ARCPClient {
        get async { fatalError("elided: transport, identity, auth, capabilities") }
    }
}
