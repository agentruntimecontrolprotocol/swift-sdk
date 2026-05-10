/// Negotiate capabilities between client offer and runtime support. RFC §7.
///
/// The negotiated capability set is the *intersection* of what the runtime
/// supports and what the client requested. Required-but-unsupported features
/// (declared via `required`) cause a `session.rejected` with `UNIMPLEMENTED`.
public struct CapabilityNegotiator: Sendable {
    public let runtimeSupported: Capabilities
    public let required: Set<String>

    public init(runtimeSupported: Capabilities, required: Set<String> = []) {
        self.runtimeSupported = runtimeSupported
        self.required = required
    }

    /// Returns the negotiated capability set, or throws if a required feature
    /// is missing on either side.
    public func negotiate(clientOffered: Capabilities) throws -> Capabilities {
        for requirement in required {
            guard isSupportedOnBothSides(requirement, runtime: runtimeSupported, client: clientOffered)
            else {
                throw ARCPError.unimplemented(
                    section: "§7",
                    detail: "required capability \(requirement) is not supported"
                )
            }
        }
        // intersect each boolean
        return Capabilities(
            streaming: runtimeSupported.streaming && clientOffered.streaming,
            durableJobs: runtimeSupported.durableJobs && clientOffered.durableJobs,
            checkpoints: runtimeSupported.checkpoints && clientOffered.checkpoints,
            binaryStreams: runtimeSupported.binaryStreams && clientOffered.binaryStreams,
            agentHandoff: runtimeSupported.agentHandoff && clientOffered.agentHandoff,
            humanInput: runtimeSupported.humanInput && clientOffered.humanInput,
            artifacts: runtimeSupported.artifacts && clientOffered.artifacts,
            subscriptions: runtimeSupported.subscriptions && clientOffered.subscriptions,
            scheduledJobs: runtimeSupported.scheduledJobs && clientOffered.scheduledJobs,
            anonymous: runtimeSupported.anonymous && clientOffered.anonymous,
            interrupt: runtimeSupported.interrupt && clientOffered.interrupt,
            heartbeatRecovery: runtimeSupported.heartbeatRecovery,
            heartbeatIntervalSeconds: max(
                runtimeSupported.heartbeatIntervalSeconds,
                clientOffered.heartbeatIntervalSeconds
            ),
            binaryEncoding: Array(
                Set(runtimeSupported.binaryEncoding).intersection(Set(clientOffered.binaryEncoding))
            ),
            artifactRetention: runtimeSupported.artifactRetention,
            extensions: Array(
                Set(runtimeSupported.extensions).intersection(Set(clientOffered.extensions))
            ),
            extras: runtimeSupported.extras.merging(clientOffered.extras) { lhs, _ in lhs }
        )
    }

    private func isSupportedOnBothSides(
        _ key: String,
        runtime: Capabilities,
        client: Capabilities
    ) -> Bool {
        switch key {
        case "streaming": return runtime.streaming && client.streaming
        case "durable_jobs": return runtime.durableJobs && client.durableJobs
        case "checkpoints": return runtime.checkpoints && client.checkpoints
        case "binary_streams": return runtime.binaryStreams && client.binaryStreams
        case "agent_handoff": return runtime.agentHandoff && client.agentHandoff
        case "human_input": return runtime.humanInput && client.humanInput
        case "artifacts": return runtime.artifacts && client.artifacts
        case "subscriptions": return runtime.subscriptions && client.subscriptions
        case "scheduled_jobs": return runtime.scheduledJobs && client.scheduledJobs
        case "anonymous": return runtime.anonymous && client.anonymous
        case "interrupt": return runtime.interrupt && client.interrupt
        default:
            return runtime.extras[key] == true && client.extras[key] == true
        }
    }
}
