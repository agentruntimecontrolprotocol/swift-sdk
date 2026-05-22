# Conformance

Implemented versus deferred protocol surfaces are summarized in **README.md** (Status section). Source modules cite RFC sections in doc comments (e.g. `RFC §8`).

## ARCP v1.1 claimed surfaces

- `job.result_chunk` wire messages, runtime emission, and client `ResultChunkStream`.
- `lease_constraints.expires_at` on `tool.invoke`, submission validation, and in-handler expiry checks.
- `cost.budget` parsing, budget tracking, metrics, subset checks, and `BUDGET_EXHAUSTED`.
- `model.use` parsing, matching, subset checks, and runtime policy helper.
- `provisioned_credentials` wire payloads, provisioner protocol, in-memory test provisioner, issue/rotate/revoke lifecycle, and redacted credential descriptions.

For cross-language conformance tracking, use the monorepo `spec/` tree and shared issue milestones.
