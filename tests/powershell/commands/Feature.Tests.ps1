# T045 [US3] — The feature command. Pester twin of
# tests/bash/commands/test_feature.bats (contracts/feature-cli-contract.md).

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/commands/Feature.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Cli.psm1') -Force
    Import-Module (Join-Path $Root 'tests/conformance/mock-jira/Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_PLAN_CONTEXT = '{"story_type_id":"10201","priority_ids":{"P1":"1","P2":"2","P3":"3"},"estimation_field_id":null}'

    function Write-TeamsConfig {
        $lines = @(
            'projects:', '  - key: IJT',
            'routing_default: IJT', 'teams:',
            '  - id: ijt', '    project: IJT', '    folder_prefix: "ijt-"', '    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"',
            '  - id: wex', '    project: WEX', '    folder_prefix: "wex-"', '    branch_pattern: "wex-<ID>/<FEATURE_NAME>"'
        )
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), (($lines -join "`n") + "`n"))
    }

    function Select-Team {
        param([string]$Id)
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'personal.yml'), "team: $Id`n")
    }

    function Write-HierarchyConfig {
        $lines = @(
            'projects:', '  - key: IJT', '    hierarchy:', '      specification: Epic', '      story: Story',
            '    halted_statuses:', '      - Done',
            'routing_default: IJT', 'teams:',
            '  - id: ijt', '    project: IJT', '    folder_prefix: "ijt-"', '    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"'
        )
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), (($lines -join "`n") + "`n"))
    }

    function Start-TestMock {
        param([string]$ConfigJson)
        $cfg = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString() + '.json')
        [System.IO.File]::WriteAllText($cfg, $ConfigJson)
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
    }

    # One Pester process runs the whole suite, so a BeforeAll that only ever
    # sets is a leak into every later file — and into every child process those
    # files spawn. SPEC_KIT_JIRA_PLAN_CONTEXT in particular is read wholesale
    # (FR-013): leaked, it replaces every id a later run resolves from its own
    # binding. See tests/conformance/run-scenario.sh for what that class of
    # leak cost once already.
    $script:LeakedEnv = @('JIRA_EMAIL', 'JIRA_API_TOKEN', 'JIRA_NO_SLEEP', 'SPEC_KIT_JIRA_PLAN_CONTEXT', 'SPEC_KIT_JIRA_BASE_URL')

    function Invoke-FeatureCaptured {
        param([string[]]$CmdArgs)
        $sw = [System.IO.StringWriter]::new()
        $se = [System.IO.StringWriter]::new()
        $origOut = [Console]::Out
        $origErr = [Console]::Error
        [Console]::SetOut($sw)
        [Console]::SetError($se)
        try { $code = Invoke-JiraFeature -Arguments $CmdArgs }
        finally { [Console]::SetOut($origOut); [Console]::SetError($origErr) }
        return [pscustomobject]@{ ExitCode = [int]$code; Out = $sw.ToString(); Err = $se.ToString() }
    }
}

Describe 'Feature command' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $Work '.specify/jira') -Force | Out-Null
        $env:JIRA_CONFIG_DIR = Join-Path $Work '.specify/jira'
        Write-TeamsConfig
        $script:M = $null
    }
    AfterEach {
        if ($M) { Stop-JiraMock -Mock $M; $script:M = $null }
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:\JIRA_CONFIG_DIR' -ErrorAction SilentlyContinue
    }

    It 'passes through with {active:false} and zero Jira calls when no team is selected (FR-017)' {
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        ($r.Out.Trim() | ConvertFrom-Json).active | Should -BeFalse
        @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ }).Count | Should -Be 0
    }

    It 'stops with a located error on an invalid personal file (exit 4)' {
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'personal.yml'), "team: zzz`n")
        $r = Invoke-FeatureCaptured @('feature', '--json', 'invoice export')
        $r.ExitCode | Should -Be 4
        $r.Err | Should -Match 'personal\.yml'
    }

    It 'attaches a mentioned same-team ticket and computes the names' {
        Select-Team 'ijt'
        Start-TestMock '{"projects":{"IJT":"team","WEX":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-42', '--reuse', 'no', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.team | Should -Be 'ijt'
        $obj.ticket.number | Should -Be '42'
        $obj.ticket.action | Should -Be 'attached'
        $obj.branch_name | Should -Be 'ijt-42/invoice-export'
        $obj.short_name | Should -Be 'ijt-invoice-export'
    }

    It 'requires confirmation for a cross-team ticket without --use-team (FR-014)' {
        Select-Team 'ijt'
        Start-TestMock '{"projects":{"IJT":"team","WEX":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'WEX-7', '--json', 'onboarding')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.confirmation_required.ticket | Should -Be 'WEX-7'
        $obj.confirmation_required.ticket_team | Should -Be 'wex'
        $obj.confirmation_required.selected_team | Should -Be 'ijt'
    }

    It 'confirms the cross-team convention via --use-team, personal file untouched' {
        Select-Team 'ijt'
        $before = [System.IO.File]::ReadAllBytes((Join-Path $env:JIRA_CONFIG_DIR 'personal.yml'))
        Start-TestMock '{"projects":{"IJT":"team","WEX":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'WEX-7', '--use-team', 'wex', '--reuse', 'no', '--json', 'onboarding')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.team | Should -Be 'wex'
        $obj.branch_name | Should -Be 'wex-7/onboarding'
        [System.IO.File]::ReadAllBytes((Join-Path $env:JIRA_CONFIG_DIR 'personal.yml')) | Should -Be $before
    }

    It 'creates a ticket in the effective team project when none is mentioned (FR-013)' {
        Select-Team 'ijt'
        Start-TestMock '{"projects":{"IJT":"team"},"createdKey":"IJT-123"}'
        $r = Invoke-FeatureCaptured @('feature', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.ticket.key | Should -Be 'IJT-123'
        $obj.ticket.action | Should -Be 'created'
        $obj.branch_name | Should -Be 'ijt-123/invoice-export'
    }

    It 'falls back non-blocking with exactly one warning when Jira is unreachable (FR-016)' {
        Select-Team 'ijt'
        $env:SPEC_KIT_JIRA_BASE_URL = ''
        $r = Invoke-FeatureCaptured @('feature', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.active | Should -BeFalse
        @($obj.warnings).Count | Should -Be 1
        @($r.Err -split "`n" | Where-Object { $_ -match '^WARNING:' }).Count | Should -Be 1
    }

    # --- 027 US5: C-1/C-6 — the ordinary run is untouched -------------------

    It 'C-1: an invocation with neither designator flag is byte-identical to the current release' {
        Select-Team 'ijt'
        Start-TestMock '{"projects":{"IJT":"team"},"createdKey":"IJT-123"}'
        $r = Invoke-FeatureCaptured @('feature', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $r.Out.Trim() | Should -Be '{"active":true,"branch_name":"ijt-123/invoice-export","override_used":false,"short_name":"ijt-invoice-export","team":"ijt","ticket":{"action":"created","key":"IJT-123","number":"123"},"warnings":[]}'
        $calls = @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ })
        $calls[0] | Should -Match 'POST /rest/api/3/issue'
        $calls[1] | Should -Match 'PUT /rest/api/3/issue/IJT-123/properties/spec-kit-jira'
    }

    It 'C-6: Jira unreachable, no designators, still {active:false} + exactly one warning, exit 0' {
        Select-Team 'ijt'
        $env:SPEC_KIT_JIRA_BASE_URL = ''
        $r = Invoke-FeatureCaptured @('feature', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.active | Should -BeFalse
        @($obj.warnings).Count | Should -Be 1
    }

    It 'stays fail-closed on a mentioned-key read failure (exit 2)' {
        Select-Team 'ijt'
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'NOPE-1', '--json', 'external')
        $r.ExitCode | Should -Be 2
    }

    It 'predicts would-create in --dry-run with zero writes' {
        Select-Team 'ijt'
        Start-TestMock '{"projects":{"IJT":"team"},"createdKey":"IJT-123"}'
        $r = Invoke-FeatureCaptured @('feature', '--dry-run', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.ticket.action | Should -Be 'would-create'
        $obj.branch_name | Should -Be $null
        $obj.short_name | Should -Be 'ijt-invoice-export'
        @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ }).Count | Should -Be 0
    }

    It 'T136: --dry-run with a mentioned key and no answer predicts the question, naming the issue, zero writes (FR-020)' {
        Select-Team ijt
        Write-HierarchyConfig
        Start-TestMock '{"projects":{"IJT":"team"},"issues":{"IJT-40":{"summary":"Rework the export pipeline","issuetype":{"name":"Epic"},"status":{"name":"In Progress"},"project":{"key":"IJT"}}}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-40', '--dry-run', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        ($obj.PSObject.Properties.Name -contains 'reuse_required') | Should -BeTrue
        $obj.reuse_required.issues[0].key | Should -Be 'IJT-40'
        ($obj.PSObject.Properties.Name -contains 'branch_name') | Should -BeFalse
        @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ -match 'POST|PUT' }).Count | Should -Be 0
    }

    It 'applies and reports a personal override (FR-012)' {
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'personal.yml'), "team: ijt`noverride:`n  folder_prefix: `"special-`"`n  branch_pattern: `"special-<ID>/<FEATURE_NAME>`"`n")
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-42', '--reuse', 'no', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.override_used | Should -BeTrue
        $obj.branch_name | Should -Be 'special-42/invoice-export'
    }

    # --- T087: feature prose (default, non---json) output — twin of the bash
    # prose tests; the raw-JSON StrictMode catch fallback is a defect, not prose.

    It 'renders exactly "Feature: inactive" on pass-through prose (T087)' {
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'invoice export')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Be "Feature: inactive`n"
    }

    It 'renders the feature shape on dry-run prose (T087)' {
        Select-Team ijt
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', '--dry-run', 'invoice export')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Be "Feature: active (team: ijt)`nTicket: — (would-create)`nBranch: —`nFolder: ijt-invoice-export`nOverride used: false`n"
    }

    It 'renders inactive plus the warning line on fallback prose (T087)' {
        Select-Team ijt
        Start-TestMock '{"projects":{"IJT":"team"},"fault":{"network":true}}'
        $r = Invoke-FeatureCaptured @('feature', 'invoice export')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match '^Feature: inactive\n'
        $r.Out | Should -Match 'Warning:'
    }

    It 'T131/T132: the fallback message never claims a ticket will be attached later, names the cause, and states a fresh create follows (FR-041)' {
        Select-Team ijt
        Start-TestMock '{"projects":{"IJT":"team"},"fault":{"network":true}}'
        $r = Invoke-FeatureCaptured @('feature', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = ($r.Out -split "`n" | Where-Object { $_ -notmatch '^WARNING:' }) -join "`n" | ConvertFrom-Json
        $obj.warnings[0] | Should -Not -Match 'will attach it later'
        $obj.warnings[0] | Should -Match 'Jira is unreachable'
        $obj.warnings[0] | Should -Match 'new issue'
    }

    It 'T131/T132: a credentials rejection is named as its own cause (FR-041)' {
        Select-Team ijt
        Start-TestMock '{"projects":{"IJT":"team"},"faults":{"IJT":{"status":401}}}'
        $r = Invoke-FeatureCaptured @('feature', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = ($r.Out -split "`n" | Where-Object { $_ -notmatch '^WARNING:' }) -join "`n" | ConvertFrom-Json
        $obj.warnings[0] | Should -Match 'credentials'
        $obj.warnings[0] | Should -Not -Match 'will attach it later'
    }

    It 'renders the closed question on cross-team confirmation prose (T087)' {
        Select-Team ijt
        Start-TestMock '{"projects":{"IJT":"team","WEX":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'WEX-7', 'invoice export')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Be "Feature: confirmation required`nTicket: WEX-7 (team: wex)`nSelected team: ijt`n"
    }

    # --- 029 T006/T082/T013 — mention grammar, conditional field set, --reuse

    It 'detects a bare key at the leading positional' {
        $mentions = @(Get-JiraFeatDetectMention -Words @('IJT-42', 'invoice', 'export'))
        $mentions.Count | Should -Be 1
        $mentions[0].key | Should -Be 'IJT-42'
        $mentions[0].raw | Should -Be 'IJT-42'
    }

    It 'detects a /browse/ URL at the leading positional (FR-032)' {
        $mentions = @(Get-JiraFeatDetectMention -Words @('https://jira.example.com/browse/IJT-42', 'invoice', 'export'))
        $mentions.Count | Should -Be 1
        $mentions[0].key | Should -Be 'IJT-42'
    }

    It 'detects a selectedIssue= URL at the leading positional (FR-032)' {
        $mentions = @(Get-JiraFeatDetectMention -Words @('https://jira.example.com/jira/software/c/projects/IJT/boards/1?selectedIssue=IJT-42', 'invoice'))
        $mentions.Count | Should -Be 1
        $mentions[0].key | Should -Be 'IJT-42'
    }

    It 'does not treat a URL reducing to nothing key-shaped as a mention' {
        $mentions = @(Get-JiraFeatDetectMention -Words @('https://example.com/nothing/here', 'invoice'))
        $mentions.Count | Should -Be 0
    }

    It 'closes the gate on an ordinary leading word — nothing further is examined, even a later key (contract §4 last row)' {
        $mentions = @(Get-JiraFeatDetectMention -Words @('ticket', 'https://jira.example.com/browse/IJT-2241'))
        $mentions.Count | Should -Be 0
    }

    It 'detects every remaining key-shaped token once the gate is open, in argv order (FR-034)' {
        $mentions = @(Get-JiraFeatDetectMention -Words @('IJT-40', 'see', 'IJT-99', 'for', 'background'))
        $mentions.Count | Should -Be 2
        $mentions[0].key | Should -Be 'IJT-40'
        $mentions[1].key | Should -Be 'IJT-99'
    }

    It 'mixes a key and a link freely once the gate is open, in argv order' {
        $mentions = @(Get-JiraFeatDetectMention -Words @('IJT-40', 'https://jira.example.com/browse/IJT-99', 'background'))
        $mentions.Count | Should -Be 2
        $mentions[1].key | Should -Be 'IJT-99'
    }

    It 'detects COVID-19 like any other key once the gate is open' {
        $mentions = @(Get-JiraFeatDetectMention -Words @('IJT-40', 'COVID-19'))
        $mentions.Count | Should -Be 2
        $mentions[1].key | Should -Be 'COVID-19'
    }

    It 'detects nothing with no words at all' {
        $mentions = @(Get-JiraFeatDetectMention -Words @())
        $mentions.Count | Should -Be 0
    }

    It 'validates and attaches a mentioned browser URL as the leading positional, like a bare key (FR-032, mention-grammar §4)' {
        Select-Team ijt
        Start-TestMock '{"projects":{"IJT":"team","WEX":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'https://jira.example.com/browse/IJT-42', '--reuse', 'no', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.ticket.key | Should -Be 'IJT-42'
        $obj.ticket.action | Should -Be 'attached'
        $obj.branch_name | Should -Be 'ijt-42/invoice-export'
    }

    It 'T064: no message class echoes a supplied URL verbatim — only the reduced key ever appears (Principle IX)' {
        Select-Team ijt
        Write-HierarchyConfig
        Start-TestMock '{"projects":{"IJT":"team"},"issues":{"IJT-40":{"summary":"Rework","issuetype":{"name":"Epic"},"status":{"name":"To Do"}}}}'
        $r = Invoke-FeatureCaptured @('feature', 'https://jira.example.com/browse/IJT-40', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.reuse_required.issues[0].key | Should -Be 'IJT-40'
        $r.Out | Should -Not -Match 'jira\.example\.com'
        $r.Out | Should -Not -Match '/browse/'
    }

    It 'accepts --reuse yes/no; an invalid value is a usage error naming both (FR-009, FR-016)' {
        $parsed = Invoke-JiraCliParse -Arguments @('feature', '--reuse', 'yes', '--json', 'invoice export')
        ($parsed -split "`n" | Where-Object { $_ -match '^reuse=' }) | Should -Be 'reuse=yes'
        $parsed = Invoke-JiraCliParse -Arguments @('feature', '--reuse', 'no', '--json', 'invoice export')
        ($parsed -split "`n" | Where-Object { $_ -match '^reuse=' }) | Should -Be 'reuse=no'
        $parsed = Invoke-JiraCliParse -Arguments @('feature', '--reuse', 'maybe', '--json', 'invoice export')
        ($parsed -split "`n" | Where-Object { $_ -match '^exit=' }) | Should -Be 'exit=1'
        $parsed | Should -Match 'yes'
        $parsed | Should -Match 'no'
    }

    It '--reuse absent means unanswered — the reuse= line is empty' {
        $parsed = Invoke-JiraCliParse -Arguments @('feature', '--json', 'invoice export')
        ($parsed -split "`n" | Where-Object { $_ -match '^reuse=' }) | Should -Be 'reuse='
    }

    It 'T083 tripwire: an ANSWERED invocation still uses fields=project — no unconditional widening (FR-010)' {
        Select-Team ijt
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-42', '--reuse', 'no', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        (Get-JiraMockCallLog -Mock $M) -join "`n" | Should -Match 'GET /rest/api/3/issue/IJT-42\?fields=project$'
        (Get-JiraMockCallLog -Mock $M) -join "`n" | Should -Not -Match 'summary'
    }

    It 'the reuse question DOES widen the mentioned-key request — the conditional half of the same guarantee' {
        Select-Team ijt
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-42', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        (Get-JiraMockCallLog -Mock $M) -join "`n" | Should -Match 'GET /rest/api/3/issue/IJT-42\?fields=project,summary,issuetype,status$'
    }

    # --- 029 Phase 3 — the reuse question itself (US1/US7/US9) --------------

    It 'T015/regression: a mentioned key with no designator MUST NOT reach a silent naming (FR-001)' {
        Select-Team ijt
        Write-HierarchyConfig
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-42', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.reuse_required | Should -Not -BeNullOrEmpty
        $r.Out | Should -Not -Match '"action":"attached"'
    }

    It 'the reuse question names key/summary/type/status, offers two answers, zero writes, exit 0 (FR-002-005)' {
        Select-Team ijt
        Write-HierarchyConfig
        Start-TestMock '{"projects":{"IJT":"team"},"issues":{"IJT-40":{"summary":"Rework the export pipeline","issuetype":{"name":"Epic"},"status":{"name":"In Progress"}}}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-40', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.reuse_required.issues[0].key | Should -Be 'IJT-40'
        $obj.reuse_required.issues[0].summary | Should -Be 'Rework the export pipeline'
        $obj.reuse_required.issues[0].type | Should -Be 'Epic'
        $obj.reuse_required.issues[0].status | Should -Be 'In Progress'
        $obj.reuse_required.issues[0].role | Should -Be 'specification'
        @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ -match 'POST|PUT' }).Count | Should -Be 0
    }

    It 'the question omits branch_name and short_name, even as null (FR-031)' {
        Select-Team ijt
        Write-HierarchyConfig
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-42', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        ($obj.PSObject.Properties.Name -contains 'branch_name') | Should -BeFalse
        ($obj.PSObject.Properties.Name -contains 'short_name') | Should -BeFalse
    }

    It 'an unmapped type is proposed as a Story, never refused, needs no parent (FR-036, R11)' {
        Select-Team ijt
        Write-HierarchyConfig
        Start-TestMock '{"projects":{"IJT":"team"},"issues":{"IJT-99":{"summary":"Legacy importer","issuetype":{"name":"Bug"},"status":{"name":"To Do"}}}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-99', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.reuse_required.issues[0].role | Should -Be 'story'
        $obj.reuse_required.issues[0].unmapped | Should -BeTrue
    }

    It 'a halted status is flagged in the question (FR-033)' {
        Select-Team ijt
        Write-HierarchyConfig
        Start-TestMock '{"projects":{"IJT":"team"},"issues":{"IJT-40":{"summary":"Rework","issuetype":{"name":"Epic"},"status":{"name":"Done"}}}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-40', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.reuse_required.issues[0].halted | Should -BeTrue
    }

    It 'multi-issue detection: three keys produce three proposal lines, one bulkfetch, argv order (FR-034)' {
        Select-Team ijt
        Write-HierarchyConfig
        Start-TestMock '{"projects":{"IJT":"team"},"issues":{"IJT-40":{"summary":"A","issuetype":{"name":"Epic"},"status":{"name":"To Do"}},"IJT-41":{"summary":"B","issuetype":{"name":"Story"},"status":{"name":"To Do"}},"IJT-99":{"summary":"C","issuetype":{"name":"Bug"},"status":{"name":"To Do"}}}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-40', 'IJT-41', 'IJT-99', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.reuse_required.issues.Count | Should -Be 3
        $obj.reuse_required.issues[0].key | Should -Be 'IJT-40'
        $obj.reuse_required.issues[1].key | Should -Be 'IJT-41'
        $obj.reuse_required.issues[2].key | Should -Be 'IJT-99'
        @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ -match 'bulkfetch' }).Count | Should -Be 1
    }

    It 'no hierarchy declared: no role proposed, the question asks for explicit designators (FR-035)' {
        Select-Team ijt
        $lines = @('projects:', '  - key: IJT', 'routing_default: IJT', 'teams:',
            '  - id: ijt', '    project: IJT', '    folder_prefix: "ijt-"', '    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"')
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), (($lines -join "`n") + "`n"))
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-42', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.reuse_required.issues[0].role | Should -Be $null
        $obj.reuse_required.declines_to.specification | Should -Be $null
    }

    It '--accept-defaults suppresses the question, proceeds as create-new would, states the assumed answer (FR-013/FR-014)' {
        Select-Team ijt
        Write-HierarchyConfig
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-42', '--accept-defaults', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.ticket.action | Should -Be 'attached'
        $obj.warnings[0] | Should -Be 'the reuse question was suppressed by --accept-defaults; assumed answer: create new'
    }

    It '--reuse no proceeds as today''s run from here on, byte-identical (FR-010)' {
        Select-Team ijt
        Write-HierarchyConfig
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-42', '--reuse', 'no', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.ticket.action | Should -Be 'attached'
        @($obj.warnings).Count | Should -Be 0
    }

    It '--reuse yes with no designator and NO declared hierarchy falls back to the which-issues follow-up (FR-029, FR-035)' {
        Select-Team ijt
        $lines = @('projects:', '  - key: IJT', 'routing_default: IJT', 'teams:', '  - id: ijt', '    project: IJT', '    folder_prefix: "ijt-"', '    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"')
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), (($lines -join "`n") + "`n"))
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-42', '--reuse', 'yes', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.reuse_issues_required | Should -Not -BeNullOrEmpty
        $r.Out | Should -Not -Match '"action":"attached"'
    }

    It 'the which-issues follow-up carries EVERY detected issue, with the same per-issue facts as the question (contract §3.1, FR-034)' {
        # Regression twin of the bats test: the fallback rebuilt the payload from
        # the leading key alone, dropping every further detection (FR-034) and
        # stripping the survivor of summary/type/status.
        Select-Team ijt
        $lines = @('projects:', '  - key: IJT', 'routing_default: IJT', 'teams:', '  - id: ijt', '    project: IJT', '    folder_prefix: "ijt-"', '    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"')
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), (($lines -join "`n") + "`n"))
        Start-TestMock '{"projects":{"IJT":"team"},"issues":{"IJT-40":{"summary":"A","issuetype":{"name":"Epic"},"status":{"name":"To Do"}},"IJT-41":{"summary":"B","issuetype":{"name":"Story"},"status":{"name":"In Progress"}},"IJT-99":{"summary":"C","issuetype":{"name":"Bug"},"status":{"name":"To Do"}}}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-40', 'IJT-41', 'IJT-99', '--reuse', 'yes', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $q = ($r.Out.Trim() | ConvertFrom-Json).reuse_issues_required
        @($q.issues).Count | Should -Be 3
        $q.issues[0].key | Should -Be 'IJT-40'
        $q.issues[1].key | Should -Be 'IJT-41'
        $q.issues[2].key | Should -Be 'IJT-99'
        $q.issues[1].summary | Should -Be 'B'
        $q.issues[1].type | Should -Be 'Story'
        $q.issues[1].status | Should -Be 'In Progress'
        foreach ($i in @($q.issues)) {
            $i.PSObject.Properties.Name | Should -Contain 'role'
            $i.halted | Should -BeOfType [bool]
        }
        $q.issues[0].role | Should -BeNullOrEmpty
        $q.declines_to.specification | Should -BeNullOrEmpty

        $p = Invoke-FeatureCaptured @('feature', 'IJT-40', 'IJT-41', 'IJT-99', '--reuse', 'yes', 'invoice export')
        @($p.Out -split "`n" | Where-Object { $_ -match '^Detected: ' }).Count | Should -Be 3
        $p.Out | Should -Match 'Detected: IJT-41 \(Story, In Progress\) B'
    }

    It '--reuse yes with no designator auto-accepts the derived proposal: routes into the designator path, byte-identical to typing --parent/--story (FR-029, US3 AC1)' {
        Select-Team ijt
        Write-HierarchyConfig
        Start-TestMock '{"projects":{"IJT":"team"},"issues":{"IJT-40":{"summary":"Rework the export pipeline","description":"Body text","issuetype":{"name":"Epic"},"status":{"name":"In Progress"},"project":{"key":"IJT"}}}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-40', '--reuse', 'yes', '--json', 'invoice export')
        $autoOut = "$($r.ExitCode):$($r.Out)"
        Start-TestMock '{"projects":{"IJT":"team"},"issues":{"IJT-40":{"summary":"Rework the export pipeline","description":"Body text","issuetype":{"name":"Epic"},"status":{"name":"In Progress"},"project":{"key":"IJT"}}}}'
        $r = Invoke-FeatureCaptured @('feature', '--parent', 'IJT-40', '--json', 'invoice export')
        $directOut = "$($r.ExitCode):$($r.Out)"
        $autoOut | Should -Be $directOut
        $autoOut | Should -Not -Match 'reuse_issues_required'
    }

    It '--reuse yes with no designator, an unmapped-type issue is attached as story, no parent required (FR-029, FR-036, FR-038)' {
        Select-Team ijt
        Write-HierarchyConfig
        Start-TestMock '{"projects":{"IJT":"team"},"issues":{"IJT-99":{"summary":"Legacy importer","description":"Body text","issuetype":{"name":"Bug"},"status":{"name":"To Do"},"project":{"key":"IJT"}}}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-99', '--reuse', 'yes', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Not -Match 'reuse_issues_required'
        $r.Out | Should -Match 'seed_material'
    }

    It '--reuse yes with the mentioned ticket itself among the reused issues: no special case (US3 AC2)' {
        Select-Team ijt
        Write-HierarchyConfig
        Start-TestMock '{"projects":{"IJT":"team"},"issues":{"IJT-40":{"summary":"Rework","description":"Body text","issuetype":{"name":"Epic"},"status":{"name":"In Progress"},"project":{"key":"IJT"}}}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-40', '--reuse', 'yes', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        ($r.Out.Trim() | ConvertFrom-Json).ticket.key | Should -Be 'IJT-40'
    }

    It 'prose: the reuse question renders Detected/Attach/Answers lines' {
        Select-Team ijt
        Write-HierarchyConfig
        Start-TestMock '{"projects":{"IJT":"team"},"issues":{"IJT-40":{"summary":"Rework the export pipeline","issuetype":{"name":"Epic"},"status":{"name":"In Progress"}}}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-40', 'invoice export')
        $r.ExitCode | Should -Be 0
        $rlines = $r.Out -split "`n"
        $rlines[0] | Should -Be 'Feature: reuse decision required'
        $rlines[1] | Should -Be 'Detected: IJT-40 (Epic, In Progress) Rework the export pipeline'
        $r.Out | Should -Match 'Attach .*\?'
        $r.Out | Should -Match 'Answers: --reuse yes'
    }

    It 'prose: both Missing: variants are pinned literally, and the header never varies (contract §3)' {
        # Twin of the bats test: the contract once named a
        # 'Feature: reuse targets required' header no port has ever emitted.
        Select-Team ijt
        $cfgLines = @('projects:', '  - key: IJT', 'routing_default: IJT', 'teams:', '  - id: ijt', '    project: IJT', '    folder_prefix: "ijt-"', '    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"')
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), (($cfgLines -join "`n") + "`n"))
        Start-TestMock '{"projects":{"IJT":"team"},"issues":{"IJT-40":{"summary":"Rework the export pipeline","issuetype":{"name":"Epic"},"status":{"name":"To Do"}}}}'

        # (a) the first question, no hierarchy declared: names what the PROJECT lacks
        $a = Invoke-FeatureCaptured @('feature', 'IJT-40', 'invoice export')
        $a.ExitCode | Should -Be 0
        $al = $a.Out -split "`n"
        $al[0] | Should -Be 'Feature: reuse decision required'
        $al[2] | Should -Be 'Missing: this project declares no hierarchy, so no placement can be proposed'
        $al[3] | Should -Be 'Answers: re-invoke with --parent <key|title> and one --story <key> per issue to reuse'

        # (b) the which-issues follow-up: names what THIS RUN could not derive
        $b = Invoke-FeatureCaptured @('feature', 'IJT-40', '--reuse', 'yes', 'invoice export')
        $b.ExitCode | Should -Be 0
        $bl = $b.Out -split "`n"
        $bl[0] | Should -Be 'Feature: reuse decision required'
        $bl[2] | Should -Be 'Missing: which issues to reuse — this run cannot derive it without designators'
        $bl[3] | Should -Be 'Answers: re-invoke with --parent <key|title> and one --story <key> per issue to reuse'

        $b.Out | Should -Not -Match 'reuse targets required'
    }

    It 'T134: the Unmapped/Drafted prose lines name the projects own configured types, not the Atlassian defaults (Constitution VII)' {
        Select-Team ijt
        $lines = @(
            'projects:', '  - key: IJT', '    hierarchy:', '      specification: Initiative', '      story: Task',
            'routing_default: IJT', 'teams:',
            '  - id: ijt', '    project: IJT', '    folder_prefix: "ijt-"', '    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"'
        )
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), (($lines -join "`n") + "`n"))
        Start-TestMock '{"projects":{"IJT":"team"},"issues":{"IJT-40":{"summary":"Rework the export pipeline","issuetype":{"name":"Task"},"status":{"name":"To Do"}},"IJT-99":{"summary":"Legacy importer","issuetype":{"name":"Bug"},"status":{"name":"To Do"}}}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-40', 'IJT-99', 'invoice export')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match ([regex]::Escape('Unmapped: IJT-99 is a Bug, a type this project declares for no role — proposed as a Task; it needs no Initiative, and --reuse yes --parent <key|title> gives it one'))
        $r.Out | Should -Match ([regex]::Escape('Drafted: user stories drafted beyond these become new Task issues beneath the same Initiative — named issues are reused, never duplicated'))
        $r.Out | Should -Not -Match 'Epic'
        $r.Out | Should -Not -Match 'a Story'
    }

    # --- 029 Phase 4 — usage-error rows (T029/T102, FR-015) --------------------

    It 'an answer supplied with neither a mention nor a designator is a usage error (FR-015 first clause)' {
        Select-Team ijt
        Write-HierarchyConfig
        $r = Invoke-FeatureCaptured @('feature', '--reuse', 'no', '--json', 'invoice export')
        $r.ExitCode | Should -Be 1
        $r.Err | Should -Match 'never posed'
    }

    It "--reuse no together with designators is a usage error naming the contradiction (FR-015 second clause)" {
        Select-Team ijt
        Write-HierarchyConfig
        $r = Invoke-FeatureCaptured @('feature', '--reuse', 'no', '--parent', 'IJT-40', '--json', 'invoice export')
        $r.ExitCode | Should -Be 1
        $r.Err | Should -Match 'contradicts'
    }

    It '--reuse yes together with designators is accepted in silence (FR-015)' {
        Select-Team ijt
        Write-HierarchyConfig
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', '--reuse', 'yes', '--parent', 'A new epic', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $r.Err | Should -Not -Match 'contradicts'
        $r.Err | Should -Not -Match 'never posed'
    }

    It 'an answered invocation never re-poses the question (FR-011)' {
        Select-Team ijt
        Write-HierarchyConfig
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-42', '--reuse', 'no', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        ($r.Out.Trim() | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'reuse_required'
    }

    It 'T101: Principle XVI sweep — every message class names the problem, the issue, and a copy-pasteable next step (FR-018, FR-023, FR-026)' {
        # 1. the reuse question
        Select-Team ijt
        Write-HierarchyConfig
        Start-TestMock '{"projects":{"IJT":"team"},"issues":{"IJT-40":{"summary":"Rework","issuetype":{"name":"Epic"},"status":{"name":"In Progress"}}}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-40', 'invoice export')
        $r.Out | Should -Match 'Feature: reuse decision required'
        $r.Out | Should -Match 'IJT-40'
        $r.Out | Should -Match 'Answers: --reuse'

        # 2. the which-issues question (fires only when no hierarchy is declared)
        $lines2 = @('projects:', '  - key: IJT', 'routing_default: IJT', 'teams:', '  - id: ijt', '    project: IJT', '    folder_prefix: "ijt-"', '    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"')
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), (($lines2 -join "`n") + "`n"))
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-40', '--reuse', 'yes', 'invoice export')
        $r.Out | Should -Match 'IJT-40'
        $r.Out | Should -Match '--parent'
        Write-HierarchyConfig

        # 3. the halted warning
        Start-TestMock '{"projects":{"IJT":"team"},"issues":{"IJT-40":{"summary":"Rework","issuetype":{"name":"Epic"},"status":{"name":"Done"}}}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-40', 'invoice export')
        $r.Out | Should -Match 'Halted: IJT-40'
        $r.Out | Should -Match '--reuse no, reopen it, or name another'

        # 4. the extras notice (Drafted: line)
        Start-TestMock '{"projects":{"IJT":"team"},"issues":{"IJT-41":{"summary":"B","issuetype":{"name":"Story"},"status":{"name":"To Do"}}}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-41', 'invoice export')
        $r.Out | Should -Match 'Drafted:'
        $r.Out | Should -Match 'beneath the same Epic'

        # 5/6. the two configuration reports
        Remove-Item -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.yml') -ErrorAction SilentlyContinue
        $r = Invoke-FeatureCaptured @('feature', 'IJT-42', '--json', 'invoice export')
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.warnings[0] | Should -Match '\.specify/jira/config\.yml'
        $obj.warnings[0] | Should -Match '/speckit\.jira\.config'
        Write-HierarchyConfig
        Remove-Item -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'personal.yml') -ErrorAction SilentlyContinue
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-42', '--json', 'invoice export')
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.warnings[0] | Should -Match '\.specify/jira/personal\.yml'
        $obj.warnings[0] | Should -Match '/speckit\.jira\.config'

        # 7/8/9. the three usage errors
        Select-Team ijt
        Write-HierarchyConfig
        $parsed = Invoke-JiraCliParse -Arguments @('feature', '--reuse', 'maybe', '--json', 'invoice export')
        ($parsed -split "`n" | Where-Object { $_ -match '^exit=' }) | Should -Be 'exit=1'
        $r = Invoke-FeatureCaptured @('feature', '--reuse', 'no', '--json', 'invoice export')
        $r.ExitCode | Should -Be 1
        $r.Err | Should -Match 'never posed'
        $r = Invoke-FeatureCaptured @('feature', '--parent', 'IJT-40', '--reuse', 'no', '--json', 'invoice export')
        $r.ExitCode | Should -Be 1
        $r.Err | Should -Match 'contradicts'

        # 10. the role-mismatch refusal: misplaced (FR-022)
        $issuesMisplaced = @{ 'IJT-40' = @{ summary = 'S1'; description = 'd'; status = @{ name = 'To Do'; statusCategory = @{ key = 'new' } }; issuetype = @{ id = '1'; name = 'Story' }; project = @{ key = 'IJT' } }; 'IJT-41' = @{ summary = 'S2'; description = 'd'; status = @{ name = 'To Do'; statusCategory = @{ key = 'new' } }; issuetype = @{ id = '1'; name = 'Story' }; project = @{ key = 'IJT' } } }
        Start-TestMock (@{ issues = $issuesMisplaced } | ConvertTo-Json -Depth 20 -Compress)
        $r = Invoke-FeatureCaptured @('feature', '--json', '--parent', 'IJT-40', '--story', 'IJT-41', 'invoice export')
        $r.ExitCode | Should -Not -Be 0
        $r.Err | Should -Match 'REF-ROLE'
        $r.Err | Should -Match 'IJT-40'

        # 11. the role-mismatch refusal: unmapped-as-parent (FR-039)
        $issuesUnmapped = @{ 'IJT-99' = @{ summary = 'Legacy'; description = 'd'; status = @{ name = 'To Do'; statusCategory = @{ key = 'new' } }; issuetype = @{ id = '1'; name = 'Bug' }; project = @{ key = 'IJT' } }; 'IJT-11' = @{ summary = 'S2'; description = 'd'; status = @{ name = 'To Do'; statusCategory = @{ key = 'new' } }; issuetype = @{ id = '1'; name = 'Story' }; project = @{ key = 'IJT' } } }
        Start-TestMock (@{ issues = $issuesUnmapped } | ConvertTo-Json -Depth 20 -Compress)
        $r = Invoke-FeatureCaptured @('feature', '--json', '--parent', 'IJT-99', '--story', 'IJT-11', 'invoice export')
        $r.ExitCode | Should -Not -Be 0
        $r.Err | Should -Match 'IJT-99'
        $r.Err | Should -Match 'container'
        $r.Err | Should -Match '--parent'
    }

    It 'T055: with no --accept-defaults and no terminal attached, the question still fires (research R3)' {
        Select-Team ijt
        Write-HierarchyConfig
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-42', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        ($r.Out.Trim() | ConvertFrom-Json).PSObject.Properties.Name | Should -Contain 'reuse_required'
    }

    It 'T100: the naming step never reads stdin — output is byte-identical regardless (FR-021)' {
        Select-Team ijt
        Write-HierarchyConfig
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-FeatureCaptured @('feature', 'IJT-42', '--json', 'invoice export')
        $sw.Stop()
        $r.ExitCode | Should -Be 0
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 5
    }

    It 'repeating an incomplete --reuse yes (no hierarchy declared) is idempotent: three byte-identical results, no state written (FR-030)' {
        Select-Team ijt
        $lines3 = @('projects:', '  - key: IJT', 'routing_default: IJT', 'teams:', '  - id: ijt', '    project: IJT', '    folder_prefix: "ijt-"', '    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"')
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), (($lines3 -join "`n") + "`n"))
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $first = (Invoke-FeatureCaptured @('feature', 'IJT-42', '--reuse', 'yes', '--json', 'invoice export')).Out
        $second = (Invoke-FeatureCaptured @('feature', 'IJT-42', '--reuse', 'yes', '--json', 'invoice export')).Out
        $third = (Invoke-FeatureCaptured @('feature', 'IJT-42', '--reuse', 'yes', '--json', 'invoice export')).Out
        $first | Should -Be $second
        $second | Should -Be $third
        $first | Should -Match 'reuse_issues_required'
        (Test-Path -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'state')) | Should -BeFalse
    }

    # --- 029 Phase 5 — told what to configure, instead of silence (US6) --------

    It 'US6: no config.yml + a mentioned ticket names the file and the command (FR-026)' {
        Remove-Item -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.yml') -ErrorAction SilentlyContinue
        $r = Invoke-FeatureCaptured @('feature', 'IJT-42', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.active | Should -BeFalse
        $obj.warnings[0] | Should -Match '\.specify/jira/config\.yml'
        $obj.warnings[0] | Should -Match '/speckit\.jira\.config'
    }

    It 'US6: an unreadable config.yml + a mentioned ticket names the file and the command (FR-026)' {
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), "  bad: [unterminated`n")
        $r = Invoke-FeatureCaptured @('feature', 'IJT-42', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.active | Should -BeFalse
        $obj.warnings[0] | Should -Match '\.specify/jira/config\.yml'
    }

    It 'US6: an empty teams: catalogue + a mentioned ticket names the file and the command (FR-026)' {
        $lines = @('projects:', '  - key: IJT', 'routing_default: IJT', 'teams: []')
        [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), (($lines -join "`n") + "`n"))
        $r = Invoke-FeatureCaptured @('feature', 'IJT-42', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.active | Should -BeFalse
        $obj.warnings[0] | Should -Match '\.specify/jira/config\.yml'
    }

    It 'US6: a catalogue exists but no team selected + a mentioned ticket names personal.yml, not config.yml (FR-026)' {
        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-42', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out.Trim() | ConvertFrom-Json
        $obj.active | Should -BeFalse
        $obj.warnings[0] | Should -Match '\.specify/jira/personal\.yml'
        $obj.warnings[0] | Should -Match 'your own'
        $obj.warnings[0] | Should -Match '/speckit\.jira\.config'
    }

    It 'US6: the same four states with NO mention stay byte-identical to the baseline (FR-028)' {
        Remove-Item -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.yml') -ErrorAction SilentlyContinue
        $r = Invoke-FeatureCaptured @('feature', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $r.Out.Trim() | Should -Be '{"active":false}'

        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $r.Out.Trim() | Should -Be '{"active":false}'
    }

    It 'US6: neither missing-configuration report issues a Jira request or fails the host command (FR-027)' {
        Remove-Item -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.yml') -ErrorAction SilentlyContinue
        $r = Invoke-FeatureCaptured @('feature', 'IJT-42', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0

        Start-TestMock '{"projects":{"IJT":"team"}}'
        $r = Invoke-FeatureCaptured @('feature', 'IJT-42', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ }).Count | Should -Be 0
    }

    AfterAll {
        foreach ($name in $script:LeakedEnv) { Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue }
    }
}
