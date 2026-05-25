import Foundation
import Logging

/// Per-runtime subscription registry. RFC §13.
///
/// A subscriber calls `subscribe(...)` (typically forwarded from the dispatch
/// loop's `subscribe` envelope handler), the manager validates and records
/// the filter, then `route(envelope:)` is invoked for every envelope flowing
/// out of the runtime. Matching envelopes are wrapped in `subscribe.event`
/// and delivered to the subscription's transport.
public actor SubscriptionManager {
    private let log: Logger
    private let eventLog: EventLog
    private var subscriptions: [SubscriptionId: SubscriptionRecord] = [:]

    public init(eventLog: EventLog) {
        self.eventLog = eventLog
        self.log = Logger(label: "arcp.subscriptions")
    }

    /// Register a subscription. Backfill (if requested) is fired off as a
    /// child Task that emits `subscribe.event` envelopes for each historical
    /// match, ending with a synthetic `subscription.backfill_complete` event.
    public func subscribe(
        subscriptionId: SubscriptionId,
        ownerSessionId: SessionId? = nil,
        filter: SubscriptionFilter,
        since: SubscriptionSince?,
        send: @escaping @Sendable (Envelope) async throws -> Void
    ) async {
        subscriptions[subscriptionId] = SubscriptionRecord(
            ownerSessionId: ownerSessionId,
            filter: filter,
            send: send
        )
        if let since {
            Task { [weak self] in
                await self?.backfill(subscriptionId: subscriptionId, since: since)
            }
        }
    }

    public func unsubscribe(_ subscriptionId: SubscriptionId) {
        subscriptions.removeValue(forKey: subscriptionId)
    }

    /// Remove every subscription owned by `sessionId`, attempting to notify
    /// each one with a `subscribe.closed` envelope. Cleanup proceeds even if
    /// the notification fails (the owning transport is typically already shut).
    public func removeAllOwned(by sessionId: SessionId, reason: String) async {
        let owned = subscriptions.filter { $0.value.ownerSessionId == sessionId }
        for (subId, record) in owned {
            subscriptions.removeValue(forKey: subId)
            try? await record.send(
                Envelope(
                    sessionId: sessionId,
                    subscriptionId: subId,
                    payload: .subscribeClosed(
                        SubscribeClosedPayload(
                            subscriptionId: subId,
                            code: .unavailable,
                            reason: reason
                        )
                    )
                )
            )
        }
    }

    /// Push `envelope` to every subscriber whose filter matches.
    ///
    /// `subscribe.event` envelopes are ignored to prevent a subscriber with an
    /// empty filter from re-wrapping its own delivery into another
    /// `subscribe.event` and cascading without bound.
    public func route(envelope: Envelope) async {
        if case .subscribeEvent = envelope.payload { return }
        for (subId, record) in subscriptions where record.matches(envelope) {
            try? await record.send(
                Envelope(
                    sessionId: envelope.sessionId,
                    subscriptionId: subId,
                    payload: .subscribeEvent(SubscribeEventPayload(event: encode(envelope)))
                )
            )
        }
    }

    public func shutdown(reason: String) async {
        for (subId, record) in subscriptions {
            try? await record.send(
                Envelope(
                    subscriptionId: subId,
                    payload: .subscribeClosed(
                        SubscribeClosedPayload(
                            subscriptionId: subId,
                            code: .unavailable,
                            reason: reason
                        )
                    )
                )
            )
        }
        subscriptions.removeAll()
    }

    private func backfill(subscriptionId: SubscriptionId, since: SubscriptionSince) async {
        guard let record = subscriptions[subscriptionId] else { return }
        guard let firstSession = record.filter.sessionIds?.first else {
            // Without a session_id filter, we don't know which session log to
            // backfill from in v0.1 — emit only the boundary marker.
            await sendBoundary(subscriptionId: subscriptionId, send: record.send)
            return
        }
        let envelopes: [Envelope]
        do {
            envelopes = try await eventLog.replay(
                sessionId: firstSession,
                after: since.afterMessageId
            )
        } catch {
            try? await record.send(
                Envelope(
                    subscriptionId: subscriptionId,
                    payload: .subscribeClosed(
                        SubscribeClosedPayload(
                            subscriptionId: subscriptionId,
                            code: .dataLoss,
                            reason: "\(error)"
                        )
                    )
                )
            )
            return
        }
        for envelope in envelopes where record.matches(envelope) {
            try? await record.send(
                Envelope(
                    sessionId: envelope.sessionId,
                    subscriptionId: subscriptionId,
                    payload: .subscribeEvent(SubscribeEventPayload(event: encode(envelope)))
                )
            )
        }
        await sendBoundary(subscriptionId: subscriptionId, send: record.send)
    }

    private func sendBoundary(
        subscriptionId: SubscriptionId,
        send: @Sendable (Envelope) async throws -> Void
    ) async {
        try? await send(
            Envelope(
                subscriptionId: subscriptionId,
                payload: .subscribeEvent(
                    SubscribeEventPayload(
                        event: .object(["type": .string("subscription.backfill_complete")])
                    )
                )
            )
        )
    }

    private func encode(_ envelope: Envelope) -> JSONValue {
        guard let data = try? envelope.toJSON(),
            let value = try? Envelope.makeDecoder().decode(JSONValue.self, from: data)
        else {
            return .object(["type": .string(envelope.payload.typeName)])
        }
        return value
    }

    private struct SubscriptionRecord: Sendable {
        let ownerSessionId: SessionId?
        let filter: SubscriptionFilter
        let send: @Sendable (Envelope) async throws -> Void

        func matches(_ envelope: Envelope) -> Bool {
            if let allowed = filter.sessionIds,
                !allowed.contains(where: { envelope.sessionId == $0 })
            {
                return false
            }
            if let allowed = filter.traceIds,
                !allowed.contains(where: { envelope.traceId == $0 })
            {
                return false
            }
            if let allowed = filter.jobIds, !allowed.contains(where: { envelope.jobId == $0 }) {
                return false
            }
            if let allowed = filter.streamIds,
                !allowed.contains(where: { envelope.streamId == $0 })
            {
                return false
            }
            if let allowed = filter.types, !allowed.contains(envelope.payload.typeName) {
                return false
            }
            if let minPriority = filter.minPriority, envelope.priority.rank < minPriority.rank {
                return false
            }
            return true
        }
    }
}
