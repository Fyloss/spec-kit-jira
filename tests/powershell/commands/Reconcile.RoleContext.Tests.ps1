# T011, T013 [Phase 2, Foundational] — the phase->status map's two accepted
# shapes normalise to the per-role resolved form of data-model.md §1
# (contract role-lifecycle-config.md §2/§4), PowerShell port. Mirror of
# tests/bash/commands/test_reconcile_role_context.bats.
#
# T010/T014 (every lifecycle-context entry's role matches the tier it was
# recognised at, and the whole existing safety corpus stays byte-identical
# once the context gains role) are proven by the two-role-workflow
# isolation test — tests/powershell/commands/Reconcile.TwoRoleIsolation.
# Tests.ps1's T079 — and by the full regression sweep this feature's every
# other phase already runs unchanged.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force
}

Describe 'Get-JiraReconcilePhaseStatusMap — the per-role resolved form' {
    It 'T013 -- a role-blind mapping (every key a lifecycle event) resolves wholesale under "story", the other two roles empty' {
        $cfg = '{"projects":[{"key":"COMP","phase_status_map":{"after_specify":"To Do","after_plan":"In Progress"}}]}'
        $resolved = InModuleScope Reconcile -Parameters @{ Cfg = $cfg } {
            Get-JiraReconcilePhaseStatusMap -ProjectKey 'COMP' -ConfigJson $Cfg
        } | ConvertFrom-Json -Depth 100
        ($resolved.PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be 'specification,story,task'
        $resolved.story.after_specify | Should -Be 'To Do'
        $resolved.story.after_plan | Should -Be 'In Progress'
        @($resolved.specification.PSObject.Properties).Count | Should -Be 0
        @($resolved.task.PSObject.Properties).Count | Should -Be 0
    }

    It 'T013 -- a per-role mapping (every key a hierarchy role) is used as-is, all three keys present' {
        $cfg = '{"projects":[{"key":"COMP","phase_status_map":{"specification":{"after_specify":"Funnel"},"story":{"after_specify":"To Do"}}}]}'
        $resolved = InModuleScope Reconcile -Parameters @{ Cfg = $cfg } {
            Get-JiraReconcilePhaseStatusMap -ProjectKey 'COMP' -ConfigJson $Cfg
        } | ConvertFrom-Json -Depth 100
        $resolved.specification.after_specify | Should -Be 'Funnel'
        $resolved.story.after_specify | Should -Be 'To Do'
        # task was never declared: present as an empty object, never absent.
        $resolved.PSObject.Properties.Name | Should -Contain 'task'
        @($resolved.task.PSObject.Properties).Count | Should -Be 0
    }

    It 'T013 -- a project declaring no phase_status_map at all resolves to all three roles empty' {
        $cfg = '{"projects":[{"key":"COMP"}]}'
        $resolved = InModuleScope Reconcile -Parameters @{ Cfg = $cfg } {
            Get-JiraReconcilePhaseStatusMap -ProjectKey 'COMP' -ConfigJson $Cfg
        } | ConvertFrom-Json -Depth 100
        @($resolved.specification.PSObject.Properties).Count | Should -Be 0
        @($resolved.story.PSObject.Properties).Count | Should -Be 0
        @($resolved.task.PSObject.Properties).Count | Should -Be 0
    }
}
