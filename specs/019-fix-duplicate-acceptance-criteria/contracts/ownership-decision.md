# Contract: The Ownership Decision

**Feature**: 019-fix-duplicate-acceptance-criteria | **Date**: 2026-08-06

Two ports, one behaviour, proven byte-for-byte by `tests/conformance/ci-conformance.sh`. Every signature
below is an addition or a backward-compatible extension: no existing caller changes shape.

---

## §1 Neutral engine — the decision itself

### bash

```
managed_section_ownership_split <marker> <managed-nodes-json> <ownership>
  stdin : the existing content-node array (may be empty or absent → treated as [])
  stdout: canonical {prefix: <node array>, status: "ok"|"malformed"|"migrated-warned"}
  return: 0 always (a refusal is expressed as status, not as an exit code)
```

`<ownership>` ∈ `self` | `other` | `unknown`. Any other string is a programming error and MUST be treated
as `unknown` rather than accepted.

### PowerShell

```
Split-JiraManagedSectionOwnership -Marker <string> -ManagedJson <string> -Ownership <string> -ExistingJson <string>
  → the same canonical JSON, same three statuses
```

### Rules

| # | Condition | `prefix` | `status` |
| --- | --- | --- | --- |
| 1 | marker occurs more than once | *(absent)* | `malformed` |
| 2 | marker occurs exactly once | nodes above the marker | `ok` |
| 3 | marker absent, ownership `self` | `[]` | `ok` |
| 4 | marker absent, ownership `other` | suffix split; matched → nodes before the match, else whole content | `ok` / `migrated-warned` |
| 5 | marker absent, ownership `unknown` | whole content | `migrated-warned` |

Rules 1, 2, 4 are today's behaviour, moved behind this entrypoint unchanged. Rule 3 is the fix; rule 5 is
FR-004.

**Named exception, rule 4 (research.md §R8)**: FR-005 ("MUST NOT depend on the content being byte-stable
across a round trip") is satisfied unconditionally by rule 3, the branch this feature adds. Rule 4 retains
018's structural suffix comparison unchanged, which *is* content-dependent — measured against
`tests/bash/sink/test_boundary_migration.bats`'s PRE-2 case, narrowing it to origin-only reintroduces the
literal duplication FR-006/FR-007 forbid on a legacy, human-adopted, pre-boundary ticket. Nothing a human
wrote is discarded by either outcome of rule 4: a matched suffix is not lost, it reappears verbatim in the
freshly rendered region below the marker (§5 invariant 1), and an unmatched one is kept whole in `prefix`.
FR-005 is scoped to the `self` decision; `other` is 018's inherited behaviour, unchanged by design.

**Ordering is normative**: the marker count is evaluated before ownership. A delimited description is never
subject to rule 3.

### Neutrality obligations

- Zero Jira identifiers. The marker is a parameter; ownership is a parameter; nodes are opaque JSON.
- No `jq` invocation outside `lib/output.sh` (bash port) — the Windows build emits CRLF on multi-line output.
- No `$'\r\n'` inside any glob pattern.

---

## §2 Sink — translation and pass-through

```
_adf_resolve_managed <managed-nodes-json> [existing-desc-json] [origin]
adf_render_managed_description <content-json> [existing-desc-json] [origin]
adf_render_managed_task_description <task-json> [existing-desc-json] [origin]
```

PowerShell: `Resolve-JiraManagedAdfContent`, `ConvertTo-JiraManagedAdfDocument`,
`ConvertTo-JiraManagedTaskAdfDocument` each gain an optional `-Origin`.

**Translation (total, sink-side only)**

| `origin` | `ownership` |
| --- | --- |
| `bridge` | `self` |
| `human` | `other` |
| anything else, including empty and absent | `unknown` |

**Backward compatibility**: the third argument is optional. Omitted → `unknown`. A creation (no
`existing-desc-json`) short-circuits before ownership is consulted and is unaffected.

---

## §3 Caller obligations

Each of the six update call sites MUST pass the origin already present in its plan context:

| Port | Site | Source |
| --- | --- | --- |
| bash | `plan_apply.sh` story update | `ctx.ticket_origins[<sid>]` |
| bash | `plan_apply.sh` parent update | `ctx.parent_origin` |
| bash | `plan_apply.sh` task update | `ctx.ticket_origins[<tid>]` |
| pwsh | `PlanApply.psm1` story update | `$ticketOrigins` — **hoist above the render call** |
| pwsh | `PlanApply.psm1` parent update | `$parentOrigin` — **hoist above the render call** |
| pwsh | `PlanApply.psm1` task update | `$taskOrigins` — **hoist above the render call** |

No caller may compute an origin, infer one from content, or default a missing one to `bridge`.

---

## §4 Output contract, unchanged

`_plan_apply_managed_field` and its PowerShell twin consume `{status, doc}` exactly as today:

- `ok` → send `description`, no warning
- `migrated-warned` → send `description`, append the existing named warning
- `malformed` → **omit the `description` key entirely** from the payload (never send `null`), append the
  existing named warning

No new status, no new warning string, no new count (FR-015).

---

## §5 Invariants a reviewer can check mechanically

1. For any `status == "ok"` result, the rendered region occurs exactly once in `prefix ++ marker ++ region`.
2. For `ownership == "self"` with the marker absent, `prefix` is empty — never partially populated.
3. For `ownership != "self"`, the output is byte-identical to the pre-feature implementation given the same
   inputs. This is the regression guard: existing tests must pass **unmodified** except the two artefacts
   named in `research.md` §R7.
4. `malformed` produces no `description` key, on every tier, on both ports.
5. Running the same specification twice produces zero writes on the second run (Principle II).
