import Foundation
import Testing

@testable import ARCP

@Suite("SubscriptionManager")
struct SubscriptionManagerTests {
    @Test("route applies session, job, stream, trace, type, and priority filters")
    func routeAppliesFilters() async throws {
        let eventLog = try EventLog.inMemory()
        let manager = SubscriptionManager(eventLog: eventLog)
        let sink = EnvelopeSink()
        let subscriptionId = SubscriptionId("sub_filters")
        let matching = Envelope(
            sessionId: SessionId("sess_match"),
            jobId: JobId("job_match"),
            streamId: StreamId("stream_match"),
            traceId: TraceId("trace_match"),
            priority: .high,
            payload: .log(LogPayload(level: .info, message: "matched"))
        )
        await manager.subscribe(
            subscriptionId: subscriptionId,
            filter: SubscriptionFilter(
                sessionIds: [SessionId("sess_match")],
                traceIds: [TraceId("trace_match")],
                jobIds: [JobId("job_match")],
                streamIds: [StreamId("stream_match")],
                types: ["log"],
                minPriority: .normal
            ),
            since: nil,
            send: { envelope in await sink.append(envelope) }
        )

        await manager.route(envelope: matching.with(jobId: JobId("job_other")))
        await manager.route(envelope: matching.with(priority: .low))
        await manager.route(envelope: matching)
        await manager.route(
            envelope: Envelope(
                sessionId: SessionId("sess_match"),
                subscriptionId: subscriptionId,
                payload: .subscribeEvent(SubscribeEventPayload(event: .object([:])))
            )
        )

        let delivered = await sink.all()
        #expect(delivered.count == 1)
        #expect(delivered[0].subscriptionId == subscriptionId)
        guard case .subscribeEvent(let payload) = delivered[0].payload,
            case .object(let event) = payload.event
        else {
            Issue.record("expected subscribe.event")
            return
        }
        #expect(event["type"] == .string("log"))
    }

    @Test("unsubscribe prevents future delivery")
    func unsubscribePreventsDelivery() async throws {
        let manager = SubscriptionManager(eventLog: try EventLog.inMemory())
        let sink = EnvelopeSink()
        let subscriptionId = SubscriptionId("sub_unsubscribe")
        await manager.subscribe(
            subscriptionId: subscriptionId,
            filter: SubscriptionFilter(types: ["log"]),
            since: nil,
            send: { envelope in await sink.append(envelope) }
        )
        await manager.unsubscribe(subscriptionId)
        await manager.route(
            envelope: Envelope(payload: .log(LogPayload(level: .info, message: "ignored")))
        )
        #expect(await sink.all().isEmpty)
    }

    @Test("backfill replays matching session events and emits boundary")
    func backfillReplaysMatches() async throws {
        let eventLog = try EventLog.inMemory()
        let sessionId = SessionId("sess_backfill")
        let first = Envelope(
            id: MessageId("msg_backfill_1"),
            sessionId: sessionId,
            payload: .log(LogPayload(level: .info, message: "first"))
        )
        let second = Envelope(
            id: MessageId("msg_backfill_2"),
            sessionId: sessionId,
            payload: .metric(MetricPayload(name: "ignored", value: 1))
        )
        let third = Envelope(
            id: MessageId("msg_backfill_3"),
            sessionId: sessionId,
            payload: .log(LogPayload(level: .info, message: "third"))
        )
        try await eventLog.append(first)
        try await eventLog.append(second)
        try await eventLog.append(third)

        let sink = EnvelopeSink()
        let manager = SubscriptionManager(eventLog: eventLog)
        await manager.subscribe(
            subscriptionId: SubscriptionId("sub_backfill"),
            filter: SubscriptionFilter(sessionIds: [sessionId], types: ["log"]),
            since: SubscriptionSince(afterMessageId: first.id),
            send: { envelope in await sink.append(envelope) }
        )

        try await waitUntilEnvelopeCount(2, sink: sink)
        let delivered = await sink.all()
        #expect(delivered.count == 2)
        let events = delivered.compactMap { envelope -> JSONValue? in
            if case .subscribeEvent(let payload) = envelope.payload { return payload.event }
            return nil
        }
        #expect(events.contains { $0 == .object(["type": .string("subscription.backfill_complete")]) })
        #expect(events.contains { event in
            guard case .object(let dict) = event else { return false }
            return dict["id"] == .string(third.id.rawValue)
        })
    }

    @Test("shutdown closes all subscriptions")
    func shutdownClosesSubscriptions() async throws {
        let manager = SubscriptionManager(eventLog: try EventLog.inMemory())
        let sink = EnvelopeSink()
        await manager.subscribe(
            subscriptionId: SubscriptionId("sub_close_a"),
            filter: SubscriptionFilter(),
            since: nil,
            send: { envelope in await sink.append(envelope) }
        )
        await manager.subscribe(
            subscriptionId: SubscriptionId("sub_close_b"),
            filter: SubscriptionFilter(),
            since: nil,
            send: { envelope in await sink.append(envelope) }
        )
        await manager.shutdown(reason: "test shutdown")
        let closed = await sink.payloads().filter {
            if case .subscribeClosed = $0 { return true }
            return false
        }
        #expect(closed.count == 2)
    }

    private func waitUntilEnvelopeCount(_ count: Int, sink: EnvelopeSink) async throws {
        for _ in 0..<50 {
            if await sink.all().count >= count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ARCPError.deadlineExceeded(operation: "subscription manager test")
    }
}

private extension Envelope {
    func with(jobId: JobId? = nil, priority: Priority? = nil) -> Envelope {
        Envelope(
            arcp: arcp,
            id: id,
            timestamp: timestamp,
            source: source,
            target: target,
            sessionId: sessionId,
            jobId: jobId ?? self.jobId,
            streamId: streamId,
            subscriptionId: subscriptionId,
            traceId: traceId,
            spanId: spanId,
            parentSpanId: parentSpanId,
            correlationId: correlationId,
            causationId: causationId,
            idempotencyKey: idempotencyKey,
            priority: priority ?? self.priority,
            extensions: extensions,
            payload: payload
        )
    }
}
