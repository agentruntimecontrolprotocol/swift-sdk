# Recipe: Stream Resume

**ARCP v1.1 §10 / §19 / §7.2 — crash-and-resume for streamed results**

A writer agent emits 10 result chunks over a `ResultChunkStream`. The client
reads 4 chunks then simulates a crash (breaks the iterator). It re-submits the
same `IdempotencyKey` — the runtime deduplicates and returns the same
`job_id` — and resumes consuming the buffered remainder from the exact same
`ResultChunkStream` object. All 10 chunks are assembled in two phases without
re-running the agent.

## What it shows

| Feature | RFC section |
|---------|-------------|
| `context.emitResultChunk(resultId:chunkSeq:data:encoding:more:)` | §19 |
| `.streamed(resultId:size:summary:)` tool output | §19 |
| `client.resultChunks(for: jobId) -> ResultChunkStream` | §19 |
| `IdempotencyKey` deduplication: same key → same `job_id` | §7.2 |
| Sequential multi-iterator on shared `ResultChunkStream` buffer | §10 |
| `Capabilities(durableJobs: true)` on both runtime and client | §10 |

## Run

```bash
cd Recipes/stream-resume && swift run
```

## Expected output

```
→ report.write submitted  key=report-write-001
← job.accepted  job_id=xxxxxxxx
→ phase 1: collecting first 4 chunks (simulating crash after chunk 4)…
   chunk  seq=0  size=Xb
   chunk  seq=1  size=Xb
   chunk  seq=2  size=Xb
   chunk  seq=3  size=Xb
← phase 1: received 4 chunks (last seq=3)
→ phase 2: re-submitting same idempotency key…
← job.accepted  job_id=xxxxxxxx  (same — idempotent ✓)
→ consuming remaining chunks from buffered stream…
   chunk  seq=4  size=Xb
   ...
   chunk  seq=9  size=Xb
← phase 2: received 6 more chunks
← total: 10 chunks (expected 10)  ✓
← log[info]  report written: N bytes
← job.completed  summary=report with 10 sections
```

## How the resume works

`ResultChunkStream` is backed by a shared `AsyncThrowingStream` buffer. When
the first `for await` loop breaks after 4 chunks, the buffer retains chunks
4–9. A second `for await` on the same stream object picks up from where the
first left off — no re-delivery needed from the runtime.

## Key files

| File | What it shows |
|------|---------------|
| `Sources/StreamResume/main.swift` | End-to-end wiring |
| `WriterAgent` | `emitResultChunk` loop + `.streamed` return |
| Phase 1 / phase 2 | Break-and-resume pattern on `ResultChunkStream` |

## Related samples

- [Resumability](../../Samples/Resumability) — actual `exit(137)` crash and OS-level resume
- [IdempotentRetry](../../Samples/IdempotentRetry) — idempotency key deduplication
