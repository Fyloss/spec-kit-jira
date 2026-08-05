# T009 [US1] — The stray-marker scan. Pester twin of
# tests/bash/engine/test_marker_stray.bats.

BeforeAll {
    $EngineDir = Join-Path $PSScriptRoot '../../../scripts/powershell/engine'
    Import-Module (Join-Path $EngineDir 'MarkerSplice.psm1') -Force
}

Describe 'Get-JiraMarkerSpliceStrayFile' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Work -Force | Out-Null
    }
    AfterEach {
        Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
    }

    It 'a clean folder yields nothing' {
        'no markers here' | Set-Content -LiteralPath (Join-Path $script:Work 'spec.md') -NoNewline
        'no markers here either' | Set-Content -LiteralPath (Join-Path $script:Work 'plan.md') -NoNewline
        (Get-JiraMarkerSpliceStrayFile -Folder $script:Work) | Should -Be ''
    }

    It 'finds a marker-bearing sibling and excludes spec.md' {
        '<!-- speckit-jira spec=0123456789abcdef ticket=COMP-1 -->' | Set-Content -LiteralPath (Join-Path $script:Work 'spec.md') -NoNewline
        @('some text', '<!-- speckit-jira story=abcdef0123456789 ticket=COMP-2 -->') -join "`n" | Set-Content -LiteralPath (Join-Path $script:Work 'plan.md') -NoNewline
        (Get-JiraMarkerSpliceStrayFile -Folder $script:Work) | Should -Be 'plan.md'
    }

    It 'sorts multiple matches as bare file names' {
        'no markers' | Set-Content -LiteralPath (Join-Path $script:Work 'spec.md') -NoNewline
        '<!-- speckit-jira spec=0123456789abcdef -->' | Set-Content -LiteralPath (Join-Path $script:Work 'research.md') -NoNewline
        '<!-- speckit-jira story=abcdef0123456789 -->' | Set-Content -LiteralPath (Join-Path $script:Work 'plan.md') -NoNewline
        (Get-JiraMarkerSpliceStrayFile -Folder $script:Work) | Should -Be 'plan.md, research.md'
    }

    It 'excludes tasks.md — the task tier writes its own markers there (012)' {
        'no markers' | Set-Content -LiteralPath (Join-Path $script:Work 'spec.md') -NoNewline
        @('- [ ] T001 do the thing', '<!-- speckit-jira task=abcdef0123456789 ticket=COMP-3 -->') -join "`n" | Set-Content -LiteralPath (Join-Path $script:Work 'tasks.md') -NoNewline
        (Get-JiraMarkerSpliceStrayFile -Folder $script:Work) | Should -Be ''
    }

    It 'excludes tasks.md while still naming a genuine stray sibling' {
        'no markers' | Set-Content -LiteralPath (Join-Path $script:Work 'spec.md') -NoNewline
        @('- [ ] T001 do the thing', '<!-- speckit-jira task=abcdef0123456789 -->') -join "`n" | Set-Content -LiteralPath (Join-Path $script:Work 'tasks.md') -NoNewline
        '<!-- speckit-jira story=abcdef0123456789 -->' | Set-Content -LiteralPath (Join-Path $script:Work 'plan.md') -NoNewline
        (Get-JiraMarkerSpliceStrayFile -Folder $script:Work) | Should -Be 'plan.md'
    }

    It 'ignores subdirectories — no recursion' {
        'no markers' | Set-Content -LiteralPath (Join-Path $script:Work 'spec.md') -NoNewline
        New-Item -ItemType Directory -Path (Join-Path $script:Work 'contracts') -Force | Out-Null
        '<!-- speckit-jira spec=0123456789abcdef -->' | Set-Content -LiteralPath (Join-Path $script:Work 'contracts/api.md') -NoNewline
        (Get-JiraMarkerSpliceStrayFile -Folder $script:Work) | Should -Be ''
    }

    It 'opens no file for writing — LastWriteTimeUtc untouched' {
        'no markers' | Set-Content -LiteralPath (Join-Path $script:Work 'spec.md') -NoNewline
        $planPath = Join-Path $script:Work 'plan.md'
        '<!-- speckit-jira spec=0123456789abcdef -->' | Set-Content -LiteralPath $planPath -NoNewline
        $before = (Get-Item -LiteralPath $planPath).LastWriteTimeUtc
        Start-Sleep -Seconds 1
        Get-JiraMarkerSpliceStrayFile -Folder $script:Work | Out-Null
        $after = (Get-Item -LiteralPath $planPath).LastWriteTimeUtc
        $after | Should -Be $before
    }
}
