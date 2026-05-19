import Foundation
import Logging

/// Server-side runtime that owns sessions, an event log, and the dispatch
/// loop for incoming envelopes. RFC §6.3 / §8.
///
/// In Phase 2 the runtime handles the handshake (RFC §8.1) and basic
/// control messages (`ping`, `session.close`). Phase 3 layers job/stream
/// dispatch on top, Phase 4 adds permissions/HITL, etc.
public actor ARCPRuntime {
    public let identity: IdentityBlock
    public let supportedCapabilities: Capabilities
    public let auth: any AuthValidator
    public let eventLog: EventLog
    public let extensionRegistry: ExtensionRegistry
    public let subscriptionManager: SubscriptionManager
    public let artifactStore: ArtifactStore

    private let log: Logger
    private let negotiator: CapabilityNegotiator
    private var sessions: [SessionId: SessionInfo] = [:]
    private var jobManagers: [SessionId: JobManager] = [:]
    private var registeredHandlers: [any ToolHandler] = []
    private let challengeRequired: Bool
    private let challengeNonce: @Sendable () -> String

    public init(
        identity: IdentityBlock,
        supportedCapabilities: Capabilities,
        auth: any AuthValidator,
        requiredCapabilities: Set<String> = [],
        challengeRequired: Bool = false,
        eventLog: EventLog? = nil,
        extensionRegistry: ExtensionRegistry? = nil,
        challengeNonce: @escaping @Sendable () -> String = { Ulid.next() }
    ) throws {
        self.identity = identity
        self.supportedCapabilities = supportedCapabilities
        self.auth = auth
        self.negotiator = CapabilityNegotiator(
            runtimeSupported: supportedCapabilities,
            required: requiredCapabilities
        )
        self.challengeRequired = challengeRequired
        self.challengeNonce = challengeNonce
        self.eventLog = try eventLog ?? EventLog.inMemory()
        self.extensionRegistry =
            extensionRegistry ?? ExtensionRegistry(advertised: supportedCapabilities.extensions)
        self.subscriptionManager = SubscriptionManager(eventLog: self.eventLog)
        self.artifactStore = ArtifactStore(eventLog: self.eventLog)
        self.log = Logger(label: "arcp.runtime")
    }

    /// Snapshot of currently-open session metadata.
    public var openSessions: [SessionInfo] {
        Array(sessions.values)
    }

    /// Register a tool handler globally. Future sessions inherit it.
    public func register(_ handler: any ToolHandler) {
        registeredHandlers.append(handler)
        for manager in jobManagers.values {
            Task { await manager.register(handler) }
        }
    }

    /// Drive the session over `transport`. Completes the handshake and then
    /// dispatches incoming envelopes until the channel closes or
    /// `session.close` is received. This call returns when the session ends.
    public func acceptSession(over transport: any Transport) async throws -> SessionInfo {
        let mailbox = Mailbox<Envelope>()
        let drainer = Task {
            for await envelope in transport.receive {
                await mailbox.put(envelope)
            }
            await mailbox.finish()
        }
        defer { drainer.cancel() }

        let info = try await runHandshake(transport: transport, mailbox: mailbox)
        sessions[info.sessionId] = info
        let jobManager = JobManager(
            sessionId: info.sessionId,
            send: { [weak self] envelope in
                guard let self else { return }
                try await self.send(envelope, transport: transport)
            }
        )
        for handler in registeredHandlers {
            await jobManager.register(handler)
        }
        jobManagers[info.sessionId] = jobManager
        log.info("session opened", metadata: ["session": "\(info.sessionId)"])
        await dispatchLoop(transport: transport, mailbox: mailbox, info: info, jobManager: jobManager)
        await jobManager.shutdown()
        jobManagers.removeValue(forKey: info.sessionId)
        sessions.removeValue(forKey: info.sessionId)
        log.info("session closed", metadata: ["session": "\(info.sessionId)"])
        return info
    }

    private func send(_ envelope: Envelope, transport: any Transport) async throws {
        try await transport.send(envelope)
        try? await persistOptional(envelope, sessionId: envelope.sessionId)
        await subscriptionManager.route(envelope: envelope)
    }

    private func runHandshake(
        transport: any Transport,
        mailbox: Mailbox<Envelope>
    ) async throws -> SessionInfo {
        guard let openEnvelope = await mailbox.next() else {
            throw ARCPError.unauthenticated(detail: "transport closed before session.open")
        }
        guard case .sessionOpen(let openPayload) = openEnvelope.payload else {
            throw ARCPError.invalidArgument(
                field: "type",
                detail: "expected session.open, got \(openEnvelope.payload.typeName)"
            )
        }

        let principal: AuthenticatedPrincipal
        if challengeRequired {
            let nonce = challengeNonce()
            try await transport.send(
                Envelope(
                    payload: .sessionChallenge(
                        SessionChallengePayload(
                            nonce: nonce,
                            scheme: openPayload.auth.scheme,
                            expiresAt: Date(timeIntervalSinceNow: 60)
                        )
                    )
                )
            )
            guard let authEnvelope = await mailbox.next() else {
                throw ARCPError.unauthenticated(detail: "transport closed during challenge")
            }
            guard case .sessionAuthenticate(let authPayload) = authEnvelope.payload else {
                throw ARCPError.invalidArgument(
                    field: "type",
                    detail: "expected session.authenticate, got \(authEnvelope.payload.typeName)"
                )
            }
            do {
                principal = try await auth.validate(auth: authPayload.auth, challenge: nonce)
            } catch let error as ARCPError {
                try await sendRejection(transport: transport, error: error)
                throw error
            }
        } else {
            do {
                if openPayload.auth.scheme == .none {
                    guard openPayload.capabilities.anonymous, supportedCapabilities.anonymous else {
                        throw ARCPError.unauthenticated(
                            detail: "scheme=none requires anonymous capability (RFC §8.2)"
                        )
                    }
                    principal = AuthenticatedPrincipal(
                        subject: "anonymous",
                        trustLevel: .untrusted
                    )
                } else {
                    principal = try await auth.validate(auth: openPayload.auth, challenge: nil)
                }
            } catch let error as ARCPError {
                try await sendRejection(transport: transport, error: error)
                throw error
            }
        }

        let negotiated: Capabilities
        do {
            negotiated = try negotiator.negotiate(clientOffered: openPayload.capabilities)
        } catch let error as ARCPError {
            try await sendRejection(transport: transport, error: error)
            throw error
        }
        try await extensionRegistry.setAdvertised(negotiated.extensions)

        let info = SessionInfo(
            sessionId: SessionId.random(),
            principal: principal,
            clientIdentity: openPayload.client,
            runtimeIdentity: identity,
            negotiatedCapabilities: negotiated
        )
        let accepted = Envelope(
            sessionId: info.sessionId,
            correlationId: openEnvelope.id,
            payload: .sessionAccepted(
                SessionAcceptedPayload(
                    sessionId: info.sessionId,
                    runtime: identity,
                    capabilities: negotiated
                )
            )
        )
        try await transport.send(accepted)
        try await persistOptional(accepted, sessionId: info.sessionId)
        return info
    }

    private func sendRejection(transport: any Transport, error: ARCPError) async throws {
        let envelope = Envelope(
            payload: .sessionRejected(SessionRejectedPayload(error: error.toEnvelope()))
        )
        try await transport.send(envelope)
    }

    private func dispatchLoop(
        transport: any Transport,
        mailbox: Mailbox<Envelope>,
        info: SessionInfo,
        jobManager: JobManager
    ) async {
        while let envelope = await mailbox.next() {
            do {
                try await persistOptional(envelope, sessionId: info.sessionId)
                let shouldEnd = try await handle(
                    envelope: envelope,
                    transport: transport,
                    info: info,
                    jobManager: jobManager
                )
                if shouldEnd { break }
            } catch let error as ARCPError {
                log.error(
                    "dispatch error",
                    metadata: ["code": "\(error.code.rawValue)", "msg": "\(error.message)"]
                )
                try? await transport.send(
                    Envelope(
                        sessionId: info.sessionId,
                        correlationId: envelope.id,
                        payload: .nack(NackPayload(error: error.toEnvelope()))
                    )
                )
            } catch {
                log.error("unexpected dispatch error: \(error)")
            }
        }
    }

    private func handle(
        envelope: Envelope,
        transport: any Transport,
        info: SessionInfo,
        jobManager: JobManager
    ) async throws -> Bool {
        switch envelope.payload {
        case .ping(let payload):
            try await transport.send(
                Envelope(
                    sessionId: info.sessionId,
                    correlationId: envelope.id,
                    payload: .pong(PongPayload(nonce: payload.nonce))
                )
            )
            return false
        case .sessionClose:
            return true
        case .toolInvoke(let payload):
            try await jobManager.handleToolInvoke(envelope: envelope, payload: payload)
            return false
        case .cancel(let payload):
            try await jobManager.handleCancel(envelope: envelope, payload: payload)
            return false
        case .interrupt(let payload):
            try await jobManager.handleInterrupt(envelope: envelope, payload: payload)
            return false
        case .streamChunk, .streamClose, .streamError:
            await jobManager.handleStreamEnvelope(envelope)
            return false
        case .humanInputResponse(let payload):
            await jobManager.handleHumanInputResponse(envelope: envelope, payload: payload)
            return false
        case .humanChoiceResponse(let payload):
            await jobManager.handleHumanChoiceResponse(envelope: envelope, payload: payload)
            return false
        case .humanInputCancelled:
            // Client signals timeout/cancel of an in-flight HITL request.
            return false
        case .permissionGrant(let payload):
            await jobManager.handlePermissionGrant(envelope: envelope, payload: payload)
            return false
        case .permissionDeny(let payload):
            await jobManager.handlePermissionDeny(envelope: envelope, payload: payload)
            return false
        case .leaseRefresh(let payload):
            await jobManager.handleLeaseRefresh(envelope: envelope, payload: payload)
            return false
        case .subscribe(let payload):
            try await handleSubscribe(envelope: envelope, payload: payload, transport: transport)
            return false
        case .unsubscribe(let payload):
            await subscriptionManager.unsubscribe(payload.subscriptionId)
            return false
        case .artifactPut(let payload):
            try await handleArtifactPut(
                envelope: envelope, payload: payload, info: info, transport: transport)
            return false
        case .artifactFetch(let payload):
            try await handleArtifactFetch(
                envelope: envelope, payload: payload, info: info, transport: transport)
            return false
        case .artifactRelease(let payload):
            try await artifactStore.release(artifactId: payload.artifactId)
            return false
        case .resume(let payload):
            try await handleResume(envelope: envelope, payload: payload, info: info, transport: transport)
            return false
        case .sessionListJobs(let payload):
            try await handleListJobs(
                envelope: envelope,
                payload: payload,
                info: info,
                jobManager: jobManager,
                transport: transport
            )
            return false
        case .log, .metric, .traceSpan, .eventEmit:
            // Telemetry from the client side is logged & persisted only.
            return false
        case .unknown(let typeName, _):
            let optional = envelope.extensions?["optional"] == .bool(true)
            switch await extensionRegistry.disposition(forUnknown: typeName, optional: optional) {
            case .drop:
                log.debug("dropping optional unknown type", metadata: ["type": "\(typeName)"])
                return false
            case .accept:
                return false  // no per-extension handler in v0.1
            case .nack:
                throw ARCPError.unimplemented(section: "§21.3", detail: "unknown type \(typeName)")
            }
        default:
            throw ARCPError.unimplemented(
                section: "§6.2",
                detail: "message type \(envelope.payload.typeName) not handled at the runtime"
            )
        }
    }

    private func handleSubscribe(
        envelope: Envelope,
        payload: SubscribePayload,
        transport: any Transport
    ) async throws {
        let subscriptionId = SubscriptionId.random()
        let send: @Sendable (Envelope) async throws -> Void = { [weak self] env in
            guard let self else { return }
            try await self.send(env, transport: transport)
        }
        await subscriptionManager.subscribe(
            subscriptionId: subscriptionId,
            filter: payload.filter,
            since: payload.since,
            send: send
        )
        try await transport.send(
            Envelope(
                sessionId: envelope.sessionId,
                correlationId: envelope.id,
                payload: .subscribeAccepted(
                    SubscribeAcceptedPayload(subscriptionId: subscriptionId)
                )
            )
        )
    }

    private func handleArtifactPut(
        envelope: Envelope,
        payload: ArtifactPutPayload,
        info: SessionInfo,
        transport: any Transport
    ) async throws {
        guard let bytes = Data(base64Encoded: payload.data) else {
            throw ARCPError.invalidArgument(field: "data", detail: "not base64")
        }
        let ref = try await artifactStore.put(
            sessionId: info.sessionId,
            artifactId: payload.artifactId,
            mediaType: payload.mediaType,
            data: bytes,
            ttlSeconds: payload.ttlSeconds
        )
        try await send(
            Envelope(
                sessionId: info.sessionId,
                correlationId: envelope.id,
                payload: .artifactRef(ArtifactRefPayload(ref: ref))
            ),
            transport: transport
        )
    }

    private func handleArtifactFetch(
        envelope: Envelope,
        payload: ArtifactFetchPayload,
        info: SessionInfo,
        transport: any Transport
    ) async throws {
        let (ref, data) = try await artifactStore.fetch(artifactId: payload.artifactId)
        try await send(
            Envelope(
                sessionId: info.sessionId,
                correlationId: envelope.id,
                payload: .artifactRef(
                    ArtifactRefPayload(ref: ref, data: data.base64EncodedString())
                )
            ),
            transport: transport
        )
    }

    private func handleListJobs(
        envelope: Envelope,
        payload: SessionListJobsPayload,
        info: SessionInfo,
        jobManager: JobManager,
        transport: any Transport
    ) async throws {
        let (entries, nextCursor) = await jobManager.listJobs(
            filter: payload.filter,
            limit: payload.limit,
            cursor: payload.cursor
        )
        let response = SessionJobsPayload(
            requestId: envelope.id.rawValue,
            jobs: entries,
            nextCursor: nextCursor
        )
        try await send(
            Envelope(
                sessionId: info.sessionId,
                correlationId: envelope.id,
                payload: .sessionJobs(response)
            ),
            transport: transport
        )
    }

    private func handleResume(
        envelope: Envelope,
        payload: ResumePayload,
        info: SessionInfo,
        transport: any Transport
    ) async throws {
        guard payload.checkpointId == nil else {
            throw ARCPError.unimplemented(
                section: "§19",
                detail: "checkpoint-based resume is out of scope for v0.1"
            )
        }
        let envelopes = try await eventLog.replay(
            sessionId: info.sessionId,
            after: payload.afterMessageId
        )
        for replayed in envelopes {
            try await transport.send(replayed)
        }
        try await transport.send(
            Envelope(
                sessionId: info.sessionId,
                correlationId: envelope.id,
                payload: .ack(AckPayload(detail: "resume complete: \(envelopes.count) events"))
            )
        )
    }

    private func persistOptional(_ envelope: Envelope, sessionId: SessionId?) async throws {
        let withSession: Envelope
        if envelope.sessionId == nil {
            guard let sessionId else { return }
            withSession = envelope.with(sessionId: sessionId)
        } else {
            withSession = envelope
        }
        try await eventLog.append(withSession)
    }
}

extension Envelope {
    /// Return a copy with `sessionId` replaced (used when stamping pre-handshake
    /// envelopes for the event log).
    public func with(sessionId: SessionId) -> Envelope {
        Envelope(
            arcp: arcp,
            id: id,
            timestamp: timestamp,
            source: source,
            target: target,
            sessionId: sessionId,
            jobId: jobId,
            streamId: streamId,
            subscriptionId: subscriptionId,
            traceId: traceId,
            spanId: spanId,
            parentSpanId: parentSpanId,
            correlationId: correlationId,
            causationId: causationId,
            idempotencyKey: idempotencyKey,
            priority: priority,
            extensions: extensions,
            payload: payload
        )
    }
}
