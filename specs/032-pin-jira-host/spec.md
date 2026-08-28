# Feature Specification: Pin the Jira Destination Host

**Feature Branch**: `032-pin-jira-host`

**Created**: 2026-08-28

**Status**: Draft

**Input**: User description: "Pin the Jira destination host so a committed `config.yml` cannot silently redirect the operator's API token. A security review of the whole project found that the destination coordinate lives in the committed team config, that its only validation constrains the scheme and never the host, and that the transport attaches the operator's credential to every request unconditionally — so a one-line change on a branch redirects a live token to a host the branch author chose, with no operator action and no visible signal. Record the destination the binding ceremony actually reached in the gitignored local layer, refuse before the first request when the declared destination no longer matches it, and refuse to produce the credential for an unpinned destination. Explicitly out of scope: re-validating the merged configuration document."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A redirected destination is refused before the first request (Priority: P1)

An operator has bound their repository to their team's Jira. Someone changes the destination coordinate in the committed team config — on a branch, in a merge, or by mistake. The operator checks that state out and runs any command that talks to Jira.

Before a single request leaves the machine, the bridge notices that the destination the repository now declares is not the one this checkout is bound to. It refuses, names both destinations, and says how to accept the change deliberately. No request is issued, so no credential is transmitted.

**Why this priority**: This is the whole feature. Without it the credential is delivered to the new destination and nothing else in this spec matters. It is also the only story that closes the reported vulnerability; the others make it durable and adoptable.

**Independent Test**: Bind a repository against one destination, alter the declared destination, run a command that reads Jira, and assert zero requests were issued, the documented refusal code was returned, and the message names both destinations.

**Acceptance Scenarios**:

1. **Given** a checkout bound to destination A, **When** the committed team config declares destination B and any Jira-reading command runs, **Then** zero requests are issued, the run exits with the documented configuration-refusal code, and the message names both A and B and the gesture that accepts B.
2. **Given** a checkout bound to destination A, **When** the committed team config still declares destination A, **Then** the run proceeds exactly as it does today, with no additional output and no additional question.
3. **Given** a checkout bound to destination A and a declared destination B, **When** the refusal occurs, **Then** no credential is resolved, or if already resolved it is not transmitted, and nothing in the message reveals any part of it.
4. **Given** a refusal raised while running inside a lifecycle hook, **When** the host command completes, **Then** the host command's own outcome is unchanged and the operator sees exactly one actionable message.
5. **Given** a checkout bound to destination A, **When** the declared destination differs from A only by scheme or port, **Then** it is refused on the same terms as a different host.
6. **Given** a checkout bound to destination A and a declared destination B, **When** the operator runs the binding ceremony exactly as the refusal message instructs but without naming B, **Then** the ceremony refuses too and records nothing — following the instruction verbatim is not sufficient to accept B.
7. **Given** that same state, **When** the operator runs the ceremony naming B explicitly, **Then** B is recorded and subsequent runs proceed against B.

---

### User Story 2 - An installation with no binding on record says so and stays inert (Priority: P2)

An operator upgrades to this release. Their repository was bound before this feature existed, so the local binding carries no record of which destination it was bound against. There is nothing to compare, and inventing one from the current declaration would bind them to whatever the repository happens to say right now — including a value an attacker put there.

The bridge refuses before its first read, writes nothing, and names the one ceremony that repairs it.

**Why this priority**: Every existing installation lands here on first upgrade. If this path is wrong, the feature either breaks every consumer with an unactionable error or silently adopts an unverified destination, which would defeat User Story 1 entirely.

**Independent Test**: Take a local binding produced by the previous release, run any Jira-reading command, and assert zero requests, zero writes, and a message naming the ceremony to run.

**Acceptance Scenarios**:

1. **Given** a local binding that records no destination, **When** any Jira-reading command runs, **Then** zero requests are issued, nothing on disk is modified, and the message names the binding ceremony as the repair.
2. **Given** that same state, **When** the operator runs the binding ceremony once, **Then** the destination it reaches is recorded and subsequent runs proceed normally without further prompting.
3. **Given** a local binding whose recorded destination is present but malformed, **When** any Jira-reading command runs, **Then** it is refused on the same terms as an absent one, naming the malformed value's key rather than guessing an intent.

---

### User Story 3 - The credential is never produced for an unbound destination (Priority: P3)

A future call site builds a request URL of its own without going through the shared resolution path. The credential must still not be produced for a destination this checkout is not bound to.

**Why this priority**: Defence in depth. It converts the guarantee from a convention that every call site must remember into a structural property of the one function that produces the credential. It has no user-visible behaviour of its own when User Story 1 holds, which is why it is last — but it is what keeps the guarantee true a year from now.

**Independent Test**: Ask the credential-producing path directly for a destination that is not the bound one, and assert it refuses rather than returning an authorization value.

**Acceptance Scenarios**:

1. **Given** a checkout bound to destination A, **When** the credential-producing path is asked to authorize a request to destination B, **Then** it refuses and produces no authorization value.
2. **Given** a checkout bound to destination A, **When** the credential-producing path is asked to authorize a request to destination A, **Then** it behaves exactly as it does today.

---

### Edge Cases

- **The repair instruction must not become the bypass.** The refusal tells the operator to run a ceremony. If that ceremony re-records the destination without the operator affirming it, an attacker only has to change the coordinate and wait for the victim to follow the instruction. The gesture that accepts a new destination must be distinct from the gesture that repairs a missing record. See FR-010.
- **A hook has nobody to answer.** Lifecycle hooks run unattended. No path introduced here may prompt, wait for input, or block; a refusal is the only outcome available there.
- **Case and trailing form.** Hostnames are case-insensitive, so `Example.Invalid` and `example.invalid` are the same destination; a trailing separator or an empty path segment does not make a destination different.
- **The first binding has nothing to compare against.** During the ceremony that establishes the binding, the destination is being learned, not verified. The refusal cannot apply to the act of binding itself, or nothing could ever be bound.
- **Two projects, one repository.** A repository may map several projects. They resolve to one site coordinate, so one record per checkout is sufficient; a per-project record would imply the site can differ per project, which the configuration layering does not admit.
- **The record lives in the layer an outsider cannot reach.** The record is only meaningful because it sits in the gitignored local layer. If it were readable from the committed layer, the attacker would simply set both.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The binding ceremony MUST record the destination it actually reached, into the gitignored local binding layer, at a dedicated key introduced by this feature (`bound_site`). It MUST NOT reuse the existing `site_alias` key, whose published contract states the opposite — that the real site URL is never persisted there — and which existing installations already populate with a human alias.
- **FR-002**: The recorded destination MUST be the full origin — scheme, host, and port — and MUST NOT include a path, query, or credential component.
- **FR-003**: The bridge MUST compare the declared destination against the recorded one before issuing the first Jira request of any run, in every command that reads or writes Jira.
- **FR-004**: On a mismatch, the bridge MUST issue zero requests, exit with the documented configuration-refusal code, and emit one message naming the declared destination, the recorded destination, and the exact invocation that accepts the change — an invocation that names the destination being accepted, per FR-010.
- **FR-005**: When the local binding records no destination, or records one that is malformed, the bridge MUST issue zero requests, modify nothing on disk, and emit one message naming the ceremony that repairs it.
- **FR-006**: No path introduced by this feature may prompt, wait for input, or block; refusal is the only outcome available when a decision cannot be made from what is already on disk.
- **FR-007**: A refusal raised while running inside an `after_*` lifecycle hook MUST NOT change the host command's outcome — at worst one actionable message, with success returned to the host.
- **FR-008**: The credential-producing path MUST refuse to produce an authorization value for a destination that is not the recorded one.
- **FR-009**: Every message, exit code, and stream introduced by this feature MUST be byte-identical across both ports for the same input.
- **FR-010**: Accepting a changed destination MUST require the operator to name that destination explicitly. The binding ceremony MUST NOT record a destination that differs from the one already on record unless the operator supplies that destination's origin as an explicit argument; run without it against a changed destination, the ceremony MUST refuse on the same terms as FR-004. Following the refusal's instruction verbatim, without supplying the origin, MUST NOT be sufficient to accept the change.
- **FR-011**: A destination supplied through the process environment is NOT subject to the comparison, and MUST NOT be recorded by it. The environment is operator-typed and unreachable from a pull request — the same ground on which the constitution admits the credential retrieval command's name from there and nowhere else. The comparison therefore applies to a destination resolved from the committed team config, which is the only source a contributor can change.
- **FR-012**: Scheme MUST be compared exactly. Host comparison MUST be case-insensitive, folded by an explicitly enumerated ASCII mapping — never by a locale-, culture-, or Unicode-dependent facility, whose results differ between the two ports. Port comparison MUST treat an absent port and its scheme's default as equal (`https://x` and `https://x:443` are the same destination); a trailing dot on the host and a trailing separator on the URL are likewise not distinguishing.
- **FR-013**: No message introduced by this feature may echo any part of the credential, and the refusal messages MUST name destinations only.
- **FR-014**: The recorded destination MUST be validated for shape when read, and a value failing that validation MUST be treated as malformed under FR-005 rather than silently ignored.
- **FR-015**: The comparison MUST NOT be disabled by any configuration value readable from a committed file.
- **FR-016**: The recorded destination MUST be admitted by the local layer's credential-shape guard at its own key and nowhere else. That guard today refuses a real site host at every key of the local layer, enforcing a constitutional rule that names exactly two narrow exemptions; adding a third, key-scoped exemption is a prerequisite of this feature, not a consequence of it. The exemption MUST NOT widen to any other key, or the guard stops being a guard.
- **FR-017**: The origin comparison MUST behave identically across both ports before this feature depends on it. Two divergences exist today in the primitive being reused — one in how many trailing dots a host loses, one in how a host is case-folded — and each MUST be closed, with its own failing cross-port case, ahead of the gate that consumes it. A bracketed IPv6 literal, which the scheme validator already admits, MUST parse to a correct origin rather than to a value that merely happens to be equally wrong in both ports.

### Key Entities

- **Declared destination**: the site coordinate the repository asks the bridge to use, resolved from the committed team config layer. Controlled by anyone who can change a tracked file.
- **Recorded destination** (`bound_site`): the site coordinate this checkout is bound to, held at a dedicated key of the gitignored local binding layer. Written by the binding ceremony; not reachable through a pull request. Distinct from the pre-existing `site_alias`, which remains a human label and is left untouched.
- **Refusal**: the outcome when the two disagree or the second is absent — a documented exit code, zero requests, and one message naming both destinations and the repair.

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | Adds no new source of truth. The recorded destination lives in the existing gitignored local binding layer, at a key that layer's schema already admits; it is read from disk on every run and never cached across runs. |
| II | Zero-Churn Idempotency | The matching case produces no additional output, no additional question, and no write. The ceremony records the destination it already resolved, so a re-run against an unchanged site rewrites an identical value. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | The refusal is fail-closed by construction: it precedes the first request, so zero writes are possible, and it maps to the existing documented configuration code without disturbing the monotonic escalation. FR-007 preserves the hook contract — the host command's outcome is untouched. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | **Conflict, resolved by a separate amendment — not diluted here.** IV admits a real site URL at the committed team config's one dedicated key and forbids it "at any other key, any other file". FR-001 records an origin at a key of the gitignored local layer, which IV as written forbids. The feature does not reinterpret IV: it depends on an amendment adding a third narrow, key-scoped exemption, exactly as v2.0.0 was amended to unblock 030 (FR-016). That amendment lands before implementation or the feature does not proceed. In every other respect the feature strengthens IV — it extends "no pull request can introduce a command" to the destination that command's output is sent to; FR-013 keeps the credential out of every new message; FR-008 withholds it from an unbound destination. No token, email, or accountId enters a tracked file. |
| V | Separation of Team Config / Local Binding / Secrets | **Same conflict, same resolution.** V's enforcement test names exactly two narrow exemptions and requires a test proving the shape is refused at every key of the other files; the local-layer guard implements that with no exemptions at all. FR-016 makes the third exemption a prerequisite and confines it to one key, so the guard's proof — the live scenario asserting it is not a hole — still holds. The layering itself is respected: the declared destination stays in the committable team config at its existing key; the record is machine-specific and gitignored, which is what layer 2 is for; FR-015 forbids the committed layer from disabling the check. |
| VI | macOS / Linux / Windows Portability | FR-009 requires byte-identical messages, codes, and streams across both ports. No new external process, no new path spelling, and no new filesystem write are introduced on either platform. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | Introduces no assumption about issue types, statuses, transitions, or fields. The comparison is over a URL origin and is indifferent to the workflow behind it. A self-hosted deployment is supported on exactly the same terms as a hosted one — deliberately, since a suffix-based allowlist would both fail (a hosted site is trivially registrable by an attacker) and exclude self-hosted operators. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | The comparison is transport and configuration concern only. Nothing is added to the neutral engine, and the interchange document is untouched. |
| IX | Two-Tier Privacy Guard, With an Allowlist | Repairs a weakness in it. The guard derives its known-coordinate set from the declared destination, so an unverified destination currently widens the guard's own allowlist. Once the destination is verified before first use, that derivation rests on a checked value. |
| X | Self-Healing Automatic Mirror | The refusal is self-healing in the intended sense: it names the exact state that is wrong and the one gesture that repairs it, and it repairs itself with no manual file surgery once that gesture is performed. |
| XI | Universal Dry-Run and Auditability | A dry run still issues reads, so it is gated by the same comparison and refuses on the same terms. The refusal is auditable — it names both destinations rather than reporting a generic failure. |
| XII | Quality and Catalog Publication | Documentation is in scope, not optional: the header of the team-config template, the configuration document, the install guide, and the README each currently present the destination coordinate as safe because the file is reviewed, which is the claim this feature contradicts. |
| XIII | TDD With a Minimum 80% Coverage | The failing test that comes first is a conformance scenario, not a per-port unit test, because FR-009 makes byte equivalence part of the requirement. Per-port suites cover the comparison, the absent record, the malformed record, and the hook non-blocking guarantee. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | A string comparison against a value the ceremony already has, at a key that already exists in both schemas. No allowlist to maintain, no network call, no new file, no new configuration surface. |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | Scope is held to the reported vulnerability. Re-validating the merged configuration document is explicitly excluded: verification established it grants an attacker nothing the committed layer already permits, and it would break consumers whose local overrides carry values the team schema rejects. |
| XVI | Human Readable — Readable by a Human Above All | The refusal names both destinations and the repair, in place of the generic transport failure an operator sees today. The recorded value is a plain hostname a human can read and verify in a text file. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A checkout whose declared destination differs from its recorded one issues **zero** network requests, on both ports, for every command that reads or writes Jira.
- **SC-002**: The refusal message, exit code, and stream layout are byte-identical between the two ports for the same input, verified by the cross-port corpus.
- **SC-003**: An operator binding a repository for the first time answers **no additional question** and performs **no additional step** compared with today.
- **SC-004**: An installation carrying no recorded destination receives a message that names the ceremony to run, and resumes normal operation after running it exactly **once**.
- **SC-005**: **100%** of the paths that attach a credential to a request verify the destination first, demonstrated by a test that reaches the credential-producing path directly rather than through the shared resolution path.
- **SC-006**: A refusal raised inside a lifecycle hook leaves the host command's exit status and output unchanged, for every one of the registered lifecycle events.
- **SC-007**: No output produced on any refusal path contains any portion of the credential, verified at maximum verbosity.
- **SC-008**: Following the refusal's own instruction verbatim, without naming the new destination, records **nothing** and changes nothing — demonstrated by a test that replays the printed instruction literally and asserts the recorded destination is unchanged.

## Assumptions

- The gitignored local binding layer is genuinely unreachable through a pull request in the consumer's repository. This holds because the binding ceremony writes the ignore rule itself; a repository that ships the file tracked anyway defeats it, which is a limitation to document rather than an outcome to detect.
- A single recorded destination per checkout is sufficient. The configuration layering admits one site coordinate for the whole repository, so a per-project record would model a state that cannot exist.
- Refusing an installation that carries no recorded destination is preferable to adopting the currently declared one. Adoption on first sight would bind the operator to whatever the repository says at that moment, which is exactly the attacker-controlled value. This follows the precedent already set for a local binding that predates a capability.
- Existing consumers will run the binding ceremony once on upgrade. This is an accepted, documented migration cost, consistent with how prior capability additions to the binding have been handled.
- Because the record uses a new key rather than the existing `site_alias`, there is no "malformed record" migration class for installations that followed the published contract and set a human alias. Their record is simply *absent*, which FR-005 already covers with one message and one remedy. `site_alias` keeps its documented meaning and its value.
- The destination reached by the binding ceremony is the correct one to record. The ceremony contacts the site and resolves real metadata, so a destination that answers it is one the operator's credential already reached deliberately.
- **Known limitation, documented rather than detected (FR-011).** The environment is treated as operator-typed and therefore exempt. A consumer repository can nonetheless supply an environment variable from a tracked file — a direnv `.envrc`, a `Makefile`, a compose file — which would set the destination without passing the comparison. This is mitigated in practice (direnv requires an explicit per-change approval) and sits outside the trust boundary the constitution already draws around the environment, but it is the residual path and belongs in the operator documentation. Detecting it would mean auditing every mechanism that can populate a process environment, which no configuration layer can do.
- Out of scope, tracked separately: re-validating the merged configuration document so that a local override cannot escape the team schema. Verification established it yields no attacker advantage over the committed layer, and closing it would break consumers whose overrides carry values that schema rejects — a breaking change that does not belong in a security fix.
- Out of scope: any allowlist of destination hostnames. A suffix-based allowlist is not a control, because a hosted site under the expected suffix is registrable by anyone, and it would exclude self-hosted deployments.
