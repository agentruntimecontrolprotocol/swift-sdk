import ARCP
import ArgumentParser
import Foundation
import Logging

@main
struct ArcpCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "arcp",
        abstract: "Reference CLI for the Agent Runtime Control Protocol (ARCP).",
        version: ARCPVersion.sdk,
        subcommands: [
            ServeCommand.self,
            SendCommand.self,
            TailCommand.self,
            ReplayCommand.self,
        ]
    )
}

/// `arcp serve` — accept a single ARCP session over stdio.
struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Accept a single ARCP session over stdio (NDJSON)."
    )

    @Option(help: "Bearer token to accept (defaults to a test token).")
    var token: String = "demo-token"

    @Option(help: "Subject mapped to the bearer token.")
    var subject: String = "demo-user"

    func run() async throws {
        let runtime = try ARCPRuntime(
            identity: IdentityBlock(kind: "example-runtime-cli", version: ARCPVersion.sdk),
            supportedCapabilities: Capabilities(
                streaming: true,
                durableJobs: true,
                humanInput: true,
                artifacts: true,
                subscriptions: true
            ),
            auth: BearerAuthValidator(subjectsByToken: [token: subject])
        )
        let transport = StdioTransport()
        FileHandle.standardError.write(
            Data("arcp serve: ready (wire \(ARCPVersion.wire))\n".utf8)
        )
        _ = try await runtime.acceptSession(over: transport)
    }
}

/// `arcp send` — open a session and send a single envelope, print result.
struct SendCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send a single tool.invoke over stdio and print the result."
    )

    @Argument(help: "Tool name to invoke.")
    var tool: String

    @Option(help: "JSON arguments for the tool.")
    var args: String = "{}"

    @Option(help: "Bearer token.")
    var token: String = "demo-token"

    func run() async throws {
        let transport = StdioTransport()
        let argsData = args.data(using: .utf8) ?? Data()
        let argsValue = try Envelope.makeDecoder().decode(JSONValue.self, from: argsData)
        let client = try await ARCPClient.open(
            transport: transport,
            auth: AuthBlock(scheme: .bearer, token: token),
            client: IdentityBlock(kind: "arcp-cli", version: ARCPVersion.sdk)
        )
        let result = try await client.invoke(tool: tool, arguments: argsValue)
        switch result.outcome {
        case .completed(let payload):
            print(String(decoding: try Envelope.makeEncoder().encode(payload), as: UTF8.self))
        case .failed(let envelope):
            FileHandle.standardError.write(Data("[\(envelope.code.rawValue)] \(envelope.message)\n".utf8))
            throw ExitCode.failure
        case .cancelled(let payload):
            FileHandle.standardError.write(Data("cancelled: \(payload.reason)\n".utf8))
            throw ExitCode.failure
        }
        await client.close()
    }
}

/// `arcp tail` — open a subscription and print incoming events as NDJSON.
struct TailCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tail",
        abstract: "Subscribe over stdio and print every subscribe.event payload."
    )

    @Option(help: "Bearer token.")
    var token: String = "demo-token"

    @Option(help: "Comma-separated message types to filter.")
    var types: String = "log,job.progress,job.completed,job.failed,job.cancelled"

    func run() async throws {
        let transport = StdioTransport()
        let client = try await ARCPClient.open(
            transport: transport,
            auth: AuthBlock(scheme: .bearer, token: token),
            client: IdentityBlock(kind: "arcp-cli", version: ARCPVersion.sdk),
            capabilities: Capabilities(subscriptions: true)
        )
        let typeList = types.split(separator: ",").map(String.init)
        try await client.send(
            Envelope(
                sessionId: client.info.sessionId,
                payload: .subscribe(
                    SubscribePayload(filter: SubscriptionFilter(types: typeList))
                )
            )
        )
        for await env in client.unhandled {
            if case .subscribeEvent(let payload) = env.payload {
                let data = try Envelope.makeEncoder().encode(payload.event)
                print(String(decoding: data, as: UTF8.self))
            }
        }
    }
}

/// `arcp replay` — load a SQLite event log file and print every envelope for a session.
struct ReplayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "replay",
        abstract: "Replay envelopes from a SQLite event log."
    )

    @Argument(help: "Path to the SQLite event-log file.")
    var path: String

    @Argument(help: "Session id to replay.")
    var sessionId: String

    @Option(help: "Optional after-message-id cutoff.")
    var after: String?

    func run() async throws {
        let log = try EventLog(path: path)
        let envelopes = try await log.replay(
            sessionId: SessionId(sessionId),
            after: after.map { MessageId($0) }
        )
        let encoder = Envelope.makeEncoder()
        for envelope in envelopes {
            let data = try encoder.encode(envelope)
            print(String(decoding: data, as: UTF8.self))
        }
    }
}
