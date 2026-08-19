# T022 [003 US2] — Hook resilience under `optional: false`. Twin of
# tests/bash/hooks/test_hook_resilience.bats. Originally T081 [US9] — Hook resilience, PowerShell side.
# Mirror of tests/bash/hooks/test_hook_resilience.bats. Cross-port byte agreement
# is proven in bats; here we assert the resilience semantics (FR-046, FR-048, SC-008).

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $CmdDir = Join-Path $Root 'scripts/powershell/commands'
    $HookDir = Join-Path $Root 'scripts/powershell/hooks'
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force
    Import-Module (Join-Path $HookDir 'RegisterHooks.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Config.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Output.psm1') -Force

    function Invoke-ReconcileCode([string[]] $ArgList) {
        # Swallow the summary and return only the exit code. The param must NOT be
        # named $Args — that collides with PowerShell's automatic variable.
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { return (Invoke-JiraReconcile -Arguments $ArgList) }
        finally { [Console]::SetOut($orig) }
    }
}

Describe 'Hook resilience' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $Work -Force | Out-Null
        $script:Spec = Join-Path $Work 'spec.md'
        @(
            '# Feature Specification: Resilience', '', 'A spec that mirrors to Jira.', '',
            '### User Story 1 - The core story (Priority: P1)', '',
            '- **Given** a user', '- **When** they act', '- **Then** it works'
        ) -join "`n" | Set-Content -LiteralPath $Spec -NoNewline
        $env:SPEC_KIT_JIRA_BASE_URL = 'http://127.0.0.1:1'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-feature'
        # 004 FR-005: the shipped placeholder is now refused outright, so this
        # suite (about hook resilience, not config resolution) is migrated to
        # a real key with a matching epic-strategy override — both bypass
        # config.yml, which this isolated work dir never has.
        $env:SPEC_KIT_JIRA_PROJECT_KEY = 'TEST'
        $env:SPEC_KIT_JIRA_EXTENSIONS_YML = Join-Path $Work '.specify/extensions.yml'
        $env:JIRA_NO_SLEEP = '1'
        $env:JIRA_MAX_ATTEMPTS = '1'
        $env:JIRA_EMAIL = 'user@example.com'
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        # A minimal override supplying the issue type the assembly guard
        # requires — this suite has no persisted binding to resolve one from.
        $env:SPEC_KIT_JIRA_PLAN_CONTEXT = '{"story_type_id":"10004"}'
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue
    }
    AfterEach {
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue
        Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
    }

    It 'fails a bridge error outside hook context (baseline)' {
        $code = Invoke-ReconcileCode @('reconcile', '--json', $Spec)
        $code | Should -Not -Be 0
    }

    It 'never fails the host in hook context (FR-046)' {
        $env:SPEC_KIT_JIRA_HOOK_CONTEXT = '1'
        $code = Invoke-ReconcileCode @('reconcile', '--json', $Spec)
        $code | Should -Be 0
    }

    It 'leaves the host exit code untouched for every bridge fault (FR-015)' {
        # Under `optional: false` the agent PERFORMS this step as part of the host
        # command, so a fault that returns early must be downgraded too — not only
        # the ones that reach the end of the run.
        $env:SPEC_KIT_JIRA_HOOK_CONTEXT = '1'
        (Invoke-ReconcileCode @('reconcile', '--json', $Spec)) | Should -Be 0

        $bad = Join-Path ([System.IO.Path]::GetTempPath()) "$([System.Guid]::NewGuid()).md"
        Set-Content -Path $bad -Value 'not a specification at all' -NoNewline
        (Invoke-ReconcileCode @('reconcile', '--json', $bad)) | Should -Be 0
        Remove-Item -Force $bad -ErrorAction SilentlyContinue

        $env:SPEC_KIT_JIRA_LIFECYCLE = '{not json'
        try { (Invoke-ReconcileCode @('reconcile', '--json', $Spec)) | Should -Be 0 }
        finally { Remove-Item Env:SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue }
    }

    It 'is inert at dispatch for a recorded event — no Jira call, no warning (FR-020)' {
        # The operator's decision lives in OUR file, so it survives the reinstall
        # that rewrote the registry to `enabled: true`. The guarantee is on the
        # EFFECT (no bridge step runs), not on the registry field, which upstream
        # rewrites unconditionally (research R5).
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $env:JIRA_CONFIG_DIR = $dir
        try {
            $null = Add-JiraHooksDisabled -LifecycleEvent 'after_specify' -ConfigDir $dir
            $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_specify'
            (Invoke-ReconcileCode @('reconcile', '--json', $Spec)) | Should -Be 0
        }
        finally {
            Remove-Item Env:SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue
            Remove-Item Env:JIRA_CONFIG_DIR -ErrorAction SilentlyContinue
            Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
        }
    }

    It 'an unreadable local binding inside a hook leaves the host exit 0 with the three lines plus one WARNING (007 FR-011)' {
        $cfgDir = Join-Path $Work '.specify/jira'
        New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $cfgDir 'config.local.yml') -Value "resolved_ids:`n  TEST:`n    this line has no delimiter" -NoNewline
        $env:JIRA_CONFIG_DIR = $cfgDir
        $env:SPEC_KIT_JIRA_HOOK_CONTEXT = '1'
        $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_plan'
        $sw = [System.IO.StringWriter]::new(); $se = [System.IO.StringWriter]::new()
        $oo = [Console]::Out; $oe = [Console]::Error
        [Console]::SetOut($sw); [Console]::SetError($se)
        try { $code = Invoke-JiraReconcile -Arguments @('reconcile', '--json', $Spec) }
        finally {
            [Console]::SetOut($oo); [Console]::SetError($oe)
            Remove-Item Env:JIRA_CONFIG_DIR -ErrorAction SilentlyContinue
            Remove-Item Env:SPEC_KIT_JIRA_HOOK_EVENT -ErrorAction SilentlyContinue
        }
        $text = $sw.ToString() + $se.ToString()
        [int]$code | Should -Be 0
        @([regex]::Matches($text, 'WARNING:')).Count | Should -Be 1
        $text | Should -Match 'cannot parse this line as a mapping entry'
    }

    It 'never brings the hook registry into existence (FR-022, SC-011)' {
        $ext = $env:SPEC_KIT_JIRA_EXTENSIONS_YML
        Remove-Item -Force $ext -ErrorAction SilentlyContinue
        $env:SPEC_KIT_JIRA_HOOK_CONTEXT = '1'
        $null = Invoke-ReconcileCode @('reconcile', '--json', $Spec)
        $null = Invoke-ReconcileCode @('reconcile', '--dry-run', '--json', $Spec)
        Test-Path -LiteralPath $ext | Should -BeFalse
    }
}

Describe 'T110b [Phase 8, 022] — a checklist-caused fault downgrades identically' {
    BeforeAll {
        $Root = Join-Path $PSScriptRoot '../../..'
        $ConfigCmdDir = Join-Path $Root 'scripts/powershell/commands'
        $Mock = Join-Path $Root 'tests/conformance/mock-jira'
        $Fixture = Join-Path $Root 'tests/conformance/fixtures/repo-with-config'
        Import-Module (Join-Path $Mock 'Mock.psm1') -Force
        # Same clobber, one layer deeper (030): commands/Config.psm1 -Force-
        # imports sink/jira/Discovery.psm1, which itself imports
        # sink/jira/Client.psm1 WITHOUT -Force (module-scope reuse, by
        # design — see project memory: powershell-import-force-clobbers-
        # caller-scope). That reuse means Discovery.psm1 stays bound to
        # WHATEVER Client.psm1 instance was first loaded in this process —
        # if an earlier-discovered file (CredentialFailClosed.Tests.ps1)
        # already poisoned that instance's Credentials.psm1 cache to
        # 'unresolved', config's own discovery call inherits the poison
        # even with JIRA_EMAIL/JIRA_API_TOKEN freshly set below. Force a
        # fresh Client.psm1 FIRST, before any Config.psm1 reimport, so
        # Discovery.psm1's later non-force nested import picks up the new
        # one instead of the stale one.
        Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/Client.psm1') -Force
        Import-Module (Join-Path $ConfigCmdDir 'Config.psm1') -Force
        # Config.psm1 -Force-imports lib/Config.psm1 internally, rebinding it into
        # its own scope — reimport here so this Describe's own use of it (and
        # Reconcile.psm1's) keeps working too (memory:
        # powershell-import-force-clobbers-caller-scope).
        Import-Module (Join-Path $Root 'scripts/powershell/lib/Config.psm1') -Force
        # Same clobber, the credential-cache direction (030): commands/Config.psm1
        # (imported once, above) carries its OWN binding to lib/Credentials.psm1
        # from THAT import. An earlier-run test file that already left the
        # credential cache in an 'unresolved' state leaves it there for this
        # Describe too — the cache check short-circuits before ever looking at
        # JIRA_API_TOKEN again, so setting it fresh in the It block below is not
        # enough on its own. Re-import commands/Config.psm1 -Force AGAIN, last
        # among the Config.psm1 reimports, so it is the most-recent binder of
        # lib/Credentials.psm1 (module instances are process-wide, not
        # per-Describe).
        Import-Module (Join-Path $ConfigCmdDir 'Config.psm1') -Force
        # Same clobber: EVERY Config.psm1 -Force reimport above also
        # -Force-imports sink/jira/Hierarchy.psm1 nested (non-Global),
        # re-scoping Get-JiraHierarchyMandatoryGate out of Reconcile.psm1's own
        # -Global registration. This must run LAST — after both Config.psm1
        # reimports above, not between them — or the second Config.psm1
        # reimport just re-breaks it again.
        Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/Hierarchy.psm1') -Force -Global

        function Invoke-CapturedConfig {
            param([string[]] $ArgList)
            $sw = [System.IO.StringWriter]::new()
            $orig = [Console]::Out
            [Console]::SetOut($sw)
            try { $null = Invoke-JiraConfig -Arguments $ArgList } finally { [Console]::SetOut($orig) }
        }
    }

    It "a checklist entry's privacy BLOCK never fails the host in hook context, and is reported as a warning" {
        $hookWork = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $hookWork -Force | Out-Null
        Copy-Item -Recurse (Join-Path $Fixture '.specify') (Join-Path $hookWork '.specify')
        $env:JIRA_CONFIG_DIR = Join-Path $hookWork '.specify/jira'
        # Explicit, not ambient: this Describe block has its own BeforeAll and
        # no BeforeEach, so it must not depend on what a DIFFERENT Describe
        # block's test happened to leave in the process environment.
        $env:JIRA_EMAIL = 'user@example.com'
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $cfgPath = Write-JiraMockConfig -Json '{"projects":{"COMP":"company"}}'
        $m = Start-JiraMock -ConfigPath $cfgPath
        $env:SPEC_KIT_JIRA_BASE_URL = $m.BaseUrl
        try {
            Invoke-CapturedConfig -ArgList @('config', '--child-type', 'COMP=Story', '--json')
            Add-Content -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.yml') -Value "task_mirror:`n  COMP: checklist"

            $specDir = Join-Path $hookWork 'specs/001-feature'
            New-Item -ItemType Directory -Path $specDir -Force | Out-Null
            $hspec = Join-Path $specDir 'spec.md'
            $htasks = Join-Path $specDir 'tasks.md'
            Set-Content -LiteralPath $hspec -Value @(
                '# Feature Specification: Hook Resilience Demo', '',
                'We need a working task tier.', '',
                '### User Story 1 - The first story (Priority: P1)', '',
                'As a user, I want the first story.', '',
                '- **Given** a thing', '- **When** it happens', '- **Then** it works'
            )
            Set-Content -LiteralPath $htasks -Value @(
                '# Tasks', '', '## Phase 3: User Story 1', '',
                '- [ ] T001 [US1] leak acme-corp.atlassian.net'
            )

            $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111 2222222222222222 3333333333333333'
            $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-feature'
            $env:SPEC_KIT_JIRA_REPO = 'acme/app'
            Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
            Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
            Remove-Item Env:\SPEC_KIT_JIRA_PROJECT_KEY -ErrorAction SilentlyContinue
            $env:SPEC_KIT_JIRA_HOOK_CONTEXT = '1'

            $sw = [System.IO.StringWriter]::new(); $se = [System.IO.StringWriter]::new()
            $oo = [Console]::Out; $oe = [Console]::Error
            [Console]::SetOut($sw); [Console]::SetError($se)
            try { $code = Invoke-JiraReconcile -Arguments @('reconcile', $hspec, '--json') }
            finally { [Console]::SetOut($oo); [Console]::SetError($oe) }
            $text = $sw.ToString() + $se.ToString()

            [int]$code | Should -Be 0
            $text | Should -Match 'WARNING:'
            $text | Should -Match ([regex]::Escape('the privacy guard blocked the write'))
            (@(Get-JiraMockCallLog -Mock $m) | Where-Object { $_ -match '^POST /rest/api/3/issue$' }).Count | Should -Be 0
        }
        finally {
            Stop-JiraMock -Mock $m
            Remove-Item -Recurse -Force $hookWork -ErrorAction SilentlyContinue
            Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue
            Remove-Item Env:\JIRA_EMAIL -ErrorAction SilentlyContinue
            Remove-Item Env:\JIRA_API_TOKEN -ErrorAction SilentlyContinue
            Remove-Item Env:\JIRA_CONFIG_DIR -ErrorAction SilentlyContinue
            Remove-Item Env:\SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
        }
    }
}
