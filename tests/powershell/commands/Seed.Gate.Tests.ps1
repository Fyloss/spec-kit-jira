# T107/T109/T111/T113/T115/T117 [027, US7] — Pester twin of
# test_seed_gate.bats. Provenance, decline, and resume
# (contracts/seed-cli-contract.md §4/§5/§8: C-8…C-12, S-2…S-4;
# contracts/pin-marker.md §5/§8: P-5/P-6).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/commands/Seed.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../../../scripts/powershell/lib/SeedState.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../../../tests/conformance/mock-jira/Mock.psm1') -Force
    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'

    function New-GateWork {
        $work = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString())
        $env:JIRA_CONFIG_DIR = Join-Path $work '.specify/jira'
        New-Item -ItemType Directory -Path $env:JIRA_CONFIG_DIR -Force | Out-Null
        $featureDir = Join-Path $work 'specs/001-add-payment-webhooks'
        New-Item -ItemType Directory -Path $featureDir -Force | Out-Null
        return (Join-Path $featureDir 'spec.md')
    }

    function Get-GateRouting {
        return (@{ project = 'PROJ'; declared_type_specification = 'Epic'; declared_type_story = 'Story'; terminal_statuses_csv = 'Done' } | ConvertTo-Json -Compress)
    }

    function Get-GateDesignators {
        return '[{"role":"specification","form":"key","key":"PROJ-1","raw":"PROJ-1","position":0},{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0},{"role":"story","form":"key","key":"PROJ-12","raw":"PROJ-12","position":1}]'
    }

    function Write-GateRecord([string] $Spec) {
        $doc = New-JiraSeedStateDocument -Slug 'add-payment-webhooks' -DesignatorsJson (Get-GateDesignators) -PlanDigest '' -RoutingJson (Get-GateRouting) -PlanSnapshotJson '[]'
        Save-JiraSeedState -SpecPath $Spec -DocumentJson $doc
    }

    function Write-TwoStorySpec([string] $Spec) {
        $text = @(
            '# Feature'
            ''
            '### User Story 1 - Accept a partial payment (Priority: P1)'
            '<!-- speckit-jira pin=PROJ-11 -->'
            ''
            'Body one.'
            ''
            '### User Story 2 - Refund a captured payment (Priority: P1)'
            '<!-- speckit-jira pin=PROJ-12 -->'
            ''
            'Body two.'
        ) -join "`n"
        Set-Content -NoNewline -LiteralPath $Spec -Value ($text + "`n")
    }

    function Start-GateMockThreeIssues {
        $issues = @{
            'PROJ-1'  = @{ summary = 'Payment webhooks rollout'; description = 'Parent body'; status = @{ name = 'In Progress' }; issuetype = @{ name = 'Epic' }; project = @{ key = 'PROJ' } }
            'PROJ-11' = @{ summary = 'Accept a partial payment'; description = 'Story one body'; status = @{ name = 'To Do' }; issuetype = @{ name = 'Story' }; project = @{ key = 'PROJ' } }
            'PROJ-12' = @{ summary = 'Refund a captured payment'; description = 'Story two body'; status = @{ name = 'To Do' }; issuetype = @{ name = 'Story' }; project = @{ key = 'PROJ' } }
        }
        $cfgJson = (@{ issues = $issues } | ConvertTo-Json -Depth 20 -Compress)
        $cfg = Write-JiraMockConfig -Json $cfgJson
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
    }

    function Invoke-SeedCaptured {
        param([string[]]$CmdArgs)
        $sw = [System.IO.StringWriter]::new()
        $se = [System.IO.StringWriter]::new()
        $origOut = [Console]::Out
        $origErr = [Console]::Error
        [Console]::SetOut($sw)
        [Console]::SetError($se)
        try { $code = Invoke-JiraSeed -Arguments $CmdArgs }
        finally { [Console]::SetOut($origOut); [Console]::SetError($origErr) }
        return [pscustomobject]@{ ExitCode = [int]$code; Out = $sw.ToString(); Err = $se.ToString() }
    }
}

Describe 'Invoke-JiraSeed: gate provenance, decline, resume' {
    AfterEach {
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
        Remove-Item Env:\SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
    }

    It 'T107: provenance maps each drafted user story to its pin source' {
        $spec = New-GateWork
        Write-TwoStorySpec -Spec $spec
        Write-GateRecord -Spec $spec
        $r = Invoke-SeedCaptured @($spec, '--json')
        $r.ExitCode | Should -Be 0
        $out = $r.Out | ConvertFrom-Json
        $prov = @($out.confirmation_required.provenance)
        (@($prov | Where-Object { $_.source -eq 'PROJ-11' })).Count | Should -Be 1
        (@($prov | Where-Object { $_.source -eq 'PROJ-12' })).Count | Should -Be 1
    }

    It "T107: an unpinned user story maps to source 'new'" {
        $spec = New-GateWork
        $text = @(
            '# Feature'
            ''
            '### User Story 1 - Accept a partial payment (Priority: P1)'
            '<!-- speckit-jira pin=PROJ-11 -->'
            ''
            'Body one.'
            ''
            '### User Story 2 - A brand new story (Priority: P2)'
            ''
            'Body two, unpinned.'
        ) -join "`n"
        Set-Content -NoNewline -LiteralPath $spec -Value ($text + "`n")
        $doc = New-JiraSeedStateDocument -Slug 'add-payment-webhooks' -DesignatorsJson '[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0}]' -PlanDigest '' -RoutingJson (Get-GateRouting) -PlanSnapshotJson '[]'
        Save-JiraSeedState -SpecPath $spec -DocumentJson $doc
        $r = Invoke-SeedCaptured @($spec, '--json')
        $r.ExitCode | Should -Be 0
        $out = $r.Out | ConvertFrom-Json
        $prov = @($out.confirmation_required.provenance)
        (@($prov | Where-Object { $_.source -eq 'new' })).Count | Should -Be 1
    }

    It 'T107: a named parent maps to the Overview section' {
        $spec = New-GateWork
        Write-TwoStorySpec -Spec $spec
        Write-GateRecord -Spec $spec
        $r = Invoke-SeedCaptured @($spec, '--json')
        $r.ExitCode | Should -Be 0
        $out = $r.Out | ConvertFrom-Json
        $prov = @($out.confirmation_required.provenance)
        (@($prov | Where-Object { $_.heading -eq 'Overview' -and $_.source -eq 'PROJ-1' })).Count | Should -Be 1
    }

    It 'T107: provenance is emitted before any Jira mutation (zero writes at the gate)' {
        $spec = New-GateWork
        Write-TwoStorySpec -Spec $spec
        Write-GateRecord -Spec $spec
        $cfg = Write-JiraMockConfig -Json '{}'
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl
        $r = Invoke-SeedCaptured @($spec, '--json')
        $r.ExitCode | Should -Be 0
        @(Get-JiraMockCallLog -Mock $M).Count | Should -Be 0
    }

    It 'C-8: declining leaves the seed record present, pins present, zero identity markers' {
        $spec = New-GateWork
        Write-TwoStorySpec -Spec $spec
        Write-GateRecord -Spec $spec
        $r = Invoke-SeedCaptured @($spec, '--json')
        $r.ExitCode | Should -Be 0
        Read-JiraSeedState -SpecPath $spec | Should -Not -BeNullOrEmpty
        $text = Get-Content -Raw -LiteralPath $spec
        $text | Should -Match 'pin=PROJ-11'
        $text | Should -Match 'pin=PROJ-12'
        $text | Should -Not -Match 'story='
        $text | Should -Not -Match 'spec='
    }

    It 'C-9: resume with the same set returns to the gate, spec.md byte-identical, no REF-EXISTS' {
        $spec = New-GateWork
        Write-TwoStorySpec -Spec $spec
        Write-GateRecord -Spec $spec
        $r1 = Invoke-SeedCaptured @($spec, '--json')
        $r1.ExitCode | Should -Be 0
        $before = Get-Content -Raw -LiteralPath $spec

        Start-GateMockThreeIssues
        $r2 = Invoke-SeedCaptured @($spec, '--json')
        $r2.ExitCode | Should -Be 0
        $r2.Err | Should -Not -Match 'REF-EXISTS'
        (Get-Content -Raw -LiteralPath $spec) | Should -Be $before
    }

    It 'C-10: resume with a different set refuses REF-RESEED, zero writes' {
        $spec = New-GateWork
        Write-TwoStorySpec -Spec $spec
        Write-GateRecord -Spec $spec
        $r1 = Invoke-SeedCaptured @($spec, '--json')
        $r1.ExitCode | Should -Be 0

        $r2 = Invoke-SeedCaptured @($spec, '--parent', 'PROJ-1', '--story', 'PROJ-11', '--story', 'PROJ-99', '--json')
        $r2.ExitCode | Should -Not -Be 0
        $r2.Err | Should -Match 'REF-RESEED'
        Read-JiraSeedState -SpecPath $spec | Should -Not -BeNullOrEmpty
    }

    It 'S-2: the recorded slug is read on resume, never re-derived' {
        $spec = New-GateWork
        Write-TwoStorySpec -Spec $spec
        Write-GateRecord -Spec $spec
        $r1 = Invoke-SeedCaptured @($spec, '--json')
        $r1.ExitCode | Should -Be 0
        $slugBefore = (Read-JiraSeedState -SpecPath $spec | ConvertFrom-Json).slug

        Start-GateMockThreeIssues
        Invoke-RestMethod -Method Put -Uri "$($M.BaseUrl)/rest/api/3/issue/PROJ-1" -ContentType 'application/json' -Body '{"fields":{"description":"Completely different now."}}' | Out-Null

        $r2 = Invoke-SeedCaptured @($spec, '--json')
        $r2.ExitCode | Should -Be 0
        $slugAfter = (Read-JiraSeedState -SpecPath $spec | ConvertFrom-Json).slug
        $slugAfter | Should -Be $slugBefore
    }

    It 'S-3: a key and its URL compare equal across invocations' {
        $spec = New-GateWork
        Write-TwoStorySpec -Spec $spec
        Write-GateRecord -Spec $spec
        $r1 = Invoke-SeedCaptured @($spec, '--json')
        $r1.ExitCode | Should -Be 0

        Start-GateMockThreeIssues
        $r2 = Invoke-SeedCaptured @($spec, '--parent', 'PROJ-1', '--story', "$($M.BaseUrl)/browse/PROJ-11", '--story', 'PROJ-12', '--json')
        $r2.ExitCode | Should -Be 0
        $r2.Err | Should -Not -Match 'REF-RESEED'
    }

    It 'S-4: reordered --story flags refuse REF-RESEED' {
        $spec = New-GateWork
        Write-TwoStorySpec -Spec $spec
        Write-GateRecord -Spec $spec
        $r1 = Invoke-SeedCaptured @($spec, '--json')
        $r1.ExitCode | Should -Be 0

        $r2 = Invoke-SeedCaptured @($spec, '--parent', 'PROJ-1', '--story', 'PROJ-12', '--story', 'PROJ-11', '--json')
        $r2.ExitCode | Should -Not -Be 0
        $r2.Err | Should -Match 'REF-RESEED'
    }

    It 'C-11: a story closed between decline and resume refuses REF-TERMINAL on resume' {
        $spec = New-GateWork
        Write-TwoStorySpec -Spec $spec
        Write-GateRecord -Spec $spec
        $r1 = Invoke-SeedCaptured @($spec, '--json')
        $r1.ExitCode | Should -Be 0

        $issues = @{
            'PROJ-1'  = @{ summary = 'Payment webhooks rollout'; description = 'Parent body'; status = @{ name = 'In Progress' }; issuetype = @{ name = 'Epic' }; project = @{ key = 'PROJ' } }
            'PROJ-11' = @{ summary = 'Accept a partial payment'; description = 'Story one body'; status = @{ name = 'Done' }; issuetype = @{ name = 'Story' }; project = @{ key = 'PROJ' } }
            'PROJ-12' = @{ summary = 'Refund a captured payment'; description = 'Story two body'; status = @{ name = 'To Do' }; issuetype = @{ name = 'Story' }; project = @{ key = 'PROJ' } }
        }
        $cfgJson = (@{ issues = $issues } | ConvertTo-Json -Depth 20 -Compress)
        $cfg = Write-JiraMockConfig -Json $cfgJson
        $script:M = Start-JiraMock -ConfigPath $cfg
        $env:SPEC_KIT_JIRA_BASE_URL = $M.BaseUrl

        $r2 = Invoke-SeedCaptured @($spec, '--json')
        $r2.ExitCode | Should -Not -Be 0
        $r2.Err | Should -Match 'REF-TERMINAL'
        $r2.Err | Should -Match 'PROJ-11'
        Read-JiraSeedState -SpecPath $spec | Should -Not -BeNullOrEmpty
    }

    It 'C-19: a resume issues the same ceil(N/B) reads as the first run, never a comment field' {
        $spec = New-GateWork
        Write-TwoStorySpec -Spec $spec
        Write-GateRecord -Spec $spec
        $r1 = Invoke-SeedCaptured @($spec, '--json')
        $r1.ExitCode | Should -Be 0

        Start-GateMockThreeIssues
        $r2 = Invoke-SeedCaptured @($spec, '--json')
        $r2.ExitCode | Should -Be 0
        $calls = @(Get-JiraMockCallLog -Mock $M)
        (@($calls | Where-Object { $_ -match 'POST /rest/api/3/issue/bulkfetch' })).Count | Should -Be 1
        ($calls -join "`n") | Should -Not -Match '"comment"'
    }

    It 'P-5: a prose rewrite, a renamed heading, and a new unpinned story all pass on resume' {
        $spec = New-GateWork
        Write-TwoStorySpec -Spec $spec
        Write-GateRecord -Spec $spec
        $r1 = Invoke-SeedCaptured @($spec, '--json')
        $r1.ExitCode | Should -Be 0

        $text = @(
            '# Feature'
            ''
            '### User Story 1 - Accept a partial payment, rewritten (Priority: P1)'
            '<!-- speckit-jira pin=PROJ-11 -->'
            ''
            'Body one, entirely rewritten prose.'
            ''
            '### User Story 2 - Refund a captured payment (Priority: P1)'
            '<!-- speckit-jira pin=PROJ-12 -->'
            ''
            'Body two.'
            ''
            '### User Story 3 - A brand new addition (Priority: P2)'
            ''
            'Body three, unpinned, added during review.'
        ) -join "`n"
        Set-Content -NoNewline -LiteralPath $spec -Value ($text + "`n")

        Start-GateMockThreeIssues
        $r2 = Invoke-SeedCaptured @($spec, '--json')
        $r2.ExitCode | Should -Be 0
        $r2.Err | Should -Not -Match 'REF-DRAFT-EDIT'
    }

    It 'P-6: a deleted pinned user story refuses REF-DRAFT-EDIT on resume' {
        $spec = New-GateWork
        Write-TwoStorySpec -Spec $spec
        Write-GateRecord -Spec $spec
        $r1 = Invoke-SeedCaptured @($spec, '--json')
        $r1.ExitCode | Should -Be 0

        $text = @(
            '# Feature'
            ''
            '### User Story 1 - Accept a partial payment (Priority: P1)'
            '<!-- speckit-jira pin=PROJ-11 -->'
            ''
            'Body one.'
        ) -join "`n"
        Set-Content -NoNewline -LiteralPath $spec -Value ($text + "`n")

        Start-GateMockThreeIssues
        $r2 = Invoke-SeedCaptured @($spec, '--json')
        $r2.ExitCode | Should -Not -Be 0
        $r2.Err | Should -Match 'REF-DRAFT-EDIT'
        $r2.Err | Should -Not -Match 'REF-DECOMP'
        $r2.Err | Should -Match 'PROJ-12'
        Read-JiraSeedState -SpecPath $spec | Should -Not -BeNullOrEmpty
    }

    It 'C-12: resume after adding a user story shows the plan and its delta' {
        $spec = New-GateWork
        Write-TwoStorySpec -Spec $spec
        Write-GateRecord -Spec $spec
        $r1 = Invoke-SeedCaptured @($spec, '--json')
        $r1.ExitCode | Should -Be 0
        $out1 = $r1.Out | ConvertFrom-Json
        $planBefore = @($out1.confirmation_required.plan).Count

        $text = @(
            '# Feature'
            ''
            '### User Story 1 - Accept a partial payment (Priority: P1)'
            '<!-- speckit-jira pin=PROJ-11 -->'
            ''
            'Body one.'
            ''
            '### User Story 2 - Refund a captured payment (Priority: P1)'
            '<!-- speckit-jira pin=PROJ-12 -->'
            ''
            'Body two.'
            ''
            '### User Story 3 - A brand new addition (Priority: P2)'
            ''
            'Body three, added during review.'
        ) -join "`n"
        Set-Content -NoNewline -LiteralPath $spec -Value ($text + "`n")

        Start-GateMockThreeIssues
        $r2 = Invoke-SeedCaptured @($spec, '--json')
        $r2.ExitCode | Should -Be 0
        $out2 = $r2.Out | ConvertFrom-Json
        @($out2.confirmation_required.plan).Count | Should -Be $planBefore
        ($out2.confirmation_required.delta.PSObject.Properties.Name -contains 'added') | Should -Be $true
        ($out2.confirmation_required.delta.PSObject.Properties.Name -contains 'removed') | Should -Be $true
    }

    It 'a first gate-reach carries an empty delta (nothing to compare against yet)' {
        $spec = New-GateWork
        Write-TwoStorySpec -Spec $spec
        Write-GateRecord -Spec $spec
        $r = Invoke-SeedCaptured @($spec, '--json')
        $r.ExitCode | Should -Be 0
        $out = $r.Out | ConvertFrom-Json
        @($out.confirmation_required.delta.PSObject.Properties).Count | Should -Be 0
    }
}
