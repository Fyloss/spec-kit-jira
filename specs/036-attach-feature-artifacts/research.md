# Phase 0 — Research: Publish every feature artifact on the specification ticket

**Feature**: `036-attach-feature-artifacts` | **Date**: 2026-08-31

Each item records the decision, why it was taken, and what was rejected. Items
whose evidence is **the running code of this repository** are marked *measured*;
items resting on Jira Cloud API behaviour we have not exercised here are marked
*unverified* and are collected again in §R15, because a mock we write ourselves
cannot falsify them.

---

## R1. How an artifact reaches Jira

**Decision**: `POST /rest/api/3/issue/{issueIdOrKey}/attachments`, a
`multipart/form-data` request carrying one `file` part per artifact, with the
header `X-Atlassian-Token: no-check`. **All artifacts of a run travel in ONE
request**; the response is a JSON array of the attachment objects created, in
part order.

**Rationale**: one request for the whole set is what makes FR-023 satisfiable
without argument. The alternative — one request per artifact — is a network call
per item on the reconcile path, and in the Bash port a `curl` process per item,
which `docs/11-process-budget.md` forbids in its first clause. It would also
turn a 30-artifact first publication into 30 sequential round trips.

The `X-Atlassian-Token: no-check` header is not optional: without it Jira's XSRF
check rejects the upload. It is the one Jira endpoint in this codebase that
needs a header the transport does not already send.

**Alternatives rejected**:

- *One request per artifact.* Simpler to write, but violates the process budget
  and multiplies the failure surface: a partial failure mid-sequence leaves the
  manifest and the ticket disagreeing in more ways.
- *Jira's media API (`/rest/api/2/attachment` + media services).* Needed only to
  embed images inline in ADF; see R8, where we decide not to embed.

**Status**: *unverified* — see §R15.

---

## R2. Discovering the size limit rather than assuming one

**Decision**: `GET /rest/api/3/attachment/meta`, which returns
`{"enabled": <bool>, "uploadLimit": <bytes>}`. The limit is read once per run,
only when there is something to publish, and cached in-process. `enabled: false`
means the site has attachments switched off entirely: the whole publication is
withheld with one warning, not attempted.

**Rationale**: Principle VII forbids compiling in an Atlassian default, and
10 MB is exactly such a default — sites raise and lower it. FR-017 requires the
warning to state *the limit*, which means we must hold the real number.

**Alternatives rejected**:

- *Assume 10 MB.* A site that lowered its limit would get every oversized upload
  rejected by the server with a 4xx we would have to interpret after the fact,
  and a site that raised it would see us refuse files Jira would have accepted.
- *Skip discovery and let the server reject.* The rejection arrives for the
  whole multipart request, so one oversized artifact would fail the publication
  of every other artifact in the same request. Pre-filtering is what keeps
  FR-017's "MUST NOT prevent the remaining artifacts from publishing" true.

**Status**: *unverified* — see §R15.

---

## R3. Where the "already published" record lives

**Decision**: a **Jira entity property on the specification ticket**, key
`spec-kit-jira-artifacts`, holding the current path→hash→attachment-id manifest.
Written with `PUT /rest/api/3/issue/{key}/properties/{key}`, read with the
matching `GET`. It records the *current* state — one entry per artifact path,
carrying the last published hash — never the full history.

**Rationale**: this is the only location that makes FR-012's "across machines"
clause true. The obvious alternative, the local run-state file under
`.specify/jira/state/`, is gitignored per-machine state: a second developer's
first run would find no record, conclude nothing had been published, and
republish every artifact — a zero-churn violation (Principle II) that would only
appear on a colleague's machine, never on the author's.

The mechanism is also already in the codebase and already blessed: the ticket
identity marker lives in an entity property for precisely the reason Principle
II gives — entity properties are server-side, stable, and invisible to the
editable UI, so no human can silently invalidate them (`sink/jira/identity.sh`).
*Measured*: `identity.sh` reads and writes `/issue/{key}/properties/{key}` today,
so the transport path and its error mapping already exist.

Storing only the current state, not the history, keeps the document bounded by
artifact count rather than by run count — a feature living through forty runs
does not grow a forty-times-larger property. Jira caps an entity property value
at 32 KB; thirty artifacts at roughly 100 bytes each is about 3 KB, an order of
magnitude of headroom. The history a reader wants is in the comment stream,
which is where FR-004 already puts it.

**Alternatives rejected**:

- *Local run-state file.* Fails across machines, as above.
- *Encode the content hash in the attachment filename* (`spec@a1b2c3.md`).
  Needs no extra state and is self-describing, but every filename a human sees
  in Jira becomes noise, which Principle XVI rules out for the sake of an
  internal bookkeeping concern.
- *List the ticket's existing attachments and compare filenames.* Cannot
  distinguish "same file, same content" from "same file, revised" without a
  hash, which is the thing we would be trying to avoid storing.
- *A marker block inside the announcing comment.* Works and is consistent with
  the managed-panel markers this codebase already uses, but it puts machine
  bookkeeping into the one artifact whose entire purpose is being read by a
  human (Principle XVI), and reading it back means fetching and parsing the
  comment list on every run.

**Status**: *measured* for the mechanism, *unverified* for the 32 KB cap.

---

## R4. Hashing N artifacts without N processes

**Decision**: `git hash-object --no-filters --stdin-paths`, fed the artifact
paths on **stdin**, one per line. One process for the whole set, whatever its
size.

**Rationale**: `lib/run_state.sh` today calls `git hash-object --no-filters
<path>` once per input, which is fine for three fixed inputs and is a per-item
spawn the moment the input set becomes the artifact set. `--stdin-paths` is the
batched form, and routing the paths through stdin rather than argv satisfies the
*second half* of the process-budget rule at the same time — the half
`docs/11-process-budget.md` records as having been dropped three times. The
payload here grows with the number of artifacts and with path length, so the
Windows ~32 767-byte command-line cap is exactly the one that would bind.

*Measured*: `_run_state_add_input` at `scripts/bash/lib/run_state.sh:39` is the
current per-input call site.

**Alternatives rejected**:

- *`git hash-object a b c …` with paths on argv.* One process, but a growing
  command line — the defect the process-budget document exists to prevent.
- *A shell-level checksum (`shasum`, `Get-FileHash`).* Adds a dependency the
  prerequisite gate does not declare (`curl jq git`, `lib/prereq.sh:18`), and
  `git hash-object` was chosen originally because it is the one content hash
  guaranteed identical on all three hosts.

---

## R5. Enumerating the artifacts, and honouring the ignore rules

**Decision**: `git ls-files --cached --others --exclude-standard -- <feature
dir>` — one process, returning exactly the files that are tracked or untracked
**and not ignored**, recursively.

**Rationale**: FR-007 requires ignored files to be excluded, and the naive
implementation of that is `git check-ignore` per file, which is a per-item spawn.
`ls-files -co --exclude-standard` computes the same answer for the whole subtree
in one call, and it is the standard idiom, not a trick. It also inherently
recurses, which FR-001 requires.

The port must treat the output as bytes: a path may contain a space, and
`git ls-files` quotes paths containing unusual characters unless `-z` is used.
Use `-z` and split on NUL in both ports.

**Alternatives rejected**:

- *`find <dir> -type f` plus `git check-ignore --stdin`.* Two processes rather
  than one, and it re-implements the exclusion rules' precedence in the seam
  between them.
- *`find` alone, with a hardcoded skip list (`.DS_Store`, `*~`).* Guesses at what
  a repository considers noise instead of asking it.

---

## R6. Multipart from the Bash port without putting anything sensitive on argv

**Decision**: extend the `curl --config` document the transport already writes,
adding one `form = "file=@<path>;filename=<attachment-name>"` line per artifact
and `header = "X-Atlassian-Token: no-check"`. The config still travels on
**stdin**. Every path in it is spelled through the existing `_jira_curl_path`
helper, i.e. `cygpath -m` on MSYS.

**Rationale**: three constraints meet here and only this shape satisfies all
three. The credential must stay off argv (`client.sh`'s opening comment,
NFR-3/SC-007). The path must be spelled the way the `curl` on PATH understands —
`docs/10-windows-portability.md`, and the measured `posix=26 win=26 mixed=7`
result recorded in `client.sh` itself. And the request must not grow argv, which
a `-F` per artifact would do; the config file on stdin has no such cap.

The `;filename=` parameter is what lets the part carry the flattened attachment
name from R7 while reading from the real on-disk path — without it curl derives
the name from the path's basename and two artifacts in different subdirectories
would both arrive as `api.md`.

*Measured*: `_jira_curl_path` and the stdin-config mechanism exist at
`scripts/bash/sink/jira/client.sh:35-71`; the MSYS argv-rewriting behaviour is
recorded there from a real runner measurement.

**Alternatives rejected**:

- *`-F` arguments on argv.* Grows the command line with the artifact set, and
  MSYS's argv path rewriting would apply to `file=@/posix/path` in a way we have
  not measured — the constitution's measurement-over-emulation rule means we
  would have to go to the probe to find out. The config-file form sidesteps the
  question rather than answering it.
- *A second transport function that shells out separately.* Duplicates the retry,
  backoff and exit-code mapping that Principle III requires be identical.

**Status**: *unverified* on Windows — see §R15.

---

## R7. What the attachment is called

**Decision**: a top-level artifact keeps its exact filename (`spec.md`,
`plan.md`). A nested artifact flattens its path with `__` (double underscore):
`contracts/api.md` → `contracts__api.md`, `checklists/ux/a.md` →
`checklists__ux__a.md`. If two artifacts flatten to the same attachment name,
**both are withheld** with one warning naming both paths, and the rest of the
run proceeds.

**Rationale**: FR-005 asks for two things at once — distinguishable, and mappable
back to a path without documentation. The common case is the top-level file,
where the exact name is what a reader expects to see; the nested case needs a
separator, and `__` reads as a path separator to anyone who has seen one. The
collision case is reachable only by a literal `__` in a real filename, which is
why it warns rather than silently mangling further.

A **revision** reuses the same attachment name. Jira permits several attachments
with one filename — each has its own id — so the ticket will list `spec.md`
three times with three timestamps. That is the accepted cost of FR-014 (nothing
is deleted) plus readability: appending a hash to disambiguate would make every
filename in the panel unreadable to serve the rarer case, and the comment stream
already carries the ordering FR-013 needs.

**Alternatives rejected**:

- *Replace `/` with a single `_`.* Collides with ordinary filenames far too
  easily (`data_model.md` vs `data/model.md`).
- *Suffix every attachment with a short content hash.* Removes the collision
  question entirely and destroys readability in the common case.
- *A non-ASCII separator (`»`).* Cross-platform filename encoding is a hazard we
  would be adopting for cosmetic gain.

---

## R8. What the comment says, and what it does not

**Decision**: one ADF comment per run (FR-008), built from the existing
`sink/jira/adf.sh` / `Adf.psm1` primitives: a short sentence naming the
lifecycle event, then a bullet list with one entry per artifact — its path
relative to the feature directory, and whether it is a first publication or a
revision. **No ADF `media` nodes**; the artifacts are reached through the
ticket's own attachment panel.

The exact wording is pinned literally in `contracts/comment-body.md` and
constructed identically by both ports.

**Rationale**: embedding an attachment inline in ADF requires a `media` node
carrying the attachment id *and* the media-services collection id, which is not
returned by the attachment endpoint in a form we can rely on. The gain would be
a thumbnail; the cost is a fragile dependency on an API surface we would be
guessing at. KISS (Principle XIV) settles it.

Pinning the wording as a literal rather than composing it from a shared helper
is a direct consequence of a measured cross-port hazard: piping to a native
command in PowerShell appends a newline, and a body composed differently in the
two ports diverges in ways the conformance corpus cannot always attribute. The
contract file is the single source both ports copy.

---

## R9. When the ticket refuses the upload

**Decision**: a failure on the attachment or comment write **withholds the
publication and emits one named warning**; it does not fail the run, and it does
not roll back the writes the reconcile already made. The manifest is not updated
for anything that did not land. A `401` is out of scope here — it would have
failed the run at recognition, long before publication.

**Rationale**: the precedent is in the codebase. When mandatory custom fields
are unmet, the task tier is *withheld* with a warning naming the ticket and the
reason, and the rest of the run proceeds (`sink/jira/hierarchy.sh:488-521`,
"reconcile uses when it withholds the task tier"). Publication is the same shape
of problem: a capability this site or this token does not grant.

The alternative matters more than it looks. A `403` from "Create attachments" not
being granted, mapped to the transport's `auth` exit code and propagated, would
make **every reconcile fail** for every team whose token lacks that one
permission — the moment they upgrade. That is a regression of the entire mirror
in exchange for a feature they may not have asked for, and Principle III's
fail-closed clause does not require it: it governs writes attempted after an
unreliable *read*, and here the reads were fine and the earlier writes succeeded.

**Note for the plan**: the transport maps `403` to `auth` (exit 3) for every
caller today. The publication call site must therefore inspect the result and
translate, rather than letting the code propagate — this is a real seam and it
needs its own test.

*Measured*: `client.sh` maps `401/403 → auth(3)`; `Client.psm1` does the same at
line 130.

---

## R10. Adding two lifecycle events touches six enumeration sites

**Decision**: `after_converge` and `after_checklist` are added to the manifest
and to every place the six-event set is written out. *Measured* — the sites are:

| # | Site | What it is |
|---|------|-----------|
| 1 | `extension.yml` `hooks:` | the manifest the host reads |
| 2 | `scripts/bash/lib/config.sh:963` | `phase_status_map` unknown-key error message |
| 3 | `scripts/bash/lib/config.sh:1065` | `JIRA_HOOK_EVENT_NAMES` |
| 4 | `scripts/bash/commands/reconcile.sh:309` | phase-order canonical list |
| 5 | `scripts/powershell/lib/Config.psm1:942` | the error message's twin |
| 6 | `scripts/powershell/lib/Config.psm1:1858` | the name list's twin |
| 7 | `scripts/powershell/commands/Reconcile.psm1:380` | `$canonicalOrder` |
| 8 | `templates/config.yml.template:91` | the `phase_status_map` comment |
| 9 | `docs/03-lifecycle-hooks.md` | "The seven declared events" — prose and diagram |
| 10 | `tests/bash/ci/test_manifest_hooks.bats:33,69,81` | `EXPECTED_EVENTS` plus an *exactly seven* assertion |
| 11 | `tests/powershell/ci/Manifest.Hooks.Tests.ps1` | its twin |

Sites 10 and 11 were found while writing `tasks.md`, after this section first
claimed nine. They are the reason the count matters: the guard asserts
**exactly** the declared set, so it fails closed on a widening — which is the
behaviour we want, and which means the guard is part of the change rather than
a bystander.

**Consequence worth stating**: `phase_status_map` gains two accepted keys for
free. A team can now declare a board move on `after_converge`. That is a
side effect of the event set being shared, not a new capability this spec asks
for, and it needs no new code — only the validation lists above.

**Rationale for the two chosen, and the two refused**: `/speckit-checklist`
writes only into `checklists/`, so under the old six events plus the run-state
short-circuit its output could sit unpublished indefinitely — that is the gap
that makes `after_checklist` load-bearing rather than tidy. `after_converge` was
named by the operator. `after_constitution` writes to `.specify/memory/`, outside
the feature directory, so declaring it would fire runs that can publish nothing;
`after_taskstoissues` writes no feature-directory artifact, and where it touches
`tasks.md` the next declared event catches it. Principle XV refuses both.

*Measured*: the four unused events are offered by the host — `hooks.after_converge`,
`hooks.after_checklist`, `hooks.after_constitution` and `hooks.after_taskstoissues`
all appear in the installed skill documents under `.claude/skills/`.

---

## R11. Run-state schema goes to v3

**Decision**: `_RUN_STATE_SCHEMA` 2 → 3. The `inputs` object stops being three
fixed keys and becomes the full artifact map, path → hash, for every publishable
artifact. `spec.md`, `plan.md` and `tasks.md` are no longer special-cased; they
are simply three of the entries.

**Rationale**: FR-011, and the point the specification's Context section makes.
The short-circuit is a correctness mechanism for zero-churn; the moment the
publishable set is larger than the hashed set, the short-circuit becomes a way to
lose artifacts silently. Making the two sets the same object is the only shape
where they cannot drift apart again.

The bump invalidates every existing run-state file, which is exactly the
documented behaviour of a change to the *set* of recorded inputs — the first
run after upgrade does work, which is correct, because it has artifacts to
publish.

*Measured*: `scripts/bash/lib/run_state.sh:25` carries the constant and the rule
that a change to the input set bumps it.

---

## R12. The privacy guard over binary artifacts

**Decision**: every artifact is scanned, binary included, with no special case.

**Rationale**: the BLOCK tier matches an ASCII token prefix, an
`*.atlassian.net` host, and known coordinate strings. Those are byte sequences;
scanning a PNG for them is well-defined and finds them if they are there — an
API token pasted into an image's metadata is not a hypothetical. A false
positive requires those exact byte sequences to occur by chance in compressed
data, which is not a practical concern at these lengths.

Adding a text/binary discriminator would mean deciding what "text" is per host
and creating a class of file the guard does not cover — a hole, for no gain.

---

## R13. Mock surface: two implementations, not one

**Decision**: both mocks gain the attachment endpoint, the attachment-meta
endpoint, the comment endpoint and the entity-property round-trip.

*Measured*: the Bash suites do not talk to the HTTP mock — they intercept
`curl` through `tests/conformance/mock-jira/curl-shim.sh` (27 KB), while the
PowerShell suites and the conformance corpus drive the real loopback server
`tests/conformance/mock-jira/mock-server.ps1` (37 KB). A route added to one and
not the other produces a green suite on one port and a failure on the other, or
worse, a green suite on both that proves nothing.

The shim additionally has to *parse a multipart config* to record what was
uploaded — it is the only place in the test estate that can observe the request
body the Bash port builds.

**Known trap, from this repository's history**: the mock keys some responses on
the exact `fields=` query string, so widening a field list silently serves the
wrong fixture. The attachment read (R3's manifest is a property, but FR-012's
"re-derive when Jira contradicts" needs the attachment list) must be added with
that in mind rather than by pattern-matching an existing route.

---

## R14. PowerShell multipart

**Decision**: `Invoke-WebRequest -Form @{ file = @(<FileInfo>, <FileInfo>, …) }`,
which PowerShell 7 renders as `multipart/form-data` with one part per array
element. `Invoke-JiraRequest` gains an optional parameter for it; when present,
`ContentType` is *not* set (PowerShell computes the boundary itself) and the
`X-Atlassian-Token` header is added.

**Rationale**: `-Form` is the built-in multipart path in PS7 and needs no
dependency, satisfying Principle XIV's minimal-dependency rule and Principle
VI's no-build-step rule. The existing function hardcodes
`ContentType = 'application/json'` (`Client.psm1:107`), so the parameter must
suppress it rather than sit beside it — setting both is an error.

The part **filename** must be set explicitly to the flattened name from R7.
A `FileInfo` contributes its own basename by default, which would reintroduce
the collision R7 exists to prevent.

**Status**: *unverified* — the exact mechanism for overriding a part's filename
in `-Form` is the detail most likely to differ from this description; see §R15.

---

## R15. What a mock cannot prove — the dogfood list

This feature's tests will pass against mocks we write. That is precisely the
condition under which Principle II records that three live-only bugs were found
in the original extension. The following are **unverified against a real Jira
Cloud site** and must each be confirmed by the dogfood run before release; the
release gate is not satisfied by a green three-OS matrix alone:

1. **R1** — that one multipart request carrying several `file` parts creates
   several attachments, and that the response array order matches part order.
2. **R1** — that `X-Atlassian-Token: no-check` is accepted alongside the
   existing `Authorization: Basic` header.
3. **R2** — the response shape of `GET /rest/api/3/attachment/meta`, and whether
   `enabled: false` is actually returned by a site with attachments disabled.
4. **R3** — the entity-property value size cap, and the behaviour on exceeding it.
5. **R6** — that the `form =` directive in a `curl` config file on stdin behaves
   as `-F` does, on Windows, through MSYS. This one is a `ci/windows-probe` run,
   not a dogfood: it is a host quirk and the constitution requires measurement on
   the real runner.
6. **R7** — that Jira accepts two attachments with the same filename on one
   issue, and lists both.
7. **R9** — the exact status returned when the token lacks "Create attachments"
   (403 assumed).
8. **R14** — the `-Form` part-filename override.

Items 1–4 and 6–8 are dogfood; item 5 is a probe. Both are gates, not
formalities.
