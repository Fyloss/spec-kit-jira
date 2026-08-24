# Conformance scenarios

Each `*.json` file here is a language-agnostic golden scenario run against **both**
ports by the harness (`../run-scenario.sh`). For identical inputs the two ports
must produce a byte-identical capture — stdout, exit code, the Jira API call
sequence, and the post-run repository tree (NFR-1, Constitution VI). A divergence
is a failing test, not a documented quirk.

## Schema

```jsonc
{
  "name": "us1-config-idempotent",     // informational label
  "description": "…",                  // optional, human note
  "mock": {                            // mock-jira config (see ../mock-jira/README.md)
    "projects": { "COMP": "company", "TEAM": "team" },
    "faults":   { "AUTH": { "status": 401 } }
  },
  "fixture": "tests/conformance/fixtures/repo-basic",  // optional repo dir copied into the workdir
  "cwd":     "sub/module",             // optional: invoke from this dir under the fixture, not its root (031, C1.2)
  "argv": ["config", "--json"],        // optional args to the entry point
  "env":  { "SPEC_KIT_JIRA_SITE": "x" }// optional extra environment variables
}
```

The harness injects `SPEC_KIT_JIRA_BASE_URL` (the mock's base URL) into the run;
scenarios never hard-code a port number.

## Running

```sh
run-scenario.sh <scenario.json> bash        out-bash/
run-scenario.sh <scenario.json> powershell  out-ps/
diff -r out-bash/workdir out-ps/workdir      # repository tree parity
diff out-bash/stdout out-ps/stdout           # summary parity
diff out-bash/calls.log out-ps/calls.log     # API call-sequence parity
diff out-bash/exit out-ps/exit               # exit-code parity
```

Scenarios are added per user story (US1 → `us1-config-idempotent.json`, etc.);
the entry-point dispatcher (T024) makes them runnable end-to-end.
