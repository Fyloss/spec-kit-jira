# T045 [036] — Pester twin of the comment-body half of
# tests/bash/sink/test_attachments.bats (contracts/comment-body.md B1-B4, B6).
#
# The two paragraph literals are compared against the CONTRACT'S OWN LINES, not
# against a copy of them written here. A transcription would drift with the
# contract silently, and — measured during this feature — the display layer
# through which a human reads a file can drop words from it, so a literal
# checked by eye is not checked at all.
#
# The Bash twin extracts the same two lines the same way (`sed -n '36p'`, then
# strip the two-space indent). If the contract moves them, both suites fail
# together, which is the intended behaviour: the literal is the contract.

BeforeAll {
    $Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/Attachments.psm1') -Force
    $script:Contract = Join-Path $Root 'specs/036-attach-feature-artifacts/contracts/comment-body.md'

    $script:SetJson = @'
[
  {"path":"spec.md",         "hash":"aaa","size":10,"attachment_name":"spec.md"},
  {"path":"contracts/api.md","hash":"bbb","size":5, "attachment_name":"contracts__api.md"}
]
'@

    # The contract's own line, one-based, with the fenced block's two-space
    # indent removed.
    function Get-ContractLine {
        param([int] $Number)
        return ((Get-Content -LiteralPath $script:Contract)[$Number - 1] -replace '^  ', '')
    }

    # The paragraph as a reader sees it, with the event put back where the
    # contract writes `<event>` — so the comparison is against the contract's
    # line rather than a reconstruction of it.
    function Get-ParagraphText {
        param($Body)
        return "$($Body.content[0].content[0].text)``<event>``$($Body.content[0].content[2].text)"
    }

    function Get-Body {
        param([string] $Event, [string] $ManifestJson = '{}', [int64] $Limit = 100)
        $d = Get-JiraArtifactDecision -SetJson $script:SetJson -ManifestJson $ManifestJson -Limit $Limit
        return (New-JiraArtifactComment -LifecycleEvent $Event -DecisionsJson $d)
    }
}

Describe 'New-JiraArtifactComment — the pinned literals (comment-body.md B2)' {
    It 'B2 the all-new paragraph is byte-identical to the contract literal' {
        $body = (Get-Body -Event 'after_plan') | ConvertFrom-Json
        (Get-ParagraphText -Body $body) | Should -Be (Get-ContractLine -Number 36)
    }

    It 'B2 the revision paragraph is byte-identical to the contract literal' {
        $m = '{"spec.md":{"hash":"OLD","attachment_id":"1","run":"x"}}'
        $body = (Get-Body -Event 'after_plan' -ManifestJson $m) | ConvertFrom-Json
        (Get-ParagraphText -Body $body) | Should -Be (Get-ContractLine -Number 42)
    }

    It 'B2 the lifecycle event is rendered as code-marked text, verbatim' {
        $body = (Get-Body -Event 'after_converge') | ConvertFrom-Json
        $body.content[0].content[1].text | Should -Be 'after_converge'
        $body.content[0].content[1].marks[0].type | Should -Be 'code'
    }

    It 'B2 an empty event — a reconcile invoked directly — still renders' {
        # Not a hook, so there is no event. A Mandatory [string] rejected this
        # at bind time and killed the whole publication on a run with nothing
        # wrong with it; the Bash port has always rendered an empty span.
        $body = (Get-Body -Event '') | ConvertFrom-Json
        $body.content[0].content[1].text | Should -Be ''
        $body.content[0].content[1].marks[0].type | Should -Be 'code'
    }
}

Describe 'New-JiraArtifactComment — the bullet list (B3, B4)' {
    It 'B3 one list item per published artifact, in set order, path code-marked' {
        $body = (Get-Body -Event 'after_plan') | ConvertFrom-Json
        @($body.content[1].content).Count | Should -Be 2
        $body.content[1].content[0].content[0].content[0].text | Should -Be 'spec.md'
        $body.content[1].content[0].content[0].content[0].marks[0].type | Should -Be 'code'
        $body.content[1].content[1].content[0].content[0].text | Should -Be 'contracts/api.md'
    }

    It 'B3 a new artifact reads new and a revised one revised' {
        $m = '{"spec.md":{"hash":"OLD","attachment_id":"1","run":"x"}}'
        $body = (Get-Body -Event 'after_plan' -ManifestJson $m) | ConvertFrom-Json
        $body.content[1].content[0].content[0].content[1].text | Should -Be ' — revised'
        $body.content[1].content[1].content[0].content[1].text | Should -Be ' — new'
    }

    It 'B4 a withheld artifact is ABSENT from the comment' {
        # The comment announces what a reader can now download; naming a file
        # that is not there is worse than silence. The summary reports it.
        $body = (Get-Body -Event 'after_plan' -Limit 6) | ConvertFrom-Json
        @($body.content[1].content).Count | Should -Be 1
        ($body.content[1] | ConvertTo-Json -Depth 20) | Should -Not -Match 'spec\.md'
    }
}

Describe 'New-JiraArtifactComment — the document itself (B1, B6)' {
    It 'B1 the body is a valid ADF doc with no media node' {
        $raw = Get-Body -Event 'after_plan'
        $body = $raw | ConvertFrom-Json
        $body.type | Should -Be 'doc'
        $body.version | Should -Be 1
        $raw | Should -Not -Match '"media"'
    }

    It 'B6.4 the body carries no trailing newline' {
        # PowerShell's pipe to a native command appends one, silently diverging
        # any stdin-fed digest from the Bash port's. The literal is pinned here
        # for that reason.
        $raw = Get-Body -Event 'after_plan'
        $raw.Substring($raw.Length - 1) | Should -Be '}'
    }

    It 'B6.2 a run with nothing to publish composes no bullet at all' {
        # FR-008/SC-004: exactly one comment per PUBLISHING run and zero
        # otherwise. The caller decides whether to post; what is asserted here
        # is that the body it would post announces nothing.
        $d = Get-JiraArtifactDecision -SetJson $script:SetJson -ManifestJson '{}' -Limit 1
        $body = (New-JiraArtifactComment -LifecycleEvent 'after_plan' -DecisionsJson $d) | ConvertFrom-Json
        @($body.content[1].content).Count | Should -Be 0
    }
}

Describe 'Cross-port byte equivalence of the comment body (Principle VI)' {
    It 'produces the identical ADF document the Bash port produces' {
        if (-not (Get-Command bash -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'no bash on this host'
            return
        }
        # Both variants, because the tail literal is the only thing that
        # changes between them and a port could pin one and compose the other.
        foreach ($manifest in '{}', '{"spec.md":{"hash":"OLD","attachment_id":"1","run":"x"}}') {
            $mine = Get-Body -Event 'after_plan' -ManifestJson $manifest

            # The inputs travel through FILES, never through the `bash -c`
            # string: JSON carries the quote characters two shells each want to
            # interpret, and an argument mangled on the way in produces an
            # empty answer that reads exactly like a divergence.
            $setF = Join-Path $TestDrive 'cb-set.json'
            $manF = Join-Path $TestDrive 'cb-manifest.json'
            [System.IO.File]::WriteAllText($setF, $script:SetJson)
            [System.IO.File]::WriteAllText($manF, $manifest)

            $prog = 'cd "$1" && source scripts/bash/sink/jira/attachments.sh && ' +
            'attachments_comment_body after_plan ' +
            '"$(attachments_classify "$(cat "$2")" "$(cat "$3")" 100)"'
            $theirs = & bash -c $prog '_' $Root $setF $manF
            ($theirs -join '') | Should -Be $mine
        }
    }
}
