# Phase 0 research — reconcile performance

Ten decisions. R2, R3, and R4 are the ones that shape everything else: the batched read has to avoid the
search index, the credential cache has to survive command substitution, and neither may cost anything on
a run that does nothing.

Every measurement claim in the feature request is treated as a hypothesis. R10 says how each one is
confirmed before the optimisation it justifies is built.

---

## R1 — The clock: `EPOCHREALTIME` first, `date +%s%N` second, whole seconds last

**Decision**: `lib/timing.sh` resolves one clock strategy at load time and caches it in a variable.

1. `EPOCHREALTIME` is set (Bash ≥ 5): parse `seconds.microseconds` with shell parameter expansion.
   **No fork at all**, which matters because the timing mode must not distort what it measures.
2. Otherwise, probe `date +%s%N` once. If the result is all digits, use it (GNU coreutils `date`).
3. Otherwise, fall back to `date +%s` × 1000 and set a degraded flag. The report then prints durations
   as whole seconds and carries one line saying the host has no sub-second clock.

PowerShell uses `[datetime]::UtcNow.Ticks / 10000`, which is always available and never forks.

**Rationale**: the declared minimum is Bash 4, so `EPOCHREALTIME` cannot be assumed — but it is present
on every host this project realistically runs on (macOS operators must install a qualifying Bash, and
Homebrew ships 5.x; current git-bash ships 5.x; every supported Linux ships 5.x). Tier 1 therefore
covers reality while tiers 2 and 3 keep the declared minimum honest. BSD `date` on macOS prints a
literal `N` for `%N`, which is why tier 2 is a probe and not an assumption.

Degrading loudly rather than silently is the point of the third tier: a report that shows `0 ms` for
every phase on a Bash 4.4 host would be a worse outcome than one that says it cannot measure that finely.

**Alternatives rejected**:

- *`SECONDS`* — integer only, and it cannot express the sub-second budget SC-001 is written in.
- *`printf '%(%s)T'`* (Bash 4.2+) — whole seconds, same problem.
- *Requiring Bash 5* — a change to the declared minimum in Principle VI, for a diagnostic feature. Out
  of proportion.
- *`perl -MTime::HiRes`* — a new runtime dependency, forbidden by C-5.

---

## R2 — The batched read is `POST /issue/bulkfetch`, and it is a fetch, not a search

**Decision**: recognition prefetches with `POST /rest/api/3/issue/bulkfetch`, body
`{"issueIdsOrKeys": [...], "fields": [...], "properties": ["spec-kit-jira"]}`, chunked at **100 keys**.

**Rationale**: this is the decision the feature request got wrong, and confirming it took reading the
published API contract rather than reasoning from the endpoint's name.

Feature 005's research (R2, R3) rejected batching outright, and it was right about the mechanism it
considered: "bulk `key IN (…)` search — same index dependency, same lag. Rejected." Jira's search index
is eventually consistent, the reported defect happened between two lifecycle commands seconds apart, and
a search-based recognition returns nothing for a ticket created moments earlier, so the bridge re-creates
it. `sink/jira/recognition.sh:5` still carries that reasoning in its header comment.

`bulkfetch` is not a search. Confirmed against the published OpenAPI document
(`developer.atlassian.com/cloud/jira/platform/swagger-v3.v3.json`, retrieved 2026-08-07):

> Returns the details for a set of requested issues. You can request up to 100 issues. Each issue is
> identified by its ID or key … Issues will be returned in ascending `id` order.

It is addressed by identifier, exactly as `GET /issue/{key}` is, with no JQL and no index on the path.
The immediate-consistency property that made per-key reads mandatory is preserved. Spec FR-016 is
therefore satisfiable, and the wording it was given — "immediately consistent for a ticket created
seconds earlier", not "use JQL" — is what makes this substitution legitimate rather than a quiet
reinterpretation.

Two properties of the endpoint decided the shape of R4 below:

- `properties` accepts up to 5 issue-property keys. We need exactly one, so the identity marker still
  folds into the same request — the very thing feature 005's R3 valued about the per-key `GET`.
- `fields` defaults to `*navigable` here, whereas `GET /issue/{key}` defaults to all fields. The
  prefetch therefore always sends an **explicit** field list. Relying on a default that differs between
  the two endpoints is exactly how a field would silently go missing.

**Alternatives rejected**:

- *JQL `key in (…)`*, as the request literally specified — the index dependency above. It would
  reintroduce, in the read phase, the duplicate-ticket defect features 005 and 017 each fixed once.
- *A `/search` call filtered on the identity property* — feature 005 established that a user-authenticated
  script cannot make entity properties searchable without shipping a Connect/Forge descriptor.
- *Keeping N per-key reads and relying on connection reuse alone* — this is the documented fallback if
  `bulkfetch` proves unavailable on a target instance (spec A-1). It meets SC-002 but not SC-003.
- *`GET /issue/bulkfetch`* — no such shape; the endpoint is a POST with a JSON body, which also keeps a
  long key list off the URL.

---

## R3 — The credential cache must be primed in the parent shell, because most callers are subshells

**Decision**: `cred_resolve_token` caches into a **non-exported** shell variable and returns it on
subsequent calls. A new `cred_prime_cache` is invoked **once, in the main shell**, immediately before the
first phase that issues requests. The PowerShell twin uses a `$script:`-scoped variable in
`Credentials.psm1` and needs no priming.

**Rationale**: this is the finding that makes or breaks the credential workstream (FR-007…FR-014), and it is
invisible until you read the call
sites. `jira_request` is invoked through command substitution at most of them —
`discovery.sh` (13 sites), `ticket.sh`, `duplicate_probe.sh` all do `resp="$(jira_request …)"`. A cache
filled inside such a call is filled inside a subshell and dies when it closes. Caching alone would leave
the secret store queried once per request, exactly as today, and every test that counted only total
invocations across a single code path would pass while SC-004 quietly failed.

A subshell inherits **all** of its parent's shell variables, exported or not. So a value written in the
main shell before the subshell is spawned is visible inside it. Priming in the parent is therefore both
necessary and sufficient, and it keeps the variable non-exported — nothing reaches a child *process*'s
environment, which is what Principle IV actually forbids.

Priming lazily rather than at startup preserves an existing property that matters more than it looks:
a run that makes no request — a disabled hook, an unbound repository, and now a run-state short-circuit —
consults the secret store **zero** times today. Eager priming at startup would make the fastest path pay
a Keychain unlock, which is both wrong in principle and a real threat to the 1-second budget.

Cache-on-miss is kept as well as priming. It is what makes the invariant hold if some future path issues
a request before the prime point: correctness never depends on the prime, only the ≤1 guarantee does.

A failed resolution is cached too (FR-013), as a distinct "resolved to nothing" state rather than an
empty string, so a token-less run consults its sources once and then reproduces today's exit code and
message on every subsequent call.

**Alternatives rejected**:

- *Exporting the token* so children inherit it — a direct Principle IV violation. It is the single thing
  the whole credential design exists to prevent.
- *A file-backed cache* — FR-010 forbids writing the token to any file, and it would make the bridge a
  persistent store for a secret, which C-1 forbids.
- *Refactoring every `$(jira_request …)` call site to avoid subshells* — a large, risky change to code
  this feature is not otherwise touching, for no benefit the prime does not already deliver.
- *A coprocess or file descriptor holding the token* — machinery in exchange for nothing; a variable set
  before the fork already works.

---

## R4 — The prefetch is a map in front of an unchanged reader, never a replacement for it

**Decision**: `sink/jira/prefetch.sh` exposes `prefetch_load <key>…` and `prefetch_get <key>`.
`_recognition_read` and `_recognition_read_parent` consult the map first and, on a miss, execute exactly
today's `GET`. A cache hit is projected down to the caller's own field list before it is returned.

**Rationale**: `bulkfetch` cannot express two of the outcomes recognition depends on. Its documentation
is explicit:

> Issues which aren't found or that the user doesn't have permission to view won't be returned in this
> list [`issueErrors`].

So a deleted ticket and an invisible ticket are indistinguishable in a `bulkfetch` response — both are
simply absent. Today those are a 404 (classified "gone", the ticket is re-created) and a 403 (auth
failure, the whole specification fails closed). Collapsing them would be a fail-closed regression in one
direction and a duplicate-ticket regression in the other.

The fall-through resolves this without a special case: a key absent from the prefetch is read
individually, and the existing code produces the existing classification from the existing status code.
Spec FR-017's clause — "the ambiguous keys alone MUST be re-read individually" — is satisfied not by new
logic but by *not removing* the old path. In the healthy steady state every key is present, so the extra
reads are zero; in an abnormal state the cost returns to today's, which is the correct place for it.

Three consequences follow, and each is a test:

- **Prefetch failure is not run failure.** Any non-2xx from `bulkfetch` empties the map and the phase
  proceeds at today's speed and today's semantics. It must not consume the fail-closed budget, because
  the authoritative read has not happened yet.
- **Field projection is mandatory.** The two readers want different field sets — the story read wants
  `summary,description,priority,status,issuelinks,parent,labels` plus `subtasks`, the parent read wants
  only `summary,description,labels`. The prefetch requests the union and each hit is projected to the
  caller's list, so the bytes handed downstream are identical to an unprefetched read.
- **Match by key, not by position.** `bulkfetch` resolves moved and case-differing identifiers to the
  issue they now name, and returns results in ascending id order — never in request order. Results are
  matched back to requested keys by comparing the returned `key`, case-insensitively; anything unmatched
  falls through to an individual read.

**Alternatives rejected**:

- *Replacing the per-key reader outright* — loses the 404/403 distinction, as above.
- *Inferring "gone" from absence* — silently converts an invisible ticket into a re-created duplicate.
  This is the single worst outcome available in this feature and the reason the fall-through is not
  optional.
- *Two prefetches, one per field set* — the parent is one key; batching it saves one request and costs a
  second endpoint call. The union plus projection is cheaper and has one code path.
- *Prefetching inside `recognition_run`* — the parent read happens in a different function and an earlier
  phase. Priming from the command layer, where the full key list is known, covers both.

---

## R5 — The request counter is a plain global in the client, incremented per attempt

**Decision**: `client.sh` increments `JIRA_REQUEST_COUNT` once per curl attempt — retries included — and
`lib/timing.sh` samples it at each phase boundary. The variable is **not** exported.

**Rationale**: counting attempts rather than logical requests is the honest number: a 429 retried twice
costs three round trips, and a timing report that hid that would mislead precisely when it is most
needed. `JIRA_LAST_STATUS` sets the precedent for a client-owned global that callers read.

The subshell problem of R3 applies here in reverse and is deliberately accepted: an increment inside
`resp="$(jira_request …)"` is lost to the parent. That undercount is confined to `discovery.sh`,
`ticket.sh`, and `duplicate_probe.sh` — the config-ceremony and mention paths — and never touches the
recognition or apply phases, which use `> "${tmpfile}"` redirects and therefore run in the parent. The
phases whose counts the success criteria are written about are counted exactly.

This is a limitation with a documented boundary, not a bug to hide: `contracts/timing-report.md` states
which phases carry exact counts. The authoritative count for tests is not this variable at all — it is
`calls.log`, which the conformance mock writes per request and which no subshell can lose.

**Alternatives rejected**:

- *A counter file appended to per request* — subshell-proof, but it adds file I/O to the hot path and a
  temp file to clean up, to fix an undercount in phases nobody is measuring.
- *Exporting the counter* — an exported variable cannot be written back by a child either. It would
  change nothing and add an environment entry.
- *Counting in the timing module via a wrapper around `jira_request`* — the wrapper would sit in the same
  subshell as the call it wraps. Same loss, more indirection.

---

## R6 — Connection reuse comes from one curl per phase, not from a rewritten transport

**Decision**: keep one `curl` invocation per request. Add `--keepalive-time` and rely on the existing
config-on-stdin shape; where a phase issues several **independent reads**, chain them into a single curl
invocation with `--next`, writing each response to its own `--output` file.

**Rationale**: `--next` chaining is the only mechanism that reuses a TCP+TLS connection without changing
what the caller sees, because it stays one process writing to files the caller already reads. Both the
recognition fall-through reads and the completion-pass transition lookups are independent reads of this
shape.

The write path is explicitly excluded. Its ordering is load-bearing — the parent must exist before a
child can carry its key — and C-1/spec FR-030 make ordering win over parallelism without argument. After
the prefetch of R4 lands, the read phase issues one or two requests in the healthy case anyway, so
chaining is a fallback-path optimisation and is scheduled last.

**Alternatives rejected**:

- *`curl --parallel`* — reorders completions, which would make `calls.log` non-deterministic and break
  the corpus's cross-port diff. Determinism is worth more here than the milliseconds.
- *`xargs -P`* — same non-determinism, plus each worker is a fresh curl with a fresh handshake, which is
  the cost being removed.
- *A persistent curl daemon or a keep-alive proxy* — a new process model for a script bridge. Rejected
  under Principle XIV without further argument.
- *Rewriting the transport around a single long-lived connection* — the change with the highest chance of
  breaking the credential discipline, for a saving the prefetch already captures.

---

## R7 — The run-state digest is `git hash-object`, and the state file is the manifest itself

**Decision**: each input is hashed with `git hash-object --no-filters <path>`. The resulting
`input → hash` pairs are assembled into a canonical JSON document and written to
`.specify/jira/state/<feature-dir>.json`. Comparison is byte equality of the freshly computed document
against the recorded one. **There is no second hash of the manifest.**

**Rationale**: `git` is already a declared, enforced prerequisite of the Bash port, and `git hash-object`
is the only content hash guaranteed present and identical on all three hosts — `sha256sum` is absent on
macOS, `shasum` is absent from some minimal Linux images, and `Get-FileHash` produces a different digest
from either. Verified locally: `git hash-object --no-filters` and `git hash-object --stdin` agree, and
both work outside a repository.

Storing the manifest instead of a digest of the manifest removes a step and buys two things. Comparison
becomes ordinary equality on a document the canonical serialiser already guarantees is byte-identical
across ports. And the file answers "why did it not skip?" by inspection — Principle XVI applied to a
machine artefact, which is where it is usually forgotten.

The manifest records the **extension version** from `extension.yml`. This is not bookkeeping: a bridge
upgrade changes rendered output for unchanged inputs — feature 020's closing marker is exactly that — so
a state file that survived an upgrade would suppress the upgrade until someone happened to edit a spec.
A hand-maintained schema integer was considered and rejected: it works only if every author remembers to
bump it in the PR that changes rendering, and nothing enforces that.

**Alternatives rejected**:

- *`sha256sum` / `shasum` / `Get-FileHash`* — not uniformly present, and not mutually byte-identical.
- *Hashing the derived effective configuration* — requires the config phase to have run, which is most of
  what the short-circuit is trying to skip. Hashing the config **files** is stricter and cheaper.
- *File modification times* — a checkout, a rebase, or a `touch` invalidates them; content is what
  matters.
- *One shared state file keyed by spec path* — concurrent runs on different specs would lose each other's
  entries, and spelling a path safely as a filename is a Windows hazard. The feature directory name is
  already a safe slug, and feature 017's target guard means reconcile only ever addresses
  `<feature-dir>/spec.md`.

---

## R8 — The short-circuit sits after the guards, writes on success only, and never meets `--dry-run`

**Decision**: the state phase is evaluated after the dispatch guard and the target guard and before the
config phase. The state file is written only by a real run that applied every planned action with no
warning and no pending confirmation. `--dry-run` neither reads nor writes it. `--force` skips the read
and still writes on success.

**Rationale**: placing the gate after the guards preserves two behaviours exactly — a disabled event
still exits silently with no config read, and a rejected target still exits 1 with zero requests. Placing
it before the config phase is what makes SC-001 reachable at all, since config resolution is a
meaningful part of the second.

`--dry-run` must not consume the state, or a preview run over an unchanged spec would print "nothing to
do" for a reason the real run does not share, and Principle XI's "the preview predicts exactly the real
run" would be false. It must not write the state either, since it applied nothing.

The write-then-`mv` gives atomicity on POSIX and on NTFS for a same-directory rename. Two racing hooks
can therefore each read a whole document or none, never half of one; the loser's write is simply
overwritten by an equally valid document.

**Alternatives rejected**:

- *An expiring state (skip only within N minutes of the last full run)* — genuinely attractive: it would
  collapse a burst of lifecycle hooks while restoring Principle X's self-healing on a longer horizon. It
  is rejected here for one reason and recorded so it is not lost: it introduces a duration nobody can
  choose correctly, and the spec's Out of Scope names it as the natural follow-up if out-of-band drift
  proves to bite in practice.
- *A lock file around the whole reconcile* — turns a race into a hang inside a lifecycle hook.
- *Recording state after a partially successful run, with a "partial" flag* — every consumer of that flag
  would have to reason about which subset was applied. Recording nothing is both simpler and correct.

---

## R9 — De-forking the hot loops means one `jq` per item, not one per field

**Decision**: in the per-story and per-task loops, replace the sequence of single-field `jq` reads with
one `jq` per item emitting a tab-separated record, consumed by a single `read` into shell variables.

**Rationale**: `commands/reconcile.sh` holds ~192 `jq` invocations across 18 loops. The dominant pattern
is several consecutive extractions from the *same* JSON value — `jq -r '.state'`, then `jq -c '.marker'`,
then `jq -r '.gone'` — each a fork and an exec, each re-parsing the same document. One `jq -r '[…] |
@tsv'` per item collapses them with no change to the values produced.

`@tsv` is chosen over `@csv` or a newline-delimited list because the fields carried here — issue keys,
identifiers, state tokens — cannot contain a tab, while summaries and descriptions (which can contain
anything) are **not** part of this refactor: they stay in JSON and never round-trip through a shell
variable. That boundary is the safety property, and it is what makes the change provable by the corpus
rather than merely plausible.

This is the lowest-value and highest-risk item in the feature, so it is scheduled last and applied one
loop at a time, each with the corpus green before the next.

**Alternatives rejected**:

- *One `jq` for the whole loop, emitting every item at once* — needs the whole collection in memory as
  shell state and rewrites the loop's control flow. A larger change for a marginal further saving.
- *Replacing `jq` with shell string parsing* — parsing JSON in Bash is how the CRLF and escaping defects
  in this project's history began.
- *A long-lived `jq` coprocess* — a new process model, and a deadlock surface, for a script bridge.

---

## R10 — Every measurement in the request is a hypothesis until the timing mode prints it

**Decision**: `lib/timing.sh` and its conformance scenario land **first**. Each subsequent optimisation
is admitted only when the instrument shows the cost it claims to remove, and each carries a
before/after number recorded in `tasks.md`.

**Rationale**: spec A-3 requires it, and the numbers in the feature request are plausible enough to be
dangerous. Three are worth stating as open:

- *"~50–200 ms per `security find-generic-password`"* — decides whether R3 is the largest win or a
  rounding error. Measured directly by the timing report with and without the prime.
- *"30–80 sequential requests at 0.5–1.5 s each"* — the request-count half is measured exactly by
  `calls.log`; the per-request latency half is the part R6 addresses and is the weakest claim.
- *"~1,141 jq call sites … thousands of fork+exec per run"* — call *sites* are not call *counts*. The
  loops of R9 are what matter, and only the instrument can say whether they cost enough to justify the
  risk. If they do not, R9 is dropped rather than performed for tidiness.

**Alternatives rejected**:

- *Implementing the optimisations first and measuring afterwards* — the ordering the request explicitly
  forbids, and the reason it does is that an unmeasured optimisation is indistinguishable from a
  refactor with a story about it.
