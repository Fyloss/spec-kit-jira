# T062 [US5] — README-block idempotency (FR 028, FR 029).
# Mirror of tests/bash/engine/test_readme_idempotent.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $Hooks = Join-Path $Root '.specify/extensions/jira/scripts/powershell/hooks'
    Import-Module (Join-Path $Hooks 'ReadmeBlock.psm1') -Force
    # The version is read from the single source (extension.yml), never hardcoded in
    # a test — the version literal must live only in extension.yml (SC-006/FR-022).
    $ExtYml = Join-Path $Root '.specify/extensions/jira/extension.yml'
    $script:VersionRx = [regex]::Escape(
        (Select-String -LiteralPath $ExtYml -Pattern '^version:\s*(.+)$').Matches[0].Groups[1].Value.Trim())
}

Describe 'README-block idempotency' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $Work -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $Work 'tmpl'),
            "<!-- spec-kit-jira:begin v{{VERSION}} -->`nMANAGED v{{VERSION}}`n<!-- spec-kit-jira:end v{{VERSION}} -->`n",
            (New-Object System.Text.UTF8Encoding($false)))
        $env:SPEC_KIT_JIRA_README_TEMPLATE = Join-Path $Work 'tmpl'
        $script:Path = Join-Path $Work 'README.md'
    }
    AfterEach { Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue }

    It 'reports unchanged and rewrites nothing on a second run' {
        Set-JiraReadmeBlock -Path $Path -DryRun $false | Out-Null
        $snap = [System.IO.File]::ReadAllText($Path)
        $res = Set-JiraReadmeBlock -Path $Path -DryRun $false
        $res.Status | Should -Be 'unchanged'
        [System.IO.File]::ReadAllText($Path) | Should -BeExactly $snap
    }

    It 'regenerates a hand-edited block and reports it written' {
        Set-JiraReadmeBlock -Path $Path -DryRun $false | Out-Null
        $tampered = (Get-Content -Raw -LiteralPath $Path) -replace "MANAGED v$VersionRx", 'HUMAN EDIT'
        [System.IO.File]::WriteAllText($Path, $tampered, (New-Object System.Text.UTF8Encoding($false)))
        $res = Set-JiraReadmeBlock -Path $Path -DryRun $false
        $res.Status | Should -Be 'written'
        $content = Get-Content -Raw -LiteralPath $Path
        $content | Should -Match "MANAGED v$VersionRx"
        $content | Should -Not -Match 'HUMAN EDIT'
    }

    It 'dry-run reports the status without writing the file' {
        $res = Set-JiraReadmeBlock -Path $Path -DryRun $true
        $res.Status | Should -Be 'created'
        Test-Path -LiteralPath $Path | Should -BeFalse
    }

    It 'byte-preserves content outside a present block across an update' {
        [System.IO.File]::WriteAllText($Path,
            "INTRO LINE`n`n<!-- spec-kit-jira:begin v0.0.1 -->`nold`n<!-- spec-kit-jira:end v0.0.1 -->`n`nOUTRO LINE`n",
            (New-Object System.Text.UTF8Encoding($false)))
        $res = Set-JiraReadmeBlock -Path $Path -DryRun $false
        $res.Status | Should -Be 'written'
        $content = Get-Content -Raw -LiteralPath $Path
        $content.StartsWith('INTRO LINE') | Should -BeTrue
        $content.TrimEnd("`n").EndsWith('OUTRO LINE') | Should -BeTrue
        $content | Should -Match "MANAGED v$VersionRx"
    }

    It 'renders the version-marked block from the single source' {
        $block = Get-JiraReadmeBlock
        $block | Should -Match "spec-kit-jira:begin v$VersionRx"
        $block | Should -Match "spec-kit-jira:end v$VersionRx"
    }
}
