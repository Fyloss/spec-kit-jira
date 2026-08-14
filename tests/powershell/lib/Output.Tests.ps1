# T016 — Run-summary rendering, PowerShell side.
# Mirror of tests/bash/lib/test_output.bats. Cross-port byte-parity proven in bats.

BeforeAll {
    $LibDir = Join-Path $PSScriptRoot '../../../scripts/powershell/lib'
    Import-Module (Join-Path $LibDir 'Output.psm1') -Force
}

Describe 'New-JiraSummaryJson' {
    It 'emits canonical JSON with required keys' {
        $json = New-JiraSummaryJson -Command reconcile -Created 1 -Updated 2 -ExitCode 0
        $o = $json | ConvertFrom-Json
        $o.schema_version | Should -Be '1.0'
        $o.command | Should -Be 'reconcile'
        $o.counts.created | Should -Be 1
        $o.counts.updated | Should -Be 2
        $o.exit_code | Should -Be 0
    }

    It 'sorts keys canonically (command first)' {
        (New-JiraSummaryJson -Command config) | Should -Match '^\{"command":'
    }
}

Describe 'ConvertTo-JiraSummaryProse' {
    It 'shows counts and exit' {
        $json = New-JiraSummaryJson -Command reconcile -Created 1 -Updated 2 -Skipped 3
        $prose = ConvertTo-JiraSummaryProse $json
        $prose | Should -Match 'reconcile'
        $prose | Should -Match 'Created: 1'
        $prose | Should -Match 'Updated: 2'
        $prose | Should -Match 'Exit: 0'
    }

    It 'marks a dry-run in the prose' {
        $json = New-JiraSummaryJson -Command reconcile -DryRun $true
        (ConvertTo-JiraSummaryProse $json) | Should -Match 'dry-run'
    }
}

# T098 — the per-project style audit (FR-003) lives at
# effects.discovery.projects.<KEY>.{style,style_source}. It must reach the
# DEFAULT output, not only --json: prose is the default rendering.
# Cross-port byte-parity is proven in tests/bash/lib/test_output.bats.
Describe 'ConvertTo-JiraSummaryProse style audit (T098)' {
    BeforeAll {
        # Two projects, deliberately declared out of order, so the renderer's own
        # ordering (project key, ordinal) is what is asserted.
        $script:AuditJson = '{"command":"config","counts":{"created":0,"errors":0,"skipped":0,"updated":0,"warnings":0},"dry_run":false,"effects":{"discovery":{"detail":"2 project(s) discovered","projects":{"WEX":{"style":"company_managed","style_source":"operator"},"IJT":{"style":"team_managed","style_source":"api"}},"status":"written"},"gitignore":{"detail":"personal.yml gitignore coverage","status":"unchanged"},"hooks":{"detail":"lifecycle hooks already registered","status":"unchanged"},"readme":{"detail":"block present","status":"unchanged"}},"exit_code":0,"schema_version":"1.0"}'
    }

    It 'renders the per-project style audit under the discovery effect' {
        $prose = ConvertTo-JiraSummaryProse $AuditJson
        $prose | Should -BeLike '*    IJT: team_managed (api)*'
        $prose | Should -BeLike '*    WEX: company_managed (operator)*'
    }

    It 'nests the audit under discovery and orders it by project key' {
        $prose = ConvertTo-JiraSummaryProse $AuditJson
        $rendered = $prose -split "`n"
        $discIdx = [array]::FindIndex($rendered, [Predicate[string]] { param($l) $l.StartsWith('  discovery: ') })
        $ijtIdx = [array]::FindIndex($rendered, [Predicate[string]] { param($l) $l.Contains('IJT: ') })
        $wexIdx = [array]::FindIndex($rendered, [Predicate[string]] { param($l) $l.Contains('WEX: ') })
        $hooksIdx = [array]::FindIndex($rendered, [Predicate[string]] { param($l) $l.StartsWith('  hooks: ') })
        # discovery < IJT < WEX < hooks: ordinal key order, inside the discovery block.
        $discIdx | Should -BeLessThan $ijtIdx
        $ijtIdx | Should -BeLessThan $wexIdx
        $wexIdx | Should -BeLessThan $hooksIdx
    }

    It 'adds no style-audit lines when the projects map is empty (degraded run)' {
        $json = '{"command":"config","counts":{"created":0,"errors":0,"skipped":0,"updated":0,"warnings":1},"dry_run":false,"effects":{"discovery":{"detail":"0 project(s) discovered","projects":{},"status":"skipped"},"gitignore":{"detail":"personal.yml gitignore coverage","status":"skipped"}},"exit_code":0,"schema_version":"1.0"}'
        $indented = @((ConvertTo-JiraSummaryProse $json) -split "`n" | Where-Object { $_.StartsWith('    ') })
        $indented.Count | Should -Be 0
    }
}

# T181 [Phase 14, Convergence] — counts.transitioned reaches the PROSE report
# too, not only --json (FR-037). Cross-port byte-parity proven in
# tests/bash/lib/test_output.bats.
Describe 'ConvertTo-JiraSummaryProse Transitioned (T181)' {
    It 'renders Transitioned when the summary carries counts.transitioned' {
        $json = '{"schema_version":"1.0","command":"reconcile","dry_run":false,"counts":{"created":0,"updated":1,"skipped":0,"warnings":0,"errors":0,"transitioned":2},"actions":[],"hook_health":{},"exit_code":0}'
        (ConvertTo-JiraSummaryProse $json) | Should -Match 'Transitioned: 2'
    }

    It 'omits Transitioned when counts.transitioned is absent' {
        $json = '{"schema_version":"1.0","command":"reconcile","dry_run":false,"counts":{"created":0,"updated":0,"skipped":0,"warnings":0,"errors":0},"actions":[],"hook_health":{},"exit_code":0}'
        (ConvertTo-JiraSummaryProse $json) | Should -Not -Match 'Transitioned'
    }
}
