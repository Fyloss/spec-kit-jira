# Contract: Artifact publication (sink-internal)

**Feature**: `036-attach-feature-artifacts` | **Scope**: `sink/jira/` only —
no `engine/` script may reference any endpoint or identifier below
(Constitution VIII, grep-enforced).

Extends `specs/001-jira-reconcile-engine/contracts/jira-cloud-endpoints.md`.
Base and auth are unchanged: `https://<site>/rest/api/3`, `Authorization: Basic`
carried off argv (Bash `curl --config` on stdin; PowerShell in-process header).

---

## C1. Endpoints

| # | Purpose | Method + Path | Notes |
|---|---------|---------------|-------|
| C1.1 | Upload limit | `GET /attachment/meta` | `{ "enabled": bool, "uploadLimit": int }`. Read **once per run**, and only when there is something to publish. `enabled: false` ⇒ whole publication withheld, one warning, no upload attempted. |
| C1.2 | Read manifest | `GET /issue/{key}/properties/spec-kit-jira-artifacts` | `404` ⇒ no manifest ⇒ every artifact is a first publication. Not a fail-closed condition. |
| C1.3 | Read attachment list | `GET /issue/{key}?fields=attachment` | Only to honour the trust rule (C4.3). |
| C1.4 | Upload | `POST /issue/{key}/attachments` | `multipart/form-data`; **one request for the whole run**; header `X-Atlassian-Token: no-check`; one `file` part per artifact, each with an explicit part filename. Response: JSON array of attachment objects, part order. |
| C1.5 | Comment | `POST /issue/{key}/comment` | ADF body per `comment-body.md`. **One request per run.** |
| C1.6 | Write manifest | `PUT /issue/{key}/properties/spec-kit-jira-artifacts` | Issued **only** when at least one artifact landed. |

**Call budget per run**, stated precisely because a test written to a loose
version of it fails correct code:

| Run shape | Calls |
|-----------|-------|
| Run-state short-circuits (no input changed at all) | **0** — publication is never reached |
| Run proceeds, every artifact classifies `unchanged` | **1** — the manifest read (C1.2) and nothing else. Reads are not writes: FR-009's floor is zero *writes*, and this row is what it means in practice. Reachable whenever a non-artifact input changed — base URL, email, hook event, extension version |
| Run proceeds, at least one artifact publishes | at most 1 × C1.1 + 1 × C1.2 + 1 × C1.4 + 1 × C1.5 + 1 × C1.6, plus C1.3 only when the manifest and the ticket disagree |

**Never a call per artifact**, in any row.

---

## C2. The upload request

### C2.1 Bash port

The transport writes its `curl` config to stdin as it does today, plus:

```
header = "X-Atlassian-Token: no-check"
form = "file=@<curl-path>;filename=<attachment_name>"
form = "file=@<curl-path>;filename=<attachment_name>"
```

- `<curl-path>` is the absolute on-disk path through `_jira_curl_path`
  (`cygpath -m` on MSYS, verbatim elsewhere). **Never a bare POSIX path** —
  see the measured `posix=26 win=26 mixed=7` note in `client.sh`.
- `<attachment_name>` is the flattened name; without the explicit `filename=`,
  curl derives it from the basename and nested artifacts collide.
- One `form =` line per artifact. The config is on **stdin**, so this list is
  not subject to any command-line length cap (`docs/11-process-budget.md`).
- `Content-Type` is **not** set by us; curl composes the multipart boundary.

### C2.2 PowerShell port

`Invoke-JiraRequest` gains `-FormParts <object[]>`. When supplied:

- `ContentType` is **not** set (`Invoke-WebRequest` computes the boundary);
  setting both is an error.
- `X-Atlassian-Token: no-check` is added to the header table.
- Each part carries an explicit filename equal to `attachment_name` — a
  `FileInfo` contributes its own basename by default, which reintroduces the
  collision the flattening exists to prevent.

### C2.3 Cross-port invariant

For the same artifact set, both ports MUST produce the same **ordered** part
list — sorted by `path`, byte-wise — and therefore the same response order.
The conformance corpus asserts the recorded call sequence and the recorded
part filenames, not just the status codes.

---

## C3. Outcome mapping

| Condition | Behaviour | Exit code |
|-----------|-----------|-----------|
| C3.1 Upload 2xx | Attachments created; manifest updated with returned ids. | 0 |
| C3.2 Upload `403` | **Withheld.** One warning naming the ticket and the missing capability, with the remedy. The reconcile's earlier writes stand; the run's exit code is unchanged. | unchanged |
| C3.3 Upload `413` / limit rejection | Withheld, warning names the artifact set size and the discovered limit. | unchanged |
| C3.4 Upload 5xx / network / 429-exhausted | Withheld, one warning. Manifest **not** written. Next run retries. | unchanged |
| C3.5 Comment write fails | Attachments already landed; manifest **is** written (they are published), and one warning says the announcement did not post. | unchanged |
| C3.6 Manifest write fails after a successful upload | One warning. The next run re-derives from C1.3 and does not duplicate — this is the trust rule earning its place. | unchanged |
| C3.7 `attachment/meta` unreachable | Whole publication withheld, one warning. No upload is attempted without a known limit. | unchanged |
| C3.8 Privacy guard BLOCK on any artifact | **Zero writes for the entire run**, including the reconcile's own — achievable only because the scan sits at the pre-write sweep, never in the publication phase (C5.1). Message names the artifact and the shape; never the value. | `9` (privacy) |
| C3.9 `enabled: false` | Whole publication withheld, one warning naming the site setting. | unchanged |

**C3.2 is the load-bearing row.** The shared transport maps `401/403` to
`auth` (exit 3) for every caller. Propagating that here would fail **every
reconcile** for any team whose token lacks "Create attachments", the moment they
upgrade. The publication call site MUST inspect the transport result and
translate; a test asserts the run's exit code is unchanged by a `403` on C1.4.
The precedent is the task tier being withheld on unmet mandatory fields
(`sink/jira/hierarchy.sh`).

`401` does not appear above: an invalid credential fails at recognition, before
publication is reached.

---

## C4. Decision rules

### C4.1 Per-artifact classification

For each entry of the sorted artifact set, against the manifest:

| Manifest state | Classification | Write |
|----------------|----------------|-------|
| path absent | `published` (first publication) | upload |
| `hash` differs | `revised` | upload |
| `hash` matches, `attachment_id` present on the ticket | `unchanged` | none |
| `hash` matches, `attachment_id` absent from the ticket | `published` | upload (trust rule) |

### C4.2 Withholding precedence

Evaluated in this order, first match wins, so a run's warnings are deterministic
across ports: **name-collision** → **oversized** → **site-disabled**. A withheld
artifact is reported and excluded from the upload; it never reaches the manifest.

### C4.3 The trust rule

`GET /issue/{key}?fields=attachment` (C1.3) is issued **only** when the manifest
claims at least one `attachment_id` and the run is about to conclude
`unchanged` for it. Its purpose is to catch the interrupted-run states:

- property written, upload never landed → republish;
- upload landed, property never written → the manifest is missing the entry, so
  C4.1 already republishes; the duplicate is accepted (Principle I forbids
  removing the first copy) and the comment marks it a revision.

### C4.4 The manifest has a bound, and a behaviour at the bound

The manifest is bounded by artifact count, not run count — but "bounded" is not
"small enough". An entity-property value has a site-enforced size cap (assumed
32 KB, *unverified* — research §R15 item 4), which at roughly 110 bytes per entry
is reached somewhere near **290 artifacts**. A feature directory that large is
unusual and not impossible.

Without a rule, the failure is silent and permanent: the property write fails,
C3.6 degrades it to a warning, and **every subsequent run republishes every
artifact** — a Principle II violation that no test would catch, in the only
repositories big enough to hit it.

The rule:

| # | Condition | Behaviour |
|---|-----------|-----------|
| C4.4.1 | The composed manifest would exceed the cap | The publication is **withheld before any upload**, with one warning naming the artifact count, the composed size and the cap, and stating that the feature directory holds more artifacts than one ticket can track. Zero writes of every kind. |
| C4.4.2 | A manifest write is rejected by the site for size, despite C4.4.1 | Treated as C3.6 — one warning — **plus** the warning names size as the cause, so the operator is not left with a generic "the record did not save". |

C4.4.1 fails closed rather than publishing what fits: a partial manifest would
make the next run republish exactly the artifacts the previous one dropped,
forever, which is worse than not starting.

The cap is **discovered where possible and otherwise assumed conservatively** —
it is a site fact, and Principle VII forbids baking one in as though it were
universal. Until §R15 item 4 is answered by the dogfood run, the assumed value is
documented as an assumption in the code, not as a constant that looks measured.

### C4.5 Zero-churn floor

When every artifact classifies `unchanged`, the run issues **C1.4, C1.5 and C1.6
zero times**. This is the assertion Principle II's enforcement test requires,
and the live idempotency suite's exhaustive write-kind list MUST gain
`attached` and `commented` in the same change that adds them to the sink.

---

## C5. Privacy guard placement — the artifact scan joins the EXISTING pre-write sweep

**C5.1 — Where.** The artifact scan runs at the reconcile's existing **pre-write
privacy sweep**, the single point that already covers every payload of the run
before any of them is written (`commands/reconcile.sh`, the sweep documented
there as "the pre-write privacy sweep must cover every payload of the run before
any of them is written — never a second call"). It is **not** a second sweep, and
it is **not** in the publication phase.

This placement is load-bearing, not stylistic. Publication runs after the
description and story writes; a guard sitting there could abort the *upload*, but
the reconcile's own writes would already have landed, and FR-016 with C3.8
require **zero writes for the entire run** — the reconcile's included. A scan at
the publication phase cannot deliver that. The artifact set is a pure function of
the filesystem and is available long before any write, so there is no reason for
the scan to wait.

**C5.2 — What.** Every artifact's bytes, binary included, with no text/binary
special case (research R12).

**C5.3 — Outcome.** A BLOCK finding aborts the whole run before any write, on the
documented exit code (C3.8). WARN findings are surfaced and gate nothing.

**C5.4 — Cost.** One pass over the set, folded into the sweep that already runs.
It MUST NOT spawn a process per artifact, and MUST NOT add a second traversal of
the artifact content.

**C5.5 — Test.** The assertion is not "a BLOCK aborts the upload" but "a BLOCK
leaves the ticket untouched": with a BLOCK-tier coordinate in `research.md`, the
run issues **zero** calls of every write kind — no create, no update, no
transition, no attachment, no comment, no property — verifiable on the mock call
log alone.

---

## C6. What this contract does not do

- No `media` node in the comment ADF; no media-services API. Artifacts are
  reached through the ticket's attachment panel (research R8).
- No `DELETE /attachment/{id}` anywhere, in any mode, including the guarded
  re-mode. Principle I, FR-014.
- No publication onto story-tier or task-tier tickets. FR-003.
