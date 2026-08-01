# T021/T022/T029/T032a [Phase 3, US4] — mirror of
# tests/bash/lib/test_config_retired_keys.bats. epic_strategy, task_strategy
# and link_type are retired (spec FR-030/FR-031); a configuration declaring
# any of them is refused, naming the key, project index and file.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $LibDir = Join-Path $Root 'scripts/powershell/lib'
    Import-Module (Join-Path $LibDir 'Config.psm1') -Force

    function Write-TeamConfig {
        param([string]$Dir, [string[]]$Lines)
        Set-Content -LiteralPath (Join-Path $Dir 'config.yml') -Value ($Lines -join "`n")
    }
}

Describe 'Retired configuration keys' {
    BeforeEach {
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Work -Force | Out-Null
    }
    AfterEach { Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue }

    It 'a team configuration declaring none of the three retired keys validates cleanly' {
        Write-TeamConfig $script:Work @('projects:', '  - key: COMP', '    style: company_managed', 'routing_default: COMP')
        $r = Import-JiraConfig -ConfigDir $script:Work
        $r.ExitCode | Should -Be 0
    }

    It 'a configuration declaring epic_strategy is refused, naming the key, project index and file' {
        Write-TeamConfig $script:Work @('projects:', '  - key: COMP', '    style: company_managed', '    epic_strategy: per_repo', 'routing_default: COMP')
        $r = Import-JiraConfig -ConfigDir $script:Work
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'epic_strategy'
        ($r.Errors -join "`n") | Should -Match 'projects\[0\]'
    }

    It 'a configuration declaring all three retired keys is refused with one error per occurrence' {
        Write-TeamConfig $script:Work @('projects:', '  - key: COMP', '    style: company_managed', '    epic_strategy: per_repo', '    task_strategy: linked_story', '    link_type: blocks', 'routing_default: COMP')
        $r = Import-JiraConfig -ConfigDir $script:Work
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'epic_strategy'
        ($r.Errors -join "`n") | Should -Match 'task_strategy'
        ($r.Errors -join "`n") | Should -Match 'link_type'
    }

    It 'T032a — the three keys are gone from scripts, templates, commands and docs, outside the retirement rule' {
        # Searched with Select-String rather than by shelling out to grep: this
        # suite runs on all three hosts, and `grep` is not on a GitHub-hosted
        # Windows runner's PATH — where a missing command is a TERMINATING
        # CommandNotFoundException, so the test would fail on the absence of
        # grep rather than on the presence of a retired key. The bats mirror
        # (tests/bash/lib/test_config_retired_keys.bats) keeps using grep: it
        # only ever runs on a POSIX host.
        $root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $searched = @(
            @('scripts', 'templates', 'commands') |
                ForEach-Object { Join-Path $root $_ } |
                Where-Object { Test-Path -LiteralPath $_ } |
                ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File }
            @('README.md', 'INSTALL.md') |
                ForEach-Object { Join-Path $root $_ } |
                Where-Object { Test-Path -LiteralPath $_ } |
                ForEach-Object { Get-Item -LiteralPath $_ }
        )
        $hits = $searched |
            Select-String -Pattern 'epic_strategy|task_strategy|link_type|SPEC_KIT_JIRA_EPIC_STRATEGY' |
            Where-Object { $_.Line -notmatch 'retired|no longer uses' }
        $hits | Should -BeNullOrEmpty
    }
}
