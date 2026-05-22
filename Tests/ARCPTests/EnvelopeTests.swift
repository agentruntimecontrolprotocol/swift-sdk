import Foundation
import Testing

@testable import ARCP

@Suite("Envelope (RFC §6.1)")
struct EnvelopeTests {
    @Test("Envelope encodes wire fields under canonical names")
    func canonicalEncoding() throws {
        let env = Envelope(
            id: MessageId("msg_001"),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            sessionId: SessionId("sess_123"),
            traceId: TraceId("trace_789"),
            idempotencyKey: IdempotencyKey("refund-ord_4812"),
            priority: .high,
            payload: .ack(AckPayload(detail: "ok"))
        )
        let json = try env.toJSON()
        let raw = String(decoding: json, as: UTF8.self)
        #expect(raw.contains("\"arcp\":\"1.1\""))
        #expect(raw.contains("\"id\":\"msg_001\""))
        #expect(raw.contains("\"type\":\"ack\""))
        #expect(raw.contains("\"session_id\":\"sess_123\""))
        #expect(raw.contains("\"trace_id\":\"trace_789\""))
        #expect(raw.contains("\"idempotency_key\":\"refund-ord_4812\""))
        #expect(raw.contains("\"priority\":\"high\""))
    }

    @Test("Missing priority decodes as default 'normal'")
    func priorityDefault() throws {
        let json = """
            {
              "arcp": "1.1",
              "id": "msg_x",
              "type": "ack",
              "timestamp": "2026-05-09T13:00:00Z",
              "session_id": "sess_x",
              "payload": {}
            }
            """
        let decoded = try Envelope.fromJSON(json.data(using: .utf8)!)
        #expect(decoded.priority == .normal)
    }

    @Test("Round-trips every in-scope payload variant", arguments: roundTripFixtures)
    func roundTrip(fixture: RoundTripFixture) throws {
        let envelope = Envelope(
            sessionId: SessionId("sess_x"),
            jobId: JobId("job_y"),
            payload: fixture.payload
        )
        let data = try envelope.toJSON()
        let decoded = try Envelope.fromJSON(data)
        #expect(decoded.payload.typeName == fixture.payload.typeName)
        let reEncoded = try decoded.toJSON()
        let re = try Envelope.fromJSON(reEncoded)
        #expect(re.payload.typeName == fixture.payload.typeName)
    }

    @Test("Unknown wire type round-trips as .unknown")
    func unknownTypeRoundTrip() throws {
        let json = """
            {
              "arcp": "1.1",
              "id": "msg_unknown",
              "type": "arcpx.acme.cache.v1.warm",
              "timestamp": "2026-05-09T13:00:00Z",
              "payload": {"warmed": true}
            }
            """
        let decoded = try Envelope.fromJSON(json.data(using: .utf8)!)
        guard case .unknown(let typeName, let payload) = decoded.payload else {
            Issue.record("expected unknown variant, got \(decoded.payload)")
            return
        }
        #expect(typeName == "arcpx.acme.cache.v1.warm")
        #expect(payload == .object(["warmed": .bool(true)]))
    }

    @Test("Correlation/causation/extensions preserved round-trip")
    func metadataPreservation() throws {
        let env = Envelope(
            sessionId: SessionId("sess_x"),
            correlationId: MessageId("msg_cmd"),
            causationId: MessageId("msg_root"),
            extensions: ["arcpx.acme.cache.v1.optional": .bool(true)],
            payload: .ack(AckPayload(detail: "ok"))
        )
        let data = try env.toJSON()
        let decoded = try Envelope.fromJSON(data)
        #expect(decoded.correlationId == MessageId("msg_cmd"))
        #expect(decoded.causationId == MessageId("msg_root"))
        #expect(decoded.extensions?["arcpx.acme.cache.v1.optional"] == .bool(true))
    }

    @Test("RFC 3339 timestamp without fractional seconds decodes")
    func timestampNoFraction() throws {
        let json = """
            {
              "arcp": "1.1",
              "id": "msg_x",
              "type": "ping",
              "timestamp": "2026-05-09T13:00:00Z",
              "session_id": "sess_x",
              "payload": {}
            }
            """
        let decoded = try Envelope.fromJSON(json.data(using: .utf8)!)
        #expect(decoded.id == MessageId("msg_x"))
    }
}

/// Fixture value pairing a wire type name with a representative `MessageType`.
struct RoundTripFixture: Sendable, CustomTestStringConvertible {
    let payload: MessageType
    var testDescription: String { payload.typeName }
}

private let now = Date(timeIntervalSince1970: 1_700_000_000)
private let later = Date(timeIntervalSince1970: 1_700_000_120)

/// Every in-scope MessageType variant. Tests parameterize over this list.
let roundTripFixtures: [RoundTripFixture] = [
    .init(
        payload: .sessionOpen(
            SessionOpenPayload(
                auth: AuthBlock(scheme: .bearer, token: "tok"),
                client: IdentityBlock(kind: "example-client", version: "1.4.2"),
                capabilities: Capabilities(streaming: true, artifacts: true)
            )
        )
    ),
    .init(
        payload: .sessionChallenge(
            SessionChallengePayload(nonce: "n", scheme: .bearer, expiresAt: later)
        )
    ),
    .init(
        payload: .sessionAuthenticate(
            SessionAuthenticatePayload(
                auth: AuthBlock(scheme: .bearer, token: "tok"),
                nonce: "n"
            )
        )
    ),
    .init(
        payload: .sessionAccepted(
            SessionAcceptedPayload(
                sessionId: SessionId("sess_a"),
                runtime: IdentityBlock(kind: "example-runtime", version: "0.1"),
                capabilities: Capabilities(streaming: true)
            )
        )
    ),
    .init(payload: .sessionUnauthenticated(SessionUnauthenticatedPayload(detail: "bad creds"))),
    .init(
        payload: .sessionRejected(
            SessionRejectedPayload(
                error: ErrorEnvelope(code: .unimplemented, message: "no anonymous")
            )
        )
    ),
    .init(payload: .sessionRefresh(SessionRefreshPayload(deadlineMs: 30_000))),
    .init(payload: .sessionEvicted(SessionEvictedPayload(reason: "idle", code: .deadlineExceeded))),
    .init(payload: .sessionClose(SessionClosePayload(reason: "done"))),
    .init(
        payload: .sessionListJobs(
            SessionListJobsPayload(
                filter: SessionListJobsFilter(status: ["running"], agent: "code-refactor"),
                limit: 100,
                cursor: nil
            )
        )
    ),
    .init(
        payload: .sessionJobs(
            SessionJobsPayload(
                requestId: "01J_REQ",
                jobs: [
                    JobListEntry(
                        jobId: JobId("job_a"),
                        agent: "code-refactor@2.0.0",
                        status: "running",
                        createdAt: now,
                        traceId: "4bf92f",
                        lastEventSeq: 1822
                    )
                ],
                nextCursor: nil
            )
        )
    ),
    .init(payload: .ping(PingPayload(nonce: "p"))),
    .init(payload: .pong(PongPayload(nonce: "p"))),
    .init(payload: .ack(AckPayload(detail: "ok"))),
    .init(
        payload: .nack(
            NackPayload(error: ErrorEnvelope(code: .invalidArgument, message: "bad"))
        )
    ),
    .init(
        payload: .cancel(
            CancelPayload(target: .job, targetId: "job_y", reason: "user", deadlineMs: 5_000)
        )
    ),
    .init(payload: .cancelAccepted(CancelAcceptedPayload(deadlineMs: 5_000))),
    .init(payload: .cancelRefused(CancelRefusedPayload(reason: "already done"))),
    .init(
        payload: .interrupt(
            InterruptPayload(target: .job, targetId: "job_y", prompt: "halt")
        )
    ),
    .init(payload: .resume(ResumePayload(afterMessageId: MessageId("msg_x")))),
    .init(payload: .backpressure(BackpressurePayload(desiredRatePerSecond: 20))),
    .init(
        payload: .toolInvoke(
            ToolInvokePayload(tool: "filesystem.search", arguments: .object(["q": .string("*.ts")]))
        )
    ),
    .init(payload: .toolResult(ToolResultPayload(value: .int(42)))),
    .init(
        payload: .toolError(
            ToolErrorPayload(error: ErrorEnvelope(code: .resourceExhausted, message: "rate"))
        )
    ),
    .init(payload: .jobAccepted(JobAcceptedPayload(jobId: JobId("job_y")))),
    .init(payload: .jobStarted(JobStartedPayload(jobId: JobId("job_y"), startedAt: now))),
    .init(payload: .jobProgress(JobProgressPayload(percent: 42, message: "embedding"))),
    .init(
        payload: .jobHeartbeat(
            JobHeartbeatPayload(sequence: 1, deadlineMs: 60_000, state: .running)
        )
    ),
    .init(payload: .jobCompleted(JobCompletedPayload(result: .string("ok")))),
    .init(
        payload: .jobFailed(
            JobFailedPayload(error: ErrorEnvelope(code: .internal, message: "boom"))
        )
    ),
    .init(payload: .jobCancelled(JobCancelledPayload(reason: "user"))),
    .init(payload: .streamOpen(StreamOpenPayload(kind: .text, contentType: "text/plain"))),
    .init(payload: .streamChunk(StreamChunkPayload(sequence: 1, content: "hi"))),
    .init(payload: .streamClose(StreamClosePayload(reason: "eof"))),
    .init(
        payload: .streamError(
            StreamErrorPayload(error: ErrorEnvelope(code: .cancelled, message: "stop"))
        )
    ),
    .init(
        payload: .permissionRequest(
            PermissionRequestPayload(
                permission: "fs.write",
                resource: "/tmp",
                operation: "write"
            )
        )
    ),
    .init(
        payload: .permissionGrant(
            PermissionGrantPayload(
                permission: "fs.write",
                resource: "/tmp",
                operation: "write",
                leaseSeconds: 300
            )
        )
    ),
    .init(
        payload: .permissionDeny(
            PermissionDenyPayload(permission: "fs.write", resource: "/etc", reason: "policy")
        )
    ),
    .init(
        payload: .leaseGranted(
            LeaseGrantedPayload(
                leaseId: LeaseId("lease_x"),
                permission: "fs.write",
                resource: "/tmp",
                operation: "write",
                expiresAt: later
            )
        )
    ),
    .init(
        payload: .leaseExtended(
            LeaseExtendedPayload(leaseId: LeaseId("lease_x"), expiresAt: later)
        )
    ),
    .init(
        payload: .leaseRevoked(
            LeaseRevokedPayload(leaseId: LeaseId("lease_x"), reason: "policy")
        )
    ),
    .init(
        payload: .leaseRefresh(
            LeaseRefreshPayload(leaseId: LeaseId("lease_x"), requestedSeconds: 60)
        )
    ),
    .init(payload: .subscribe(SubscribePayload(filter: SubscriptionFilter(types: ["log"])))),
    .init(
        payload: .subscribeAccepted(
            SubscribeAcceptedPayload(subscriptionId: SubscriptionId("sub_x"))
        )
    ),
    .init(
        payload: .subscribeEvent(
            SubscribeEventPayload(event: .object(["t": .string("log")]))
        )
    ),
    .init(payload: .unsubscribe(UnsubscribePayload(subscriptionId: SubscriptionId("sub_x")))),
    .init(
        payload: .subscribeClosed(
            SubscribeClosedPayload(subscriptionId: SubscriptionId("sub_x"), code: .cancelled)
        )
    ),
    .init(
        payload: .artifactPut(
            ArtifactPutPayload(mediaType: "application/json", data: "e30=", size: 2)
        )
    ),
    .init(payload: .artifactFetch(ArtifactFetchPayload(artifactId: ArtifactId("art_x")))),
    .init(
        payload: .artifactRef(
            ArtifactRefPayload(
                ref: ArtifactRef(
                    artifactId: ArtifactId("art_x"),
                    uri: "arcp://session/sess_a/artifact/art_x",
                    mediaType: "application/json",
                    size: 2
                )
            )
        )
    ),
    .init(payload: .artifactRelease(ArtifactReleasePayload(artifactId: ArtifactId("art_x")))),
    .init(payload: .eventEmit(EventEmitPayload(name: "subscription.backfill_complete"))),
    .init(payload: .log(LogPayload(level: .info, message: "hi"))),
    .init(
        payload: .metric(
            MetricPayload(
                name: StandardMetric.tokensUsed,
                value: 1432,
                unit: "tokens",
                dims: ["kind": .string("input")]
            )
        )
    ),
    .init(payload: .traceSpan(TraceSpanPayload(name: "tool.exec", startedAt: now))),
]
