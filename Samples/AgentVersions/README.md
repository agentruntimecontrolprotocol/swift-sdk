# AgentVersions

ARCP v1.1 §7.5 — agent versioning (`name@version`).

The runtime advertises an `echo` agent at versions `1.0.0` and
`2.0.0` (default `2.0.0`) under
`capabilities.agents`. The client submits:

1. A job pinning the existing version (`echo@1.0.0`) → completes.
2. A job pinning a missing version (`echo@9.9.9`) → fails with
   `AGENT_VERSION_NOT_AVAILABLE`.

## ARCP primitives

- `AgentRef` parsing for `name` and `name@version`.
- `Capabilities.agents` rich shape `[ { name, versions, default } ]`
  alongside the v1.0-compatible flat string list.
- `AGENT_VERSION_NOT_AVAILABLE` error code surfaced when the runtime
  cannot satisfy a pinned version.

## File tour

- `Sources/AgentVersions/main.swift` — paired runtime + client over
  a memory transport. Builds the rich inventory, submits both jobs,
  and asserts the expected outcomes.
