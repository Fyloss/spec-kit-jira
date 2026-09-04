# T035/T036/T057/T058/T061/T063 [036] — Pester twin of the pure half of
# tests/bash/sink/test_attachments.bats: classification, the manifest, and the
# zero-churn cycle (contracts/artifact-publication.md C1, C4).
#
# The comment body has its own file (CommentBody.Tests.ps1), mirroring the two
# task numbers rather than the Bash port's single file — the Bash suite keeps
# them together because bats has no cheaper unit than a file.
#
# The zero-churn cycle is the assertion that matters most and it is the last
# block: publish, record, re-classify. If the hash does not survive that round
# trip the feature re-uploads everything forever while looking like it works.

BeforeAll {
    $Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/Attachments.psm1') -Force

    $script:SetJson = @'
[
  {"path":"spec.md",         "hash":"aaa","size":10,"attachment_name":"spec.md"},
  {"path":"contracts/api.md","hash":"bbb","size":5, "attachment_name":"contracts__api.md"}
]
'@

    function ConvertFrom-DecisionJson {
        param([string] $Json)
        return , @($Json | ConvertFrom-Json)
    }
}

Describe 'Get-JiraArtifactDecision — the four classifications (C4.1)' {
    It 'C4.1 an artifact absent from the manifest is a first publication' {
        $d = ConvertFrom-DecisionJson (Get-JiraArtifactDecision -SetJson $script:SetJson -ManifestJson '{}' -Limit 100)
        $d[0].action | Should -Be 'published'
        $d[1].action | Should -Be 'published'
    }

    It 'C4.1 an artifact whose hash differs is a revision' {
        $m = '{"spec.md":{"hash":"OLD","attachment_id":"1","run":"after_specify"}}'
        $d = ConvertFrom-DecisionJson (Get-JiraArtifactDecision -SetJson $script:SetJson -ManifestJson $m -Limit 100)
        $d[0].action | Should -Be 'revised'
    }

    It 'C4.1 an artifact whose hash matches is unchanged — the zero-write case' {
        $m = '{"spec.md":{"hash":"aaa","attachment_id":"1","run":"after_specify"}}'
        $d = ConvertFrom-DecisionJson (Get-JiraArtifactDecision -SetJson $script:SetJson -ManifestJson $m -Limit 100)
        $d[0].action | Should -Be 'unchanged'
    }

    It 'C4.3 the trust rule republishes when the ticket does not carry the claimed id' {
        # The manifest is ahead of reality: the property write landed, the
        # upload did not. Without this the artifact reads `unchanged` forever
        # and never actually exists on the ticket.
        $m = '{"spec.md":{"hash":"aaa","attachment_id":"999","run":"after_specify"}}'
        $d = ConvertFrom-DecisionJson (Get-JiraArtifactDecision -SetJson $script:SetJson -ManifestJson $m `
                -Limit 100 -TicketAttachmentIdsJson '["1","2"]')
        $d[0].action | Should -Be 'published'
    }

    It 'C4.3 the trust rule leaves an artifact unchanged when the id IS on the ticket' {
        $m = '{"spec.md":{"hash":"aaa","attachment_id":"1","run":"after_specify"}}'
        $d = ConvertFrom-DecisionJson (Get-JiraArtifactDecision -SetJson $script:SetJson -ManifestJson $m `
                -Limit 100 -TicketAttachmentIdsJson '["1","2"]')
        $d[0].action | Should -Be 'unchanged'
    }

    It 'C1.2 an absent manifest is "nothing published yet", never a fail-closed condition' {
        # A 404 on the property read reaches this function as `{}`. Every
        # artifact is then a first publication — the ordinary state of a first
        # run, and treating it as an error would make every one of them fail.
        $d = ConvertFrom-DecisionJson (Get-JiraArtifactDecision -SetJson $script:SetJson -ManifestJson '{}' -Limit 100)
        @($d | Where-Object { $_.action -ne 'published' }).Count | Should -Be 0
    }
}

Describe 'Get-JiraArtifactDecision — withholding and its precedence (C4.2)' {
    It 'FR-017 an artifact above the discovered limit is withheld, naming size and limit' {
        $d = ConvertFrom-DecisionJson (Get-JiraArtifactDecision -SetJson $script:SetJson -ManifestJson '{}' -Limit 6)
        $d[0].action | Should -Be 'withheld'
        $d[0].reason | Should -Be 'oversized'
        $d[0].size | Should -Be 10
        $d[0].limit | Should -Be 6
        # And the rest still publishes — FR-017's "MUST NOT prevent the remaining".
        $d[1].action | Should -Be 'published'
    }

    It 'FR-005 two artifacts sharing an attachment name are BOTH withheld, each naming the other' {
        $colliding = @'
[
  {"path":"contracts/x.md","hash":"a","size":1,"attachment_name":"c.md"},
  {"path":"c.md",          "hash":"b","size":1,"attachment_name":"c.md"}
]
'@
        $d = ConvertFrom-DecisionJson (Get-JiraArtifactDecision -SetJson $colliding -ManifestJson '{}' -Limit 100)
        $d[0].action | Should -Be 'withheld'
        $d[1].action | Should -Be 'withheld'
        $d[0].reason | Should -Be 'name-collision'
        $d[0].collides_with | Should -Be 'c.md'
        $d[1].collides_with | Should -Be 'contracts/x.md'
    }

    It 'C4.2 a collision outranks an oversize, so warnings are deterministic across ports' {
        $both = @'
[
  {"path":"contracts/x.md","hash":"a","size":9999,"attachment_name":"c.md"},
  {"path":"c.md",          "hash":"b","size":1,   "attachment_name":"c.md"}
]
'@
        $d = ConvertFrom-DecisionJson (Get-JiraArtifactDecision -SetJson $both -ManifestJson '{}' -Limit 10)
        $d[0].reason | Should -Be 'name-collision'
    }

    It 'C4.1 a limit of 0 disables the size gate rather than withholding everything' {
        # A run that could not read the site limit must not silently decide
        # every artifact is too big.
        $d = ConvertFrom-DecisionJson (Get-JiraArtifactDecision -SetJson $script:SetJson -ManifestJson '{}' -Limit 0)
        @($d | Where-Object { $_.action -eq 'withheld' }).Count | Should -Be 0
    }
}

Describe 'New-JiraArtifactManifest — the publication record (data-model §2)' {
    It 'data-model §2 the manifest records path, hash, id and the run that published' {
        $d = Get-JiraArtifactDecision -SetJson $script:SetJson -ManifestJson '{}' -Limit 100
        $created = '[{"id":"10001","filename":"spec.md"},{"id":"10002","filename":"contracts__api.md"}]'
        $m = (New-JiraArtifactManifest -ManifestJson '{}' -DecisionsJson $d -CreatedJson $created `
                -LifecycleEvent 'after_plan') | ConvertFrom-Json
        $m.'spec.md'.hash | Should -Be 'aaa'
        $m.'spec.md'.attachment_id | Should -Be '10001'
        $m.'spec.md'.run | Should -Be 'after_plan'
        $m.'contracts/api.md'.attachment_id | Should -Be '10002'
    }

    It 'data-model §2 an upload that did not land contributes nothing to the manifest' {
        # `Created` is the sink's own response: one entry short means one upload
        # did not happen, and the next run must retry it rather than record it.
        $d = Get-JiraArtifactDecision -SetJson $script:SetJson -ManifestJson '{}' -Limit 100
        $m = (New-JiraArtifactManifest -ManifestJson '{}' -DecisionsJson $d `
                -CreatedJson '[{"id":"10001","filename":"spec.md"}]' -LifecycleEvent 'after_plan') | ConvertFrom-Json
        $m.PSObject.Properties.Name | Should -Contain 'spec.md'
        $m.PSObject.Properties.Name | Should -Not -Contain 'contracts/api.md'
    }

    It 'FR-015 a path no longer in the set keeps its manifest entry' {
        # Its attachment still exists on the ticket, so the manifest still
        # describes reality. Dropping it would make a later re-add look like a
        # first publication.
        $d = Get-JiraArtifactDecision -SetJson $script:SetJson -ManifestJson '{}' -Limit 100
        $prior = '{"gone.md":{"hash":"z","attachment_id":"7","run":"old"}}'
        $m = (New-JiraArtifactManifest -ManifestJson $prior -DecisionsJson $d `
                -CreatedJson '[{"id":"1"},{"id":"2"}]' -LifecycleEvent 'after_plan') | ConvertFrom-Json
        $m.'gone.md'.attachment_id | Should -Be '7'
    }
}

Describe 'Test-JiraManifestOversized — the manifest bound (C4.4)' {
    It 'C4.4.1 a manifest that would exceed the property cap is detected' {
        $entries = [ordered]@{}
        foreach ($i in 0..399) {
            $entries["contracts/c$i.md"] = [ordered]@{
                hash = '0123456789abcdef0123456789abcdef01234567'; attachment_id = '1'; run = 'after_plan'
            }
        }
        $big = ConvertTo-Json -InputObject $entries -Depth 10 -Compress
        (Test-JiraManifestOversized -ArtifactsJson $big) | Should -BeTrue
    }

    It 'C4.4.1 an ordinary manifest is not flagged' {
        $d = Get-JiraArtifactDecision -SetJson $script:SetJson -ManifestJson '{}' -Limit 100
        $m = New-JiraArtifactManifest -ManifestJson '{}' -DecisionsJson $d `
            -CreatedJson '[{"id":"1"},{"id":"2"}]' -LifecycleEvent 'after_plan'
        (Test-JiraManifestOversized -ArtifactsJson $m) | Should -BeFalse
    }
}

Describe 'The zero-churn cycle, end to end (C4.5)' {
    It 'C4.5 publish, record, re-classify: the second pass is entirely unchanged' {
        # THE assertion. If the hash does not survive the manifest round trip,
        # every later run reads "the hash differs" and the feature re-uploads
        # everything forever while looking like it works.
        $d = Get-JiraArtifactDecision -SetJson $script:SetJson -ManifestJson '{}' -Limit 100
        $created = '[{"id":"10001","filename":"spec.md"},{"id":"10002","filename":"contracts__api.md"}]'
        $m = New-JiraArtifactManifest -ManifestJson '{}' -DecisionsJson $d -CreatedJson $created -LifecycleEvent 'after_plan'
        $d2 = ConvertFrom-DecisionJson (Get-JiraArtifactDecision -SetJson $script:SetJson -ManifestJson $m -Limit 100)
        @($d2 | Where-Object { $_.action -ne 'unchanged' }).Count | Should -Be 0
    }

    It 'C4.5 a run with nothing to publish produces an empty part list' {
        $d = Get-JiraArtifactDecision -SetJson $script:SetJson -ManifestJson '{}' -Limit 100
        $m = New-JiraArtifactManifest -ManifestJson '{}' -DecisionsJson $d `
            -CreatedJson '[{"id":"1"},{"id":"2"}]' -LifecycleEvent 'after_plan'
        $d2 = ConvertFrom-DecisionJson (Get-JiraArtifactDecision -SetJson $script:SetJson -ManifestJson $m -Limit 100)
        @($d2 | Where-Object { $_.action -in 'published', 'revised' }).Count | Should -Be 0
    }

    It 'C4.5 changing exactly one artifact republishes exactly that one' {
        $d = Get-JiraArtifactDecision -SetJson $script:SetJson -ManifestJson '{}' -Limit 100
        $m = New-JiraArtifactManifest -ManifestJson '{}' -DecisionsJson $d `
            -CreatedJson '[{"id":"1"},{"id":"2"}]' -LifecycleEvent 'after_plan'
        $changed = @'
[
  {"path":"spec.md",         "hash":"NEW","size":10,"attachment_name":"spec.md"},
  {"path":"contracts/api.md","hash":"bbb","size":5, "attachment_name":"contracts__api.md"}
]
'@
        $d2 = ConvertFrom-DecisionJson (Get-JiraArtifactDecision -SetJson $changed -ManifestJson $m -Limit 100)
        $d2[0].action | Should -Be 'revised'
        $d2[1].action | Should -Be 'unchanged'
    }
}

Describe 'Cross-port byte equivalence of the decision set (Principle VI)' {
    It 'produces the identical canonical document the Bash port produces' {
        # The two ports were compared directly during development and agreed on
        # all five decision shapes; that comparison lived in a shell one-liner
        # and not in either suite, which is the same as it not existing.
        $bash = Join-Path $Root 'scripts/bash/sink/jira/attachments.sh'
        if (-not (Test-Path $bash) -or -not (Get-Command bash -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'no bash on this host'
            return
        }
        $m = '{"spec.md":{"hash":"OLD","attachment_id":"999","run":"after_specify"}}'
        $mine = Get-JiraArtifactDecision -SetJson $script:SetJson -ManifestJson $m -Limit 100 `
            -TicketAttachmentIdsJson '["1","2"]'

        # The three inputs travel through FILES, never through the `bash -c`
        # string. JSON carries the quote characters two shells each want to
        # interpret, and an argument mangled on the way in produces an empty
        # answer that reads exactly like a cross-port divergence.
        $setF = Join-Path $TestDrive 'set.json'
        $manF = Join-Path $TestDrive 'manifest.json'
        $idsF = Join-Path $TestDrive 'ids.json'
        [System.IO.File]::WriteAllText($setF, $script:SetJson)
        [System.IO.File]::WriteAllText($manF, $m)
        [System.IO.File]::WriteAllText($idsF, '["1","2"]')

        # `bash -c`, not a direct source: sourcing a port script at the top
        # level corrupts its own BASH_SOURCE resolution.
        $prog = 'cd "$1" && source scripts/bash/sink/jira/attachments.sh && ' +
        'attachments_classify "$(cat "$2")" "$(cat "$3")" 100 "$(cat "$4")"'
        $theirs = & bash -c $prog '_' $Root $setF $manF $idsF
        ($theirs -join '') | Should -Be $mine
    }
}
