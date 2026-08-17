# Contract — Mention grammar

**Feature**: 029 | Governs FR-032, FR-008, and the trigger of every other
requirement in this feature.

What counts as naming a ticket. Both ports MUST implement this identically; a
divergence here changes which runs ask a question, which is the feature itself.

---

## §1 Position

**The leading positional is the gate; it is no longer the whole grammar.**

1. **The gate.** If the leading positional argument does not reduce to an issue key,
   the request names nothing. No further token is examined, no question is asked, and
   the run is byte-identical to the current release. This is what keeps `COVID-19`,
   `ISO-9001` and `RGPD-2016` in an ordinary description from producing Jira guidance
   in a repository that never installed this extension — the shape alone is not
   evidence of intent, and a control with false positives ends up disabled.
2. **Once the gate is open**, every remaining positional token that reduces to an issue
   key is detected too, in argv order. Flag values and environment variables are never
   examined.
3. **The leading positional alone computes the name.** The slug, the branch and the
   folder short name derive from the first detected issue and from nothing else, so
   reordering the words of a request can never rename its branch.

Detection is not adoption. Every detected issue is *proposed* in the question and bound
only by the operator's answer — which is why a token that turns out to be a mere
citation (`IJT-40 see IJT-99 for background`) costs a glance rather than a wrong write.
This reverses [research R2](../research.md)'s leading-positional-only recognition rule,
which R2 recorded as the one decision a maintainer could reasonably overturn; R8 and
R10 record why it was overturned and what makes it safe now.

This is a deliberate narrowing, justified in [research.md §R2](../research.md). The
description is the slug source, so recognising a key found mid-sentence would
silently change the computed branch and folder names, and a description that merely
cites a related ticket would be misread as naming this feature's ticket.

**Consequence to state in the agent ceremony**: an operator who types
`ticket <url> …` has `ticket` as their leading positional and therefore names
nothing — the gate stays shut and no later token is examined.
`commands/speckit.jira.feature.md` MUST instruct the assistant to pass a ticket as the
leading positional. This consequence is now sharper than before, because the gate no
longer costs only the first ticket: it costs every ticket in the request.

---

## §2 Accepted forms

| Form | Shape | Result |
| --- | --- | --- |
| Bare key | matches the key shape already used at `commands/feature.sh:474` | that key |
| Browser URL | reduced per §3 to something matching the key shape | the reduced key |
| Anything else | — | no mention; the argument is part of the description |

A leading positional that looks like a URL but reduces to nothing key-shaped is
**not** a mention. It is not an error either — it stays part of the description,
exactly as any other word does today.

---

## §3 URL reduction

Reduction MUST reuse the rules the designator grammar already applies
(`sink/jira/designator.sh`, `designator_reduce_url_candidate`), in this order:

1. strip the fragment;
2. a `selectedIssue` query parameter, if present;
3. otherwise the segment following `/browse/`;
4. otherwise the final path segment.

**Reuse is normative, not advisory.** A second reduction implementation would be two
grammars for one concept, and the shipped one is already Windows-proven. A new glob
pattern written beside it is not: `docs/10-windows-portability.md` records that the
MSYS matcher bends a `$'\r\n'` pattern onto a bare LF, so no CRLF may appear in any
pattern added here.

**Host checking is out of scope of this contract.** Whether a URL's host must match
the configured site is the designator grammar's own concern (`REF-HOST`); this
contract governs only what reduces to a key.

---

## §4 Conformance obligations

| Scenario | Expected |
| --- | --- |
| Leading positional is a bare key | mention recognised, question path reachable |
| Leading positional is a `/browse/` URL | identical outcome to the bare key, byte for byte |
| Leading positional is a `selectedIssue=` board URL | identical outcome |
| Leading positional is a URL reducing to nothing key-shaped | no mention; description unchanged |
| Leading positional is an ordinary word | no mention; **byte-identical to the current release** |
| No arguments beyond the description | no mention; **byte-identical to the current release** |
| Leading positional is a key, later tokens hold two more keys | three issues detected, three proposal lines, one answer; branch and folder from the first alone |
| Leading positional is a key, later tokens hold a link | identical to the row above — keys and links mix freely |
| Leading positional is a key, a later token is `COVID-19` | detected and proposed like any other; the operator declines it by naming what they meant |
| No leading key, later tokens hold keys | **nothing detected, no question, no report**: byte-identical to the current release |

The last row is deliberate and costly. `ticket https://…/browse/IJT-2241` — the
reported incident's exact keystrokes — falls in it and stays silent, because the
alternative is worse: `^[A-Z][A-Z0-9_]+-[0-9]+$` matches `COVID-19`, so examining
tokens in a run whose first word named nothing would emit Jira guidance into
repositories that have never heard of this extension. Precision beats recall at a
control that speaks unprompted. Inside an already-gated request the calculus inverts —
a false positive there is one extra line in a list the operator is reading anyway — and
the prose-prefixed shape stays the agent ceremony's job
(`commands/speckit.jira.feature.md`, §1 above).

The last two rows are the regression proof for FR-008. The existing
`tests/conformance/scenarios/us3-feature-*.json` scenarios already cover them and
MUST run unmodified — editing them destroys the evidence they exist to provide.
