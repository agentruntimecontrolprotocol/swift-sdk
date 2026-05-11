// Sink stubs. Real versions ship envelopes to stdout / SQLite / OTLP.

import ARCP
import Foundation

protocol EventSink: Sendable {
    func handle(_ event: JSONValue) async
}

struct StdoutSink: EventSink {
    func handle(_ event: JSONValue) async {
        // Real version: structured-logger.log("event", fields: event)
        fatalError("elided")
    }
}

struct SQLiteSink: EventSink {
    let path: String
    func handle(_ event: JSONValue) async {
        // Real version: insert into the SDK's eventlog schema.
        fatalError("elided")
    }
}

struct OTLPSink: EventSink {
    let endpoint: String
    func handle(_ event: JSONValue) async {
        // Real version: translate `metric` and `trace.span` payloads into OTLP.
        fatalError("elided")
    }
}

extension ARCPClient {
    static var placeholder: ARCPClient {
        get async { fatalError("elided: transport, identity, auth setup") }
    }
}
