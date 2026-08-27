# T057/T058 [US2] — mirror of tests/bash/commands/test_reconcile_field_defaults.bats.
# The reconcile-time consolidated question (011, contract §3.3/§3.4/§3.10,
# data-model.md §4). T059/T060/T063/T064 extend this file with summary
# provenance and non-blocking coverage; T075/T076/T079/T080 [US3] extend it
# with the surviving refusal and a rejected value.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    $Fixture = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-mandatory-field'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Config.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force
    # Reconcile.psm1 -Force-imports sink/jira/PlanApply.psm1 internally, which
    # rebinds Get-JiraPlanConfirmationField into Reconcile.psm1's own scope —
    # reimport here so this test file keeps direct access to it too (see
    # memory: powershell-import-force-clobbers-caller-scope).
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira/PlanApply.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/lib/Config.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/lib/Output.psm1') -Force

    $env:SPEC_KIT_JIRA_REPO = 'acme/app'
    $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-reporting'
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_ID_SOURCE = 'aaaaaaaaaaaaaaaa 1111111111111111'
    Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue

    function Invoke-CapturedWithCode {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out; $origErr = [Console]::Error
        [Console]::SetOut($sw); [Console]::SetError($sw)
        try { $code = Invoke-JiraReconcile -Arguments $ArgList }
        finally { [Console]::SetOut($orig); [Console]::SetError($origErr) }
        return [pscustomobject]@{ ExitCode = [int]$code; Out = $sw.ToString() }
    }

    function Set-BothFieldsRecorded {
        $code = Invoke-JiraConfig -Arguments @('config', 'PM', '--issue-type', 'PM=story=Story', `
                '--field-default', 'PM=Deliverable=Business Owner=Platform Team', `
                '--field-default', 'PM=Deliverable=Program Increment=PI-2026-Q3', '--json')
        $code | Should -Be 0
    }
}

Describe 'Invoke-JiraReconcile — the consolidated question (011)' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $script:Work
        $script:Spec = Join-Path $script:Work 'specs/001-reporting/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $script:Work '.specify/jira'
    }
    AfterEach { if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'FR-013 — no question when the plan creates nothing' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Set-BothFieldsRecorded
        $null = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--accept-defaults', '--json')

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out | ConvertFrom-Json
        ($obj.PSObject.Properties.Match('status')).Count | Should -Be 0
        $obj.counts.created | Should -Be 0
    }

    It 'FR-014 — no question when ask is false; the summary still attributes each value to its source' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Set-BothFieldsRecorded
        $map = '{"PM":{"ask":false,"Deliverable":{"Business Owner":"Platform Team","Program Increment":"PI-2026-Q3"}}}'
        Set-JiraFieldDefaultsBlock -Path (Join-Path $env:JIRA_CONFIG_DIR 'config.yml') -MapJson $map -DryRun $false | Out-Null

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out | ConvertFrom-Json
        ($obj.PSObject.Properties.Match('status')).Count | Should -Be 0
        $r.Out | Should -Match 'sent from team-config'
        $r.Out | Should -Match 'ask: false'
    }

    It 'FR-015 — no question with --accept-defaults' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Set-BothFieldsRecorded

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--accept-defaults', '--json')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out | ConvertFrom-Json
        ($obj.PSObject.Properties.Match('status')).Count | Should -Be 0
    }

    It 'FR-028 — no question when creations are pending, ask is on, but neither trigger fires: an optional defaultable field is never recorded and every required field is already satisfiable' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/optional-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $code = Invoke-JiraConfig -Arguments @('config', 'PM', '--issue-type', 'PM=story=Story', '--json')
        $code | Should -Be 0

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out | ConvertFrom-Json
        ($obj.PSObject.Properties.Match('status')).Count | Should -Be 0
        $obj.counts.created | Should -Be 2
    }

    It 'FR-011 — one question naming each field once, however many creations are pending' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Set-BothFieldsRecorded

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out | ConvertFrom-Json
        $obj.status | Should -Be 'confirmation-pending'
        $obj.creations_pending | Should -Be 2
        @($obj.fields | Where-Object { $_.label -eq 'Business Owner' }).Count | Should -Be 1
        @($obj.fields | Where-Object { $_.label -eq 'Program Increment' }).Count | Should -Be 1
    }

    It 'FR-012 — an answer applies to every creation in the run' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Set-BothFieldsRecorded

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--field-value', 'PM=Deliverable=Business Owner=Override Team', '--accept-defaults', '--json')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out | ConvertFrom-Json
        $parentAction = $obj.actions | Where-Object { $_.role -eq 'parent' }
        $parentAction.body.fields.customfield_40011 | Should -Be 'Override Team'
        $r.Out | Should -Match 'Override Team'
    }

    It 'FR-015 — a decline resumed with --accept-defaults is indistinguishable from an acceptance; the summary gives that one reason' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Set-BothFieldsRecorded

        $first = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json')
        $first.ExitCode | Should -Be 0
        ($first.Out | ConvertFrom-Json).status | Should -Be 'confirmation-pending'

        $second = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--accept-defaults', '--json')
        $second.ExitCode | Should -Be 0
        $secondObj = $second.Out | ConvertFrom-Json
        ($secondObj.PSObject.Properties.Match('status')).Count | Should -Be 0
        @($secondObj.notes | Where-Object { $_ -match '--accept-defaults was given' }).Count | Should -Be 1
    }

    # --- T060 [US2] — summary provenance (contract §4.1, FR-022) ------------

    It 'FR-022 — every filled field is attributed to its source; the raw resolution map is never printed' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Set-BothFieldsRecorded

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--field-value', 'PM=Deliverable=Business Owner=Override Team', '--accept-defaults', '--json')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out | ConvertFrom-Json
        $notes = @($obj.notes)
        @($notes | Where-Object { $_ -match 'Business Owner' -and $_ -match 'sent from operator-answer' }).Count | Should -Be 1
        @($notes | Where-Object { $_ -match 'Program Increment' -and $_ -match 'sent from team-config' }).Count | Should -Be 1
        @($notes | Where-Object { $_ -match 'speckit\.jira-mirror\.config' -and $_ -match '--field-default' }).Count | Should -BeGreaterOrEqual 1
        # The promotion line is copy-pasteable, so its KEY=Type=Label=Value token
        # is quoted — both the label and the answered value here carry a space.
        @($notes | Where-Object { $_ -match ([regex]::Escape("--field-default 'PM=Deliverable=Business Owner=Override Team'")) }).Count | Should -Be 1
        ($notes -join "`n") | Should -Not -Match 'customfield_'
        ($notes -join "`n") | Should -Not -Match 'field_default_sources'
    }

    It 'FR-022 — a bridge-supplied field (never recorded, never answered) earns no provenance line at all' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Set-BothFieldsRecorded

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--accept-defaults', '--json')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out | ConvertFrom-Json
        $notes = @($obj.notes) -join "`n"
        $notes | Should -Not -Match 'Summary'
        $notes | Should -Not -Match 'sent from bridge'
    }

    # --- T064 [US2] — non-blocking (FR-020, contract §3.9) -------------------

    It 'FR-020 — a hook-fired run that stops for the question leaves the host command''s outcome unchanged, at most one WARNING line' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Set-BothFieldsRecorded
        $env:SPEC_KIT_JIRA_HOOK_CONTEXT = '1'

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out | ConvertFrom-Json
        $obj.status | Should -Be 'confirmation-pending'
        @($r.Out -split "`n" | Where-Object { $_ -match '^WARNING: ' }).Count | Should -Be 0
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue
    }

    It 'FR-020 — a hook-fired run that fails while applying a default leaves the host command''s outcome unchanged, at most one WARNING line' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Set-BothFieldsRecorded
        # Stop the mock server before pointing reconcile at a dead port — a
        # transport failure while APPLYING the already-recorded defaults.
        Stop-JiraMock -Mock $script:M
        $script:M = $null
        $env:SPEC_KIT_JIRA_BASE_URL = 'http://127.0.0.1:1'
        $env:SPEC_KIT_JIRA_HOOK_CONTEXT = '1'

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--accept-defaults', '--json')
        $r.ExitCode | Should -Be 0
        @($r.Out -split "`n" | Where-Object { $_ -match '^WARNING: ' }).Count | Should -Be 1
        $r.Out | Should -Match 'This spec-kit command completed normally'
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue
    }

    # --- T075/T076 [US3] — the surviving refusal (contract §3.6, FR-016) ----

    It 'FR-016 — with no default and no answer, the run refuses with zero writes, the pre-existing exit code, and a remedy naming each field' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        # Nothing recorded at all. --accept-defaults declares the operator
        # unreachable (§3.10), so the run must refuse rather than ask.

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--accept-defaults', '--json')
        $r.ExitCode | Should -Be 4
        $r.Out | Should -Match 'Business Owner'
        $r.Out | Should -Match 'Program Increment'
        # The remedy is advertised as copy-pasteable, so the KEY=Type=Label=Value
        # token must survive a shell round-trip: both labels here carry a space,
        # and the placeholder is spelled `<value>` — unquoted, the token would
        # word-split and `<value>` would read as an input redirection.
        $r.Out | Should -Match ([regex]::Escape("speckit.jira-mirror.config PM --field-default 'PM=Deliverable=Business Owner=<value>'"))
        $r.Out | Should -Match ([regex]::Escape("speckit.jira-mirror.config PM --field-default 'PM=Deliverable=Program Increment=<value>'"))
        $r.Out | Should -Not -Match 'customfield_'
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -notlike 'GET *' }).Count | Should -Be 0
    }

    # --- T079/T080 [US3] — a rejected value (contract §3.7, FR-019) ---------

    It 'FR-019 — Jira rejecting a defaulted value names the field by label and the value sent, explains in human terms, substitutes nothing, does not retry' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Set-BothFieldsRecorded
        Stop-JiraMock -Mock $script:M

        $faultyCfg = Join-Path $TestDrive 'faulty-mandatory-field.json'
        $cfg = Get-Content -Raw (Join-Path $Mock 'configs/mandatory-field.json') | ConvertFrom-Json -Depth 100
        $cfg | Add-Member -NotePropertyName faults -NotePropertyValue ([ordered]@{
                PM = [ordered]@{ status = 400; errors = [ordered]@{ customfield_40012 = 'Option id 123 is not valid' } }
            })
        ($cfg | ConvertTo-Json -Depth 100 -Compress) | Set-Content -LiteralPath $faultyCfg -NoNewline
        $script:M = Start-JiraMock -ConfigPath $faultyCfg
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--accept-defaults', '--json')
        $r.ExitCode | Should -BeGreaterOrEqual 2
        # "the value", not "the recorded value": this path also reports a value
        # that came from a --field-value answer this run, never recorded.
        $rejectionLine = @($r.Out -split "`n" | Where-Object { $_ -match 'Jira rejected the value' })
        $rejectionLine.Count | Should -Be 1
        $rejectionLine[0] | Should -Match ([regex]::Escape('Jira rejected the value for "Program Increment"'))
        $rejectionLine[0] | Should -Match ([regex]::Escape('sent PI-2026-Q3'))
        $rejectionLine[0] | Should -Match 'Option id 123 is not valid'
        $rejectionLine[0] | Should -Match 'Nothing was substituted and the creation was not retried'
        # The human message never names the raw field id — only its Jira
        # label (FR-019); the JSON summary's own action payload elsewhere in
        # $r.Out legitimately carries the id and is not this clause's concern.
        $rejectionLine[0] | Should -Not -Match 'customfield_40012'
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'POST /rest/api/3/issue' }).Count | Should -Be 1
    }

    # --- T101 — a reconcile run never modifies config.yml (contract §3.8, FR-021) -

    It 'T101 — a plain run that stops at the consolidated question leaves config.yml byte-for-byte unchanged' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Set-BothFieldsRecorded
        $cfgPath = Join-Path $env:JIRA_CONFIG_DIR 'config.yml'
        $before = Get-Content -Raw -LiteralPath $cfgPath

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json')
        $r.ExitCode | Should -Be 0
        ($r.Out | ConvertFrom-Json).status | Should -Be 'confirmation-pending'
        (Get-Content -Raw -LiteralPath $cfgPath) | Should -Be $before
    }

    It 'T101 — an --accept-defaults run that writes tickets leaves config.yml byte-for-byte unchanged' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Set-BothFieldsRecorded
        $cfgPath = Join-Path $env:JIRA_CONFIG_DIR 'config.yml'
        $before = Get-Content -Raw -LiteralPath $cfgPath

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--accept-defaults', '--json')
        $r.ExitCode | Should -Be 0
        ($r.Out | ConvertFrom-Json).counts.created | Should -BeGreaterThan 0
        (Get-Content -Raw -LiteralPath $cfgPath) | Should -Be $before
    }

    It 'T101 — a --field-value override run leaves config.yml byte-for-byte unchanged' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Set-BothFieldsRecorded
        $cfgPath = Join-Path $env:JIRA_CONFIG_DIR 'config.yml'
        $before = Get-Content -Raw -LiteralPath $cfgPath

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--field-value', 'PM=Deliverable=Business Owner=Override Team', '--accept-defaults', '--json')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out | ConvertFrom-Json
        ($obj.actions | Where-Object { $_.role -eq 'parent' }).body.fields.customfield_40011 | Should -Be 'Override Team'
        (Get-Content -Raw -LiteralPath $cfgPath) | Should -Be $before
    }

    It 'T101 — a hook-fired run leaves config.yml byte-for-byte unchanged' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Set-BothFieldsRecorded
        $cfgPath = Join-Path $env:JIRA_CONFIG_DIR 'config.yml'
        $before = Get-Content -Raw -LiteralPath $cfgPath
        $env:SPEC_KIT_JIRA_HOOK_CONTEXT = '1'

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--json')
        $r.ExitCode | Should -Be 0
        ($r.Out | ConvertFrom-Json).status | Should -Be 'confirmation-pending'
        (Get-Content -Raw -LiteralPath $cfgPath) | Should -Be $before
        Remove-Item Env:\SPEC_KIT_JIRA_HOOK_CONTEXT -ErrorAction SilentlyContinue
    }

    # --- T103 — the write-path half of the removal off switch (FR-029, contract §5.2) -

    It 'T103 — removing a recorded default for an optional field excludes it from the next creation payload' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/optional-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        # Type id 10101 (the derived specification role, "Deliverable") carries
        # the fd-optional shape's sole custom field, "Slack Channel" —
        # optional, never asked about (FR-004), recorded here by flag.
        $code = Invoke-JiraConfig -Arguments @('config', 'PM', '--issue-type', 'PM=story=Story', `
                '--field-default', 'PM=Deliverable=Slack Channel=general', '--json')
        $code | Should -Be 0

        # The operator removes the entry by hand — the map the region carries
        # no longer names "Slack Channel" at all.
        $cfgPath = Join-Path $env:JIRA_CONFIG_DIR 'config.yml'
        Set-JiraFieldDefaultsBlock -Path $cfgPath -MapJson '{"PM":{}}' -DryRun $false | Out-Null

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--accept-defaults', '--json')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out | ConvertFrom-Json
        $obj.counts.created | Should -Be 2
        $parentAction = $obj.actions | Where-Object { $_.role -eq 'parent' }
        ($parentAction.body.fields.PSObject.Properties.Match('customfield_40099')).Count | Should -Be 0
        $r.Out | Should -Not -Match 'general'
    }

    It 'T103 — removing a recorded default for a required field returns the §3.6 refusal with zero writes and the remedy line' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/mandatory-field.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        Set-BothFieldsRecorded

        # The operator removes only "Program Increment"; "Business Owner"
        # stays recorded and satisfiable.
        $cfgPath = Join-Path $env:JIRA_CONFIG_DIR 'config.yml'
        $map = '{"PM":{"Deliverable":{"Business Owner":"Platform Team"}}}'
        Set-JiraFieldDefaultsBlock -Path $cfgPath -MapJson $map -DryRun $false | Out-Null

        $r = Invoke-CapturedWithCode @('reconcile', $script:Spec, '--accept-defaults', '--json')
        $r.ExitCode | Should -Be 4
        $r.Out | Should -Match 'Program Increment'
        $r.Out | Should -Match ([regex]::Escape("speckit.jira-mirror.config PM --field-default 'PM=Deliverable=Program Increment=<value>'"))
        $r.Out | Should -Not -Match ([regex]::Escape("speckit.jira-mirror.config PM --field-default 'PM=Deliverable=Business Owner="))
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -notlike 'GET *' }).Count | Should -Be 0
    }
}

# --- 015 T021 [US2] — mirror of the 015 T019/T020 bash guard tests. Decision
# R2 makes this hold BY CONSTRUCTION: the three display sites keep reading
# the recorded map, never the encoded one.

Describe '015 T021 — operator-facing surfaces keep speaking the operator''s own words' {
    BeforeAll {
        $script:ITypes015 = '[{"logical_name":"Deliverable","id":"10101"}]'
        $script:Df015 = '{"10101":[{"logical_name":"Region","field_id":"customfield_1","schema_type":"option","required":true,"defaultable":true,"allowed_values":["EMEA","APAC"]}]}'
    }

    It 'Get-JiraPlanConfirmationField''s recorded_value for an option-typed field is the plain recorded string' {
        $defaults = '{"10101":{"customfield_1":"EMEA"}}'
        $out = @(Get-JiraPlanConfirmationField -IssueTypesJson $script:ITypes015 -DefaultableFieldsByTypeJson $script:Df015 -FieldDefaultsByTypeJson $defaults -PendingTypeIdsJson '["10101"]' | ConvertFrom-Json -Depth 100)
        $out[0].recorded_value | Should -Be 'EMEA'
    }

    It 'FR-010 — a required option-typed field with nothing to send is still listed, with a null value' {
        $out = @(Get-JiraPlanConfirmationField -IssueTypesJson $script:ITypes015 -DefaultableFieldsByTypeJson $script:Df015 -FieldDefaultsByTypeJson '{}' -PendingTypeIdsJson '["10101"]' | ConvertFrom-Json -Depth 100)
        $out.Count | Should -Be 1
        $out[0].recorded_value | Should -Be $null
    }

    It 'the provenance line reads the plain recorded value for an option-typed field, never its wire shape' {
        # Get-JiraReconcileFieldDefaultNote is Reconcile.psm1-internal (not
        # exported) — reach it the way Pester reaches any private module
        # function, via InModuleScope.
        $resolved = '{"field_defaults":{"10101":{"customfield_1":"EMEA"}},"field_default_sources":{"10101":{"customfield_1":"team-config"}},"unresolved":[]}'
        $actions = '[{"method":"POST","url":"https://example.atlassian.net/rest/api/3/issue","body":{"fields":{"issuetype":{"id":"10101"},"customfield_1":"EMEA"}}}]'
        $out = InModuleScope Reconcile -Parameters @{ ITypes = $script:ITypes015; Df = $script:Df015; Resolved = $resolved; Actions = $actions } {
            (Get-JiraReconcileFieldDefaultNote -ProjectKey 'PM' -IssueTypesJson $ITypes -DefaultableFieldsByTypeJson $Df -ResolvedJson $Resolved -ActionsJson $Actions -ParentActionJson 'null' -Ask $true -AcceptDefaults $false -DryRun $false) -join "`n"
        }
        $out | Should -Match ([regex]::Escape('Region (Deliverable) = "EMEA" — sent from team-config'))
        $out | Should -Not -Match ([regex]::Escape('"value"'))
    }

    It 'the --field-default promotion command embeds the recorded value verbatim' {
        $resolved = '{"field_defaults":{"10101":{"customfield_1":"EMEA"}},"field_default_sources":{"10101":{"customfield_1":"operator-answer"}},"unresolved":[]}'
        $actions = '[{"method":"POST","url":"https://example.atlassian.net/rest/api/3/issue","body":{"fields":{"issuetype":{"id":"10101"},"customfield_1":"EMEA"}}}]'
        $out = InModuleScope Reconcile -Parameters @{ ITypes = $script:ITypes015; Df = $script:Df015; Resolved = $resolved; Actions = $actions } {
            (Get-JiraReconcileFieldDefaultNote -ProjectKey 'PM' -IssueTypesJson $ITypes -DefaultableFieldsByTypeJson $Df -ResolvedJson $Resolved -ActionsJson $Actions -ParentActionJson 'null' -Ask $true -AcceptDefaults $false -DryRun $false) -join "`n"
        }
        $out | Should -Match ([regex]::Escape("--field-default 'PM=Deliverable=Region=EMEA'"))
        $out | Should -Not -Match ([regex]::Escape('{"value"'))
    }
}
