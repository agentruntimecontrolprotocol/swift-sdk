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
    private let send: @Sendable (Envelope) async throws -> Void
    private var handlers: [String: any ToolHandler] = [:]
    private var jobs: [JobId: JobRecord] = [:]
    private let streamManager: StreamManager

    public init(
        sessionId: SessionId,
        heartbeatInterval: TimeInterval = 30,
        cancelDeadline: TimeInterval = 5,
        send: @escaping @Sendable (Envelope) async throws -> Void
    ) {
        self.sessionId = sessionId
        self.heartbeatInterval = heartbeatInterval
        self.cancelDeadline = cancelDeadline
        self.send = send
        self.streamManager = StreamManager(sessionId: sessionId, send: send)
        self.log = Logger(label: "arcp.jobs.\(sessionId)")
    }

    /// Register a handler for a named tool. Replaces a previous registration.
    public func register(_ handler: any ToolHandler) {
        handlers[handler.name] = handler
    }

    /// Snapshot of currently-tracked job ids and their states.
    public var snapshot: [(JobId, JobState)] {
        jobs.map { ($0.key, $0.value.state) }
    }

    /// Handle a `tool.invoke` envelope. Spawns a child Task to run the handler.
    public func handleToolInvoke(envelope: Envelope, payload: ToolInvokePayload) async throws {
        guard let handler = handlers[payload.tool] else {
            try await send(
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

    /// Mark all open jobs cancelled and stop heartbeats. Called when a session
    /// ends to ensure no orphaned Tasks are left running.
    public func shutdown() async {
        for (jobId, record) in jobs {
            record.runTask?.cancel()
            record.heartbeatTask?.cancel()
            jobs[jobId]?.state = .cancelled
        }
        await streamManager.shutdown()
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
        var state: JobState
        var cancelRequested: Bool = false
        var cancelReason: String?
        var runTask: Task<Void, Never>?
        var heartbeatTask: Task<Void, Never>?
    }
}

/// Concrete `JobContext` implementation backed by the runtime's send hook.
struct ConcreteJobContext: JobContext, Sendable {
    let jobId: JobId
    let sessionId: SessionId
    let sendEnvelope: @Sendable (Envelope) async throws -> Void
    let streamManager: StreamManager
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
}
