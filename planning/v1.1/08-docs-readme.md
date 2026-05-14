# 08 — Docs & README

**Inputs:**
[`../../BOOTSTRAP.md`](../../BOOTSTRAP.md) Phase 8,
[`01-spec-delta.md`](01-spec-delta.md),
[`02-current-audit.md`](02-current-audit.md),
`04-architecture.md` (target split: `ARCPCore`, `ARCPClient`,
`ARCPRuntime`, umbrella `ARCP`, plus middleware targets),
`06-examples.md` (quickstart maps to `Samples/SubmitAndStream/`),
[`../../../typescript-sdk/docs/`](../../../typescript-sdk/docs/) for
the shared `docs/` tree shape,
[`../../README.md`](../../README.md) for the existing voice and
`swift package generate-documentation --target ARCP` invocation
(line 72).

Plan only. No doc bodies (skeleton templates and outlines only).

## 1. `docs/` tree

Mirror the TS layout (`../../../typescript-sdk/docs/`: `README.md`
front door, `getting-started.md`, `architecture.md`, `transports.md`,
`cli.md`, plus `guides/` keyed to spec §). The TS site does **not**
ship frontmatter today; ARCP Swift adopts it for two reasons: the
shared docs site ingests by `sdk` discriminator (one site renders TS
+ Swift + future SDKs side by side, keyed off `sdk:`), and `kind`
unblocks per-template rendering without filename heuristics. Frontmatter
is additive: GitHub renders the YAML block silently, so the file
double-roles as a docs-site source and a browsable repo file.

```
docs/
  README.md                         # front door, mirrors typescript-sdk/docs/README.md
  getting-started.md                # five-minute path; pairs with Samples/SubmitAndStream/
  architecture.md                   # ARCPCore/ARCPClient/ARCPRuntime split (cite 04-architecture.md)
  transports.md                     # MemoryTransport, StdioTransport, WebSocketTransport
  cli.md                            # `swift run arcp …`
  concepts/
    sessions.md                     # §6, §6.2, §6.4 capability features
    jobs.md                         # §7, §7.1 lease_constraints, §7.5 agent_versions
    leases.md                       # §9, §9.5 lease_expires_at, §9.4 subsetting
    events.md                       # §8, §8.2.1 progress, §8.4 result_chunk
    capability-negotiation.md       # §6.2 features[] intersection
  guides/
    submit-and-stream.md            # quickstart Swift idiom: AsyncThrowingStream
    subscribe-from-another-session.md  # §7.6 + JobSubscription (no cancel authority)
    budget-and-expiry.md            # §9.5 + §9.6, Decimal + ContinuousClock
    versioning.md                   # name@version grammar + AGENT_VERSION_NOT_AVAILABLE
    middleware.md                   # ARCPVapor, ARCPHummingbird, ARCPOTel attachment
  reference/
    error-codes.md                  # §12 (12 v1.0 + 3 v1.1), retryable flag
    feature-flags.md                # nine §6.2 features, Swift Feature enum mapping
    wire-format.md                  # §5.1 envelope, including event_seq
  diagrams/                         # filled by Phase 9 (09-diagrams.md); SVG renders here
```

### Frontmatter

Every Markdown file in `docs/` carries the following frontmatter
block as the first lines, before the first `#` heading.

```yaml
---
title: <human-readable, sentence case>
sdk: swift
spec_sections: ["§6.4", "§7.6"]  # cite every section the page covers
order: 30                         # in-section sort key; multiples of 10
kind: overview | concept | guide | reference
---
```

Rationale: the shared docs site ingests by these five keys. `sdk`
discriminates the language tab; `spec_sections` powers the cross-SDK
"§7.6 in every language" view (visible in the TS conformance page
today, even though TS does not yet emit frontmatter — verify by
reading `typescript-sdk/docs/guides/sessions.md` line 1 which uses
H1-anchored §-tags inline). `order` is conservative (multiples of 10)
so future inserts do not renumber siblings. `kind` controls the
template: `overview` gets a hero diagram slot from `docs/diagrams/`,
`reference` gets a sticky TOC, `guide` gets a "see also" footer,
`concept` is plain prose.

## 2. DocC catalogs

DocC is generated via the existing
[`README.md:72`](../../README.md#L72) command
`swift package generate-documentation --target ARCP`. The umbrella
`ARCP` target re-exports the public surface (per `04-architecture.md`),
so a single invocation produces one navigable archive that spans all
three core targets.

Catalog placement:

| Target              | Catalog path                                       |
| ------------------- | -------------------------------------------------- |
| `ARCPCore`          | `Sources/ARCPCore/Documentation.docc/`             |
| `ARCPClient`        | `Sources/ARCPClient/Documentation.docc/`           |
| `ARCPRuntime`       | `Sources/ARCPRuntime/Documentation.docc/`          |
| `ARCP` (umbrella)   | `Sources/ARCP/Documentation.docc/`                 |
| `ARCPVapor`         | `Sources/ARCPVapor/Documentation.docc/`            |
| `ARCPHummingbird`   | `Sources/ARCPHummingbird/Documentation.docc/`      |
| `ARCPOTel`          | `Sources/ARCPOTel/Documentation.docc/`             |

### Catalog contents

Each catalog contains:

1. A landing page (`<Target>.md`) — DocC `Article` with the target's
   one-paragraph purpose and a `## Topics` section organizing every
   public symbol by spec area. Topic groups: **Sessions**, **Jobs**,
   **Events**, **Leases**, **Budget**, **Errors**, **Middleware**,
   **Deprecated APIs**. The umbrella `ARCP` catalog's landing page
   mirrors `docs/README.md` (concept overview); the per-target landings
   stay terse and link out.
2. Per-concept articles (`<Concept>.md`) — one per `docs/concepts/`
   page, kept symbol-aware (link to types via DocC's `<doc:>` syntax).
   These do not duplicate `docs/concepts/` prose; they wrap the same
   content with symbol cross-references DocC needs.
3. Symbol docs on every public symbol. Required, not optional —
   `swift-docc-plugin` warns on undocumented public symbols and the
   build gate (`-Xswiftc -warnings-as-errors`,
   [`README.md:70`](../../README.md#L70)) promotes the warning.

### Symbol-doc voice

Terse imperative, present tense, first sentence is the abstract.
DocC parses the first sentence as the symbol summary in the navigator;
verbose first sentences truncate badly.

```swift
/// Submits a job to the runtime and returns a handle for streaming events.
///
/// - Parameters:
///   - agent: Agent reference. Use `name@version` for §7.5 versioning;
///     a bare `name` resolves to the runtime's default version.
///   - input: Agent-defined JSON payload.
///   - leaseConstraints: Optional §7.1 `expires_at` cap (v1.1).
///   - budget: Optional §9.6 per-currency budget (v1.1).
/// - Returns: A ``JobHandle`` whose ``JobHandle/events`` is an
///   `AsyncThrowingStream` of ``JobEvent``.
/// - Throws: ``ARCPError/agentVersionNotAvailable(name:version:available:)``
///   if the agent name exists but the requested version does not.
///
/// ## Discussion
/// See spec §7.1. The runtime MAY reduce the lease before accepting;
/// MUST NOT expand it. The returned handle owns the cancellation
/// authority — a subscription obtained via ``subscribe(jobID:)`` does
/// not.
```

Rules:

- First sentence ≤ 12 words, imperative, no marketing.
- Cite spec § in `## Discussion` only when behavior is non-obvious from
  the signature (lease subsetting, ack coalescing, chunk encoding
  union).
- Cross-reference with DocC `<doc:>` and ``Type/member`` syntax;
  raw symbol names render as inline code only.

### `## Topics` organization

DocC's `## Topics` section on the umbrella `ARCP` landing page groups
symbols by spec area:

```markdown
## Topics

### Sessions
- ``ARCPClient/connect(to:auth:)``
- ``ARCPClient/disconnect()``
- ``SessionFeatures``
- ``Capabilities``

### Jobs
- ``ARCPClient/submit(_:input:leaseConstraints:budget:)``
- ``JobHandle``
- ``JobState``

### Events
- ``JobEvent``
- ``JobEvent/Kind``
- ``ResultChunkData``

### Leases
- ``LeaseConstraints``
- ``LeaseEvaluator``

### Budget
- ``Budget``
- ``Currency``

### Errors
- ``ARCPError``
- ``ARCPError/retryable``

### Middleware
- <doc:OTelIntegration>
- <doc:VaporIntegration>

### Deprecated APIs
<!-- Empty at v1.1.0 — populated when a future minor release
     marks symbols `@available(*, deprecated, message: "...")`. -->
```

### `@available` policy

- Platform availability annotated on every public symbol that requires
  it: `@available(macOS 14, iOS 17, *)` on transports using APIs above
  the Package.swift floor.
- Deprecations carry `@available(*, deprecated, message: "Use X.")`
  and a `renamed:` argument when applicable; DocC surfaces the
  message in the navigator. Initial v1.1.0 ships zero deprecated
  symbols, so the **Deprecated APIs** topic group is empty (kept in
  the catalog so future releases populate it without restructuring).

### Build command

Documented in `README.md` build gate (unchanged from current
[`README.md:72`](../../README.md#L72)):

```bash
swift package generate-documentation --target ARCP
```

For hosted docs, the synthesis plan owns the choice of static-site
host; this phase only asserts the generator command.

## 3. README outline

Replaces [`../../README.md`](../../README.md) on the v1.1 cut. Sections,
in order, with single-sentence purpose. Numbers match the BOOTSTRAP
Phase 8 spec.

1. **Title + protocol version line.** First line under the H1 reads:
   `ARCP v1.1 reference SDK for Swift; SDK version: 1.0.0. Wire envelope `arcp: "1"`, additive over v1.0.`
   Mirrors the current
   [`README.md:3`](../../README.md#L3) format ("Wire version: 1.0.
   SDK version: 0.1.0") but updated for the v1.1 cut.
2. **Compatibility table.** Three columns — toolchain, OS floor, which
   targets compile. Justifies the matrix:

   | Toolchain    | Platform                  | Builds                                                |
   | ------------ | ------------------------- | ----------------------------------------------------- |
   | Swift 6.1+   | macOS 14+                 | All targets including middleware (Vapor, Hummingbird) |
   | Swift 6.1+   | Linux (Ubuntu 22.04+)     | All targets including middleware                      |
   | Swift 6.1+   | iOS 17+                   | `ARCPCore`, `ARCPClient`, `ARCP` (no server targets)  |

   Cite `Package.swift` `platforms:` line; `04-architecture.md` owns
   which targets compile where. iOS excludes the runtime targets
   because the WS server pulls SwiftNIO; iOS clients use
   `URLSessionWebSocketTask` per `03-libraries.md`.
3. **SwiftPM snippet.** Verbatim:

   ```swift
   dependencies: [
     .package(url: "https://github.com/<org>/swift-arcp.git", from: "1.0.0"),
   ],
   targets: [
     .target(name: "MyApp", dependencies: [
       .product(name: "ARCP", package: "swift-arcp"),
     ]),
   ]
   ```

   Plus a single-line variant pulling `ARCPClient` only for browser /
   embedded clients (cite `04-architecture.md` for the split rationale).
4. **Quickstart.** A compiling minimal client snippet — connect,
   submit, stream events. Body lives in
   `Samples/SubmitAndStream/Client.swift` per
   `06-examples.md`; the README inlines the 20-line core and links
   the example for the runnable form (`swift run SubmitAndStream`).
5. **Status.** One-row "What's in v1.1" table linking to
   [`CONFORMANCE.md`](../../CONFORMANCE.md):

   | Wire | Sessions | Jobs | Events | Leases | Budget | Errors | Subscribe |
   | ---- | -------- | ---- | ------ | ------ | ------ | ------ | --------- |
   | ✓    | ✓        | ✓    | ✓      | ✓      | ✓      | 15/15  | ✓         |

   Status badges are ASCII (`✓`/`✗`), not emojis. CONFORMANCE owns the
   row-level detail; this row is the headline.
6. **CLI.** Keep the existing `swift run arcp …`
   ([`README.md:55-61`](../../README.md#L55-L61)) block but rewrite to
   the v1.1 surface — `arcp serve`, `arcp send <agent> --input '…'`
   (was `<tool>`), `arcp tail`, `arcp replay <sqlite-db> <session>`
   (sqlite is opt-in per `02-current-audit.md` §2.1; rephrase as
   "with the SQLite event log enabled").
7. **Architecture diagram.** One ASCII block (the current
   [`README.md:77-103`](../../README.md#L77-L103) shape but redrawn for
   the four-target split). The richer SVG diagrams from
   `09-diagrams.md` render in `docs/`, not the README, because GitHub's
   `<picture>` element does work in READMEs but the docs site is the
   canonical render surface.
8. **Build & test.** Five-command gate
   ([`README.md:67-73`](../../README.md#L67-L73) shape preserved):

   ```bash
   swift package plugin --allow-writing-to-package-directory format-source-code
   swift package plugin lint-source-code -- --strict
   swift build -c release -Xswiftc -warnings-as-errors
   swift test --parallel --enable-code-coverage
   swift package generate-documentation --target ARCP
   ```
9. **Spec mapping.** Two links: [`CONFORMANCE.md`](../../CONFORMANCE.md)
   (row-level v1.0 + v1.1 status) and
   [`../../../spec/docs/draft-arcp-02.1.md`](../../../spec/docs/draft-arcp-02.1.md)
   (the v1.1 spec). One sentence: "Every requirement row carries a
   Swift `file:line` citation."
10. **License.** Apache 2.0; current
    [`README.md:115-117`](../../README.md#L115-L117) wording stands.

### README voice

Terse declarative. No marketing copy. No emojis. Status badges `✓`/`✗`
only. Every code block compiles when extracted (see §6 below). Reject
the following words at PR review: "leverage", "robust", "scalable",
"performant", "powerful", "modern", "elegant", "delightful",
"first-class". Sentences are short; bullets are not. Match the
monorepo voice — `agent-runtime-control-protocol/spec/docs/*.md`
is the floor for terseness.

## 4. `CONFORMANCE.md` skeleton

The Swift `CONFORMANCE.md` mirrors `typescript-sdk/CONFORMANCE.md`'s
structure verbatim (verified by reading
[`../../../typescript-sdk/CONFORMANCE.md`](../../../typescript-sdk/CONFORMANCE.md)
lines 1–80: section header per spec §, three-column table
**Requirement / Status / Location**, status values **Implemented** /
**Deferred** with rationale, intentional-deferrals table at the
bottom). The Swift edition keeps the existing file's identity —
update in place rather than rewrite, since
[`../../CONFORMANCE.md`](../../CONFORMANCE.md) already exists from the
v0.1 cut.

Layout:

```
# Conformance — ARCP v1.1 (additive over v1.0)

<one-paragraph framing identical to typescript-sdk/CONFORMANCE.md:1-6>

## §4. Transport
| Requirement | Status | Location |
| ----------- | ------ | -------- |
| §4.1 WebSocket … | Implemented | `Sources/ARCPCore/Transport/WebSocketTransport.swift:NN` |
…
## §5. Wire Format
…
## §6. Sessions          (v1.0 rows; v1.1 §6.2 features row, §6.4–§6.6 rows)
## §7. Jobs               (v1.0 rows; §7.1 lease_constraints/budget, §7.5 versions, §7.6 subscribe)
## §8. Job Events         (v1.0 rows; §8.2.1 progress, §8.4 result_chunk)
## §9. Leases             (v1.0 rows; §9.4 subsetting, §9.5 expires_at, §9.6 cost.budget)
## §10. Delegation
## §11. Trace Propagation (v1.0 rows; v1.1 attribute names)
## §12. Error Taxonomy    (12 v1.0 codes + 3 v1.1 codes; retryable flag column)
## §13. Wire JSON Schemas
## §14. Security
## §15. Vendor Extensions

## Intentional deferrals
| Item | Reason |
| ---- | ------ |
```

Row format (matches
[`../../../typescript-sdk/CONFORMANCE.md:17`](../../../typescript-sdk/CONFORMANCE.md#L17)):

```
| §4.1 WebSocket MUST be supported | Implemented | Sources/ARCPCore/Transport/WebSocketTransport.swift:42 |
```

### Generated vs manual

The status column is generated from the conformance harness in
`07-tests.md` (test name → spec §); a script
(`scripts/update-conformance.swift` or a Swift Argument Parser
executable under `Tools/`) parses `swift test --list-tests` output,
maps the suite/case names to requirement rows, and rewrites the
status column in-place. The requirement column and `file:line`
citations are hand-maintained — citations break on refactor and need
a human to update them. This split mirrors TS, which generates
status from `vitest` test names. The script runs as a build-gate
step in the synthesis milestone owning conformance harness wire-up.

### Intentional deferrals

Same shape as TS:

| Item                          | Reason                                                                                          |
| ----------------------------- | ----------------------------------------------------------------------------------------------- |
| mTLS / OAuth2 auth            | v1.1 conformance requires only bearer; mTLS is `04-architecture.md` future work                 |
| Sidecar binary stream frames  | §4.1 mandates JSON text frames; binary deferred to v1.2                                         |
| Scheduled jobs                | Out of v1.1 scope per spec abstract                                                             |
| Job pause/unpause             | Out of v1.1 scope per spec abstract                                                             |
| Federation across runtimes    | Out of v1.1 scope per spec abstract                                                             |
| Streaming-token LLM surface   | Out of v1.1 scope per spec abstract                                                             |

(Carried forward from
[`01-spec-delta.md`](01-spec-delta.md) §5.)

## 5. `CHANGELOG.md` guidance

Keep a Changelog 1.1 format (matches
[`../../../typescript-sdk/CHANGELOG.md:5`](../../../typescript-sdk/CHANGELOG.md#L5)).
The v1.1.0 release entry:

```markdown
## [1.1.0] - YYYY-MM-DD

### Added
- Capability negotiation `features: [String]` (§6.2) and the
  `Feature` enum mapping wire names to Swift cases.
- Heartbeat (§6.4): `session.ping` / `session.pong` over a
  `ContinuousClock` interval.
- Ack (§6.5): `session.ack { last_processed_seq }` with client-side
  auto-ack coalescing.
- `list_jobs` (§6.6) with filter + opaque cursor.
- Subscribe (§7.6): `job.subscribe` / `JobSubscription` (no cancel
  authority).
- Lease `expires_at` constraint (§7.1, §9.5) with `LEASE_EXPIRED`
  semantics on `ContinuousClock`.
- Budget (§7.1, §9.6): per-currency `Decimal` counters with
  `BUDGET_EXHAUSTED`.
- Agent versioning (§7.5): `name@version` grammar +
  `AGENT_VERSION_NOT_AVAILABLE`.
- Progress event kind (§8.2.1) with `{current, total?, units?,
  message?}` body.
- Result chunk streaming (§8.4) with `encoding ∈ {utf8, base64}` and
  the 1 MiB / 256 MiB caps from spec §14.
- Three new `ARCPError` cases:
  `leaseExpired(at:)`, `budgetExhausted(currency:attempted:)`,
  `agentVersionNotAvailable(name:version:available:)`.
- OTel tracing seam (`ARCPOTel`) with `arcp.lease.expires_at` and
  `arcp.budget.remaining` span attributes (§11).

### Changed
- Wire surface rebuilt from `draft-arcp-01.md` lineage to ARCP v1.1
  (additive over v1.0). See [`02-current-audit.md`](planning/v1.1/02-current-audit.md)
  §0 — 47/53 prior message types replaced or removed; `event_seq`
  added to the envelope; two-step `session.hello`/`session.welcome`
  handshake replaces the prior four-step model.
- `ErrorCode` (gRPC-style) replaced by closed `ARCPError` enum with
  associated values (12 v1.0 + 3 v1.1 codes).
- `Decimal` (not `Double`) for all budget amounts.

### Deprecated
_(none)_

### Removed
- Four-step session handshake (`session.open` /
  `session.challenge` / `session.authenticate` / `session.accepted`).
- Lease-per-permission model (`LeaseManager`) replaced by
  immutable per-job leases.
- Generic firehose subscriptions (`SubscriptionManager`) replaced by
  per-job `JobSubscription`.
- Out-of-spec envelope fields (`source`, `target`, `stream_id`,
  `subscription_id`, `span_id`, `parent_span_id`, `correlation_id`,
  `causation_id`, `idempotency_key`, `priority`, `extensions`).
- JWT auth from default build (moved to `ARCPAuthJWT` opt-in target).

### Fixed
_(populated at release time from bug-fix PR titles)_

### Security
- §9.5 lease expiry evaluated on `ContinuousClock`, not `Date` —
  wall-clock NTP jumps no longer extend lease validity (cite
  spec §14 "monotonic, NTP-disciplined clock").
- Chunk caps enforced at 1 MiB per chunk / 256 MiB total per result
  to bound peer-induced memory pressure.
```

Section guidance:

- Heading format: `## [1.1.0] - YYYY-MM-DD` (Keep a Changelog 1.1).
  No `v` prefix on versions inside square brackets.
- Section order is fixed: **Added**, **Changed**, **Deprecated**,
  **Removed**, **Fixed**, **Security**. Empty sections are omitted at
  release time; the template above shows `_(none)_` only for
  illustrative completeness.
- One bullet per shipped change. Cite spec § inline. Link to PRs in
  the synthesis cut; this template predates the PR numbers.

The v1.1 entry's framing line — "Wire surface rebuilt from
`draft-arcp-01.md` lineage to ARCP v1.1 (additive over v1.0)" — is the
audit headline finding ([`02-current-audit.md`](02-current-audit.md)
§0). The CHANGELOG explicitly admits this so consumers do not read
"1.1.0" as a small minor bump.

## 6. Anti-slop voice rules

Apply to every doc author (DocC symbol docs, `docs/*.md`, README,
CONFORMANCE, CHANGELOG):

1. **No marketing copy.** Reject "revolutionizes", "best-in-class",
   "industry-leading", "seamlessly", "effortlessly", "blazing fast",
   "unlock", "supercharge". Reviewers send the PR back.
2. **No emojis.** Status badges `✓` / `✗` only. The existing
   [`../../README.md`](../../README.md) uses `✅` — this is the one
   intentional exception to be cleaned up in the v1.1 README rewrite
   (replace with `✓`).
3. **Every code block compiles.** Future-task call-out: a CI step
   extracts fenced ``` ```swift ``` blocks from `docs/*.md` and the
   README, splices each into a per-block executable under a generated
   `.build/docs-snippets/` SwiftPM target, runs `swift build` against
   it, and fails on any warning. Tooling sketch:
   `Tools/extract-snippets/main.swift` walks the Markdown AST (use the
   stdlib's `Foundation.NSRegularExpression` — no extra dep) and emits
   `Snippet001.swift` etc. with the surrounding imports inferred from
   a fenced `// imports:` directive. This is a Phase-7-or-later task;
   the v1.1 release ships docs reviewed for compilation by hand, with
   the CI gate landing in 1.1.1.
4. **Match monorepo voice.** Reference for tone: the spec itself
   (`../../../spec/docs/draft-arcp-02.1.md`) and
   [`../../../typescript-sdk/docs/getting-started.md:1-13`](../../../typescript-sdk/docs/getting-started.md#L1-L13)
   ("Five minutes, zero infrastructure. By the end you'll have a job
   that streams events back…"). Imperative, sized to the reader's
   patience, no scaffolding sentences. Do not echo the heading in the
   first sentence; assume the reader sees both.
5. **Cite or it didn't happen.** Every prose claim in `docs/` cites
   either a spec §, a Swift `file:line`, a SwiftPM dep, or a Swift
   language feature (`Sendable`, `AsyncSequence`, `ContinuousClock`,
   `Decimal`). Reviewers reject uncited claims.
6. **Banned in this plan and in docs:** "leverage", "robust",
   "scalable", "performant", "powerful", "modern", "elegant",
   "delightful", "first-class".
