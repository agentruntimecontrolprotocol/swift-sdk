import Foundation
import Logging

/// Owns the per-session job lifecycle (RFC §10).
///
/// One `JobManager` per session. Tool invocations enter via `invoke`, the
/// manager runs the handler in a child Task, emits the lifecycle envelopes
/// (`job.accepted`, `job.started`, `job.progress`*, `job.heartbeat`*, then a
/// terminal event), and handles cancel/interrupt requests cooperatively.
public actor JobManager {
    public let sessionId: SessionId
    public let heartbeatInterval: TimeInterval
    public let cancelDeadline: TimeInterval

    private let log: Logger
    private let rawSend: @Sendable (Envelope) async throws -> Void
    private var handlers: [String: any ToolHandler] = [:]
    private var jobs: [JobId: JobRecord] = [:]
    /// Visible to the idempotency extension (`JobManager+Idempotency.swift`).
    let eventLog: EventLog?
    /// Visible to the idempotency extension (`JobManager+Idempotency.swift`).
    let principalSubject: String?
    /// Tracks idempotency keys for in-flight jobs so the terminal envelope can
    /// be persisted on completion. Visible to the idempotency extension.
    var idempotencyByJob: [JobId: IdempotencyKey] = [:]
    /// Optional advertised agent inventory (ARCP v1.1 §7.5). When set, the
    /// runtime validates `agent@version` references on `tool.invoke` against
    /// it and surfaces `agentVersionNotAvailable` for unknown pins.
    public var agentInventory: AgentInventory?

    /// Visible to the idempotency extension (`JobManager+Idempotency.swift`).
    func send(_ envelope: Envelope) async throws {
        if let jid = envelope.jobId, var record = jobs[jid] {
            record.lastEventSeq &+= 1
            jobs[jid] = record
        }
        try await rawSend(envelope)
    }
    private let streamManager: StreamManager
    public let permissionRegistry = PendingRegistry<PermissionOutcome>()
    public let leaseManager: LeaseManager
    public let credentialManager: CredentialManager?

    /// Outcome of a permission challenge. RFC §15.4.
    public enum PermissionOutcome: Sendable {
        case granted(LeaseId, expiresAt: Date)
        case denied(reason: String)
    }

    public init(
        sessionId: SessionId,
        heartbeatInterval: TimeInterval = 30,
        cancelDeadline: TimeInterval = 5,
        credentialManager: CredentialManager? = nil,
        eventLog: EventLog? = nil,
        principalSubject: String? = nil,
        send: @escaping @Sendable (Envelope) async throws -> Void
    ) {
        self.sessionId = sessionId
        self.heartbeatInterval = heartbeatInterval
        self.cancelDeadline = cancelDeadline
        self.rawSend = send
        self.streamManager = StreamManager(sessionId: sessionId, send: send)
        self.leaseManager = LeaseManager(sessionId: sessionId, send: send)
        self.credentialManager = credentialManager
        self.eventLog = eventLog
        self.principalSubject = principalSubject
        self.log = Logger(label: "arcp.jobs.\(sessionId)")
        // Start the lease expiry sweep automatically (RFC §15.5). Without
        // this, expired permission leases would not be revoked until a
        // caller manually reached into the subsystem and started the sweep.
        let manager = self.leaseManager
        Task { await manager.startSweep() }
    }

    /// Register a handler for a named tool. Replaces a previous registration.
    public func register(_ handler: any ToolHandler) {
        handlers[handler.name] = handler
    }

    /// Configure the advertised agent inventory used to validate
    /// `agent@version` references on `tool.invoke` (ARCP v1.1 §7.5).
    public func setAgentInventory(_ inventory: AgentInventory?) {
        self.agentInventory = inventory
    }

    /// Snapshot of currently-tracked job ids and their states.
    public var snapshot: [(JobId, JobState)] {
        jobs.map { ($0.key, $0.value.state) }
    }

    /// Handle a `tool.invoke` envelope. Spawns a child Task to run the handler.
    public func handleToolInvoke(envelope: Envelope, payload: ToolInvokePayload) async throws {
        if let trace = Self.traceContext(from: envelope) {
            try await Tracing.$current.withValue(trace) {
                try await self.handleToolInvokeInner(envelope: envelope, payload: payload)
            }
        } else {
            try await handleToolInvokeInner(envelope: envelope, payload: payload)
        }
    }

    private static func traceContext(from envelope: Envelope) -> TraceContext? {
        guard let traceId = envelope.traceId, let spanId = envelope.spanId else { return nil }
        return TraceContext(traceId: traceId, spanId: spanId, parentSpanId: envelope.parentSpanId)
    }

    private func handleToolInvokeInner(envelope: Envelope, payload: ToolInvokePayload) async throws {
        // §6.4: when the invoke carries an idempotency key and we have a
        // cached terminal response for the same (principal, key), re-emit it
        // correlated to the new invoke id without re-executing the handler.
        if let key = envelope.idempotencyKey,
            try await replayCachedIdempotency(key: key, invokeId: envelope.id)
        {
            return
        }
        // Parse the tool/agent identifier per ARCP v1.1 §7.5. Bare names and
        // `name@version` are both accepted; an unparseable identifier falls
        // through to a notFound error.
        let agentRef: AgentRef
        if let parsed = try? AgentRef.parse(payload.tool) {
            agentRef = parsed
        } else {
            agentRef = AgentRef(name: payload.tool, version: nil)
        }

        // §7.5: validate `name@version` references against the advertised
        // inventory (if one was configured). Bare names defer to the runtime
        // default and are not rejected here.
        if let inventory = agentInventory,
            agentRef.version != nil,
            !inventory.satisfies(agentRef)
        {
            try await rawSend(
                Envelope(
                    sessionId: sessionId,
                    correlationId: envelope.id,
                    payload: .toolError(
                        ToolErrorPayload(
                            error: ARCPError.agentVersionNotAvailable(
                                agent: agentRef.name,
                                version: agentRef.version ?? ""
                            ).toEnvelope()
                        )
                    )
                )
            )
            return
        }

        guard let handler = handlers[agentRef.name] else {
            try await rawSend(
                Envelope(
                    sessionId: sessionId,
                    correlationId: envelope.id,
                    payload: .toolError(
                        ToolErrorPayload(
                            error: ARCPError.agentNotAvailable(agent: payload.tool).toEnvelope()
                        )
                    )
                )
            )
            return
        }
        // §9.5: lease_constraints.expires_at must be in the future at
        // submission time. Past or invalid values surface as
        // INVALID_REQUEST (invalidArgument) BEFORE the job is accepted.
        if let constraints = payload.leaseConstraints,
            constraints.expiresAt <= Date()
        {
            try await rawSend(
                Envelope(
                    sessionId: sessionId,
                    correlationId: envelope.id,
                    payload: .toolError(
                        ToolErrorPayload(
                            error: ARCPError.invalidArgument(
                                field: "lease_constraints.expires_at",
                                detail: "must be in the future"
                            ).toEnvelope()
                        )
                    )
                )
            )
            return
        }
        let jobId = JobId.random()
        let leaseSnapshot = LeaseSnapshot(
            costBudget: payload.costBudget,
            modelUse: payload.modelUse,
            expiresAt: payload.leaseConstraints?.expiresAt
        )
        let credentials: [ProvisionedCredential]?
        if let credentialManager, !leaseSnapshot.isEmpty {
            do {
                credentials = try await credentialManager.issueForJob(jobId, lease: leaseSnapshot)
            } catch {
                try await rawSend(
                    Envelope(
                        sessionId: sessionId,
                        correlationId: envelope.id,
                        payload: .toolError(
                            ToolErrorPayload(
                                error: ARCPError.unavailable(
                                    reason: "credential provisioning failed",
                                    retryAfter: nil
                                ).toEnvelope()
                            )
                        )
                    )
                )
                return
            }
        } else {
            credentials = nil
        }
        try await send(
            Envelope(
                sessionId: sessionId,
                jobId: jobId,
                correlationId: envelope.id,
                payload: .jobAccepted(JobAcceptedPayload(jobId: jobId, credentials: credentials))
            )
        )
        let record = JobRecord(
            jobId: jobId,
            invokeId: envelope.id,
            traceId: envelope.traceId,
            agent: agentRef.wire,
            createdAt: Date(),
            parentJobId: nil,
            state: .accepted,
            leaseExpiresAt: payload.leaseConstraints?.expiresAt,
            costBudget: payload.costBudget,
            modelUse: payload.modelUse
        )
        jobs[jobId] = record

        let invocation = ToolInvocation(
            jobId: jobId,
            sessionId: sessionId,
            arguments: payload.arguments,
            idempotencyKey: envelope.idempotencyKey,
            traceId: envelope.traceId
        )
        let budgetTracker: BudgetTracker = {
            if let cb = payload.costBudget, !cb.isEmpty {
                return BudgetTracker(budget: cb)
            }
            return BudgetTracker()
        }()
        let context = ConcreteJobContext(
            jobId: jobId,
            sessionId: sessionId,
            sendEnvelope: send,
            streamManager: streamManager,
            manager: self,
            isCancelledProvider: { [weak self] in
                guard let self else { return false }
                return await self.isCancelled(jobId: jobId)
            },
            leaseExpiresAt: payload.leaseConstraints?.expiresAt,
            budget: budgetTracker,
            modelUse: payload.modelUse,
            credentialManager: credentialManager,
            invokeCorrelationId: envelope.id
        )

        if let key = envelope.idempotencyKey {
            idempotencyByJob[jobId] = key
        }
        let inboundTrace = Self.traceContext(from: envelope)
        let runTask = Task { [weak self] in
            if let inboundTrace {
                await Tracing.$current.withValue(inboundTrace) {
                    await self?.runJob(
                        jobId: jobId,
                        invokeId: envelope.id,
                        handler: handler,
                        invocation: invocation,
                        context: context
                    )
                }
            } else {
                await self?.runJob(
                    jobId: jobId,
                    invokeId: envelope.id,
                    handler: handler,
                    invocation: invocation,
                    context: context
                )
            }
            return ()
        }
        let heartbeatTask = Task { [weak self] in
            await self?.heartbeatLoop(jobId: jobId)
            return ()
        }
        var newRecord = record
        newRecord.runTask = runTask
        newRecord.heartbeatTask = heartbeatTask
        jobs[jobId] = newRecord
    }

    /// Handle a `cancel` request (RFC §10.4). Cooperative — the handler must
    /// observe `Task.checkCancellation()` to terminate cleanly.
    public func handleCancel(envelope: Envelope, payload: CancelPayload) async throws {
        guard payload.target == .job else {
            try await send(
                Envelope(
                    sessionId: sessionId,
                    correlationId: envelope.id,
                    payload: .cancelRefused(
                        CancelRefusedPayload(reason: "unsupported cancel target", code: .invalidArgument)
                    )
                )
            )
            return
        }
        let jobId = JobId(payload.targetId)
        guard var record = jobs[jobId] else {
            try await send(
                Envelope(
                    sessionId: sessionId,
                    correlationId: envelope.id,
                    payload: .cancelRefused(
                        CancelRefusedPayload(reason: "unknown job", code: .jobNotFound)
                    )
                )
            )
            return
        }
        if record.state.isTerminal {
            try await send(
                Envelope(
                    sessionId: sessionId,
                    jobId: jobId,
                    correlationId: envelope.id,
                    payload: .cancelRefused(
                        CancelRefusedPayload(reason: "already terminal", code: .failedPrecondition)
                    )
                )
            )
            return
        }
        record.cancelRequested = true
        record.cancelReason = payload.reason ?? "user"
        jobs[jobId] = record
        record.runTask?.cancel()
        try await send(
            Envelope(
                sessionId: sessionId,
                jobId: jobId,
                correlationId: envelope.id,
                payload: .cancelAccepted(CancelAcceptedPayload(deadlineMs: payload.deadlineMs))
            )
        )

        // Deadline escalation: after deadline elapses, ensure terminal event
        // was emitted. The deadline is clamped to [0, maxCancelDeadlineMs] so a
        // client cannot accumulate long-lived sleeping tasks with a huge
        // (or negative) deadline. The task handle is retained on the JobRecord
        // so it can be cancelled on terminal transition and on shutdown().
        let clampedDeadline = min(max(payload.deadlineMs, 0), Self.maxCancelDeadlineMs)
        let escalationTask = Task { [weak self, deadline = clampedDeadline] in
            try? await Task.sleep(for: .milliseconds(deadline))
            await self?.escalateCancelIfNeeded(jobId: jobId, reason: "deadline elapsed")
        }
        if var updated = jobs[jobId] {
            updated.cancelEscalationTask = escalationTask
            jobs[jobId] = updated
        }
    }

    /// Upper bound for a client-supplied cancel `deadline_ms` (10 minutes).
    static let maxCancelDeadlineMs = 10 * 60 * 1000

    /// Handle an `interrupt` (RFC §10.5). Transitions the job to `.blocked`.
    /// An ack is sent so the client knows the interrupt was received.
    public func handleInterrupt(envelope: Envelope, payload: InterruptPayload) async throws {
        guard payload.target == .job else {
            try await send(
                Envelope(
                    sessionId: sessionId,
                    correlationId: envelope.id,
                    payload: .cancelRefused(
                        CancelRefusedPayload(reason: "unsupported interrupt target", code: .invalidArgument)
                    )
                )
            )
            return
        }
        let jobId = JobId(payload.targetId)
        guard var record = jobs[jobId] else {
            // §7.4: interrupting an unknown (or already-terminal) job MUST
            // produce an explicit refusal so the client is not left waiting.
            try await send(
                Envelope(
                    sessionId: sessionId,
                    correlationId: envelope.id,
                    payload: .cancelRefused(
                        CancelRefusedPayload(reason: "unknown job", code: .jobNotFound)
                    )
                )
            )
            return
        }
        record.state = .blocked
        jobs[jobId] = record
        try await send(
            Envelope(
                sessionId: sessionId,
                jobId: jobId,
                correlationId: envelope.id,
                payload: .ack(AckPayload(detail: "interrupt"))
            )
        )
    }

    /// Forward stream events to the StreamManager.
    public func handleStreamEnvelope(_ envelope: Envelope) async {
        await streamManager.dispatch(envelope: envelope)
    }

    /// Resolve `permission.grant` / `permission.deny`.
    public func handlePermissionGrant(envelope: Envelope, payload: PermissionGrantPayload) async {
        guard let id = envelope.correlationId else { return }
        do {
            let leaseId = try await leaseManager.grant(
                permission: payload.permission,
                resource: payload.resource,
                operation: payload.operation,
                seconds: payload.leaseSeconds
            )
            let expiresAt = Date(timeIntervalSinceNow: TimeInterval(payload.leaseSeconds))
            await permissionRegistry.resolve(id: id, value: .granted(leaseId, expiresAt: expiresAt))
        } catch {
            await permissionRegistry.reject(id: id, error: error)
        }
    }

    public func handlePermissionDeny(envelope: Envelope, payload: PermissionDenyPayload) async {
        guard let id = envelope.correlationId else { return }
        await permissionRegistry.resolve(id: id, value: .denied(reason: payload.reason))
    }

    public func handleLeaseRefresh(envelope: Envelope, payload: LeaseRefreshPayload) async {
        do {
            try await leaseManager.refresh(
                leaseId: payload.leaseId, seconds: payload.requestedSeconds
            )
        } catch let error as ARCPError {
            try? await send(
                Envelope(
                    sessionId: sessionId,
                    correlationId: envelope.id,
                    payload: .nack(NackPayload(error: error.toEnvelope()))
                )
            )
        } catch {
            let wrapped = ARCPError.internal(detail: "lease refresh failed: \(error)", cause: nil)
            try? await send(
                Envelope(
                    sessionId: sessionId,
                    correlationId: envelope.id,
                    payload: .nack(NackPayload(error: wrapped.toEnvelope()))
                )
            )
        }
    }

    /// Send a permission challenge and await grant/deny.
    func requestPermission(
        jobId: JobId,
        permission: String,
        resource: String,
        operation: String,
        reason: String?,
        leaseSeconds: Int,
        timeout: Duration
    ) async throws -> LeaseId {
        let id = MessageId.random()
        try await send(
            Envelope(
                id: id,
                sessionId: sessionId,
                jobId: jobId,
                payload: .permissionRequest(
                    PermissionRequestPayload(
                        permission: permission,
                        resource: resource,
                        operation: operation,
                        reason: reason,
                        requestedLeaseSeconds: leaseSeconds
                    )
                )
            )
        )
        let outcome = try await permissionRegistry.awaitResponse(id: id, deadline: timeout)
        switch outcome {
        case .granted(let leaseId, _): return leaseId
        case .denied(let reason):
            throw ARCPError.permissionDenied(permission: permission, resource: reason)
        }
    }

    /// Mark all open jobs cancelled and stop heartbeats. Called when a session
    /// ends to ensure no orphaned Tasks are left running.
    public func shutdown() async {
        for (jobId, record) in jobs {
            record.runTask?.cancel()
            record.heartbeatTask?.cancel()
            record.cancelEscalationTask?.cancel()
            jobs[jobId]?.state = .cancelled
            await credentialManager?.revokeAll(jobId: jobId)
        }
        await streamManager.shutdown()
        await leaseManager.stop()
        let closeError = ARCPError.unavailable(reason: "session closing", retryAfter: nil)
        await permissionRegistry.failAll(error: closeError)
    }

    private func isCancelled(jobId: JobId) -> Bool {
        jobs[jobId]?.cancelRequested ?? false
    }

    private func escalateCancelIfNeeded(jobId: JobId, reason: String) async {
        guard let record = jobs[jobId], !record.state.isTerminal else { return }
        try? await send(
            Envelope(
                sessionId: sessionId,
                jobId: jobId,
                payload: .jobCancelled(
                    JobCancelledPayload(reason: reason, code: .aborted)
                )
            )
        )
        var updated = record
        updated.state = .cancelled
        updated.cancelEscalationTask = nil
        jobs[jobId] = updated
        record.heartbeatTask?.cancel()
        await credentialManager?.revokeAll(jobId: jobId)
    }

    private func runJob(
        jobId: JobId,
        invokeId: MessageId,
        handler: any ToolHandler,
        invocation: ToolInvocation,
        context: ConcreteJobContext
    ) async {
        transition(jobId: jobId, to: .running)
        try? await send(
            Envelope(
                sessionId: sessionId,
                jobId: jobId,
                correlationId: invokeId,
                payload: .jobStarted(JobStartedPayload(jobId: jobId))
            )
        )

        let terminal: MessageType
        let terminalState: JobState
        do {
            let result = try await handler.execute(invocation: invocation, context: context)
            try Task.checkCancellation()
            let completedPayload = try toCompleted(jobId: jobId, result)
            terminal = .jobCompleted(completedPayload)
            terminalState = .completed
        } catch let error as ARCPError where error.code == .cancelled {
            terminal = .jobCancelled(JobCancelledPayload(reason: error.message, code: .cancelled))
            terminalState = .cancelled
        } catch is CancellationError {
            terminal = .jobCancelled(JobCancelledPayload(reason: "task cancelled", code: .cancelled))
            terminalState = .cancelled
        } catch let error as ARCPError {
            terminal = .jobFailed(JobFailedPayload(error: error.toEnvelope()))
            terminalState = .failed
        } catch {
            let wrapped = ARCPError.internal(detail: "\(error)", cause: error)
            terminal = .jobFailed(JobFailedPayload(error: wrapped.toEnvelope()))
            terminalState = .failed
        }
        // Persist idempotency BEFORE emitting the terminal envelope so any
        // racing duplicate invocation sees the cached response.
        await persistIdempotencyIfNeeded(jobId: jobId, terminal: terminal)
        try? await send(
            Envelope(
                sessionId: sessionId,
                jobId: jobId,
                correlationId: invokeId,
                payload: terminal
            )
        )
        transition(jobId: jobId, to: terminalState)
        if let record = jobs[jobId] { record.heartbeatTask?.cancel() }
        await credentialManager?.revokeAll(jobId: jobId)
    }

    private func transition(jobId: JobId, to state: JobState) {
        if var record = jobs[jobId] {
            record.state = state
            // Once the job is terminal there is nothing left to escalate, so
            // release the cancel-deadline task instead of letting it sleep out.
            if state.isTerminal, let escalation = record.cancelEscalationTask {
                escalation.cancel()
                record.cancelEscalationTask = nil
            }
            jobs[jobId] = record
        }
    }

    func recordResultChunk(jobId: JobId, resultId: String) {
        guard var record = jobs[jobId] else { return }
        if record.streamedResultId == nil {
            record.streamedResultId = resultId
            jobs[jobId] = record
        }
    }

    private func toCompleted(jobId: JobId, _ output: ToolOutput) throws -> JobCompletedPayload {
        let streamedResultId = jobs[jobId]?.streamedResultId
        switch output {
        case .value(let value):
            if let streamedResultId {
                throw ARCPError.invalidArgument(
                    field: "result",
                    detail: "job emitted result_chunk \(streamedResultId) and returned inline result"
                )
            }
            return JobCompletedPayload(result: value)
        case .ref(let ref):
            // §8.4: once any chunk is emitted, the job MUST NOT also return an
            // inline result_ref (mixing inline result and result_chunk).
            if let streamedResultId {
                throw ARCPError.invalidArgument(
                    field: "result_ref",
                    detail:
                        "job emitted result_chunk \(streamedResultId) and returned an inline result_ref"
                )
            }
            return JobCompletedPayload(resultRef: ref)
        case .empty:
            // §8.4: a job that streamed chunks completes by referencing the
            // streamed result_id, not with an empty payload.
            if let streamedResultId {
                return JobCompletedPayload(resultId: streamedResultId)
            }
            return JobCompletedPayload()
        case .streamed(let resultId, let size, let summary):
            if let streamedResultId, streamedResultId != resultId {
                throw ARCPError.invalidArgument(
                    field: "result_id",
                    detail: "completed result_id \(resultId) does not match streamed \(streamedResultId)"
                )
            }
            return JobCompletedPayload(resultId: resultId, resultSize: size, summary: summary)
        }
    }

    private func heartbeatLoop(jobId: JobId) async {
        var sequence = 0
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(heartbeatInterval))
            } catch { return }
            guard let record = jobs[jobId], !record.state.isTerminal else { return }
            sequence += 1
            try? await send(
                Envelope(
                    sessionId: sessionId,
                    jobId: jobId,
                    payload: .jobHeartbeat(
                        JobHeartbeatPayload(
                            sequence: sequence,
                            deadlineMs: Int(heartbeatInterval * 2 * 1000),
                            state: record.state
                        )
                    )
                )
            )
        }
    }

    private struct JobRecord {
        let jobId: JobId
        let invokeId: MessageId
        let traceId: TraceId?
        let agent: String
        let createdAt: Date
        let parentJobId: JobId?
        var state: JobState
        var cancelRequested: Bool = false
        var cancelReason: String?
        var lastEventSeq: UInt64 = 0
        var runTask: Task<Void, Never>?
        var heartbeatTask: Task<Void, Never>?
        var cancelEscalationTask: Task<Void, Never>?
        var leaseExpiresAt: Date?
        var costBudget: CostBudget?
        var modelUse: ModelUse?
        var streamedResultId: String?
    }

    /// Build a read-only inventory of jobs known to this session.
    /// ARCP v1.1 §6.6.
    public func listJobs(
        filter: SessionListJobsFilter?,
        limit: Int?,
        cursor: String?
    ) -> (entries: [JobListEntry], nextCursor: String?) {
        var entries: [JobListEntry] = jobs.values.map { record in
            JobListEntry(
                jobId: record.jobId,
                agent: record.agent,
                status: record.state.rawValue,
                parentJobId: record.parentJobId,
                createdAt: record.createdAt,
                traceId: record.traceId?.rawValue,
                lastEventSeq: record.lastEventSeq
            )
        }
        // Apply filter.
        if let filter {
            if !filter.status.isEmpty {
                entries = entries.filter { filter.status.contains($0.status) }
            }
            if let agent = filter.agent {
                entries = entries.filter { $0.agent == agent }
            }
            if let after = filter.createdAfter {
                entries = entries.filter { $0.createdAt > after }
            }
            if let before = filter.createdBefore {
                entries = entries.filter { $0.createdAt < before }
            }
        }
        // Deterministic order: oldest first.
        entries.sort { $0.createdAt < $1.createdAt }
        // Cursor is the index into the filtered/sorted list, as a string.
        let start: Int
        if let cursor, let parsed = Int(cursor), parsed >= 0, parsed <= entries.count {
            start = parsed
        } else {
            start = 0
        }
        let pageSize = max(1, limit ?? entries.count)
        let end = min(entries.count, start + pageSize)
        let page = Array(entries[start..<end])
        let nextCursor: String? = end < entries.count ? String(end) : nil
        return (page, nextCursor)
    }
}
