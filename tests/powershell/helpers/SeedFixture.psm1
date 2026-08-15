# tests/powershell/helpers/SeedFixture.psm1 — Pester twin of
# tests/bash/helpers/seed_fixture.bash (T003/T004, 027).

Set-StrictMode -Version Latest

function New-JiraSeedConfig {
    <#
    .SYNOPSIS
      Default hierarchy (Epic/Story), project routing via a single team.
    #>
    param(
        [Parameter(Mandatory)][string] $Dir,
        [string] $ProjectKey = 'PROJ',
        [string] $Team = 'proj'
    )
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $lines = @(
        'projects:'
        "  - key: $ProjectKey"
        '    hierarchy:'
        '      specification: Epic'
        '      story: Story'
        "routing_default: $ProjectKey"
        'teams:'
        "  - id: $Team"
        "    project: $ProjectKey"
        "    folder_prefix: `"$Team-`""
        "    branch_pattern: `"$Team-<ID>/<FEATURE_NAME>`""
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $Dir 'config.yml'), (($lines -join "`n") + "`n"), $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $Dir 'personal.yml'), "team: $Team`n", $utf8NoBom)
}

function New-JiraSeedConfigSafe {
    <#
    .SYNOPSIS
      FR-014: a non-default hierarchy — SAFe-shaped roles, renamed types.
    #>
    param(
        [Parameter(Mandatory)][string] $Dir,
        [string] $ProjectKey = 'SAFE',
        [string] $Team = 'safe'
    )
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $lines = @(
        'projects:'
        "  - key: $ProjectKey"
        '    hierarchy:'
        '      specification: Capability'
        '      story: Feature'
        "routing_default: $ProjectKey"
        'teams:'
        "  - id: $Team"
        "    project: $ProjectKey"
        "    folder_prefix: `"$Team-`""
        "    branch_pattern: `"$Team-<ID>/<FEATURE_NAME>`""
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $Dir 'config.yml'), (($lines -join "`n") + "`n"), $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $Dir 'personal.yml'), "team: $Team`n", $utf8NoBom)
}

Export-ModuleMember -Function New-JiraSeedConfig, New-JiraSeedConfigSafe
