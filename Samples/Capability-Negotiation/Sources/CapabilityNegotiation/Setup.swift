// Per-peer client setup elision.

import ARCP

extension ARCPClient {
    static var placeholder: ARCPClient {
        get async { fatalError("elided: per-peer transport, identity, auth setup") }
    }
}
