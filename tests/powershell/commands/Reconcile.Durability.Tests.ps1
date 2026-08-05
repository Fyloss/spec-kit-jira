# T041-T042 [Phase 5, US3] / T071 — recognition depends on nothing
# machine-local, PowerShell side. Mirror of
# tests/bash/commands/test_reconcile_durability.bats. Cross-port parity is
# proven in bats.

BeforeAll {
    $CmdDir = Join-Path $PSScriptRoot '../../../scripts/powershell/commands'
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    $Mock = Join-Path $PSScriptRoot '../../conformance/mock-jira'
    $Fixture = Join-Path $PSScriptRoot '../../conformance/fixtures/repo-with-mirrored-spec'
    Import-Module (Join-Path $Mock 'Mock.psm1') -Force
    Import-Module (Join-Path $CmdDir 'Reconcile.psm1') -Force
    Import-Module (Join-Path $SinkDir 'Recognition.psm1') -Force

    $env:JIRA_EMAIL = 'user@example.com'
    $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
    $env:JIRA_NO_SLEEP = '1'
    $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111 2222222222222222 3333333333333333'
    Remove-Item Env:\SPEC_KIT_JIRA_PLAN_CONTEXT -ErrorAction SilentlyContinue
    Remove-Item Env:\SPEC_KIT_JIRA_LIFECYCLE -ErrorAction SilentlyContinue
    # Relies on config.yml-based routing (folder prefix "001-" -> COMP); clear
    # any override an earlier suite in the same Pester process left behind.
    Remove-Item Env:\SPEC_KIT_JIRA_PROJECT_KEY -ErrorAction SilentlyContinue

    function Invoke-Captured {
        param([string[]] $ArgList)
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { $null = Invoke-JiraReconcile -Arguments $ArgList } finally { [Console]::SetOut($orig) }
        return $sw.ToString()
    }
}

Describe 'Invoke-JiraReconcile — no machine-local state' {
    AfterEach { Remove-Item Env:\SPEC_KIT_JIRA_SPEC_SLUG -ErrorAction SilentlyContinue; if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It 'recognition succeeds with no local run history at all — no state file, empty HOME' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $work
        $spec = Join-Path $work 'specs/001-billing-invoices/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $work '.specify/jira'
        $null = Invoke-Captured @('reconcile', $spec, '--json')

        # A run from a completely empty $HOME and no XDG cache/state dirs:
        # nothing this feature reads or writes lives outside spec.md and the
        # Jira API.
        $emptyHome = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $emptyHome | Out-Null
        Clear-Content -LiteralPath $script:M.CallLog

        $oldHome = $env:HOME; $oldCache = $env:XDG_CACHE_HOME; $oldState = $env:XDG_STATE_HOME
        $env:HOME = $emptyHome; $env:XDG_CACHE_HOME = "$emptyHome/.cache"; $env:XDG_STATE_HOME = "$emptyHome/.state"
        try {
            $r = Invoke-Captured @('reconcile', $spec, '--json') | ConvertFrom-Json
        }
        finally { $env:HOME = $oldHome; $env:XDG_CACHE_HOME = $oldCache; $env:XDG_STATE_HOME = $oldState }

        $r.counts.created | Should -Be 0
        $r.counts.recognised | Should -Be 3
        (Test-Path (Join-Path $emptyHome '.cache')) | Should -BeFalse
        (Test-Path (Join-Path $emptyHome '.state')) | Should -BeFalse
    }

    It 'a renamed specification folder still recognises its STORY tickets and creates none' {
        # This proves story recognition's rename tolerance (its durable
        # `story` identifier, decoupled from spec_slug) — not the parent's,
        # which the contract deliberately keeps slug-sensitive
        # (contracts/hierarchy-resolution.md §7); that is covered on its
        # own in Recognition.Parent.Tests.ps1. A caller that renames a spec
        # folder mid-lifecycle keeps SPEC_KIT_JIRA_SPEC_SLUG stable across
        # the rename in practice, which this test mirrors.
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-billing-invoices'
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $work
        $spec = Join-Path $work 'specs/001-billing-invoices/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $work '.specify/jira'
        $null = Invoke-Captured @('reconcile', $spec, '--json')

        $renamedDir = Join-Path $work 'specs/001-billing-invoices-renamed'
        Move-Item -Path (Join-Path $work 'specs/001-billing-invoices') -Destination $renamedDir
        $renamedSpec = Join-Path $renamedDir 'spec.md'

        Clear-Content -LiteralPath $script:M.CallLog
        $r = Invoke-Captured @('reconcile', $renamedSpec, '--json') | ConvertFrom-Json
        $r.counts.created | Should -Be 0
        $r.counts.recognised | Should -Be 3
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -eq 'POST /rest/api/3/issue' }).Count | Should -Be 0
    }

    It "re-routed: the catalogued notice names the story, the former key and project, and the new key (T071)" {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $Fixture $work
        $spec = Join-Path $work 'specs/001-billing-invoices/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $work '.specify/jira'

        @(
            '# Feature Specification: Billing Invoices', '',
            '### User Story 1 - Export a single invoice (Priority: P1)',
            '<!-- speckit-jira story=1111111111111111 ticket=LEGACY-42 -->', '',
            'As a customer, I want to export one invoice as a PDF.', '',
            '- **Given** a signed-in customer viewing an invoice',
            '- **When** they choose Export',
            '- **Then** a PDF download starts'
        ) -join "`n" | Set-Content -NoNewline -Path $spec

        $r = Invoke-Captured @('reconcile', $spec, '--json') | ConvertFrom-Json
        $r.counts.created | Should -Be 2

        $note = if (@($r.notes).Count -gt 0) { [string]$r.notes[0] } else { '' }
        $note | Should -BeLike '*1111111111111111*'
        $note | Should -BeLike '*LEGACY-42*'
        $note | Should -BeLike '*in project LEGACY*'
        $note | Should -BeLike '*mirrored into COMP as COMP-2*'

        # the recorded marker now names the new ticket; the former one is
        # left untouched — no write was ever issued to it. COMP-1 is the
        # parent (Phase 5, US2), created first.
        (Get-Content -Raw -LiteralPath $spec) | Should -BeLike '*ticket=COMP-2*'
        (Get-Content -Raw -LiteralPath $spec) | Should -Not -BeLike '*ticket=LEGACY-42*'
        @(Get-JiraMockCallLog -Mock $script:M | Where-Object { $_ -match 'LEGACY-42' }).Count | Should -Be 0
    }
}

Describe 'Invoke-JiraReconcile — T061 [016] FR-000/FR-000a prose durability' {
    BeforeEach {
        $script:MarkdownFixture = Join-Path $Mock '../../conformance/fixtures/repo-with-markdown-prose'
    }
    AfterEach {
        Remove-Item Env:\SPEC_KIT_JIRA_SPEC_SLUG -ErrorAction SilentlyContinue
        $env:SPEC_KIT_JIRA_ID_SOURCE = '1111111111111111 2222222222222222 3333333333333333'
        if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null }
    }

    It 'a real run leaves every byte of the spec file unchanged except the speckit-jira marker lines' {
        $pristine = Join-Path $script:MarkdownFixture 'specs/001-markdown-prose/spec.md'
        $work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $script:MarkdownFixture $work
        $spec = Join-Path $work 'specs/001-markdown-prose/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $work '.specify/jira'
        $env:SPEC_KIT_JIRA_REPO = 'acme/app'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-markdown-prose'
        $env:SPEC_KIT_JIRA_ID_SOURCE = 'aaaaaaaaaaaaaaaa 1111111111111111'
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $null = Invoke-Captured @('reconcile', $spec, '--json')

        $pristineLines = Get-Content -LiteralPath $pristine | Where-Object { $_ -notmatch 'speckit-jira ' }
        $specLines = Get-Content -LiteralPath $spec | Where-Object { $_ -notmatch 'speckit-jira ' }
        (Compare-Object $pristineLines $specLines) | Should -BeNullOrEmpty
        (Get-Content -Raw -LiteralPath $spec) | Should -Match 'speckit-jira '
    }

    It 'a --dry-run leaves the spec file byte-identical, including its marker lines (there are none to add)' {
        $pristine = Join-Path $script:MarkdownFixture 'specs/001-markdown-prose/spec.md'
        $work = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Copy-Item -Recurse $script:MarkdownFixture $work
        $spec = Join-Path $work 'specs/001-markdown-prose/spec.md'
        $env:JIRA_CONFIG_DIR = Join-Path $work '.specify/jira'
        $env:SPEC_KIT_JIRA_REPO = 'acme/app'
        $env:SPEC_KIT_JIRA_SPEC_SLUG = '001-markdown-prose'
        $env:SPEC_KIT_JIRA_ID_SOURCE = 'aaaaaaaaaaaaaaaa 1111111111111111'
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        $null = Invoke-Captured @('reconcile', $spec, '--dry-run', '--json')

        (Get-Content -Raw -LiteralPath $spec) | Should -Be (Get-Content -Raw -LiteralPath $pristine)
    }
}

Describe 'Invoke-JiraRecognitionRun — scoped to the routed project' {
    AfterEach { Remove-Item Env:\SPEC_KIT_JIRA_SPEC_SLUG -ErrorAction SilentlyContinue; if ($script:M) { Stop-JiraMock -Mock $script:M; $script:M = $null } }

    It "recognition is scoped to the routed project: two specs mirrored into different projects never recognise each other's tickets" {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl

        # Reuse the SAME durable identifier across two DIFFERENT
        # specifications, mirrored into two DIFFERENT projects. Recognition
        # must never let one spec's marker satisfy the other's.
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'a') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'b') -Force | Out-Null
        $specA = Join-Path $TestDrive 'a/spec.md'
        $specB = Join-Path $TestDrive 'b/spec.md'
        @('### User Story 1 - Alpha (Priority: P1)', '<!-- speckit-jira story=1111111111111111 ticket=OTHER-1 -->', '', 'Alpha body.') -join "`n" | Set-Content -NoNewline -Path $specA
        @('### User Story 1 - Beta (Priority: P1)', '<!-- speckit-jira story=1111111111111111 ticket=COMP-9 -->', '', 'Beta body.') -join "`n" | Set-Content -NoNewline -Path $specB

        $stories = '[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"OTHER-1"}}]'
        $specRefB = '{"repo":"acme/app","spec_slug":"002-beta","folder":"x"}'
        $r = Invoke-JiraRecognitionRun -StoriesJson $stories -SpecRefJson $specRefB -ProjectKey 'COMP' -SpecPath $specB
        $r.ExitCode | Should -Be 0
        # OTHER-1 does not belong to the routed COMP project: mirrored as
        # new, the former ticket left untouched (US3 re-routed case, FR-019).
        ($r.Json | ConvertFrom-Json).new[0] | Should -Be '1111111111111111'
    }

    It 'a story whose recorded ticket lives outside the routed project is mirrored into the routed project, not blocked' {
        $script:M = Start-JiraMock -ConfigPath (Join-Path $Mock 'configs/default.json')
        $env:SPEC_KIT_JIRA_BASE_URL = $script:M.BaseUrl
        $stories = '[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"LEGACY-42"}}]'
        $specRef = '{"repo":"acme/app","spec_slug":"001-billing","folder":"x"}'
        $r = Invoke-JiraRecognitionRun -StoriesJson $stories -SpecRefJson $specRef -ProjectKey 'COMP' -SpecPath 'spec.md'
        $r.ExitCode | Should -Be 0
        $out = $r.Json | ConvertFrom-Json
        @($out.blocked).Count | Should -Be 0
        $out.new[0] | Should -Be '1111111111111111'
    }
}
