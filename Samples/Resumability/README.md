# Resumability

Five-step research job (plan → gather → synthesize → critique →
finalize) that checkpoints after every step. Crash mid-flight, resume
on next invocation, no work lost.

## Before ARCP

Long jobs survive crashes only if the team built their own checkpoint
store, retry contract, and dedupe layer. Most don't. Crash means
restart; restart means re-spending tokens; "did this already run?"
turns into a SQL detective story.

## With ARCP

```swift
// every step ends with two envelopes
try await emitProgress(client, jobId: jobId, step: "synthesize")
let chk = try await emitCheckpoint(client, jobId: jobId, step: "synthesize")

// resume picks up at the step after the last checkpoint
let last = try await issueResume(client, jobId: jobId,
                                 afterMessageId: msgId, checkpointId: chk)
let nextIdx = steps.firstIndex(of: last)! + 1
```

Per-step `IdempotencyKey` keeps execution single across retries: the
runtime returns the prior outcome if the same step is re-issued.

## Try it

```bash
# crash after `synthesize`. Prints the resume token.
CRASH_AFTER_STEP=synthesize swift run Resumability

# resume — runtime replays up to the last checkpoint, we run from next.
RESUME_JOB_ID=...  RESUME_AFTER_MSG_ID=...  RESUME_CHECKPOINT_ID=... \
  swift run Resumability
```

## ARCP primitives

- Resumability — RFC §19, `after_message_id` + `checkpoint_id`.
- Job lifecycle + checkpoints — §10.
- `idempotency_key` semantics — §6.4.
- `DATA_LOSS` on retention expiry — §19, §18.2.

## File tour

- `Sources/Resumability/main.swift` — start-fresh vs resume. `exit(137)`
  on the crash step demonstrates process death.
- `Sources/Resumability/Steps.swift` — `runStep` stub +
  `ARCPClient.placeholder`.

## Variations

- Plug a per-step persistence sidecar so checkpoints survive ARCP
  retention expiry too.
- Branch on critique severity: low → finalize; high → loop back to
  synthesize with the critique appended.
- Emit `kind: thought` between steps for Reasoning-Streams to consume.
