# T061 [US5] — Managed-section / README-block edge cases.
# Mirror of tests/bash/engine/test_readme_edgecases.bats. Absent block appended
# once; malformed markers refused with exit 4 and zero writes (FR 026, FR 027).

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $Engine = Join-Path $Root '.specify/extensions/jira/scripts/powershell/engine'
    $Hooks = Join-Path $Root '.specify/extensions/jira/scripts/powershell/hooks'
    # Import ReadmeBlock first: it internally re-imports ManagedSection -Force, so
    # ManagedSection must be imported LAST to keep its functions callable directly.
    Import-Module (Join-Path $Hooks 'ReadmeBlock.psm1') -Force
    Import-Module (Join-Path $Engine 'ManagedSection.psm1') -Force
    $script:Begin = '<!-- x:begin'
    $script:End = '<!-- x:end'
    $script:Block = "<!-- x:begin v1 -->`nMANAGED LINE A`n<!-- x:end v1 -->"
    # The version is read from the single source (extension.yml), never hardcoded in
    # a test — the version literal must live only in extension.yml (SC-006/FR-022).
    $ExtYml = Join-Path $Root '.specify/extensions/jira/extension.yml'
    $script:VersionRx = [regex]::Escape(
        (Select-String -LiteralPath $ExtYml -Pattern '^version:\s*(.+)$').Matches[0].Groups[1].Value.Trim())
}

Describe 'Managed-section edge cases' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $Work -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $Work 'tmpl'),
            "<!-- spec-kit-jira:begin v{{VERSION}} -->`nMANAGED v{{VERSION}}`n<!-- spec-kit-jira:end v{{VERSION}} -->`n",
            (New-Object System.Text.UTF8Encoding($false)))
        $env:SPEC_KIT_JIRA_README_TEMPLATE = Join-Path $Work 'tmpl'
    }
    AfterEach { Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue }

    It 'appends an absent block once, preserving the original bytes as a prefix' {
        $orig = "# Title`n`nSome content.`n"
        $r = Invoke-JiraManagedSectionSplice -Text $orig -BeginToken $Begin -EndToken $End -NewBlock $Block
        $r.ExitCode | Should -Be 0
        $r.Content.StartsWith($orig) | Should -BeTrue
        ([regex]::Matches($r.Content, [regex]::Escape('x:begin'))).Count | Should -Be 1
        ([regex]::Matches($r.Content, [regex]::Escape('x:end'))).Count | Should -Be 1
    }

    It 'refuses a start marker without an end marker (exit 4, no content)' {
        $r = Invoke-JiraManagedSectionSplice -Text "top`n<!-- x:begin v0 -->`ndangling`n" -BeginToken $Begin -EndToken $End -NewBlock $Block
        $r.ExitCode | Should -Be 4
        $r.Content | Should -BeNullOrEmpty
    }

    It 'refuses an end marker without a start marker (exit 4)' {
        $r = Invoke-JiraManagedSectionSplice -Text "top`n<!-- x:end v0 -->`nbottom`n" -BeginToken $Begin -EndToken $End -NewBlock $Block
        $r.ExitCode | Should -Be 4
        $r.Content | Should -BeNullOrEmpty
    }

    It 'refuses duplicated begin markers (exit 4)' {
        $r = Invoke-JiraManagedSectionSplice -Text "<!-- x:begin v0 -->`nA`n<!-- x:begin v0 -->`nB`n<!-- x:end v0 -->`n" -BeginToken $Begin -EndToken $End -NewBlock $Block
        $r.ExitCode | Should -Be 4
        $r.Content | Should -BeNullOrEmpty
    }

    It 'refuses an end marker preceding a begin marker (exit 4)' {
        $r = Invoke-JiraManagedSectionSplice -Text "<!-- x:end v0 -->`nmid`n<!-- x:begin v0 -->`n" -BeginToken $Begin -EndToken $End -NewBlock $Block
        $r.ExitCode | Should -Be 4
        $r.Content | Should -BeNullOrEmpty
    }

    It 'creates an absent README with only the block' {
        $path = Join-Path $Work 'README.md'
        $res = Set-JiraReadmeBlock -Path $path -DryRun $false
        $res.Status | Should -Be 'created'
        Test-Path -LiteralPath $path | Should -BeTrue
        (Get-Content -Raw -LiteralPath $path) | Should -Match "MANAGED v$VersionRx"
    }

    It 'refuses a malformed README and writes nothing (exit 4)' {
        $path = Join-Path $Work 'README.md'
        [System.IO.File]::WriteAllText($path, "top`n<!-- spec-kit-jira:begin v0.0.9 -->`ndangling`n", (New-Object System.Text.UTF8Encoding($false)))
        $before = [System.IO.File]::ReadAllText($path)
        $res = Set-JiraReadmeBlock -Path $path -DryRun $false
        $res.ExitCode | Should -Be 4
        $res.Status | Should -Be 'refused'
        [System.IO.File]::ReadAllText($path) | Should -BeExactly $before
    }
}
