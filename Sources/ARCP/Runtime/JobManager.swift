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
    public let humanInputRegistry = PendingRegistry<HumanInputResponsePayload>()
    public let humanChoiceRegistry = PendingRegistry<HumanChoiceResponsePayload>()
    public let permissionRegistry = PendingRegistry<PermissionOutcome>()
    public let leaseManager: LeaseManager

    /// Outcome of a permission challenge. RFC §15.4.
    public enum PermissionOutcome: Sendable {
        case granted(LeaseId, expiresAt: Date)
        case denied(reason: String)
    }

    public init(
        sessionId: SessionId,
        heartbeatInterval: TimeInterval = 30,
        cancelDeadline: TimeInterval = 5,
        send: @escaping @Sendable (Envelope) async throws -> Void
    ) {
        self.sessionId = sessionId
        self.heartbeatInterval = heartbeatInterval
        self.cancelDeadline = cancelDeadline
        self.rawSend = send
        self.streamManager = StreamManager(sessionId: sessionId, send: send)
        self.leaseManager = LeaseManager(sessionId: sessionId, send: send)
        self.log = Logger(label: "arcp.jobs.\(sessionId)")
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
                            error: ARCPError.notFound(kind: "tool", id: payload.tool).toEnvelope()
                        )
                    )
                )
            )
            return
        }
        let jobId = JobId.random()
        try await send(
            Envelope(
                sessionId: sessionId,
                jobId: jobId,
                correlationId: envelope.id,
                payload: .jobAccepted(JobAcceptedPayload(jobId: jobId))
            )
        )
        let record = JobRecord(
            jobId: jobId,
            invokeId: envelope.id,
            traceId: envelope.traceId,
            agent: agentRef.wire,
            createdAt: Date(),
            parentJobId: nil,
            state: .accepted
        )
        jobs[jobId] = record

        let invocation = ToolInvocation(
            jobId: jobId,
            sessionId: sessionId,
            arguments: payload.arguments,
            idempotencyKey: envelope.idempotencyKey,
            traceId: envelope.traceId
        )
        let context = ConcreteJobContext(
            jobId: jobId,
            sessionId: sessionId,
            sendEnvelope: send,
            streamManager: streamManager,
            manager: self,
            isCancelledProvider: { [weak self] in
                guard let self else { return false }
                return await self.isCancelled(jobId: jobId)
            }
        )

        let runTask = Task { [weak self] in
            await self?.runJob(
                jobId: jobId,
                invokeId: envelope.id,
                handler: handler,
                invocation: invocation,
                context: context
            )
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

    /// Handle an `interrupt` (RFC §10.5). Transitions the job to `.blocked` and
    /// emits `human.input.request`. Phase 4 wires the response loop.
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
                payload: .humanInputRequest(
                    HumanInputRequestPayload(
                        prompt: payload.prompt,
                        expiresAt: Date(timeIntervalSinceNow: 300)
                    )
                )
            )
        )
    }

    /// Forward stream events to the StreamManager.
    public func handleStreamEnvelope(_ envelope: Envelope) async {
        await streamManager.dispatch(envelope: envelope)
    }

    /// Resolve a pending human-input request from the client side.
    public func handleHumanInputResponse(envelope: Envelope, payload: HumanInputResponsePayload) async {
        guard let id = envelope.correlationId else { return }
        await humanInputRegistry.resolve(id: id, value: payload)
    }

    public func handleHumanChoiceResponse(envelope: Envelope, payload: HumanChoiceResponsePayload) async {
        guard let id = envelope.correlationId else { return }
        await humanChoiceRegistry.resolve(id: id, value: payload)
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
        try? await leaseManager.refresh(leaseId: payload.leaseId, seconds: payload.requestedSeconds)
    }

    /// Send a human input request from server to client and await the response.
    func requestHumanInput(
        jobId: JobId,
        prompt: String,
        responseSchema: JSONValue?,
        defaultValue: JSONValue?,
        expiresIn: Duration
    ) async throws -> HumanInputResponsePayload {
        let id = MessageId.random()
        let expiresAt = Date(timeIntervalSinceNow: TimeInterval(expiresIn.timeInterval))
        try await send(
            Envelope(
                id: id,
                sessionId: sessionId,
                jobId: jobId,
                payload: .humanInputRequest(
                    HumanInputRequestPayload(
                        prompt: prompt,
                        responseSchema: responseSchema,
                        default: defaultValue,
                        expiresAt: expiresAt
                    )
                )
            )
        )
        do {
            return try await humanInputRegistry.awaitResponse(id: id, deadline: expiresIn)
        } catch let error as ARCPError where error.code == .deadlineExceeded {
            if let defaultValue {
                let synthetic = HumanInputResponsePayload(
                    value: defaultValue,
                    respondedBy: "default",
                    respondedAt: Date()
                )
                return synthetic
            }
            try? await send(
                Envelope(
                    sessionId: sessionId,
                    jobId: jobId,
                    correlationId: id,
                    payload: .humanInputCancelled(
                        HumanInputCancelledPayload(code: .deadlineExceeded, reason: "expired")
                    )
                )
            )
            throw error
        }
    }

    /// Send a human choice request and await the selection.
    func requestHumanChoice(
        jobId: JobId,
        prompt: String,
        options: [HumanChoiceRequestPayload.Option],
        expiresIn: Duration
    ) async throws -> HumanChoiceResponsePayload {
        let id = MessageId.random()
        let expiresAt = Date(timeIntervalSinceNow: TimeInterval(expiresIn.timeInterval))
        try await send(
            Envelope(
                id: id,
                sessionId: sessionId,
                jobId: jobId,
                payload: .humanChoiceRequest(
                    HumanChoiceRequestPayload(prompt: prompt, options: options, expiresAt: expiresAt)
                )
            )
        )
        return try await humanChoiceRegistry.awaitResponse(id: id, deadline: expiresIn)
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
        }
        await streamManager.shutdown()
        await leaseManager.stop()
        let closeError = ARCPError.unavailable(reason: "session closing", retryAfter: nil)
        await humanInputRegistry.failAll(error: closeError)
        await humanChoiceRegistry.failAll(error: closeError)
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

        do {
            let result = try await handler.execute(invocation: invocation, context: context)
            try Task.checkCancellation()
            try? await send(
                Envelope(
                    sessionId: sessionId,
                    jobId: jobId,
                    correlationId: invokeId,
                    payload: .jobCompleted(toCompleted(result))
                )
            )
            transition(jobId: jobId, to: .completed)
        } catch let error as ARCPError where error.code == .cancelled {
            try? await send(
                Envelope(
                    sessionId: sessionId,
                    jobId: jobId,
                    correlationId: invokeId,
                    payload: .jobCancelled(
                        JobCancelledPayload(reason: error.message, code: .cancelled)
                    )
                )
            )
            transition(jobId: jobId, to: .cancelled)
        } catch is CancellationError {
            try? await send(
                Envelope(
                    sessionId: sessionId,
                    jobId: jobId,
                    correlationId: invokeId,
                    payload: .jobCancelled(
                        JobCancelledPayload(reason: "task cancelled", code: .cancelled)
                    )
                )
            )
            transition(jobId: jobId, to: .cancelled)
        } catch let error as ARCPError {
            try? await send(
                Envelope(
                    sessionId: sessionId,
                    jobId: jobId,
                    correlationId: invokeId,
                    payload: .jobFailed(JobFailedPayload(error: error.toEnvelope()))
                )
            )
            transition(jobId: jobId, to: .failed)
        } catch {
            let wrapped = ARCPError.internal(detail: "\(error)", cause: error)
            try? await send(
                Envelope(
                    sessionId: sessionId,
                    jobId: jobId,
                    correlationId: invokeId,
                    payload: .jobFailed(JobFailedPayload(error: wrapped.toEnvelope()))
                )
            )
            transition(jobId: jobId, to: .failed)
        }
        if let record = jobs[jobId] { record.heartbeatTask?.cancel() }
    }

    private func transition(jobId: JobId, to state: JobState) {
        if var record = jobs[jobId] {
            record.state = state
            jobs[jobId] = record
        }
    }

    private func toCompleted(_ output: ToolOutput) -> JobCompletedPayload {
        switch output {
        case .value(let value): return JobCompletedPayload(result: value)
        case .ref(let ref): return JobCompletedPayload(resultRef: ref)
        case .empty: return JobCompletedPayload()
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

    func requestHumanInput(
        prompt: String,
        responseSchema: JSONValue?,
        default defaultValue: JSONValue?,
        expiresIn: Duration
    ) async throws -> HumanInputResponsePayload {
        try await manager.requestHumanInput(
            jobId: jobId,
            prompt: prompt,
            responseSchema: responseSchema,
            defaultValue: defaultValue,
            expiresIn: expiresIn
        )
    }

    func requestHumanChoice(
        prompt: String,
        options: [HumanChoiceRequestPayload.Option],
        expiresIn: Duration
    ) async throws -> HumanChoiceResponsePayload {
        try await manager.requestHumanChoice(
            jobId: jobId,
            prompt: prompt,
            options: options,
            expiresIn: expiresIn
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
}
