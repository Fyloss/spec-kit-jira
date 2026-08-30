# T036/T038 [Phase 4, US2] — mirror of
# tests/bash/lib/test_config_routing_default_optional.bats.
# `routing_default` becomes OPTIONAL (contracts/routing-resolution.md
# C5.1-C5.3, spec FR-003). Optional means "may be absent", never "may be
# malformed" and never "is refused".
#
# Asserted against Test-JiraTeamConfig, the direct twin of the bash port's
# _CFG_TEAM_ERRORS_JQ programme: it returns the error list, so an accepted
# configuration is one that produces no error mentioning the key.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $LibDir = Join-Path $Root 'scripts/powershell/lib'
    Import-Module (Join-Path $LibDir 'Config.psm1') -Force

    # The parser reads a FILE, exactly as the bash twin does — there is no
    # text-taking entry point on either port.
    function New-TeamConfigObject {
        param([string[]]$Lines)
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ("cfg-" + [System.Guid]::NewGuid() + ".yml")
        Set-Content -LiteralPath $path -Value ($Lines -join "`n")
        try { return (Read-JiraConfigYamlObject -Path $path) }
        finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'routing_default is optional' {

    It 'C5.1 accepts a team configuration omitting routing_default' {
        $obj = New-TeamConfigObject -Lines @(
            'projects:',
            '  - key: ALPHA',
            '    style: company_managed'
        )
        $errs = @(Test-JiraTeamConfig -Object $obj)
        $errs | Should -Not -Contain 'routing_default must be a valid project key'
    }

    It 'C5.1 an omitted routing_default produces no error at all for a minimal config' {
        $obj = New-TeamConfigObject -Lines @(
            'projects:',
            '  - key: ALPHA',
            '    style: company_managed'
        )
        $errs = @(Test-JiraTeamConfig -Object $obj)
        $errs.Count | Should -Be 0
    }

    It 'C5.1 accepts a configuration omitting routing_default but declaring teams' {
        $obj = New-TeamConfigObject -Lines @(
            'projects:',
            '  - key: ALPHA',
            '    style: company_managed',
            '  - key: BETA',
            '    style: company_managed',
            'teams:',
            '  - id: alpha',
            '    project: ALPHA',
            '    folder_prefix: "alpha-"',
            '    branch_pattern: "alpha-<ID>/<FEATURE_NAME>"'
        )
        $errs = @(Test-JiraTeamConfig -Object $obj)
        $errs.Count | Should -Be 0
    }

    It "C5.2 still refuses a malformed routing_default with today's message" {
        $obj = New-TeamConfigObject -Lines @(
            'projects:',
            '  - key: ALPHA',
            '    style: company_managed',
            'routing_default: lower'
        )
        $errs = @(Test-JiraTeamConfig -Object $obj)
        $errs | Should -Contain 'routing_default must be a valid project key'
    }

    It 'C5.2 refuses a routing_default that does not start with a letter' {
        $obj = New-TeamConfigObject -Lines @(
            'projects:',
            '  - key: ALPHA',
            '    style: company_managed',
            'routing_default: 9NOPE'
        )
        $errs = @(Test-JiraTeamConfig -Object $obj)
        $errs | Should -Contain 'routing_default must be a valid project key'
    }

    It 'C5.3 keeps routing_default a legal top-level key' {
        $obj = New-TeamConfigObject -Lines @(
            'projects:',
            '  - key: ALPHA',
            '    style: company_managed',
            'routing_default: ALPHA'
        )
        $errs = @(Test-JiraTeamConfig -Object $obj)
        $errs | Should -Not -Contain 'unknown top-level key: routing_default'
        $errs.Count | Should -Be 0
    }
}
