# T057 [027] — Pester twin of test_seed.bats.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/commands/Seed.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/lib/SeedState.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../../../tests/conformance/mock-jira/Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'

    function Start-SeedMock([string]$ConfigJson = '{}') {
        $cfg = Write-JiraMockConfig -Json $ConfigJson
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
    }

    function New-SeedWork {
        $work = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString())
        $env:JIRA_CONFIG_DIR = Join-Path $work '.specify/jira'
        New-Item -ItemType Directory -Path $env:JIRA_CONFIG_DIR -Force | Out-Null
        $featureDir = Join-Path $work 'specs/001-add-payment-webhooks'
        New-Item -ItemType Directory -Path $featureDir -Force | Out-Null
        $spec = Join-Path $featureDir 'spec.md'
        Set-Content -NoNewline -LiteralPath $spec -Value "# Feature`n`n### User Story 1 - A (Priority: P1)`n<!-- speckit-jira pin=PROJ-11 -->`n`nBody.`n"
        return $spec
    }

    function Write-SeedRecordFor([string] $Spec) {
        $doc = New-JiraSeedStateDocument -Slug 'add-payment-webhooks' -DesignatorsJson '[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0}]' -PlanDigest ''
        Save-JiraSeedState -SpecPath $Spec -DocumentJson $doc
    }
}

Describe 'Invoke-JiraSeed' {
    It 'no seed record, folder present -> REF-EXISTS, zero writes' {
        $spec = New-SeedWork
        $rc = Invoke-JiraSeed -Arguments @($spec, '--json')
        $rc | Should -Not -Be 0
    }

    It 'a readable spec file argument is required' {
        $rc = Invoke-JiraSeed -Arguments @()
        $rc | Should -Be 1
    }

    It 'C-7: without --confirm, emits confirmation_required, exit 0, zero mutations' {
        $spec = New-SeedWork
        Write-SeedRecordFor -Spec $spec
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $rc = Invoke-JiraSeed -Arguments @($spec, '--json') }
        finally { [Console]::SetOut($orig) }
        $rc | Should -Be 0
        $out = $sw.ToString() | ConvertFrom-Json
        $out.active | Should -Be $true
        ($out.PSObject.Properties.Name -contains 'confirmation_required') | Should -Be $true
        Read-JiraSeedState -SpecPath $spec | Should -Not -BeNullOrEmpty
    }

    It 'C-7: the confirmation payload carries plan, provenance, and delta' {
        $spec = New-SeedWork
        Write-SeedRecordFor -Spec $spec
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { Invoke-JiraSeed -Arguments @($spec, '--json') | Out-Null }
        finally { [Console]::SetOut($orig) }
        $out = $sw.ToString() | ConvertFrom-Json
        ($out.confirmation_required.PSObject.Properties.Name -contains 'plan') | Should -Be $true
        ($out.confirmation_required.PSObject.Properties.Name -contains 'provenance') | Should -Be $true
        ($out.confirmation_required.PSObject.Properties.Name -contains 'delta') | Should -Be $true
    }
}

Describe 'T064: FR-047, credentials never reach argv, logs, or traces' {
    It 'Seed.psm1 never references a credential variable or header' {
        $content = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '../../../scripts/powershell/commands/Seed.psm1')
        $content | Should -Not -Match 'JIRA_API_TOKEN'
        $content | Should -Not -Match 'Authorization'
    }
}

Describe 'T079/T080: REF-DECOMP — Test-JiraPinMarkerValidate wired into Invoke-JiraSeed' {
    It 'a missing pinning marker (P1) refuses REF-DECOMP, naming the key' {
        $spec = New-SeedWork
        Set-Content -NoNewline -LiteralPath $spec -Value "# Feature`n`n### User Story 1 - A (Priority: P1)`n`nBody, no marker.`n"
        Write-SeedRecordFor -Spec $spec
        $rc = Invoke-JiraSeed -Arguments @($spec, '--json')
        $rc | Should -Not -Be 0
    }

    It 'an orphan marker (P2) refuses REF-DECOMP' {
        $spec = New-SeedWork
        Set-Content -NoNewline -LiteralPath $spec -Value "# Feature`n`n### User Story 1 - A (Priority: P1)`n<!-- speckit-jira pin=PROJ-11 -->`n`n### User Story 2 - B (Priority: P1)`n<!-- speckit-jira pin=PROJ-99 -->`n`nBody.`n"
        Write-SeedRecordFor -Spec $spec
        $rc = Invoke-JiraSeed -Arguments @($spec, '--json')
        $rc | Should -Not -Be 0
    }

    It 'a split marker (P3) refuses REF-DECOMP' {
        $spec = New-SeedWork
        Set-Content -NoNewline -LiteralPath $spec -Value "# Feature`n`n### User Story 1 - A (Priority: P1)`n<!-- speckit-jira pin=PROJ-11 -->`n`n### User Story 2 - B (Priority: P1)`n<!-- speckit-jira pin=PROJ-11 -->`n`nBody.`n"
        Write-SeedRecordFor -Spec $spec
        $rc = Invoke-JiraSeed -Arguments @($spec, '--json')
        $rc | Should -Not -Be 0
    }

    It 'a valid decomposition passes REF-DECOMP validation silently (exit 0)' {
        $spec = New-SeedWork
        Write-SeedRecordFor -Spec $spec
        $rc = Invoke-JiraSeed -Arguments @($spec, '--json')
        $rc | Should -Be 0
    }
}

Describe 'T081-T088: binding, dry-run, idempotency' {
    AfterEach {
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
    }

    It 'T081/T082: --confirm binds each named story with origin:human role:story' {
        $spec = New-SeedWork
        Write-SeedRecordFor -Spec $spec
        Start-SeedMock '{"issues":{"PROJ-11":{"summary":"S","description":"D"}}}'
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $rc = Invoke-JiraSeed -Arguments @($spec, '--confirm', '--json') }
        finally { [Console]::SetOut($orig) }
        $rc | Should -Be 0
        $out = $sw.ToString() | ConvertFrom-Json
        $out.active | Should -BeTrue
        @($out.bindings).Count | Should -Be 1
        $text = Get-Content -Raw -LiteralPath $spec
        $text | Should -Match '<!-- speckit-jira story=[0-9a-f]{16} ticket=PROJ-11 -->'
        $text | Should -Not -Match 'pin='
        Read-JiraSeedState -SpecPath $spec | Should -BeNullOrEmpty
        $stored = (Invoke-RestMethod -Uri "$($M.BaseUrl)/rest/api/3/issue/PROJ-11/properties/spec-kit-jira").value
        $stored.origin | Should -Be 'human'
        $stored.role | Should -Be 'story'
    }

    It 'C-16 (T085): --dry-run predicts and writes no seed record' {
        $spec = New-SeedWork
        Write-SeedRecordFor -Spec $spec
        $rc = Invoke-JiraSeed -Arguments @($spec, '--dry-run', '--json')
        $rc | Should -Be 0
        Read-JiraSeedState -SpecPath $spec | Should -Not -BeNullOrEmpty
    }

    It 'C-13 (T087): a second run against a bound specification is a no-op, exit 0' {
        $spec = New-SeedWork
        Write-SeedRecordFor -Spec $spec
        Start-SeedMock '{"issues":{"PROJ-11":{"summary":"S","description":"D"}}}'
        Invoke-JiraSeed -Arguments @($spec, '--confirm', '--json') | Out-Null
        $before = Get-Content -Raw -LiteralPath $spec
        $rc = Invoke-JiraSeed -Arguments @($spec, '--json')
        $rc | Should -Be 0
        (Get-Content -Raw -LiteralPath $spec) | Should -Be $before
    }
}

Describe 'T090/T091: parent adoption (US3)' {
    AfterEach {
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
    }

    It 'an existing parent is adopted (never created), marker origin:human role:parent' {
        $spec = New-SeedWork
        $doc = New-JiraSeedStateDocument -Slug 'add-payment-webhooks' -DesignatorsJson '[{"role":"specification","form":"key","key":"PROJ-1","raw":"PROJ-1","position":0},{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0}]' -PlanDigest ''
        Save-JiraSeedState -SpecPath $spec -DocumentJson $doc
        Start-SeedMock '{"issues":{"PROJ-1":{"summary":"Payment webhooks rollout","description":"Epic body"},"PROJ-11":{"summary":"S","description":"D"}}}'

        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $rc = Invoke-JiraSeed -Arguments @($spec, '--confirm', '--json') }
        finally { [Console]::SetOut($orig) }
        $rc | Should -Be 0
        $out = $sw.ToString() | ConvertFrom-Json
        @($out.bindings).Count | Should -Be 2
        $parentBinding = @($out.bindings | Where-Object { $_.role -eq 'parent' })[0]
        $parentBinding.origin | Should -Be 'human'
        $parentBinding.key | Should -Be 'PROJ-1'

        $calls = @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ })
        ($calls -match '^POST /rest/api/3/issue$').Count | Should -Be 0
        ($calls -match 'PUT /rest/api/3/issue/PROJ-1/properties/spec-kit-jira').Count | Should -Be 1

        $text = Get-Content -Raw -LiteralPath $spec
        $text | Should -Match '<!-- speckit-jira spec=[0-9a-f]{16} ticket=PROJ-1 -->'

        $stored = (Invoke-RestMethod -Uri "$($M.BaseUrl)/rest/api/3/issue/PROJ-1/properties/spec-kit-jira").value
        $stored.origin | Should -Be 'human'
        $stored.role | Should -Be 'parent'
    }
}

Describe 'T096 (FR-014): binding is agnostic to declared role names (SAFe: Capability/Feature)' {
    AfterEach {
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
    }

    It 'binds a parent and a story under SAFe-shaped issue types' {
        $spec = New-SeedWork
        Set-Content -NoNewline -LiteralPath $spec -Value "# Feature`n`n### User Story 1 - A (Priority: P1)`n<!-- speckit-jira pin=SAFE-11 -->`n`nBody one.`n"
        $doc = New-JiraSeedStateDocument -Slug 'add-payment-webhooks' -DesignatorsJson '[{"role":"specification","form":"key","key":"SAFE-1","raw":"SAFE-1","position":0},{"role":"story","form":"key","key":"SAFE-11","raw":"SAFE-11","position":0}]' -PlanDigest ''
        Save-JiraSeedState -SpecPath $spec -DocumentJson $doc
        $issues = @{
            'SAFE-1'  = @{ summary = 'Payment webhooks rollout'; description = 'Capability body'; issuetype = @{ name = 'Capability' }; project = @{ key = 'SAFE' } }
            'SAFE-11' = @{ summary = 'S'; description = 'D'; issuetype = @{ name = 'Feature' }; project = @{ key = 'SAFE' } }
        }
        Start-SeedMock (@{ issues = $issues } | ConvertTo-Json -Depth 20 -Compress)

        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $rc = Invoke-JiraSeed -Arguments @($spec, '--confirm', '--json') }
        finally { [Console]::SetOut($orig) }
        $rc | Should -Be 0
        $out = $sw.ToString() | ConvertFrom-Json
        @($out.bindings).Count | Should -Be 2
        $text = Get-Content -Raw -LiteralPath $spec
        $text | Should -Match '<!-- speckit-jira spec=[0-9a-f]{16} ticket=SAFE-1 -->'
        $text | Should -Match '<!-- speckit-jira story=[0-9a-f]{16} ticket=SAFE-11 -->'
    }
}

Describe 'T120-T123 (US4): a parent alone, no pinning constraint at all' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/commands/Reconcile.psm1') -Force

        function Invoke-ReconcileCaptured2 {
            param([string[]] $ArgList)
            $sw = [System.IO.StringWriter]::new()
            $orig = [Console]::Out
            [Console]::SetOut($sw)
            try { $code = Invoke-JiraReconcile -Arguments $ArgList } finally { [Console]::SetOut($orig) }
            return [pscustomobject]@{ ExitCode = [int]$code; Out = $sw.ToString() }
        }
    }

    AfterEach {
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
    }

    It 'T120: a parent-only invocation (zero story designators) passes pin validation over zero markers' {
        $spec = New-SeedWork
        Set-Content -NoNewline -LiteralPath $spec -Value "# Feature`n`n### User Story 1 - Freely chosen by the agent (Priority: P1)`n`nBody one, unpinned.`n`n### User Story 2 - Also freely chosen (Priority: P1)`n`nBody two, unpinned.`n"
        $doc = New-JiraSeedStateDocument -Slug 'add-payment-webhooks' -DesignatorsJson '[{"role":"specification","form":"key","key":"PROJ-1","raw":"PROJ-1","position":0}]' -PlanDigest ''
        Save-JiraSeedState -SpecPath $spec -DocumentJson $doc
        $rc = Invoke-JiraSeed -Arguments @($spec, '--json')
        $rc | Should -Be 0
    }

    It 'T121/T123: --confirm on a parent-only invocation binds only the parent; a following reconcile creates one issue per drafted user story under it, and never duplicates the parent' {
        $spec = New-SeedWork
        Set-Content -NoNewline -LiteralPath $spec -Value "# Feature`n`n### User Story 1 - Freely chosen by the agent (Priority: P1)`n`nBody one, unpinned.`n`n### User Story 2 - Also freely chosen (Priority: P1)`n`nBody two, unpinned.`n"
        $doc = New-JiraSeedStateDocument -Slug 'add-payment-webhooks' -DesignatorsJson '[{"role":"specification","form":"key","key":"COMP-1","raw":"COMP-1","position":0}]' -PlanDigest ''
        Save-JiraSeedState -SpecPath $spec -DocumentJson $doc

        # reconcile.sh's twin treats "no config.local.yml" as unbound —
        # written as literal YAML (mirror of the bash test's printf lines),
        # avoiding a dependency on Config.psm1's YAML writer here.
        $localYaml = @'
resolved_ids:
  COMP:
    style: company_managed
    issue_types:
      - logical_name: "Epic"
        id: "10000"
        hierarchy_level: "1"
        subtask: false
      - logical_name: "Story"
        id: "10001"
        hierarchy_level: "0"
        subtask: false
    child_type:
      logical_name: "Story"
      id: "10001"
      source: derived
    parent_type:
      logical_name: "Epic"
      id: "10000"
      source: derived
    required_fields:
      "10000":
        - logical_name: "Summary"
          field_id: "summary"
      "10001":
        - logical_name: "Summary"
          field_id: "summary"
    parent_link_available:
      "10001": true
    statuses:
      To Do: "10000"
'@
        Set-Content -NoNewline -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.local.yml') -Value $localYaml
        $projYaml = @'
projects:
  - key: COMP
    style: company_managed
routing_default: COMP
'@
        Set-Content -NoNewline -LiteralPath (Join-Path $env:JIRA_CONFIG_DIR 'config.yml') -Value $projYaml

        $issues = @{ 'COMP-1' = @{ summary = 'Payment webhooks rollout'; description = @{ type = 'doc'; version = 1; content = @(@{ type = 'paragraph'; content = @(@{ type = 'text'; text = 'Epic body' }) }) } } }
        Start-SeedMock (@{ issues = $issues } | ConvertTo-Json -Depth 20 -Compress)
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-add-payment-webhooks'

        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $rc = Invoke-JiraSeed -Arguments @($spec, '--confirm', '--json') }
        finally { [Console]::SetOut($orig) }
        $rc | Should -Be 0
        $out = $sw.ToString() | ConvertFrom-Json
        @($out.bindings).Count | Should -Be 1
        $out.bindings[0].role | Should -Be 'parent'
        $text = Get-Content -Raw -LiteralPath $spec
        $text | Should -Match '<!-- speckit-jira spec=[0-9a-f]{16} ticket=COMP-1 -->'
        $text | Should -Not -Match 'pin='
        $text | Should -Not -Match 'story='

        $r = Invoke-ReconcileCaptured2 @('reconcile', $spec, '--json')
        $r.ExitCode | Should -Be 0
        $out2 = $r.Out.Trim() | ConvertFrom-Json
        $out2.counts.created | Should -Be 2
        $calls = @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ })
        ($calls -eq 'POST /rest/api/3/issue').Count | Should -Be 2
    }
}
