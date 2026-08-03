# T038/T039 [US1] — mirror of tests/bash/commands/test_config_field_defaults.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/commands/Config.psm1') -Force
    $script:Mock = Join-Path $Root 'tests/conformance/mock-jira'
    $script:Fixture = Join-Path $Root 'tests/conformance/fixtures/repo-with-field-defaults'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $script:FieldDefaultsBeginToken = '# --- spec-kit-jira:field_defaults:begin ---'
    $script:FieldDefaultsEndToken = '# --- spec-kit-jira:field_defaults:end ---'
}

Describe 'Get-JiraFieldAnswersFor' {
    It 'filters by project key and splits on the unit separator, preserving spaces' {
        $us = [char]0x1F
        $fd = "CONSUMER=Epic=Business Owner=Platform Team${us}CONSUMER=Story=Team=Payments${us}OTHER=Epic=X=Y"
        $out = Get-JiraFieldAnswersFor -ProjectKey 'CONSUMER' -FieldDefaults $fd | ConvertFrom-Json
        $out.Count | Should -Be 2
        $out[0].type | Should -Be 'Epic'
        $out[0].label | Should -Be 'Business Owner'
        $out[0].value | Should -Be 'Platform Team'
        $out[1].label | Should -Be 'Team'
    }

    It 'returns an empty array for an absent flag' {
        (Get-JiraFieldAnswersFor -ProjectKey 'CONSUMER' -FieldDefaults '') | ConvertFrom-Json | Should -BeNullOrEmpty
    }
}

Describe 'Set-JiraFieldDefaultsBlock — the managed-region splice (T044/T045)' {
    BeforeEach {
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        $script:Path = Join-Path $script:Dir 'config.yml'
    }
    AfterEach { Remove-Item -Recurse -Force $script:Dir }

    It 'a non-empty map creates the region in an absent file' {
        $r = Set-JiraFieldDefaultsBlock -Path $script:Path -MapJson '{"FD":{"ask":true,"Epic":{"Business Owner":"Platform Team"}}}' -DryRun $false
        $r.ExitCode | Should -Be 0
        $r.Status | Should -Be 'created'
        $content = [System.IO.File]::ReadAllText($script:Path)
        $content | Should -Match 'spec-kit-jira:field_defaults:begin'
        $content | Should -Match ([regex]::Escape('"Business Owner": "Platform Team"'))
    }

    It 'an empty map with no pre-existing region is left untouched (FR-028, research R6)' {
        [System.IO.File]::WriteAllText($script:Path, "projects:`n  - key: FD`nrouting_default: FD`n")
        $before = [System.IO.File]::ReadAllText($script:Path)
        $r = Set-JiraFieldDefaultsBlock -Path $script:Path -MapJson '{}' -DryRun $false
        $r.Status | Should -Be 'inert'
        ([System.IO.File]::ReadAllText($script:Path)) | Should -Be $before
    }

    It 'a second run with the same map reports unchanged and leaves the file byte-identical (FR-007)' {
        Set-JiraFieldDefaultsBlock -Path $script:Path -MapJson '{"FD":{"ask":true,"Epic":{"Business Owner":"Platform Team"}}}' -DryRun $false | Out-Null
        $before = [System.IO.File]::ReadAllText($script:Path)
        $r = Set-JiraFieldDefaultsBlock -Path $script:Path -MapJson '{"FD":{"ask":true,"Epic":{"Business Owner":"Platform Team"}}}' -DryRun $false
        $r.Status | Should -Be 'unchanged'
        ([System.IO.File]::ReadAllText($script:Path)) | Should -Be $before
    }

    It 'a changed map rewrites only the region, preserving bytes outside it' {
        [System.IO.File]::WriteAllText($script:Path, "# a comment the operator wrote`nprojects:`n  - key: FD`nrouting_default: FD`n")
        Set-JiraFieldDefaultsBlock -Path $script:Path -MapJson '{"FD":{"ask":true,"Epic":{"Business Owner":"Platform Team"}}}' -DryRun $false | Out-Null
        $r = Set-JiraFieldDefaultsBlock -Path $script:Path -MapJson '{"FD":{"ask":true,"Epic":{"Business Owner":"Override Team"}}}' -DryRun $false
        $r.Status | Should -Be 'written'
        $content = [System.IO.File]::ReadAllText($script:Path)
        $content | Should -Match ([regex]::Escape('# a comment the operator wrote'))
        $content | Should -Match ([regex]::Escape('Override Team'))
        $content | Should -Not -Match ([regex]::Escape('Platform Team'))
    }

    It 'an already-present region that becomes empty is still rewritten (§5.2 removal is the off switch)' {
        Set-JiraFieldDefaultsBlock -Path $script:Path -MapJson '{"FD":{"ask":true,"Epic":{"Business Owner":"Platform Team"}}}' -DryRun $false | Out-Null
        $r = Set-JiraFieldDefaultsBlock -Path $script:Path -MapJson '{}' -DryRun $false
        $r.Status | Should -Be 'written'
        ([System.IO.File]::ReadAllText($script:Path)) | Should -Match ([regex]::Escape('"field_defaults": {}'))
    }

    It 'malformed markers refuse with exit 4 and zero writes' {
        [System.IO.File]::WriteAllText($script:Path, "# --- spec-kit-jira:field_defaults:begin ---`nstray`n")
        $before = [System.IO.File]::ReadAllText($script:Path)
        $r = Set-JiraFieldDefaultsBlock -Path $script:Path -MapJson '{"FD":{"ask":true}}' -DryRun $false
        $r.ExitCode | Should -Be 4
        $r.Status | Should -Be 'refused'
        ([System.IO.File]::ReadAllText($script:Path)) | Should -Be $before
    }

    It '-DryRun computes the status without touching the file' {
        $r = Set-JiraFieldDefaultsBlock -Path $script:Path -MapJson '{"FD":{"ask":true,"Epic":{"Business Owner":"Platform Team"}}}' -DryRun $true
        $r.Status | Should -Be 'created'
        (Test-Path -LiteralPath $script:Path) | Should -BeFalse
    }

    It 'T040 — the region is appended once into a pre-existing file, never duplicated across writes' {
        [System.IO.File]::WriteAllText($script:Path, "projects:`n  - key: FD`nrouting_default: FD`n")
        Set-JiraFieldDefaultsBlock -Path $script:Path -MapJson '{"FD":{"ask":true,"Epic":{"Business Owner":"Platform Team"}}}' -DryRun $false | Out-Null
        Set-JiraFieldDefaultsBlock -Path $script:Path -MapJson '{"FD":{"ask":true,"Epic":{"Business Owner":"Changed Team"}}}' -DryRun $false | Out-Null
        $content = [System.IO.File]::ReadAllText($script:Path)
        ([regex]::Matches($content, [regex]::Escape($FieldDefaultsBeginToken))).Count | Should -Be 1
        ([regex]::Matches($content, [regex]::Escape($FieldDefaultsEndToken))).Count | Should -Be 1
    }

    It '013 — a field default containing a double quote is written escaped and reads back identical (FR-004, FR-021)' {
        $merged = '{"FD":{"ask":true,"Epic":{"Program Increment":"Platform \"legacy\""}}}'
        $r = Set-JiraFieldDefaultsBlock -Path $script:Path -MapJson $merged -DryRun $false
        $r.Status | Should -Be 'created'
        $content = [System.IO.File]::ReadAllText($script:Path)
        $content | Should -Match ([regex]::Escape('"Program Increment": "Platform \"legacy\""'))
        $json = (ConvertFrom-JiraConfigYaml -Path $script:Path) | ConvertFrom-Json
        $json.field_defaults.FD.Epic.'Program Increment' | Should -Be 'Platform "legacy"'
    }

    It "T040 — the host's dominant CRLF line ending is respected" {
        [System.IO.File]::WriteAllText($script:Path, "projects:`r`n  - key: FD`r`nrouting_default: FD`r`n")
        Set-JiraFieldDefaultsBlock -Path $script:Path -MapJson '{"FD":{"ask":true,"Epic":{"Business Owner":"Platform Team"}}}' -DryRun $false | Out-Null
        $content = [System.IO.File]::ReadAllText($script:Path)
        $content | Should -Match ([regex]::Escape("`r`n" + $FieldDefaultsBeginToken + "`r`n"))
    }
}

Describe 'Get-JiraFieldDefaultAnswerProblem / Merge-JiraFieldDefault / Get-JiraFieldDefaultsReport (T046/T048/T050)' {
    BeforeAll {
        $script:ITypes = '[{"logical_name":"Epic","id":"10101"},{"logical_name":"Story","id":"10102"}]'
        $script:Defaultable = '{"10101":[' +
            '{"logical_name":"Business Owner","field_id":"customfield_40011","schema_type":"user","required":true,"defaultable":true,"allowed_values":[]},' +
            '{"logical_name":"Program Increment","field_id":"customfield_40012","schema_type":"option","required":true,"defaultable":true,"allowed_values":["PI-2026-Q2","PI-2026-Q3"]},' +
            '{"logical_name":"Impediment","field_id":"customfield_40013","schema_type":"array","required":false,"defaultable":false,"undefaultable_reason":"a list of values cannot be expressed as a single recorded value"}' +
            ']}'
    }

    It 'a well-formed answer produces no problem' {
        $answers = '[{"type":"Epic","label":"Business Owner","value":"Platform Team"}]'
        $out = Get-JiraFieldDefaultAnswerProblem -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $script:Defaultable -AnswersJson $answers | ConvertFrom-Json
        @($out).Count | Should -Be 0
    }

    It 'an unknown issue-type name lists the discovered types (FR-026)' {
        $answers = '[{"type":"NoSuchType","label":"Team","value":"X"}]'
        $out = Get-JiraFieldDefaultAnswerProblem -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $script:Defaultable -AnswersJson $answers | ConvertFrom-Json
        $out[0].kind | Should -Be 'unknown_type'
        (@($out[0].candidates) | Sort-Object) -join ',' | Should -Be 'Epic,Story'
    }

    It 'an unknown field label lists the defaultable fields of that type' {
        $answers = '[{"type":"Epic","label":"Nonexistent","value":"X"}]'
        $out = Get-JiraFieldDefaultAnswerProblem -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $script:Defaultable -AnswersJson $answers | ConvertFrom-Json
        $out[0].kind | Should -Be 'unknown_label'
        (@($out[0].candidates) | Sort-Object) -join ',' | Should -Be 'Business Owner,Impediment,Program Increment'
    }

    It 'an empty value is refused (FR-008)' {
        $answers = '[{"type":"Epic","label":"Business Owner","value":""}]'
        $out = Get-JiraFieldDefaultAnswerProblem -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $script:Defaultable -AnswersJson $answers | ConvertFrom-Json
        $out[0].kind | Should -Be 'empty_value'
    }

    It 'a value outside allowed_values lists the accepted values (FR-003)' {
        $answers = '[{"type":"Epic","label":"Program Increment","value":"PI-2020-Q1"}]'
        $out = Get-JiraFieldDefaultAnswerProblem -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $script:Defaultable -AnswersJson $answers | ConvertFrom-Json
        $out[0].kind | Should -Be 'outside_allowed'
        (@($out[0].candidates)) -join ',' | Should -Be 'PI-2026-Q2,PI-2026-Q3'
    }

    It 'a value inside allowed_values passes' {
        $answers = '[{"type":"Epic","label":"Program Increment","value":"PI-2026-Q3"}]'
        $out = Get-JiraFieldDefaultAnswerProblem -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $script:Defaultable -AnswersJson $answers | ConvertFrom-Json
        @($out).Count | Should -Be 0
    }

    It '013 — a value containing a double quote inside allowed_values is accepted, not outside_allowed (FR-004)' {
        $defaultable = '{"10101":[{"logical_name":"Program Increment","field_id":"customfield_40012","schema_type":"option","required":true,"defaultable":true,"allowed_values":["Platform \"legacy\"","clean"]}]}'
        $answers = '[{"type":"Epic","label":"Program Increment","value":"Platform \"legacy\""}]'
        $out = Get-JiraFieldDefaultAnswerProblem -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $defaultable -AnswersJson $answers | ConvertFrom-Json
        @($out).Count | Should -Be 0
    }

    It 'a field whose shape cannot be defaulted is refused, naming the reason (US3 scenario 3)' {
        $answers = '[{"type":"Epic","label":"Impediment","value":"X"}]'
        $out = Get-JiraFieldDefaultAnswerProblem -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $script:Defaultable -AnswersJson $answers | ConvertFrom-Json
        $out[0].kind | Should -Be 'undefaultable'
        $out[0].reason | Should -Match 'list of values'
    }

    It 'a credential-shaped value is refused before any splice (FR-024, Principle IV)' {
        $answers = '[{"type":"Epic","label":"Business Owner","value":"person@example.com"}]'
        $outJson = Get-JiraFieldDefaultAnswerProblem -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $script:Defaultable -AnswersJson $answers
        $out = $outJson | ConvertFrom-Json
        $out[0].kind | Should -Be 'credential'
        $outJson | Should -Not -Match 'person@example.com'
    }

    It 'every kind of problem is batched into one report, not one refusal per answer' {
        $answers = '[{"type":"Epic","label":"Business Owner","value":""},{"type":"Epic","label":"Program Increment","value":"PI-2020-Q1"}]'
        $out = Get-JiraFieldDefaultAnswerProblem -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $script:Defaultable -AnswersJson $answers | ConvertFrom-Json
        @($out).Count | Should -Be 2
    }

    It 'an answer overwrites the matching recorded entry' {
        $recorded = '{"ask":true,"Epic":{"Business Owner":"Platform Team"}}'
        $answers = '[{"type":"Epic","label":"Business Owner","value":"Override Team"}]'
        $out = Merge-JiraFieldDefault -RecordedJson $recorded -AnswersJson $answers | ConvertFrom-Json
        $out.Epic.'Business Owner' | Should -Be 'Override Team'
    }

    It 'an unrelated recorded entry is carried forward unchanged' {
        $recorded = '{"ask":true,"Epic":{"Business Owner":"Platform Team","Program Increment":"PI-2026-Q2"}}'
        $answers = '[{"type":"Epic","label":"Business Owner","value":"Override Team"}]'
        $out = Merge-JiraFieldDefault -RecordedJson $recorded -AnswersJson $answers | ConvertFrom-Json
        $out.Epic.'Program Increment' | Should -Be 'PI-2026-Q2'
    }

    It 'the merge never carries the ask switch as a type entry' {
        $recorded = '{"ask":false,"Epic":{"Business Owner":"Platform Team"}}'
        $out = Merge-JiraFieldDefault -RecordedJson $recorded -AnswersJson '[]' | ConvertFrom-Json
        ($out.PSObject.Properties.Match('ask').Count) | Should -Be 0
    }

    It 'an answer for a field with nothing recorded is applied on its own' {
        $answers = '[{"type":"Story","label":"Team","value":"Payments"}]'
        $out = Merge-JiraFieldDefault -RecordedJson '{}' -AnswersJson $answers | ConvertFrom-Json
        $out.Story.Team | Should -Be 'Payments'
    }

    It 'a required defaultable field with no recorded value and no answer is pending' {
        $out = Get-JiraFieldDefaultsReport -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $script:Defaultable -AskTypesJson '["Epic"]' -MergedJson '{}' -BridgeTypeIdsJson '["10101"]' | ConvertFrom-Json
        @($out.pending).Count | Should -Be 2
        (@($out.pending | ForEach-Object { $_.label }) | Sort-Object) -join ',' | Should -Be 'Business Owner,Program Increment'
    }

    It 'a required defaultable field with a recorded value is not pending' {
        $merged = '{"Epic":{"Business Owner":"Platform Team","Program Increment":"PI-2026-Q2"}}'
        $out = Get-JiraFieldDefaultsReport -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $script:Defaultable -AskTypesJson '["Epic"]' -MergedJson $merged -BridgeTypeIdsJson '["10101"]' | ConvertFrom-Json
        @($out.pending).Count | Should -Be 0
    }

    It 'a required undefaultable field is reported once, never pending (contract §2.3)' {
        $out = Get-JiraFieldDefaultsReport -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $script:Defaultable -AskTypesJson '["Epic"]' -MergedJson '{}' -BridgeTypeIdsJson '["10101"]' | ConvertFrom-Json
        @($out.undefaultable_required).Count | Should -Be 0
    }

    # The pending question's `answer with …` hint tells the operator exactly
    # what to type, so its KEY=Type=Label=Value token must survive a shell
    # round-trip: labels routinely carry a space and the placeholder is spelled
    # `<value>`, which an unquoted token would turn into an input redirection.
    It 'the pending hint quotes the --field-default token, with and without an allowed-value list' {
        $report = '{"orphaned":[],"not_yet_consumed":[],"undefaultable_required":[],' +
            '"pending":[{"type":"Deliverable","label":"Business Owner","allowed_values":[]},' +
            '{"type":"Deliverable","label":"Program Increment","allowed_values":["PI-2026-Q2","PI-2026-Q3"]}]}'
        $out = Get-JiraFieldDefaultNote -ProjectKey 'PM' -ReportJson $report
        $out | Should -Match ([regex]::Escape("(answer with --field-default 'PM=Deliverable=Business Owner=<value>')"))
        $out | Should -Match ([regex]::Escape("(answer with --field-default 'PM=Deliverable=Program Increment=<value>')"))
        $out | Should -Match ([regex]::Escape('choose one of: PI-2026-Q2, PI-2026-Q3'))
    }

    It 'the pending hint renders a quoted allowed-value label as Jira shows it, no escape notation (013 FR-003)' {
        $report = '{"orphaned":[],"not_yet_consumed":[],"undefaultable_required":[],' +
            '"pending":[{"type":"Deliverable","label":"Platform","allowed_values":["Platform \"legacy\"","clean"]}]}'
        $out = Get-JiraFieldDefaultNote -ProjectKey 'PM' -ReportJson $report
        $out | Should -Match ([regex]::Escape('choose one of: Platform "legacy", clean'))
        $out | Should -Not -Match ([regex]::Escape('\"'))
    }

    It 'an entry recorded for a type the project no longer offers is orphaned' {
        $merged = '{"Retired Type":{"Team":"Payments"}}'
        $out = Get-JiraFieldDefaultsReport -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $script:Defaultable -AskTypesJson '["Epic"]' -MergedJson $merged -BridgeTypeIdsJson '["10101"]' | ConvertFrom-Json
        @($out.orphaned).Count | Should -Be 1
        $out.orphaned[0].kind | Should -Be 'orphaned_type'
    }

    It 'an entry recorded for a field the type no longer offers is orphaned' {
        $merged = '{"Epic":{"Retired Field":"X"}}'
        $out = Get-JiraFieldDefaultsReport -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $script:Defaultable -AskTypesJson '["Epic"]' -MergedJson $merged -BridgeTypeIdsJson '["10101"]' | ConvertFrom-Json
        @($out.orphaned).Count | Should -Be 1
        $out.orphaned[0].kind | Should -Be 'orphaned_label'
    }

    It 'an entry recorded for a type the bridge does not write is reported not yet consumed (FR-027)' {
        $merged = '{"Story":{"Team":"Payments"}}'
        $out = Get-JiraFieldDefaultsReport -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $script:Defaultable -AskTypesJson '["Epic","Story"]' -MergedJson $merged -BridgeTypeIdsJson '["10101"]' | ConvertFrom-Json
        @($out.not_yet_consumed).Count | Should -Be 1
        $out.not_yet_consumed[0].type | Should -Be 'Story'
    }

    It 'a normal recorded entry for a bridge-written type is neither orphaned nor not-yet-consumed' {
        $merged = '{"Epic":{"Business Owner":"Platform Team"}}'
        $out = Get-JiraFieldDefaultsReport -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $script:Defaultable -AskTypesJson '["Epic"]' -MergedJson $merged -BridgeTypeIdsJson '["10101"]' | ConvertFrom-Json
        @($out.orphaned).Count | Should -Be 0
        @($out.not_yet_consumed).Count | Should -Be 0
    }

    It 'T038 — an optional defaultable field never appears in the pending question' {
        $optionalDf = '{"10101":[' +
            '{"logical_name":"Business Owner","field_id":"customfield_40011","schema_type":"user","required":true,"defaultable":true,"allowed_values":[]},' +
            '{"logical_name":"Slack Channel","field_id":"customfield_40099","schema_type":"string","required":false,"defaultable":true,"allowed_values":[]}' +
            ']}'
        $out = Get-JiraFieldDefaultsReport -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $optionalDf -AskTypesJson '["Epic"]' -MergedJson '{}' -BridgeTypeIdsJson '["10101"]' | ConvertFrom-Json
        (@($out.pending | ForEach-Object { $_.label }) -join ',') | Should -Be 'Business Owner'
    }

    It 'T038 — an answer given for an optional defaultable field is validated and merged' {
        $optionalDf = '{"10101":[{"logical_name":"Slack Channel","field_id":"customfield_40099","schema_type":"string","required":false,"defaultable":true,"allowed_values":[]}]}'
        $answers = '[{"type":"Epic","label":"Slack Channel","value":"#platform"}]'
        $problems = Get-JiraFieldDefaultAnswerProblem -IssueTypesJson $script:ITypes -DefaultableFieldsByTypeJson $optionalDf -AnswersJson $answers | ConvertFrom-Json
        @($problems).Count | Should -Be 0
        $out = Merge-JiraFieldDefault -RecordedJson '{}' -AnswersJson $answers | ConvertFrom-Json
        $out.Epic.'Slack Channel' | Should -Be '#platform'
    }
}

Describe 'End-to-end — the full ceremony against the mock (T035/T037 spirit)' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $Work -Force | Out-Null
        Copy-Item -Recurse (Join-Path $Fixture '.specify') (Join-Path $Work '.specify')
        $env:JIRA_CONFIG_DIR = Join-Path $Work '.specify/jira'
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/field-defaults.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
    }
    AfterEach {
        Stop-JiraMock -Mock $M
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
    }

    It 'recording both required fields via --field-default writes the managed region and satisfies the gate' {
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try {
            $code = Invoke-JiraConfig -Arguments @('config', 'FD', '--field-default', 'FD=Deliverable=Business Owner=Platform Team', '--field-default', 'FD=Deliverable=Program Increment=PI-2026-Q3', '--json')
        }
        finally { [Console]::SetOut($orig) }
        $code | Should -Be 0
        $obj = $sw.ToString().Trim() | ConvertFrom-Json
        $obj.effects.field_defaults.status | Should -Be 'written'
        $content = Get-Content -Raw -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.yml')
        $content | Should -Match 'spec-kit-jira:field_defaults:begin'
        $content | Should -Match ([regex]::Escape('"Business Owner": "Platform Team"'))
    }

    It 'a second run with no new answers reports unchanged and leaves config.yml byte-identical (FR-007)' {
        $null = Invoke-JiraConfig -Arguments @('config', 'FD', '--field-default', 'FD=Deliverable=Business Owner=Platform Team', '--field-default', 'FD=Deliverable=Program Increment=PI-2026-Q3', '--json')
        $before = Get-Content -Raw -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.yml')
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $code = Invoke-JiraConfig -Arguments @('config', 'FD', '--json') }
        finally { [Console]::SetOut($orig) }
        $code | Should -Be 0
        $obj = $sw.ToString().Trim() | ConvertFrom-Json
        $obj.effects.field_defaults.status | Should -Be 'unchanged'
        (Get-Content -Raw -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.yml')) | Should -Be $before
    }

    It 'T038/FR-009 — degraded mode asks nothing and writes nothing' {
        $before = Get-Content -Raw -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.yml')
        $origBase = $env:SPEC_KIT_JIRA_BASE_URL
        $env:SPEC_KIT_JIRA_BASE_URL = $null
        $sw = [System.IO.StringWriter]::new()
        $se = [System.IO.StringWriter]::new()
        $origOut = [Console]::Out
        $origErr = [Console]::Error
        [Console]::SetOut($sw)
        [Console]::SetError($se)
        try {
            $code = Invoke-JiraConfig -Arguments @('config', 'FD', '--field-default', 'FD=Deliverable=Business Owner=Platform Team', '--json')
        }
        finally {
            [Console]::SetOut($origOut)
            [Console]::SetError($origErr)
            $env:SPEC_KIT_JIRA_BASE_URL = $origBase
        }
        $code | Should -Be 0
        $obj = $sw.ToString().Trim() | ConvertFrom-Json
        ($obj.effects.PSObject.Properties.Match('field_defaults').Count) | Should -Be 0
        (Get-Content -Raw -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.yml')) | Should -Be $before
        (Test-Path -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')) | Should -BeFalse
    }

    It 'T041a — a credential-shaped --field-default is refused before any splice; config.yml is byte-for-byte unchanged and the value never appears in output (FR-024, Principle IV)' {
        $path = Join-Path $env:JIRA_CONFIG_DIR 'config.yml'
        [System.IO.File]::WriteAllText($path, "projects:`n  - key: FD`n    style: company_managed`n    hierarchy:`n      specification: Deliverable`n      story: Story`nrouting_default: FD`n")
        $before = Get-Content -Raw -LiteralPath $path
        $sw = [System.IO.StringWriter]::new()
        $se = [System.IO.StringWriter]::new()
        $origOut = [Console]::Out
        $origErr = [Console]::Error
        [Console]::SetOut($sw)
        [Console]::SetError($se)
        try {
            $code = Invoke-JiraConfig -Arguments @('config', 'FD', '--field-default', 'FD=Deliverable=Business Owner=person@example.com', '--json')
        }
        finally {
            [Console]::SetOut($origOut)
            [Console]::SetError($origErr)
        }
        $code | Should -Be 4
        (Get-Content -Raw -LiteralPath $path) | Should -Be $before
        $se.ToString() | Should -Match 'Business Owner'
        $se.ToString() | Should -Not -Match 'person@example\.com'
        (Get-Content -Raw -LiteralPath $path) | Should -Not -Match 'person@example\.com'
    }

    It 'T041c — a hand-written entry for an opted-in type survives a run that answers only the required fields of the written types' {
        $null = Invoke-JiraConfig -Arguments @('config', 'FD', '--field-default', 'FD=Deliverable=Business Owner=Platform Team', '--field-default', 'FD=Deliverable=Program Increment=PI-2026-Q3', '--json')
        $path = Join-Path $env:JIRA_CONFIG_DIR 'config.yml'
        $handEditedMap = '{"FD":{"ask":true,"Deliverable":{"Business Owner":"Platform Team","Program Increment":"PI-2026-Q3"},"Story":{"Team":"Payments"}}}'
        Set-JiraFieldDefaultsBlock -Path $path -MapJson $handEditedMap -DryRun $false | Out-Null
        $code = Invoke-JiraConfig -Arguments @('config', 'FD', '--field-default', 'FD=Deliverable=Business Owner=Platform Team', '--field-default', 'FD=Deliverable=Program Increment=PI-2026-Q3', '--json')
        $code | Should -Be 0
        (Get-Content -Raw -LiteralPath $path) | Should -Match ([regex]::Escape('"Team": "Payments"'))
    }

    It 'T041c — an entry written outside the managed region is refused as a duplicate top-level key, with zero writes' {
        $null = Invoke-JiraConfig -Arguments @('config', 'FD', '--field-default', 'FD=Deliverable=Business Owner=Platform Team', '--field-default', 'FD=Deliverable=Program Increment=PI-2026-Q3', '--json')
        $path = Join-Path $env:JIRA_CONFIG_DIR 'config.yml'
        Add-Content -LiteralPath $path -Value "`nfield_defaults:`n  FD:`n    ask: true"
        $before = Get-Content -Raw -LiteralPath $path
        $se = [System.IO.StringWriter]::new()
        $origErr = [Console]::Error
        [Console]::SetError($se)
        try { $code = Invoke-JiraConfig -Arguments @('config', 'FD', '--json') }
        finally { [Console]::SetError($origErr) }
        $code | Should -Be 4
        $se.ToString() | Should -Match 'duplicate key'
        (Get-Content -Raw -LiteralPath $path) | Should -Be $before
    }

    It 'with nothing recorded and no answer, the ceremony still refuses — via the pre-existing, unchanged mandatory-field/parent-link gate (plan.md Summary), not field_defaults'' own pending report' {
        # field_defaults' own "pending question" report is non-blocking
        # (contract §6). The OLDER structural gate (T050/T051, "pulled to
        # configuration time"), unchanged by this feature beyond gaining
        # recorded defaults as a satisfier, still refuses here because
        # nothing was recorded — the same refusal it has always produced,
        # now defaults-aware.
        $se = [System.IO.StringWriter]::new()
        $origErr = [Console]::Error
        [Console]::SetError($se)
        try { $code = Invoke-JiraConfig -Arguments @('config', 'FD', '--json') }
        finally { [Console]::SetError($origErr) }
        $code | Should -Be 4
        $se.ToString() | Should -Match 'Business Owner'
        $se.ToString() | Should -Match 'Program Increment'
        (Test-Path -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml')) | Should -BeFalse
    }
}
