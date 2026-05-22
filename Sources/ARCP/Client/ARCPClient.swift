import Foundation
import Logging

/// Client-side handle for an ARCP session. Drives the four-step handshake
/// (RFC §8.1) and exposes message send/receive primitives. Phase 2 ships the
/// handshake, `ping`, and a generic `send` / unhandled-stream surface; richer
/// operations (`invoke`, `subscribe`, etc.) land in subsequent phases.
public actor ARCPClient {
    public nonisolated let info: SessionInfo
    private let transport: any Transport
    private let log: Logger
    private let mailbox: Mailbox<Envelope>
    private let drainer: Task<Void, Never>
    private var dispatcher: Task<Void, Never>?
    private var pendingPongs: [MessageId: CheckedContinuation<PongPayload, any Error>] = [:]
    private var pendingByInvoke: [MessageId: JobInvocationState] = [:]
    private var invokeByJobId: [JobId: MessageId] = [:]
    private var resultChunkStreams: [JobId: ResultChunkStream] = [:]
    private var unhandledContinuation: AsyncStream<Envelope>.Continuation?
    private var permissionHandler: any PermissionHandler = DefaultPermissionHandler()

    private struct JobInvocationState {
        var jobId: JobId?
        var continuation: CheckedContinuation<(JobOutcome, JobId?), any Error>?
        var progressContinuation: AsyncStream<JobProgressPayload>.Continuation?
    }

    /// Result of a completed job invocation.
    public enum JobOutcome: Sendable {
        case completed(JobCompletedPayload)
        case failed(ErrorEnvelope)
        case cancelled(JobCancelledPayload)
    }

    /// Async stream of envelopes the client did not consume internally.
    /// Phase 3+ subsystems (job tracker, stream subscribers, …) will drain
    /// this and route to typed callbacks.
    public nonisolated let unhandled: AsyncStream<Envelope>

    private init(
        info: SessionInfo,
        transport: any Transport,
        mailbox: Mailbox<Envelope>,
        drainer: Task<Void, Never>
    ) {
        self.info = info
        self.transport = transport
        self.mailbox = mailbox
        self.drainer = drainer
        self.log = Logger(label: "arcp.client.\(info.sessionId)")
        var continuation: AsyncStream<Envelope>.Continuation!
        self.unhandled = AsyncStream { continuation = $0 }
        self.unhandledContinuation = continuation
    }

    /// Open a new ARCP session over `transport`. Performs the full handshake
    /// (RFC §8.1) and returns once `session.accepted` is received.
    public static func open(
        transport: any Transport,
        auth: AuthBlock,
        client: IdentityBlock,
        capabilities: Capabilities = Capabilities()
    ) async throws -> ARCPClient {
        let mailbox = Mailbox<Envelope>()
        let drainer = Task {
            for await envelope in transport.receive {
                await mailbox.put(envelope)
            }
            await mailbox.finish()
        }

        do {
            try await transport.send(
                Envelope(
                    payload: .sessionOpen(
                        SessionOpenPayload(auth: auth, client: client, capabilities: capabilities)
                    )
                )
            )
            let accepted = try await Self.completeHandshake(
                transport: transport,
                mailbox: mailbox,
                auth: auth
            )
            let info = SessionInfo(
                sessionId: accepted.payload.sessionId,
                principal: AuthenticatedPrincipal(
                    subject: client.principal ?? client.kind,
                    trustLevel: accepted.payload.runtime.trustLevel ?? .trusted
                ),
                clientIdentity: client,
                runtimeIdentity: accepted.payload.runtime,
                negotiatedCapabilities: accepted.payload.capabilities
            )
            let value = ARCPClient(
                info: info,
                transport: transport,
                mailbox: mailbox,
                drainer: drainer
            )
            await value.startDispatcher()
            return value
        } catch {
            drainer.cancel()
            await transport.close()
            throw error
        }
    }

    private struct AcceptedHandshake: Sendable {
        let payload: SessionAcceptedPayload
    }

    private static func completeHandshake(
        transport: any Transport,
        mailbox: Mailbox<Envelope>,
        auth: AuthBlock
    ) async throws -> AcceptedHandshake {
        while let envelope = await mailbox.next() {
            switch envelope.payload {
            case .sessionAccepted(let accepted):
                return AcceptedHandshake(payload: accepted)
            case .sessionChallenge(let challenge):
                try await transport.send(
                    Envelope(
                        correlationId: envelope.id,
                        payload: .sessionAuthenticate(
                            SessionAuthenticatePayload(auth: auth, nonce: challenge.nonce)
                        )
                    )
                )
            case .sessionRejected(let payload):
                throw ARCPError.unauthenticated(detail: payload.error.message)
            case .sessionUnauthenticated(let payload):
                throw ARCPError.unauthenticated(detail: payload.detail)
            case .nack(let payload):
                throw ARCPError.unauthenticated(detail: payload.error.message)
            default:
                throw ARCPError.invalidArgument(
                    field: "type",
                    detail: "unexpected handshake message: \(envelope.payload.typeName)"
                )
            }
        }
        throw ARCPError.unauthenticated(detail: "transport closed before session.accepted")
    }

    private func startDispatcher() {
        dispatcher = Task { [mailbox] in
            while let envelope = await mailbox.next() {
                await self.dispatch(envelope: envelope)
            }
            self.finishUnhandled()
        }
    }

    private func dispatch(envelope: Envelope) async {
        switch envelope.payload {
        case .pong(let payload):
            if let id = envelope.correlationId,
                let cont = pendingPongs.removeValue(forKey: id)
            {
                cont.resume(returning: payload)
            } else {
                unhandledContinuation?.yield(envelope)
            }
        case .jobAccepted(let payload):
            if let invokeId = envelope.correlationId, var state = pendingByInvoke[invokeId] {
                state.jobId = payload.jobId
                pendingByInvoke[invokeId] = state
                invokeByJobId[payload.jobId] = invokeId
            } else {
                unhandledContinuation?.yield(envelope)
            }
        case .jobProgress(let payload):
            if let jobId = envelope.jobId, let invokeId = invokeByJobId[jobId],
                let state = pendingByInvoke[invokeId]
            {
                state.progressContinuation?.yield(payload)
            }
        case .jobCompleted(let payload):
            if let jobId = envelope.jobId {
                if let invokeId = invokeByJobId.removeValue(forKey: jobId) {
                    resolve(invokeId: invokeId, outcome: .completed(payload))
                } else {
                    unhandledContinuation?.yield(envelope)
                }
                await finishResultStream(jobId)
            } else {
                unhandledContinuation?.yield(envelope)
            }
        case .jobFailed(let payload):
            if let jobId = envelope.jobId {
                if let invokeId = invokeByJobId.removeValue(forKey: jobId) {
                    resolve(invokeId: invokeId, outcome: .failed(payload.error))
                } else {
                    unhandledContinuation?.yield(envelope)
                }
                await failResultStream(jobId, error: ARCPError.unknown(message: payload.error.message))
            } else {
                unhandledContinuation?.yield(envelope)
            }
        case .jobCancelled(let payload):
            if let jobId = envelope.jobId {
                if let invokeId = invokeByJobId.removeValue(forKey: jobId) {
                    resolve(invokeId: invokeId, outcome: .cancelled(payload))
                } else {
                    unhandledContinuation?.yield(envelope)
                }
                await failResultStream(
                    jobId, error: ARCPError.cancelled(operation: "job", reason: payload.reason))
            } else {
                unhandledContinuation?.yield(envelope)
            }
        case .jobResultChunk(let payload):
            if let jobId = envelope.jobId, let stream = resultChunkStreams[jobId] {
                try? await stream.push(payload)
            }
            unhandledContinuation?.yield(envelope)
        case .toolError(let payload):
            if let invokeId = envelope.correlationId, pendingByInvoke[invokeId] != nil {
                resolve(invokeId: invokeId, outcome: .failed(payload.error))
            }
        case .permissionRequest(let payload):
            Task { [transport, permissionHandler] in
                let decision: PermissionDecision
                do {
                    decision = try await permissionHandler.handle(payload, jobId: envelope.jobId)
                } catch {
                    decision = .denied(reason: "\(error)")
                }
                let outboundPayload: MessageType
                switch decision {
                case .granted(let seconds):
                    outboundPayload = .permissionGrant(
                        PermissionGrantPayload(
                            permission: payload.permission,
                            resource: payload.resource,
                            operation: payload.operation,
                            leaseSeconds: seconds
                        )
                    )
                case .denied(let reason):
                    outboundPayload = .permissionDeny(
                        PermissionDenyPayload(
                            permission: payload.permission,
                            resource: payload.resource,
                            reason: reason
                        )
                    )
                }
                try? await transport.send(
                    Envelope(
                        sessionId: envelope.sessionId,
                        jobId: envelope.jobId,
                        correlationId: envelope.id,
                        payload: outboundPayload
                    )
                )
            }
        default:
            unhandledContinuation?.yield(envelope)
        }
    }

    public func resultChunks(for jobId: JobId) -> ResultChunkStream {
        if let existing = resultChunkStreams[jobId] { return existing }
        let stream = ResultChunkStream()
        resultChunkStreams[jobId] = stream
        return stream
    }

    private func finishResultStream(_ jobId: JobId) async {
        guard let stream = resultChunkStreams.removeValue(forKey: jobId) else { return }
        await stream.finish()
    }

    private func failResultStream(_ jobId: JobId, error: any Error) async {
        guard let stream = resultChunkStreams.removeValue(forKey: jobId) else { return }
        await stream.fail(error)
    }

    /// Register a custom permission handler.
    public func setPermissionHandler(_ handler: any PermissionHandler) {
        self.permissionHandler = handler
    }

    private func resolve(invokeId: MessageId, outcome: JobOutcome) {
        guard let state = pendingByInvoke.removeValue(forKey: invokeId) else { return }
        state.progressContinuation?.finish()
        state.continuation?.resume(returning: (outcome, state.jobId))
    }

    private func finishUnhandled() {
        unhandledContinuation?.finish()
        unhandledContinuation = nil
        for (_, cont) in pendingPongs {
            cont.resume(throwing: ARCPError.unavailable(reason: "transport closed", retryAfter: nil))
        }
        pendingPongs.removeAll()
    }

    /// Send a `ping`, await the corresponding `pong`. Times out after `timeout`.
    @discardableResult
    public func ping(
        nonce: String? = nil, timeout: Duration = .seconds(5)
    ) async throws
        -> PongPayload
    {
        let id = MessageId.random()
        let envelope = Envelope(
            id: id,
            sessionId: info.sessionId,
            payload: .ping(PingPayload(nonce: nonce))
        )
        try await transport.send(envelope)
        return try await withThrowingTaskGroup(of: PongPayload.self) { group in
            group.addTask { [weak self] in
                guard let self = self else {
                    throw ARCPError.unavailable(reason: "client released", retryAfter: nil)
                }
                return try await self.awaitPong(id: id)
            }
            group.addTask { [weak self] in
                try await Task.sleep(for: timeout)
                await self?.failPongWaiter(id: id)
                throw ARCPError.deadlineExceeded(operation: "ping \(id)")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw ARCPError.internal(detail: "ping group empty", cause: nil)
            }
            return result
        }
    }

    private func awaitPong(id: MessageId) async throws -> PongPayload {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PongPayload, Error>) in
            pendingPongs[id] = cont
        }
    }

    private func failPongWaiter(id: MessageId) {
        if let cont = pendingPongs.removeValue(forKey: id) {
            cont.resume(throwing: ARCPError.deadlineExceeded(operation: "ping \(id)"))
        }
    }

    /// Send `session.close` and tear down the underlying transport.
    public func close(reason: String? = nil) async {
        let envelope = Envelope(
            sessionId: info.sessionId,
            payload: .sessionClose(SessionClosePayload(reason: reason))
        )
        try? await transport.send(envelope)
        await transport.close()
        dispatcher?.cancel()
        drainer.cancel()
    }

    /// Lower-level send for callers that need to emit arbitrary envelopes.
    /// The session id is set automatically if absent.
    public func send(_ envelope: Envelope) async throws {
        let stamped = envelope.sessionId == nil ? envelope.with(sessionId: info.sessionId) : envelope
        try await transport.send(stamped)
    }

    /// Invocation result: the assigned job id, the terminal outcome, and an
    /// async stream of progress events that completes alongside the outcome.
    public struct InvocationResult: Sendable {
        public let jobId: JobId?
        public let outcome: JobOutcome
        public let progress: AsyncStream<JobProgressPayload>
    }

    /// Invoke a tool. Awaits the terminal `job.completed` / `job.failed` /
    /// `job.cancelled` envelope and returns it together with a (drained)
    /// progress stream. RFC §6.3 / §10.
    public func invoke(
        tool: String,
        arguments: JSONValue,
        costBudget: CostBudget? = nil,
        modelUse: ModelUse? = nil,
        leaseConstraints: LeaseConstraints? = nil,
        idempotencyKey: IdempotencyKey? = nil
    ) async throws -> InvocationResult {
        let invokeId = MessageId.random()
        var progressContinuation: AsyncStream<JobProgressPayload>.Continuation!
        let progressStream = AsyncStream<JobProgressPayload> { progressContinuation = $0 }
        pendingByInvoke[invokeId] = JobInvocationState(
            jobId: nil,
            continuation: nil,
            progressContinuation: progressContinuation
        )
        let envelope = Envelope(
            id: invokeId,
            sessionId: info.sessionId,
            idempotencyKey: idempotencyKey,
            payload: .toolInvoke(
                ToolInvokePayload(
                    tool: tool,
                    arguments: arguments,
                    costBudget: costBudget,
                    modelUse: modelUse,
                    leaseConstraints: leaseConstraints
                )
            )
        )
        try await transport.send(envelope)
        let (outcome, jobId) = try await withCheckedThrowingContinuation { cont in
            attachContinuation(invokeId: invokeId, cont: cont)
        }
        return InvocationResult(jobId: jobId, outcome: outcome, progress: progressStream)
    }

    private func attachContinuation(
        invokeId: MessageId,
        cont: CheckedContinuation<(JobOutcome, JobId?), any Error>
    ) {
        if var state = pendingByInvoke[invokeId] {
            state.continuation = cont
            pendingByInvoke[invokeId] = state
        } else {
            cont.resume(throwing: ARCPError.internal(detail: "lost invocation \(invokeId)", cause: nil))
        }
    }

    /// Send a `cancel` request for a running job.
    public func cancelJob(_ jobId: JobId, reason: String? = nil, deadlineMs: Int = 5_000) async throws {
        try await send(
            Envelope(
                sessionId: info.sessionId,
                payload: .cancel(
                    CancelPayload(
                        target: .job,
                        targetId: jobId.rawValue,
                        reason: reason,
                        deadlineMs: deadlineMs
                    )
                )
            )
        )
    }
}
