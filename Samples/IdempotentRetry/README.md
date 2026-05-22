# IdempotentRetry

**ARCP v1.1 §7.2 / §13.5 — idempotency key deduplication**

Submitting the same `(principal, idempotency_key)` pair twice returns the
**same `job_id`** on both replies — the runtime detects the duplicate and
returns the existing job rather than dispatching a second one.

## What it shows

| Feature | RFC section |
|---------|-------------|
| `IdempotencyKey` on `Envelope` | §7.2 |
| Duplicate key → same `job_id` | §13.5 |
| Fresh key → new `job_id` | §13.5 |
| `Capabilities(durableJobs: true)` | §5.1 |

## Practical use-case

A client crashes mid-flight, restarts, re-sends the same envelope with the
same idempotency key, and picks up the already-running job instead of
launching a duplicate.

## Running

```bash
swift run
```

## Expected output

```
first  submit envId=xxxxxxxx → job_id=yyyyyyyy
second submit envId=zzzzzzzz → job_id=yyyyyyyy
✓ idempotent: both submissions returned the SAME job_id
job.completed
fresh  submit → job_id=wwwwwwww
✓ new key created a distinct job
done
```
