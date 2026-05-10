import ARCP
import ArgumentParser
import Logging

@main
struct ArcpCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "arcp",
        abstract: "Reference CLI for the Agent Runtime Control Protocol (ARCP).",
        version: ARCPVersion.sdk,
        subcommands: [],
        defaultSubcommand: nil
    )

    @Flag(name: .shortAndLong, help: "Print the negotiated wire-protocol version and exit.")
    var version: Bool = false

    mutating func run() async throws {
        let log = Logger(label: "arcp.cli")
        if version {
            print("arcp \(ARCPVersion.sdk) (wire \(ARCPVersion.wire))")
            return
        }
        log.info(
            "arcp scaffold ready",
            metadata: ["wire": "\(ARCPVersion.wire)", "sdk": "\(ARCPVersion.sdk)"]
        )
        print("arcp \(ARCPVersion.sdk) — subcommands land in Phase 7.")
    }
}
