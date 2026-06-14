import Foundation
import Logging

/// Client-side handle for an ARCP session. Drives the handshake
/// (RFC §8.1) and exposes message send/receive primitives plus the
/// higher-level job and subscription helpers shipped in this package.
public actor ARCPClient {
    public nonisolated let info: SessionInfo
    private let transport: any Transport
    private let log: Logger
    private let mailbox: Mailbox<Envelope>
    private let drainer: Task<Void, Never>
    private var dispatcher: Task<Void, Never>?
    private var pendingPongs: [MessageId: PongSlot] = [:]

    private enum PongSlot {
        case pending
        case waiting(CheckedContinuation<PongPayload, any Error>)
        case readyValue(PongPayload)
        case readyError(any Error)
    }
    private var pendingByInvoke: [MessageId: JobInvocationState] = [:]
    private var invokeByJobId: [JobId: MessageId] = [:]
    private var resultChunkStreams: [JobId: ResultChunkStream] = [:]
    private var unhandledContinuation: AsyncStream<Envelope>.Continuation?
    private var permissionHandler: any PermissionHandler = DefaultPermissionHandler()

    /// Highest session-scoped `event_seq` observed on an inbound job-event
    /// envelope (ARCP v1.1 §8.3). `nil` until the first event arrives.
    public private(set) var lastEventSeq: UInt64?
    /// Set once a gap in the inbound `event_seq` sequence is detected, which
    /// signals the client should resume from `lastEventSeq` (ARCP v1.1 §6.3).
    public private(set) var eventSeqGapDetected = false

    private struct JobInvocationState {
        var jobId: JobId?
        var continuation: CheckedContinuation<(JobOutcome, JobId?), any Error>?
        var progressContinuation: AsyncStream<JobProgressPayload>.Continuation?
        /// Terminal outcome that arrived before `invoke()` attached its
        /// continuation (the send-await race). Delivered on attach.
        var bufferedOutcome: (JobOutcome, JobId?)?
    }

    /// Result of a completed job invocation.
    public enum JobOutcome: Sendable {
        case completed(JobCompletedPayload)
        case failed(ErrorEnvelope)
        case cancelled(JobCancelledPayload)
    }

    /// Async stream of envelopes the client did not consume internally.
    /// Callers can observe this for protocol extensions or diagnostics
    /// that do not have a typed surface yet.
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
    ///
    /// - Parameters:
    ///   - transport: Transport used for the session.
    ///   - auth: Authentication block sent in `session.open`.
    ///   - client: Client identity advertised during the handshake.
    ///   - capabilities: Capabilities offered to the runtime.
    /// - Returns: A connected client once `session.accepted` is received.
    /// - Throws: `ARCPError` when the handshake is rejected or times out.
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

    /// Track the inbound `event_seq` stream and flag any gap (§8.3).
    private func observeEventSeq(_ envelope: Envelope) {
        guard let seq = envelope.eventSeq else { return }
        if let last = lastEventSeq, seq > last + 1 {
            eventSeqGapDetected = true
            log.warning(
                "event_seq gap detected",
                metadata: ["expected": "\(last + 1)", "received": "\(seq)"]
            )
        }
        if seq > (lastEventSeq ?? 0) {
            lastEventSeq = seq
        }
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
        observeEventSeq(envelope)
        switch envelope.payload {
        case .pong(let payload):
            if let id = envelope.correlationId,
                let slot = pendingPongs[id]
            {
                switch slot {
                case .pending:
                    pendingPongs[id] = .readyValue(payload)
                case .waiting(let cont):
                    pendingPongs.removeValue(forKey: id)
                    cont.resume(returning: payload)
                case .readyValue, .readyError:
                    unhandledContinuation?.yield(envelope)
                }
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
            } else {
                unhandledContinuation?.yield(envelope)
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
            } else {
                unhandledContinuation?.yield(envelope)
            }
        case .toolError(let payload):
            if let invokeId = envelope.correlationId, pendingByInvoke[invokeId] != nil {
                resolve(invokeId: invokeId, outcome: .failed(payload.error))
            } else {
                unhandledContinuation?.yield(envelope)
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
        guard var state = pendingByInvoke[invokeId] else { return }
        state.progressContinuation?.finish()
        state.progressContinuation = nil
        if let continuation = state.continuation {
            pendingByInvoke.removeValue(forKey: invokeId)
            continuation.resume(returning: (outcome, state.jobId))
        } else {
            // The terminal envelope arrived during the invoke() send-await,
            // before the continuation was attached. Buffer the outcome so
            // attachContinuation delivers it instead of dropping it.
            state.bufferedOutcome = (outcome, state.jobId)
            pendingByInvoke[invokeId] = state
        }
    }

    private func finishUnhandled() {
        unhandledContinuation?.finish()
        unhandledContinuation = nil
        let closedError = ARCPError.unavailable(reason: "transport closed", retryAfter: nil)
        let pongSlots = pendingPongs
        pendingPongs.removeAll()
        for (_, slot) in pongSlots {
            switch slot {
            case .waiting(let cont):
                cont.resume(throwing: closedError)
            case .pending, .readyValue, .readyError:
                break
            }
        }
        let pending = pendingByInvoke
        pendingByInvoke.removeAll()
        invokeByJobId.removeAll()
        for (_, state) in pending {
            state.progressContinuation?.finish()
            state.continuation?.resume(throwing: closedError)
        }
        let streams = resultChunkStreams
        resultChunkStreams.removeAll()
        Task {
            for (_, stream) in streams {
                await stream.fail(closedError)
            }
        }
    }

    /// Send a `ping`, await the corresponding `pong`. Times out after `timeout`.
    @discardableResult
    public func ping(
        nonce: String? = nil, timeout: Duration = .seconds(5)
    ) async throws
        -> PongPayload
    {
        let id = MessageId.random()
        pendingPongs[id] = .pending
        let envelope = Envelope(
            id: id,
            sessionId: info.sessionId,
            payload: .ping(PingPayload(nonce: nonce))
        )
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if Task.isCancelled { return }
            await self?.failPongWaiter(id: id)
        }
        defer { timeoutTask.cancel() }
        do {
            try await transport.send(envelope)
        } catch {
            pendingPongs.removeValue(forKey: id)
            throw error
        }
        return try await awaitPong(id: id)
    }

    private func awaitPong(id: MessageId) async throws -> PongPayload {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PongPayload, Error>) in
            switch pendingPongs[id] {
            case .readyValue(let payload):
                pendingPongs.removeValue(forKey: id)
                cont.resume(returning: payload)
            case .readyError(let err):
                pendingPongs.removeValue(forKey: id)
                cont.resume(throwing: err)
            case .pending:
                pendingPongs[id] = .waiting(cont)
            case .none:
                // The slot was cleared (transport closed via finishUnhandled)
                // between ping()'s `.pending` insert and this attach. Fail
                // immediately instead of waiting for the ping timeout.
                cont.resume(throwing: ARCPError.unavailable(reason: "transport closed", retryAfter: nil))
            case .waiting:
                cont.resume(throwing: ARCPError.internal(detail: "double-attach pong \(id)", cause: nil))
            }
        }
    }

    private func failPongWaiter(id: MessageId) {
        guard let slot = pendingPongs[id] else { return }
        let err = ARCPError.deadlineExceeded(operation: "ping \(id)")
        switch slot {
        case .pending:
            pendingPongs[id] = .readyError(err)
        case .waiting(let cont):
            pendingPongs.removeValue(forKey: id)
            cont.resume(throwing: err)
        case .readyValue, .readyError:
            break
        }
    }

    /// Send `session.close` and tear down the underlying transport.
    ///
    /// - Parameter reason: Optional close reason forwarded to the runtime.
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
    ///
    /// - Parameter envelope: Envelope to send.
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
    ///
    /// - Parameters:
    ///   - tool: Tool or agent name to invoke.
    ///   - arguments: JSON arguments passed to the runtime.
    ///   - costBudget: Optional per-currency spend cap.
    ///   - modelUse: Optional model usage policy.
    ///   - leaseConstraints: Optional lease expiry constraint.
    ///   - idempotencyKey: Optional idempotency key.
    /// - Returns: The invocation result, including the job id and outcome.
    public func invoke(
        tool: String,
        arguments: JSONValue,
        costBudget: CostBudget? = nil,
        modelUse: ModelUse? = nil,
        leaseConstraints: LeaseConstraints? = nil,
        maxRuntimeSec: Int? = nil,
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
                    leaseConstraints: leaseConstraints,
                    maxRuntimeSec: maxRuntimeSec
                )
            )
        )
        do {
            try await transport.send(envelope)
        } catch {
            if let state = pendingByInvoke.removeValue(forKey: invokeId) {
                state.progressContinuation?.finish()
            }
            throw error
        }
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
            if let buffered = state.bufferedOutcome {
                // A terminal already arrived before we attached — deliver it now.
                pendingByInvoke.removeValue(forKey: invokeId)
                cont.resume(returning: buffered)
                return
            }
            state.continuation = cont
            pendingByInvoke[invokeId] = state
        } else {
            cont.resume(throwing: ARCPError.internal(detail: "lost invocation \(invokeId)", cause: nil))
        }
    }

    /// Send a `cancel` request for a running job.
    ///
    /// - Parameters:
    ///   - jobId: Job to cancel.
    ///   - reason: Optional cancellation reason.
    ///   - deadlineMs: Maximum wait before the runtime stops the job.
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
