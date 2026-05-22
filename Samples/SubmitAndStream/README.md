# SubmitAndStream

**ARCP v1.1 §13.1 — submit a job and stream progress events**

Demonstrates the canonical job lifecycle: `tool.invoke` → `job.accepted` →
`log` / `progress` / `metric` events → `job.completed`.

## What it shows

| Feature | RFC section |
|---------|-------------|
| `tool.invoke` submission | §5.2 |
| `job.accepted` with job ID | §13.1 |
| `context.reportProgress` mid-job | §13.3 |
| `context.log` at various levels | §14.1 |
| `context.metric` cost/latency reporting | §14.2 |
| `job.completed` with final result | §13.1 |

## Running

```bash
swift run
```

## Expected output

```
→ tool.invoke sent
← job.accepted   job_id=xxxxxxxx
← log[info]      starting summarizer  doc_length=...
← progress[25%]  extracting key points
← progress[60%]  building summary
← progress[90%]  finalising output
← metric         cost_usd=0.0012
← job.completed  result=Summary: ...
```
