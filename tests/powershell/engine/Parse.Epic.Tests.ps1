# T059/T067 [Phase 5, US2] — The parent's description, PowerShell side.
# Mirror of tests/bash/engine/test_parse_epic.bats. Cross-port parity is
# proven in bats.

BeforeAll {
    $EngineDir = Join-Path $PSScriptRoot '../../../scripts/powershell/engine'
    Import-Module (Join-Path $EngineDir 'Parse.psm1') -Force

    $script:Doc = @'
# Feature Specification: Billing Invoices

We need to let customers export their invoices.

This unlocks self-service billing support.

### User Story 1 - Export a single invoice (Priority: P1)

As a customer I want to export.

### User Story 2 - Bulk export (Priority: P2)

As a customer I want to export many.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A customer exports an invoice in under 5 seconds.
- **SC-002**: Support tickets about missing invoices drop by half.

## Out of Scope

- **Refunds.** Refund processing is handled by a separate system.
- **Bulk import.** Importing invoices is not covered.
'@
}

Describe 'Get-JiraParsedSpec — epic sections (data-model.md §7)' {
    It 'gains a named Success Criteria section as a bullet list, SC-00N labels stripped' {
        $r = Get-JiraParsedSpec -Text $script:Doc -FolderSlug '001-billing' | ConvertFrom-Json
        $blocks = $r.epic.description.blocks
        @($blocks | Where-Object { $_.type -eq 'heading' -and $_.spans[0].text -eq 'Success Criteria' }).Count | Should -Be 1
        $bl = @($blocks | Where-Object { $_.type -eq 'bullet_list' })[0]
        $bl.items[0][0].text | Should -Be 'A customer exports an invoice in under 5 seconds.'
        $bl.items[1][0].text | Should -Be 'Support tickets about missing invoices drop by half.'
        (ConvertTo-Json $blocks -Compress -Depth 10) | Should -Not -BeLike '*SC-001*'
    }

    It 'gains a named Out of Scope section as a bullet list' {
        $r = Get-JiraParsedSpec -Text $script:Doc -FolderSlug '001-billing' | ConvertFrom-Json
        $blocks = $r.epic.description.blocks
        @($blocks | Where-Object { $_.type -eq 'heading' -and $_.spans[0].text -eq 'Out of Scope' }).Count | Should -Be 1
        $bl = @($blocks | Where-Object { $_.type -eq 'bullet_list' })[1]
        $bl.items[0][0].text | Should -BeLike '*Refunds.*'
        $bl.items[1][0].text | Should -BeLike '*Bulk import.*'
    }

    It 'carries no list of user stories (FR-011)' {
        $r = Get-JiraParsedSpec -Text $script:Doc -FolderSlug '001-billing' | ConvertFrom-Json
        $epicJson = ConvertTo-Json $r.epic -Compress -Depth 10
        $epicJson | Should -Not -BeLike '*Export a single invoice*'
        $epicJson | Should -Not -BeLike '*Bulk export (Priority*'
    }

    It 'a specification with neither section is unaffected (no empty heading, no error)' {
        $doc = "# Only A Title`n`nSome prose.`n`n### User Story 1 - A (Priority: P1)`n`nBody.`n"
        $r = Get-JiraParsedSpec -Text $doc -FolderSlug '001-x' | ConvertFrom-Json
        @($r.epic.description.blocks | Where-Object { $_.type -eq 'heading' }).Count | Should -Be 0
    }
}
