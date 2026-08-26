# Contract — pass-through diagnosis

Binding on both ports. Every clause is a test obligation.

---

## §1 Directory resolution

**C1.1** — The configuration directory is resolved in this order, first hit
wins: an explicitly set `JIRA_CONFIG_DIR`; `SPECIFY_INIT_DIR` + `/.specify/jira`;
the nearest ancestor of the working directory containing `.specify/`, plus
`/jira`.

**C1.2** — Resolution walks upward from the working directory and stops at the
filesystem root. It never descends.

**C1.3** — Resolution issues no `git` invocation of any kind. A grep for git
subcommands across both ports' sources returns zero matches after this feature
exactly as it did before.

**C1.4** — When no ancestor carries `.specify/` and neither override is set,
the run reports that no project was located, names the directory it walked from,
and exits successfully with `active: false`. It does not fall back to a
relative path.

**C1.5** — The resolved directory governs `state/` as well as the two
configuration files. Run state that is no longer found is re-derived; its
absence is never reported as a recognition failure and never produces a
duplicate.

---

## §2 What speaks and what stays silent

**C2.1** — A configuration file that exists and fails to load is reported: the
absolute file, and the located reason as the loader phrases it. This holds
whether or not a ticket was mentioned.

**C2.2** — A configuration file that does not exist produces no output
whatsoever when no ticket is mentioned. Byte-identical to the release preceding
this feature.

**C2.3** — A valid configuration declaring no teams produces no output when no
ticket is mentioned. It is a supported single-project setup.

**C2.4** — A personal file that is absent, or present without a `team` key,
produces no output when no ticket is mentioned.

**C2.5** — An empty file — either file, parsing to an empty document — is a
normal unconfigured state under C2.2/C2.4, never a load failure under C2.1.

**C2.6** — No report introduced by this contract echoes a credential-shaped
value. The loader's refusal-without-echo is reproduced verbatim and never
widened.

---

## §3 Non-blocking

**C3.1** — No condition in §1 or §2 fails the run. Every one of them exits
successfully, names its fallback, and leaves the host command's outcome
untouched.

**C3.2** — No condition in §1 or §2 issues a Jira request.

**C3.3** — A personal file that exists and cannot be loaded is treated under
C2.1 and C3.1 — reported, not fatal. This replaces the shipped behaviour, which
exits with a configuration error code.

Authorised by spec 030's `connection-settings.md` **C6.2a** (amendment of
2026-08-24), which scopes C6.2's "a malformed setting refuses the run" to paths
that can reach the network. This path cannot: C3.2 forbids it a request. On
every path that can, C6.2 stands unchanged, and the validation itself is not
weakened anywhere — only the exit code on this one path.

**C3.4** — The refusal C6.2 still governs must be proven to survive: a run that
would reach the network with an unloadable `personal.yml` still fails closed.
This belongs in a test alongside C3.3, or the amendment becomes a hole.

---

## §4 On request

**C4.1** — With `--verbose`, a pass-through names which resolution state
produced it, the absolute path consulted, and what would change it.

**C4.2** — Without `--verbose`, the default and `--json` outputs are exactly
what §2 defines. No key is added to the JSON object, and no line is added to the
default output.

**C4.3** — `--verbose` introduces no new flag, no manifest change, and no new
argument surface. It is the flag the parser already accepts and the feature
command does not yet read.

---

## §5 Parity

**C5.1** — Every clause above holds identically on both ports, with identical
exit codes and byte-identical output for identical inputs.

**C5.2** — C1.1, C1.2 and C1.4 are the parity risk of this feature — path
resolution and absolute-path spelling are where the two hosts diverge — and each
belongs in a conformance scenario rather than a per-port unit test.

**C5.3** — C2.2, C2.3 and C2.4 are proven against the existing corpus:
`us3-feature-no-team.json` and `us29-feature-us6-no-config-no-mention.json` must
pass unmodified. A change to either is a failure of this feature, not an update
to the corpus.
