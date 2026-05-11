// SQL classifier stub. Production version uses sqlglot or a real parser.

import ARCP

func classify(sql: String) -> StatementClass {
    // Real version: parse with SwiftSQL/sqlite-utils/regex; return op + tables.
    fatalError("elided: replace with sqlglot-equivalent classifier")
}

extension ARCPClient {
    static var placeholder: ARCPClient {
        get async { fatalError("elided: transport, identity, auth setup") }
    }
}
