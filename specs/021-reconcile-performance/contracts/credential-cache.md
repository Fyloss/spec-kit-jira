# Contract — the per-run credential cache

Covers spec FR-007 … FR-014, and FR-033 … FR-039 for the Windows rung. Principle IV governs every line
here: a performance change that weakens any of it is a rejected change, not a trade-off.

## 1. Interface

### Bash — `lib/credentials.sh`

| Function | Change |
| --- | --- |
| `cred_resolve_token` | Returns the cached value when the cache is filled; otherwise resolves through the existing three rungs and fills it. Unchanged signature, unchanged stdout, unchanged return codes. |
| `cred_prime_cache` | **NEW.** Fills the cache. Returns 0 whether or not a token was found — priming is not a gate. Prints nothing, ever. |
| `cred_curl_config` | Unchanged. Calls `cred_resolve_token`, which is now usually a variable read. |

Cache variables, both **non-exported**:

- `_CRED_CACHE_STATE` — `unset` | `resolved` | `unresolved`
- `_CRED_CACHE_TOKEN` — the token, only when the state is `resolved`

### PowerShell — `lib/Credentials.psm1`

| Function | Change |
| --- | --- |
| `Resolve-JiraToken` | Returns `$script:CredCacheToken` when `$script:CredCacheState` is set; otherwise resolves and fills. |
| `Get-JiraSecretManagerToken` | Stops being a no-op — see §5. |
| `Get-JiraAuthHeader` | Unchanged. |

No priming function is needed: PowerShell has no subshell, so module scope persists for the process.

## 2. Where the prime is called, and why it matters

`cred_prime_cache` is invoked **once, from `cmd_reconcile`, in the main shell**, immediately before the
first phase that issues requests — after the state phase and after the config phase has established
that a base URL exists.

This placement is the whole design (research R3). Most `jira_request` call sites capture the response
through `resp="$(jira_request …)"`, so a cache filled inside one of them is filled inside a subshell and
dies with it. A subshell inherits all of its parent's shell variables, exported or not, so a value
written before the fork is visible inside every child.

Placing the prime *late* rather than at startup preserves an existing property: a run that issues no
request consults the secret store **zero** times. That covers a disabled hook, an unbound repository, and
the run-state short-circuit — the fastest path must not pay a Keychain unlock.

Cache-on-miss is retained alongside priming. Correctness never depends on the prime; only the
"at most once" guarantee does.

## 3. Invariants

| # | Invariant |
| --- | --- |
| C1 | The secret store is invoked **at most once** per process, whatever the number of requests and retries. |
| C2 | The cached value is held in a non-exported shell variable / `$script:` variable. It never enters the environment of any child process, `$env:`, or a PowerShell transcript. |
| C3 | Every function reading or writing the cache keeps its port's trace-suspension discipline. Both the token and the derived base64 value are secrets. |
| C4 | The cache is never written to any file, temporary file, the run-state document, or a timing line. |
| C5 | The resolution order keeps its shape on every OS: environment → OS secret store → gitignored `.env`. Only the frequency changes. |
| C6 | The cache is per-run and never persisted. A token rotated in the store takes effect on the very next reconcile. |
| C7 | A failed resolution is cached as `unresolved` — a distinct state, never an empty token — so a token-less run consults its sources once and reproduces today's exit code and message on every call. |
| C8 | The bridge introduces no new persistent store for credential material on any OS. |
| C9 | The secret-manager rung is soft-optional **on every platform**: tool or module absent, store unregistered, store locked, entry missing — each falls through silently, never errors, never prompts, never blocks, and is never tested by `prereq_check`. Constitution IV, v1.3.0. |

## 4. How each invariant is proven

| Invariant | Test |
| --- | --- |
| C1 | A counting stub on the `security` / `secret-tool` seam, a run issuing many requests including a retried 429, assert the counter reads exactly 1. |
| C1 (zero case) | A run that short-circuits on run state, and a run in a repository with no base URL: assert the counter reads 0. |
| C2 | Spawn a child that dumps its environment mid-run; assert no variable holds the token. Assert `declare -p` shows the cache variable without the `-x` attribute. |
| C3 | Run the whole reconcile under `set -x` / `Set-PSDebug -Trace 1` at maximum verbosity and grep every captured stream for the token and for the base64 value. This suite already exists and is extended, not replaced. |
| C4 | Grep the entire post-run tree — including `.specify/jira/state/` and every temp path — for the token. |
| C6 | Two runs with different stub tokens; assert the second uses the second token. |
| C7 | Remove every rung; assert exactly one consultation per source and today's exit code and message unchanged. |
| C9 (macOS/Linux) | **New work the amendment created.** `tests/bash/lib/test_credentials.bats` proves the empty-source fall-through today, but not `security`/`secret-tool` absent from PATH, nor either returning non-zero. Both paths get a test asserting a silent fall-through to `.env` and no error output. |
| C9 (Windows) | Per §5: module absent, no vault registered, no such secret, vault locked — each asserted silent, error-free, and **non-blocking** (assert the call returns rather than waiting). |

## 5. The Windows rung

> Authorised by **constitution v1.3.0** (2026-08-07): Principle IV's second rung is defined by its
> requirement — a store the OS encrypts at rest, read at run time — and names PowerShell
> SecretManagement as the Windows mechanism. The same amendment makes the rung soft-optional on every
> platform, so §5's fall-through rules below are constitutional, not local to this feature.

`Get-JiraSecretManagerToken` on Windows:

```text
Get-Secret -Name spec-kit-jira -AsPlainText   (default registered vault)
```

Resolution order becomes: environment → SecretManagement vault → gitignored `.env`.

| Condition | Behaviour |
| --- | --- |
| `Microsoft.PowerShell.SecretManagement` not installed | Return `$null`. Silent. |
| No vault registered | Return `$null`. Silent. |
| No secret named `spec-kit-jira` | Return `$null`. Silent. |
| Vault locked, requires an interactive unlock | Return `$null` **without prompting and without waiting**. Silent. |
| Any other error | Return `$null`. Silent. |

Rules:

- The secret name is `spec-kit-jira`, matching the Keychain service name and the libsecret attribute, so
  the three OS sections of the documentation are symmetric.
- The rung never prompts and never blocks. A lifecycle hook has nobody to answer a password prompt, so
  the call is made in a non-interactive context and any prompt attempt is a failure to fall through from.
- `prereq_check` does **not** test for the module. Its absence is never a prerequisite failure.
- Existing setups using the environment variable or `.env` are untouched; the rung only adds an option
  between them.
- The retrieved value obeys §3 in full, without exception.
- `$env:_CRED_SECRET_TOKEN` remains the test seam and continues to take precedence, so no test needs a
  real vault.

Documentation to update when this lands: `README.md` and `INSTALL.md` gain a Windows storage section
(`Install-Module` for SecretManagement + SecretStore, `Register-SecretVault`, `Set-Secret`), including
the `Set-SecretStoreConfiguration -Authentication None` trade-off for hook-driven use; and the paragraph
in `docs/07-configuration-and-secrets.md` beginning "there is no OS secret-manager rung on Windows" is
replaced.
