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
    private let eventLog: EventLog?
    private let principalSubject: String?
    /// Tracks idempotency keys for in-flight jobs so the terminal envelope can
    /// be persisted on completion.
    private var idempotencyByJob: [JobId: IdempotencyKey] = [:]
    /// Optional advertised agent inventory (ARCP v1.1 §7.5). When set, the
    /// runtime validates `agent@version` references on `tool.invoke` against
    /// it and surfaces `agentVersionNotAvailable` for unknown pins.
    public var agentInventory: AgentInventory?

    private func send(_ envelope: Envelope) async throws {
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
        guard payload.target == .job, let jobId = jobs.keys.first(where: { $0.rawValue == payload.targetId })
        else {
            try await send(
                Envelope(
                    sessionId: sessionId,
                    correlationId: envelope.id,
                    payload: .cancelRefused(
                        CancelRefusedPayload(reason: "unknown target", code: .notFound)
                    )
                )
            )
            return
        }
        guard var record = jobs[jobId] else { return }
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

        // Deadline escalation: after deadline elapses, ensure terminal event was emitted.
        Task { [weak self, deadline = payload.deadlineMs] in
            try? await Task.sleep(for: .milliseconds(deadline))
            await self?.escalateCancelIfNeeded(jobId: jobId, reason: "deadline elapsed")
        }
    }

    /// Handle an `interrupt` (RFC §10.5). Transitions the job to `.blocked`.
    /// An ack is sent so the client knows the interrupt was received.
    public func handleInterrupt(envelope: Envelope, payload: InterruptPayload) async throws {
        guard payload.target == .job,
            let jobId = jobs.keys.first(where: { $0.rawValue == payload.targetId })
        else {
            return
        }
        guard var record = jobs[jobId] else { return }
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

    /// If `jobId` carries a tracked idempotency key, persist the terminal
    /// `MessageType` for future lookups by the same (principal, key).
    private func persistIdempotencyIfNeeded(jobId: JobId, terminal: MessageType) async {
        guard let key = idempotencyByJob.removeValue(forKey: jobId),
            let eventLog,
            let principal = principalSubject
        else { return }
        guard let payloadValue = Self.encodePayloadBody(terminal) else { return }
        let cached: JSONValue = .object([
            "job_id": .string(jobId.rawValue),
            "type": .string(terminal.typeName),
            "payload": payloadValue,
        ])
        let expiresAt = Date(timeIntervalSinceNow: 24 * 60 * 60)
        try? await eventLog.recordIdempotency(
            principal: principal,
            key: key,
            response: cached,
            expiresAt: expiresAt
        )
    }

    /// Replay a cached idempotency response for `key`. Returns `true` when a
    /// hit was found and emitted, `false` otherwise (caller should proceed
    /// with normal handling).
    private func replayCachedIdempotency(
        key: IdempotencyKey,
        invokeId: MessageId
    ) async throws -> Bool {
        guard let eventLog, let principal = principalSubject else { return false }
        guard let cached = try await eventLog.lookupIdempotency(principal: principal, key: key)
        else { return false }
        guard case .object(let dict) = cached,
            case .string(let jobIdValue) = dict["job_id"] ?? .null,
            case .string(let typeName) = dict["type"] ?? .null,
            let payloadValue = dict["payload"],
            let terminal = Self.decodePayloadBody(typeName: typeName, payload: payloadValue)
        else {
            // Cached response present but malformed — treat as miss.
            return false
        }
        let jobId = JobId(jobIdValue)
        try? await send(
            Envelope(
                sessionId: sessionId,
                jobId: jobId,
                correlationId: invokeId,
                payload: .jobAccepted(JobAcceptedPayload(jobId: jobId, credentials: nil))
            )
        )
        try? await send(
            Envelope(
                sessionId: sessionId,
                jobId: jobId,
                correlationId: invokeId,
                payload: terminal
            )
        )
        return true
    }

    /// Encode a `MessageType` payload body as JSON (just the payload object —
    /// the `type` discriminant is stored separately).
    private static func encodePayloadBody(_ payload: MessageType) -> JSONValue? {
        let envelope = Envelope(payload: payload)
        guard let data = try? envelope.toJSON(),
            let value = try? Envelope.makeDecoder().decode(JSONValue.self, from: data),
            case .object(let dict) = value
        else { return nil }
        return dict["payload"]
    }

    /// Decode a payload body previously written with `encodePayloadBody`,
    /// using `typeName` as the dispatch discriminant.
    private static func decodePayloadBody(
        typeName: String,
        payload: JSONValue
    ) -> MessageType? {
        let synthetic: JSONValue = .object([
            "arcp": .string("1.1"),
            "id": .string("idempotency_replay"),
            "type": .string(typeName),
            "timestamp": .string(ISO8601DateFormatter().string(from: Date())),
            "payload": payload,
        ])
        guard let data = try? Envelope.makeEncoder().encode(synthetic),
            let envelope = try? Envelope.makeDecoder().decode(Envelope.self, from: data)
        else { return nil }
        return envelope.payload
    }

    private func transition(jobId: JobId, to state: JobState) {
        if var record = jobs[jobId] {
            record.state = state
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
        case .ref(let ref): return JobCompletedPayload(resultRef: ref)
        case .empty: return JobCompletedPayload()
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

extension Duration {
    /// Approximate seconds count, including fractional part.
    public var timeInterval: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1.0e18
    }
}

/// Concrete `JobContext` implementation backed by the runtime's send hook.
struct ConcreteJobContext: JobContext, Sendable {
    let jobId: JobId
    let sessionId: SessionId
    let sendEnvelope: @Sendable (Envelope) async throws -> Void
    let streamManager: StreamManager
    let manager: JobManager
    let isCancelledProvider: @Sendable () async -> Bool
    let leaseExpiresAt: Date?
    let budget: BudgetTracker
    let modelUse: ModelUse?
    let credentialManager: CredentialManager?
    let invokeCorrelationId: MessageId

    func checkLeaseExpiration() throws {
        guard let leaseExpiresAt, Date() >= leaseExpiresAt else { return }
        throw ARCPError.leaseExpired(
            leaseId: LeaseId("lease_job_\(jobId.rawValue)"),
            expiredAt: leaseExpiresAt
        )
    }

    func charge(name: String, amount: Double, currency: String) async throws {
        let remaining = try budget.charge(currency: currency, amount: amount)
        let dims: [String: JSONValue] = ["currency": .string(currency)]
        try await metric(name: name, value: amount, unit: currency, dims: dims)
        try await metric(
            name: "cost.budget.remaining",
            value: remaining.isFinite ? remaining : Double.greatestFiniteMagnitude,
            unit: currency,
            dims: dims
        )
    }

    func checkModelUse(_ model: String) throws {
        try ModelUsePolicy.check(modelUse, model: model)
    }

    func rotateCredential(id: String) async throws -> ProvisionedCredential {
        guard let credentialManager else {
            throw ARCPError.failedPrecondition(detail: "credential provisioner is not configured")
        }
        let credential = try await credentialManager.rotate(jobId: jobId, credentialId: id)
        try await log(
            level: .info,
            message: "credential rotated",
            attributes: [
                "phase": .string("credential_rotated"),
                "credential_id": .string(id),
            ]
        )
        return credential
    }

    func reportProgress(
        percent: Double?,
        message: String?,
        attributes: [String: JSONValue]?
    ) async throws {
        try await sendEnvelope(
            Envelope(
                sessionId: sessionId,
                jobId: jobId,
                payload: .jobProgress(
                    JobProgressPayload(percent: percent, message: message, attributes: attributes)
                )
            )
        )
    }

    /// Concrete override emitting the §8.2.1 fields directly on the wire.
    func reportProgress(
        current: Double,
        total: Double? = nil,
        units: String? = nil,
        message: String? = nil
    ) async throws {
        try await sendEnvelope(
            Envelope(
                sessionId: sessionId,
                jobId: jobId,
                payload: .jobProgress(
                    JobProgressPayload(
                        current: current,
                        total: total,
                        units: units,
                        message: message
                    )
                )
            )
        )
    }

    func openStream(
        kind: StreamKind,
        contentType: String?,
        encoding: String?
    ) async throws -> any StreamHandle {
        try await streamManager.openOutbound(
            jobId: jobId,
            kind: kind,
            contentType: contentType,
            encoding: encoding
        )
    }

    func checkCancellation() async throws {
        try Task.checkCancellation()
        if await isCancelledProvider() {
            throw ARCPError.cancelled(operation: "job \(jobId)", reason: "cancel requested")
        }
    }

    func log(level: LogLevel, message: String, attributes: [String: JSONValue]?) async throws {
        try await sendEnvelope(
            Envelope(
                sessionId: sessionId,
                jobId: jobId,
                payload: .log(LogPayload(level: level, message: message, attributes: attributes))
            )
        )
    }

    func metric(
        name: String,
        value: Double,
        unit: String?,
        dims: [String: JSONValue]?
    ) async throws {
        try await sendEnvelope(
            Envelope(
                sessionId: sessionId,
                jobId: jobId,
                payload: .metric(MetricPayload(name: name, value: value, unit: unit, dims: dims))
            )
        )
    }

    func requestPermission(
        permission: String,
        resource: String,
        operation: String,
        reason: String?,
        leaseSeconds: Int
    ) async throws -> LeaseId {
        try await manager.requestPermission(
            jobId: jobId,
            permission: permission,
            resource: resource,
            operation: operation,
            reason: reason,
            leaseSeconds: leaseSeconds,
            timeout: .seconds(300)
        )
    }

    func emitResultChunk(
        resultId: String,
        chunkSeq: UInt64,
        data: String,
        encoding: ResultChunkEncoding,
        more: Bool
    ) async throws {
        await manager.recordResultChunk(jobId: jobId, resultId: resultId)
        try await sendEnvelope(
            Envelope(
                sessionId: sessionId,
                jobId: jobId,
                payload: .jobResultChunk(
                    JobResultChunkPayload(
                        resultId: resultId,
                        chunkSeq: chunkSeq,
                        data: data,
                        encoding: encoding,
                        more: more
                    )
                )
            )
        )
    }
}
