# Leases

ARCP v1.1 lease capabilities bound a job's authority. Swift exposes the
currently implemented lease fields on `ToolInvokePayload`:

- `leaseConstraints.expiresAt` rejects submissions in the past and lets handlers call `context.checkLeaseExpiration()` before authority-bearing work.
- `costBudget` seeds a per-job `BudgetTracker`; handlers call `context.charge(name:amount:currency:)`, which emits the named cost metric plus `cost.budget.remaining`.
- `modelUse` carries case-sensitive model patterns with `*` wildcards. Use `context.checkModelUse(_:)` or `ModelUsePolicy.check(_:model:)` when the runtime is in the path of a model invocation.

Provisioned credentials are enabled by passing a `CredentialProvisioner` to
`ARCPRuntime`. The runtime issues credentials before `job.accepted`, attaches
them to `JobAcceptedPayload.credentials`, and revokes them when the job reaches
a terminal state. Credential values are secrets: `ProvisionedCredential`
redacts `description`, and `session.list_jobs` has no credential field.

Credential plug-ins should copy the effective lease into upstream controls:
`cost.budget` becomes an upstream spend cap, `model.use` becomes an allowed
model list, and `expires_at` becomes the credential TTL. Vendor-specific
provisioners belong in application code or samples, not in the core module.
