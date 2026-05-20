# Result-chunk streaming demo (ARCP v1.1 §8.4)

Hosts an in-process `report-builder` agent that emits its final result
as a sequence of `job.result_chunk` events terminated by a
`job.completed` carrying `result_id` / `result_size` / `summary`. The
client uses `ResultChunkAssembler` to reassemble the chunks into the
original payload.

```sh
swift run ResultChunk
```

Mirrors `rust-sdk/examples/result_chunk/`.
