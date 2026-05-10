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
    private var unhandledContinuation: AsyncStream<Envelope>.Continuation?

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
                self.dispatch(envelope: envelope)
            }
            self.finishUnhandled()
        }
    }

    private func dispatch(envelope: Envelope) {
        switch envelope.payload {
        case .pong(let payload):
            if let id = envelope.correlationId,
                let cont = pendingPongs.removeValue(forKey: id)
            {
                cont.resume(returning: payload)
            } else {
                unhandledContinuation?.yield(envelope)
            }
        default:
            unhandledContinuation?.yield(envelope)
        }
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
                try await withCheckedThrowingContinuation { cont in
                    Task { await self?.registerPongWaiter(id: id, continuation: cont) }
                }
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

    private func registerPongWaiter(
        id: MessageId,
        continuation: CheckedContinuation<PongPayload, any Error>
    ) {
        pendingPongs[id] = continuation
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
}
