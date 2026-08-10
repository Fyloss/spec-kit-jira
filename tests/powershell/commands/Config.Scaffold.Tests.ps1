# T114a [Phase 8, 022] — mirror of tests/bash/commands/test_config_scaffold.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Config.psm1') -Force
    Import-Module (Join-Path $Root 'scripts/powershell/lib/Output.psm1') -Force
    $script:Template = Join-Path $Root 'templates/config.yml.template'
}

Describe 'The shipped config.yml.template' {
    It 'parses as valid YAML with zero schema errors' {
        # Test-JiraTeamConfig expects the custom YAML parser's Hashtable-based
        # object (Get-CfgProp only handles IDictionary) — not a JSON round-trip
        # PSCustomObject, and not a single-element JSON array ConvertFrom-Json
        # would silently unwrap to a bare object.
        $obj = Read-JiraConfigYamlObject -Path $script:Template
        $errs = Test-JiraTeamConfig -Object $obj
        @($errs).Count | Should -Be 0
    }

    It 'task_mirror is commented out — Get-JiraTaskMirrorFor returns empty for every declared project' {
        $yaml = ConvertFrom-JiraConfigYaml -Path $script:Template
        $obj = $yaml | ConvertFrom-Json -Depth 100
        $obj.PSObject.Properties['task_mirror'] | Should -BeNullOrEmpty
        foreach ($p in @($obj.projects)) {
            (Get-JiraTaskMirrorFor -ProjectKey $p.key -ConfigJson $yaml) | Should -Be ''
        }
    }

    It 'field_defaults is likewise commented out — the template records no default' {
        $yaml = ConvertFrom-JiraConfigYaml -Path $script:Template
        $obj = $yaml | ConvertFrom-Json -Depth 100
        $obj.PSObject.Properties['field_defaults'] | Should -BeNullOrEmpty
    }
}
