# T076 [US8] — Routing resolution, PowerShell side.
# Mirror of tests/bash/engine/test_routing.bats. Cross-port byte agreement is
# proven in bats; here we assert the resolution semantics (FR-041, FR-042).

BeforeAll {
    $EngineDir = Join-Path $PSScriptRoot '../../../.specify/extensions/jira/scripts/powershell/engine'
    Import-Module (Join-Path $EngineDir 'Interchange.psm1') -Force
    $script:Cfg = @'
{
  "routing": [
    {"match": {"folder_prefix": "billing-"}, "project": "BILL"},
    {"match": {"spec_label": "infra"}, "project": "INFRA"},
    {"match": {"folder_prefix": "sec-", "spec_label": "audit"}, "project": "SEC"}
  ],
  "routing_default": "COMP"
}
'@
    function Invoke-Routing([string] $Folder, [string] $Labels, [string] $Config = $script:Cfg) {
        return (Resolve-JiraRouting -FolderName $Folder -LabelsJson $Labels -RoutingConfigJson $Config)
    }
}

Describe 'Resolve-JiraRouting' {
    It 'routes a spec by folder prefix (FR-041)' {
        $r = Invoke-Routing 'billing-payments' '[]'
        $r.ExitCode | Should -Be 0
        $r.ProjectKey | Should -Be 'BILL'
    }

    It 'routes a spec by declared label (FR-041)' {
        $r = Invoke-Routing '001-networking' '["infra"]'
        $r.ExitCode | Should -Be 0
        $r.ProjectKey | Should -Be 'INFRA'
    }

    It 'lets the first matching rule win (FR-041)' {
        $r = Invoke-Routing 'billing-core' '["infra"]'
        $r.ProjectKey | Should -Be 'BILL'
    }

    It 'matches a multi-condition rule only when every condition holds (FR-041)' {
        $r = Invoke-Routing 'sec-hardening' '["audit"]'
        $r.ProjectKey | Should -Be 'SEC'
    }

    It 'skips a multi-condition rule when only one condition holds' {
        $r = Invoke-Routing 'sec-hardening' '[]'
        $r.ProjectKey | Should -Be 'COMP'
    }

    It 'falls back to routing_default for an unmatched spec (FR-041)' {
        $r = Invoke-Routing '999-orphan' '[]'
        $r.ExitCode | Should -Be 0
        $r.ProjectKey | Should -Be 'COMP'
    }

    It 'refuses a no-match spec with no routing_default (FR-041)' {
        $r = Invoke-Routing '999-orphan' '[]' '{"routing":[{"match":{"folder_prefix":"x-"},"project":"X"}]}'
        $r.ExitCode | Should -Be 4
        $r.ProjectKey | Should -Be ''
    }

    It 'routes everything to a bare routing_default (FR-042)' {
        $r = Invoke-Routing 'anything' '["whatever"]' '{"routing_default":"SOLO"}'
        $r.ExitCode | Should -Be 0
        $r.ProjectKey | Should -Be 'SOLO'
    }
}
