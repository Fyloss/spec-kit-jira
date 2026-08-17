# T054 [027] — Pester twin of test_feature_designators.bats.
# Slug derivation number-source selection (FR-059, research R9).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/commands/Feature.psm1') -Force
}

Describe 'Get-JiraFeatDesignatorNumberSource' {
    It 'shape 1: parent by key plus stories -> the parent key' {
        $parent = '{"role":"specification","raw":"PROJ-1","form":"key","key":"PROJ-1"}'
        $stories = '[{"role":"story","raw":"PROJ-11","form":"key","key":"PROJ-11","position":0}]'
        Get-JiraFeatDesignatorNumberSource -ParentJson $parent -StoriesJson $stories | Should -Be 'PROJ-1'
    }

    It 'shape 2: parent as free text plus stories -> the first story-role key' {
        $parent = '{"role":"specification","raw":"New parent title","form":"free_text","text":"New parent title"}'
        $stories = '[{"role":"story","raw":"PROJ-11","form":"key","key":"PROJ-11","position":0},{"role":"story","raw":"PROJ-12","form":"key","key":"PROJ-12","position":1}]'
        Get-JiraFeatDesignatorNumberSource -ParentJson $parent -StoriesJson $stories | Should -Be 'PROJ-11'
    }

    It 'shape 3: stories only -> the first story-role key' {
        $stories = '[{"role":"story","raw":"PROJ-21","form":"key","key":"PROJ-21","position":0},{"role":"story","raw":"PROJ-22","form":"key","key":"PROJ-22","position":1}]'
        Get-JiraFeatDesignatorNumberSource -ParentJson '' -StoriesJson $stories | Should -Be 'PROJ-21'
    }

    It 'shape 4: parent only by key or URL -> the parent key' {
        $parent = '{"role":"specification","raw":"https://acme.atlassian.net/browse/PROJ-1","form":"url","key":"PROJ-1"}'
        Get-JiraFeatDesignatorNumberSource -ParentJson $parent -StoriesJson '[]' | Should -Be 'PROJ-1'
    }

    It 'shape 5: parent only as free text, no stories -> falls through' {
        $parent = '{"role":"specification","raw":"New parent title","form":"free_text","text":"New parent title"}'
        Get-JiraFeatDesignatorNumberSource -ParentJson $parent -StoriesJson '[]' | Should -BeNullOrEmpty
    }

    It 'no designators at all -> falls through' {
        Get-JiraFeatDesignatorNumberSource -ParentJson '' -StoriesJson '[]' | Should -BeNullOrEmpty
    }

    It 'story order fixed by FR-054: the first by position wins' {
        $stories = '[{"role":"story","raw":"PROJ-99","form":"key","key":"PROJ-99","position":1},{"role":"story","raw":"PROJ-10","form":"key","key":"PROJ-10","position":0}]'
        Get-JiraFeatDesignatorNumberSource -ParentJson '' -StoriesJson $stories | Should -Be 'PROJ-10'
    }
}

Describe 'Invoke-JiraFeatSeedFromDesignator (T070)' {
    BeforeAll {
        $Root = Join-Path $PSScriptRoot '../../..'
        Import-Module (Join-Path $Root 'tests/conformance/mock-jira/Mock.psm1') -Force
        $env:JIRA_EMAIL = 'user@example.com'
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $env:JIRA_NO_SLEEP = '1'

        function Start-TestMock {
            param([string]$ConfigJson)
            $cfg = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString() + '.json')
            [System.IO.File]::WriteAllText($cfg, $ConfigJson)
            $script:M = Start-JiraMock -ConfigPath $cfg
            $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
        }

        function Write-SeedConfig {
            $lines = @(
                'projects:', '  - key: PROJ', '    hierarchy:', '      specification: Epic', '      story: Story',
                'routing_default: PROJ', 'teams:',
                '  - id: proj', '    project: PROJ', '    folder_prefix: "proj-"', '    branch_pattern: "proj-<ID>/<FEATURE_NAME>"'
            )
            [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'config.yml'), (($lines -join "`n") + "`n"))
            [System.IO.File]::WriteAllText((Join-Path $env:JIRA_CONFIG_DIR 'personal.yml'), "team: proj`n")
        }

        function New-SeedIssue([string]$Key, [string]$Summary, [string]$Description) {
            return @{ $Key = @{ summary = $Summary; description = $Description; status = @{ name = 'To Do'; statusCategory = @{ key = 'new' } }; issuetype = @{ id = '10001'; name = 'Story' }; project = @{ key = 'PROJ' } } }
        }

        function Start-ThreeStoriesMock {
            $issues = @{}
            (New-SeedIssue 'PROJ-11' 'Accept a partial payment' 'Story one body').GetEnumerator() | ForEach-Object { $issues[$_.Key] = $_.Value }
            (New-SeedIssue 'PROJ-12' 'Refund a captured payment' 'Story two body').GetEnumerator() | ForEach-Object { $issues[$_.Key] = $_.Value }
            (New-SeedIssue 'PROJ-13' 'Reconcile a disputed charge' 'Story three body').GetEnumerator() | ForEach-Object { $issues[$_.Key] = $_.Value }
            $cfgJson = (@{ issues = $issues } | ConvertTo-Json -Depth 20 -Compress)
            Start-TestMock $cfgJson
        }

        function Invoke-FeatureCaptured2 {
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

    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $Work '.specify/jira') -Force | Out-Null
        $env:JIRA_CONFIG_DIR = Join-Path $Work '.specify/jira'
        Write-SeedConfig
        $script:M = $null
    }
    AfterEach {
        if ($M) { Stop-JiraMock -Mock $M; $script:M = $null }
        Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:\JIRA_CONFIG_DIR' -ErrorAction SilentlyContinue
    }

    It 'a key, a browse URL, and a board URL resolve to three keys in ONE bulkfetch; no parent designator => zero parent lookups' {
        Start-ThreeStoriesMock
        $r = Invoke-FeatureCaptured2 @(
            'feature', '--json',
            '--story', 'PROJ-11',
            '--story', "$($M.BaseUrl)/browse/PROJ-12",
            '--story', "$($M.BaseUrl)/jira/software/projects/PROJ/boards/7?selectedIssue=PROJ-13",
            'invoice export'
        )
        $r.ExitCode | Should -Be 0
        $calls = @(Get-JiraMockCallLog -Mock $M | Where-Object { $_ })
        $calls.Count | Should -Be 1
        $calls[0] | Should -Match 'POST .*bulkfetch'
        $out = $r.Out.Trim() | ConvertFrom-Json
        $out.active | Should -BeTrue
        $out.ticket.key | Should -Be 'PROJ-11'
        $out.ticket.number | Should -Be '11'
        $out.ticket.action | Should -Be 'adopted'
        $out.short_name | Should -Be 'proj-11'
        $out.branch_name | Should -Be 'proj-11/proj-11'
        Test-Path -LiteralPath $out.seed_material | Should -BeTrue
        $material = Get-Content -Raw -LiteralPath $out.seed_material | ConvertFrom-Json
        @($material).Count | Should -Be 3
        $material[0].key | Should -Be 'PROJ-11'
        $material[2].key | Should -Be 'PROJ-13'
    }

    It 'C-5 (T073): Jira unreachable WITH designators supplied -> exit 2, never the {active:false} fallback' {
        $cfg = Write-JiraMockConfig -Json '{"issues":{"PROJ-11":{"summary":"S","description":"D"}},"fault":{"status":500}}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
        $r = Invoke-FeatureCaptured2 @('feature', '--json', '--story', 'PROJ-11', 'invoice export')
        $r.ExitCode | Should -Be 2
    }

    It 'T075: a large description still lands whole in the seed material file' {
        $big = 'x' * 150000
        $issues = @{
            'PROJ-11' = @{ summary = 'Accept a partial payment'; description = $big; status = @{ name = 'To Do'; statusCategory = @{ key = 'new' } }; issuetype = @{ id = '10001'; name = 'Story' }; project = @{ key = 'PROJ' } }
            'PROJ-12' = @{ summary = 'Refund a captured payment'; description = 'Story two body'; status = @{ name = 'To Do'; statusCategory = @{ key = 'new' } }; issuetype = @{ id = '10001'; name = 'Story' }; project = @{ key = 'PROJ' } }
        }
        Start-TestMock (@{ issues = $issues } | ConvertTo-Json -Depth 20 -Compress)
        $r = Invoke-FeatureCaptured2 @('feature', '--json', '--story', 'PROJ-11', '--story', 'PROJ-12', 'invoice export')
        $r.ExitCode | Should -Be 0
        $out = $r.Out.Trim() | ConvertFrom-Json
        Test-Path -LiteralPath $out.seed_material | Should -BeTrue
        $material = Get-Content -Raw -LiteralPath $out.seed_material | ConvertFrom-Json
        $material[0].description.Length | Should -Be 150000
    }

    It 'the ordinary parent behaviour is byte-identical to a designator-free run (no designators supplied)' {
        $env:SPEC_KIT_JIRA_PLAN_CONTEXT = '{"story_type_id":"10201","priority_ids":{"P1":"1","P2":"2","P3":"3"},"estimation_field_id":null}'
        Start-TestMock '{"projects":{"PROJ":"team"},"createdKey":"PROJ-999"}'
        $r = Invoke-FeatureCaptured2 @('feature', '--json', 'invoice export')
        $r.ExitCode | Should -Be 0
        $out = $r.Out.Trim() | ConvertFrom-Json
        $out.active | Should -BeTrue
        $out.ticket.action | Should -Be 'created'
        ($out.PSObject.Properties.Name -contains 'seed_material') | Should -Be $false
    }

    It 'T092: a named parent whose type does not match hierarchy.specification refuses REF-ROLE' {
        $issues = @{
            'PROJ-1'  = @{ summary = 'Payment webhooks rollout'; description = 'Epic body'; status = @{ name = 'To Do'; statusCategory = @{ key = 'new' } }; issuetype = @{ id = '10001'; name = 'Story' }; project = @{ key = 'PROJ' } }
            'PROJ-11' = @{ summary = 'Accept a partial payment'; description = 'Story one body'; status = @{ name = 'To Do'; statusCategory = @{ key = 'new' } }; issuetype = @{ id = '10001'; name = 'Story' }; project = @{ key = 'PROJ' } }
        }
        Start-TestMock (@{ issues = $issues } | ConvertTo-Json -Depth 20 -Compress)
        $r = Invoke-FeatureCaptured2 @('feature', '--json', '--parent', 'PROJ-1', '--story', 'PROJ-11', 'invoice export')
        $r.ExitCode | Should -Not -Be 0
        $r.Err | Should -Match 'REF-ROLE'
    }

    It 'T093: a named parent whose type matches hierarchy.specification resolves cleanly' {
        $issues = @{
            'PROJ-1'  = @{ summary = 'Payment webhooks rollout'; description = 'Epic body'; status = @{ name = 'To Do'; statusCategory = @{ key = 'new' } }; issuetype = @{ id = '10001'; name = 'Epic' }; project = @{ key = 'PROJ' } }
            'PROJ-11' = @{ summary = 'Accept a partial payment'; description = 'Story one body'; status = @{ name = 'To Do'; statusCategory = @{ key = 'new' } }; issuetype = @{ id = '10001'; name = 'Story' }; project = @{ key = 'PROJ' } }
        }
        Start-TestMock (@{ issues = $issues } | ConvertTo-Json -Depth 20 -Compress)
        $r = Invoke-FeatureCaptured2 @('feature', '--json', '--parent', 'PROJ-1', '--story', 'PROJ-11', 'invoice export')
        $r.ExitCode | Should -Be 0
        ($r.Out.Trim() | ConvertFrom-Json).ticket.key | Should -Be 'PROJ-1'
    }

    # --- 029 T112/T118 (US8): unmapped vs misplaced on the designator path -----

    It 'T118: a --story issue matching NEITHER declared type is accepted, never refused (FR-036, R11)' {
        $issues = @{
            'PROJ-1'  = @{ summary = 'Payment webhooks rollout'; description = 'Epic body'; status = @{ name = 'To Do'; statusCategory = @{ key = 'new' } }; issuetype = @{ id = '10001'; name = 'Epic' }; project = @{ key = 'PROJ' } }
            'PROJ-99' = @{ summary = 'Legacy importer'; description = 'Bug body'; status = @{ name = 'To Do'; statusCategory = @{ key = 'new' } }; issuetype = @{ id = '10001'; name = 'Bug' }; project = @{ key = 'PROJ' } }
        }
        Start-TestMock (@{ issues = $issues } | ConvertTo-Json -Depth 20 -Compress)
        $r = Invoke-FeatureCaptured2 @('feature', '--json', '--parent', 'PROJ-1', '--story', 'PROJ-99', 'invoice export')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Not -Match 'REF-ROLE'
    }

    It "T118: a --story issue matching the OTHER role's declared type refuses, naming both types (FR-022)" {
        $issues = @{
            'PROJ-1' = @{ summary = 'Payment webhooks rollout'; description = 'Epic body'; status = @{ name = 'To Do'; statusCategory = @{ key = 'new' } }; issuetype = @{ id = '10001'; name = 'Epic' }; project = @{ key = 'PROJ' } }
            'PROJ-2' = @{ summary = 'Another epic'; description = 'Epic body'; status = @{ name = 'To Do'; statusCategory = @{ key = 'new' } }; issuetype = @{ id = '10001'; name = 'Epic' }; project = @{ key = 'PROJ' } }
        }
        Start-TestMock (@{ issues = $issues } | ConvertTo-Json -Depth 20 -Compress)
        $r = Invoke-FeatureCaptured2 @('feature', '--json', '--parent', 'PROJ-1', '--story', 'PROJ-2', 'invoice export')
        $r.ExitCode | Should -Not -Be 0
        $r.Err | Should -Match 'REF-ROLE'
        $r.Err | Should -Match 'PROJ-2'
        $r.Err | Should -Match 'Epic'
        $r.Err | Should -Match 'Story'
    }

    It 'T115/T119: every refusal on the reuse path carries the decline-and-create-fresh escape (FR-037)' {
        $issues = @{
            'PROJ-1'  = @{ summary = 'Payment webhooks rollout'; description = 'Epic body'; status = @{ name = 'To Do'; statusCategory = @{ key = 'new' } }; issuetype = @{ id = '10001'; name = 'Story' }; project = @{ key = 'PROJ' } }
            'PROJ-11' = @{ summary = 'Accept a partial payment'; description = 'Story one body'; status = @{ name = 'To Do'; statusCategory = @{ key = 'new' } }; issuetype = @{ id = '10001'; name = 'Story' }; project = @{ key = 'PROJ' } }
        }
        Start-TestMock (@{ issues = $issues } | ConvertTo-Json -Depth 20 -Compress)
        $r = Invoke-FeatureCaptured2 @('feature', '--json', '--parent', 'PROJ-1', '--story', 'PROJ-11', 'invoice export')
        $r.ExitCode | Should -Not -Be 0
        $r.Err | Should -Match 'decline, and the extension creates a new Epic plus one Story per drafted user story'
    }

    It "T118: a --parent issue matching NEITHER declared type refuses, naming the container constraint (FR-039)" {
        $issues = @{
            'PROJ-99' = @{ summary = 'Legacy importer'; description = 'Bug body'; status = @{ name = 'To Do'; statusCategory = @{ key = 'new' } }; issuetype = @{ id = '10001'; name = 'Bug' }; project = @{ key = 'PROJ' } }
            'PROJ-11' = @{ summary = 'Accept a partial payment'; description = 'Story one body'; status = @{ name = 'To Do'; statusCategory = @{ key = 'new' } }; issuetype = @{ id = '10001'; name = 'Story' }; project = @{ key = 'PROJ' } }
        }
        Start-TestMock (@{ issues = $issues } | ConvertTo-Json -Depth 20 -Compress)
        $r = Invoke-FeatureCaptured2 @('feature', '--json', '--parent', 'PROJ-99', '--story', 'PROJ-11', 'invoice export')
        $r.ExitCode | Should -Not -Be 0
        $r.Err | Should -Match 'PROJ-99'
        $r.Err | Should -Match 'container'
        $r.Err | Should -Match '--parent'
        $r.Err | Should -Match '--story PROJ-99'
    }
}
