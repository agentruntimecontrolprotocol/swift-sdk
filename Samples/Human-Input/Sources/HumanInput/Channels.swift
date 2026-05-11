// Per-channel adapter stubs. Production code calls Twilio / SES / Slack APIs.

import ARCP

func ask(dest: String, prompt: String, schema: JSONValue?) async -> JSONValue {
    fatalError("elided: dispatch prompt to \(dest), await reply, validate against schema")
}

extension ARCPClient {
    static var placeholder: ARCPClient {
        get async { fatalError("elided: transport, identity, auth setup") }
    }
}
