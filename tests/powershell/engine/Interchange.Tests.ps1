# T020 — Neutral-interchange schema validation, PowerShell side.
# Mirror of tests/bash/engine/test_interchange.bats. Cross-port agreement proven in bats.

BeforeAll {
    $EngineDir = Join-Path $PSScriptRoot '../../../scripts/powershell/engine'
    Import-Module (Join-Path $EngineDir 'Interchange.psm1') -Force
    $ValidPath = Join-Path $PSScriptRoot '../../conformance/fixtures/neutral-valid.json'
    $script:Valid = Get-Content -Raw $ValidPath
}

Describe 'Test-JiraInterchange' {
    It 'accepts a well-formed document' {
        Test-JiraInterchange $script:Valid | Should -BeTrue
    }

    It 'rejects a wrong schema_version' {
        $bad = ($script:Valid | ConvertFrom-Json)
        $bad.schema_version = '2.0'
        Test-JiraInterchange ($bad | ConvertTo-Json -Depth 100) 2>$null | Should -BeFalse
    }

    It 'rejects a malformed spec_slug' {
        $bad = ($script:Valid | ConvertFrom-Json)
        $bad.spec_ref.spec_slug = 'bad slug'
        Test-JiraInterchange ($bad | ConvertTo-Json -Depth 100) 2>$null | Should -BeFalse
    }

    It 'rejects an invalid project_key' {
        $bad = ($script:Valid | ConvertFrom-Json)
        $bad.routing.project_key = 'proj-1'
        Test-JiraInterchange ($bad | ConvertTo-Json -Depth 100) 2>$null | Should -BeFalse
    }

    It 'rejects an empty stories array' {
        $bad = ($script:Valid | ConvertFrom-Json)
        $bad.stories = @()
        Test-JiraInterchange ($bad | ConvertTo-Json -Depth 100) 2>$null | Should -BeFalse
    }

    It 'rejects invalid JSON input' {
        Test-JiraInterchange 'not json' 2>$null | Should -BeFalse
    }

    It 'rejects a case-variant priority_logical like the Bash port — "p1" is not "P1" (NFR-1)' {
        $bad = ($script:Valid | ConvertFrom-Json)
        $bad.stories[0].priority_logical = 'p1'
        Test-JiraInterchange ($bad | ConvertTo-Json -Depth 100) 2>$null | Should -BeFalse
    }

    It 'rejects a span whose marks is present but not an array (data-model.md §5 rule 3)' {
        $bad = ($script:Valid | ConvertFrom-Json)
        $bad.stories[0].description.blocks[0].spans[0].marks = 'oops'
        $sw = [System.IO.StringWriter]::new()
        $prev = [Console]::Error
        [Console]::SetError($sw)
        try { $result = Test-JiraInterchange ($bad | ConvertTo-Json -Depth 100) }
        finally { [Console]::SetError($prev) }
        $result | Should -BeFalse
        $sw.ToString() | Should -BeLike '*span.marks is required*'
    }

    It 'a document still carrying epic.strategy is not an error — it is simply ignored (008 T024/T026, FR-030)' {
        $bad = ($script:Valid | ConvertFrom-Json)
        $bad.epic | Add-Member -NotePropertyName strategy -NotePropertyValue 'per_repo' -Force
        Test-JiraInterchange ($bad | ConvertTo-Json -Depth 100) | Should -BeTrue
    }

    It 'epic.strategy absent is not an error either — the schema no longer requires it (008 T024/T026)' {
        $ok = ($script:Valid | ConvertFrom-Json)
        $ok.epic.PSObject.Properties.Remove('strategy')
        Test-JiraInterchange ($ok | ConvertTo-Json -Depth 100) | Should -BeTrue
    }
}

Describe 'Test-JiraInterchange — the task tier (Phase 2, T026/T028, data-model.md §3)' {
    It 'a story with no tasks property validates unchanged (FR-011 off switch)' {
        Test-JiraInterchange $script:Valid | Should -BeTrue
    }

    It 'a story with tasks = [] validates' {
        $doc = ($script:Valid | ConvertFrom-Json)
        $doc.stories[0] | Add-Member -NotePropertyName tasks -NotePropertyValue @() -Force
        Test-JiraInterchange ($doc | ConvertTo-Json -Depth 100) | Should -BeTrue
    }

    # Twin of test_interchange.bats "story.tasks must be an array". The Bash
    # rule is `has("tasks") and ((.tasks | type) != "array")` — once the key is
    # present, EVERY non-array type is refused, and the per-task rules never
    # run. A guard that only caught PSCustomObject let `null` and scalars
    # through to `foreach ($tk in @($tasksVal))`, where @($null) yields a
    # one-element array holding $null: the story-level error went missing and
    # four bogus task-level errors took its place (Copilot review, PR #17).
    It 'rejects a non-array story.tasks: <case>' -ForEach @(
        @{ case = 'null'; value = $null }
        @{ case = 'a string'; value = 'not-an-array' }
        @{ case = 'a number'; value = 7 }
        @{ case = 'an object'; value = ([pscustomobject]@{ nope = $true }) }
    ) {
        $doc = ($script:Valid | ConvertFrom-Json)
        $doc.stories[0] | Add-Member -NotePropertyName tasks -NotePropertyValue $value -Force
        # The module reports through [Console]::Error directly, which `2>&1`
        # does not intercept — capture the console writer itself.
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Error
        [Console]::SetError($sw)
        try { $result = Test-JiraInterchange ($doc | ConvertTo-Json -Depth 100) }
        finally { [Console]::SetError($orig) }
        $errText = $sw.ToString()
        $result | Should -BeFalse
        # The story-level refusal, and NOT the per-task rules it short-circuits.
        # Asserting only -BeFalse would pass even with the defect: `null` still
        # returned false, just for four wrong reasons.
        $errText | Should -BeLike '*story.tasks must be an array*'
        $errText | Should -Not -BeLike '*task.title is required*'
    }

    It 'rejects task.local_id missing when the marker state is not absent' {
        $doc = ($script:Valid | ConvertFrom-Json)
        $task = [ordered]@{
            local_id    = ''
            title       = 'T'
            description = [ordered]@{ blocks = @([ordered]@{ type = 'paragraph'; spans = @([ordered]@{ text = 'x'; marks = @() }) }) }
            done        = $false
            marker      = [ordered]@{ state = 'assigned'; id = ''; lines = @() }
        }
        $doc.stories[0] | Add-Member -NotePropertyName tasks -NotePropertyValue @($task) -Force
        Test-JiraInterchange ($doc | ConvertTo-Json -Depth 100) 2>$null | Should -BeFalse
    }

    It 'accepts task.local_id absent when the marker state is absent' {
        $doc = ($script:Valid | ConvertFrom-Json)
        $task = [ordered]@{
            local_id    = ''
            title       = 'T'
            description = [ordered]@{ blocks = @([ordered]@{ type = 'paragraph'; spans = @([ordered]@{ text = 'x'; marks = @() }) }) }
            done        = $false
            marker      = [ordered]@{ state = 'absent'; id = ''; lines = @() }
        }
        $doc.stories[0] | Add-Member -NotePropertyName tasks -NotePropertyValue @($task) -Force
        Test-JiraInterchange ($doc | ConvertTo-Json -Depth 100) | Should -BeTrue
    }

    It 'rejects an empty task.title' {
        $doc = ($script:Valid | ConvertFrom-Json)
        $task = [ordered]@{
            local_id    = '1111111111111111'
            title       = ''
            description = [ordered]@{ blocks = @([ordered]@{ type = 'paragraph'; spans = @([ordered]@{ text = 'x'; marks = @() }) }) }
            done        = $false
            marker      = [ordered]@{ state = 'assigned'; id = '1111111111111111'; lines = @(1) }
        }
        $doc.stories[0] | Add-Member -NotePropertyName tasks -NotePropertyValue @($task) -Force
        Test-JiraInterchange ($doc | ConvertTo-Json -Depth 100) 2>$null | Should -BeFalse
    }

    It 'rejects an empty task.description.blocks' {
        $doc = ($script:Valid | ConvertFrom-Json)
        $task = [ordered]@{
            local_id    = '1111111111111111'
            title       = 'T'
            description = [ordered]@{ blocks = @() }
            done        = $false
            marker      = [ordered]@{ state = 'assigned'; id = '1111111111111111'; lines = @(1) }
        }
        $doc.stories[0] | Add-Member -NotePropertyName tasks -NotePropertyValue @($task) -Force
        Test-JiraInterchange ($doc | ConvertTo-Json -Depth 100) 2>$null | Should -BeFalse
    }

    It 'rejects a non-boolean task.done' {
        $doc = ($script:Valid | ConvertFrom-Json)
        $task = [ordered]@{
            local_id    = '1111111111111111'
            title       = 'T'
            description = [ordered]@{ blocks = @([ordered]@{ type = 'paragraph'; spans = @([ordered]@{ text = 'x'; marks = @() }) }) }
            done        = 'false'
            marker      = [ordered]@{ state = 'assigned'; id = '1111111111111111'; lines = @(1) }
        }
        $doc.stories[0] | Add-Member -NotePropertyName tasks -NotePropertyValue @($task) -Force
        Test-JiraInterchange ($doc | ConvertTo-Json -Depth 100) 2>$null | Should -BeFalse
    }

    It 'rejects two tasks across different stories sharing a local_id' {
        $doc = ($script:Valid | ConvertFrom-Json)
        $mkTask = { param($title) [ordered]@{
                local_id    = '1111111111111111'
                title       = $title
                description = [ordered]@{ blocks = @([ordered]@{ type = 'paragraph'; spans = @([ordered]@{ text = 'x'; marks = @() }) }) }
                done        = $false
                marker      = [ordered]@{ state = 'assigned'; id = '1111111111111111'; lines = @(1) }
            }
        }
        $secondStory = $doc.stories[0] | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $secondStory.local_id = 's2'
        $doc.stories[0] | Add-Member -NotePropertyName tasks -NotePropertyValue @(& $mkTask 'T1') -Force
        $secondStory | Add-Member -NotePropertyName tasks -NotePropertyValue @(& $mkTask 'T2') -Force
        $doc.stories = @($doc.stories) + @($secondStory)
        Test-JiraInterchange ($doc | ConvertTo-Json -Depth 100) 2>$null | Should -BeFalse
    }

    # 016, FR-019 — the task tier obeys the inline model. Feature 012 landed
    # while 016 was in flight and built task descriptions in the PRE-016 shape;
    # nothing caught it, because task descriptions were the one description
    # position not run through the block rules.
    It 'rejects a task description paragraph in the old raw-string shape (FR-019)' {
        $doc = ($script:Valid | ConvertFrom-Json)
        $task = [ordered]@{
            local_id    = '1111111111111111'
            title       = 'T'
            description = [ordered]@{ blocks = @([ordered]@{ type = 'paragraph'; text = 'raw **bold** string' }) }
            done        = $false
            marker      = [ordered]@{ state = 'assigned'; id = '1111111111111111'; lines = @(1) }
        }
        $doc.stories[0] | Add-Member -NotePropertyName tasks -NotePropertyValue @($task) -Force
        $sw = [System.IO.StringWriter]::new()
        $prev = [Console]::Error
        [Console]::SetError($sw)
        try { $result = Test-JiraInterchange ($doc | ConvertTo-Json -Depth 100) }
        finally { [Console]::SetError($prev) }
        $result | Should -BeFalse
        $sw.ToString() | Should -BeLike '*block.spans is required*'
    }

    It 'accepts a task description carrying marked spans (FR-017)' {
        $doc = ($script:Valid | ConvertFrom-Json)
        $task = [ordered]@{
            local_id    = '1111111111111111'
            title       = 'T'
            description = [ordered]@{ blocks = @([ordered]@{ type = 'paragraph'; spans = @([ordered]@{ text = 'engine/x.sh'; marks = @([ordered]@{ kind = 'monospace' }) }) }) }
            done        = $false
            marker      = [ordered]@{ state = 'assigned'; id = '1111111111111111'; lines = @(1) }
        }
        $doc.stories[0] | Add-Member -NotePropertyName tasks -NotePropertyValue @($task) -Force
        Test-JiraInterchange ($doc | ConvertTo-Json -Depth 100) | Should -BeTrue
    }

    It 'rejects an invalid mark kind inside a task description (FR-019)' {
        $doc = ($script:Valid | ConvertFrom-Json)
        $task = [ordered]@{
            local_id    = '1111111111111111'
            title       = 'T'
            description = [ordered]@{ blocks = @([ordered]@{ type = 'paragraph'; spans = @([ordered]@{ text = 'x'; marks = @([ordered]@{ kind = 'underline' }) }) }) }
            done        = $false
            marker      = [ordered]@{ state = 'assigned'; id = '1111111111111111'; lines = @(1) }
        }
        $doc.stories[0] | Add-Member -NotePropertyName tasks -NotePropertyValue @($task) -Force
        Test-JiraInterchange ($doc | ConvertTo-Json -Depth 100) 2>$null | Should -BeFalse
    }

    It 'rejects a non-http link target inside a task description (FR-006)' {
        $doc = ($script:Valid | ConvertFrom-Json)
        $task = [ordered]@{
            local_id    = '1111111111111111'
            title       = 'T'
            description = [ordered]@{ blocks = @([ordered]@{ type = 'paragraph'; spans = @([ordered]@{ text = 'x'; marks = @([ordered]@{ kind = 'link'; href = 'javascript:alert(1)' }) }) }) }
            done        = $false
            marker      = [ordered]@{ state = 'assigned'; id = '1111111111111111'; lines = @(1) }
        }
        $doc.stories[0] | Add-Member -NotePropertyName tasks -NotePropertyValue @($task) -Force
        Test-JiraInterchange ($doc | ConvertTo-Json -Depth 100) 2>$null | Should -BeFalse
    }
}

Describe 'Test-JiraInterchange — the artifact set (036, T016, data-model.md §4)' {
    # Twin of the `036 §4` cases in tests/bash/engine/test_interchange.bats.
    #
    # The single-artifact case is the one that matters most here and looks the
    # least interesting: PowerShell unwraps a one-element collection on `return`,
    # so a one-artifact document was rejected as "artifacts must be an array"
    # while the Bash port accepted it. A two-artifact fixture never shows it.

    BeforeAll {
        function New-ArtifactDoc {
            param([Parameter(Mandatory)][AllowEmptyString()][string] $ArtifactsJson)
            $raw = Get-Content -Raw -LiteralPath $ValidPath
            $doc = $raw | ConvertFrom-Json -Depth 100
            $props = [ordered]@{}
            foreach ($p in $doc.PSObject.Properties) { $props[$p.Name] = $p.Value }
            $props['artifacts'] = ($ArtifactsJson | ConvertFrom-Json -Depth 100 -NoEnumerate)
            return ([pscustomobject] $props | ConvertTo-Json -Depth 100)
        }
        $script:Good = '[{"path":"spec.md","hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":12,"attachment_name":"spec.md"}]'
    }

    It 'accepts a document carrying a well-formed artifacts array' {
        Test-JiraInterchange -Json (New-ArtifactDoc $script:Good) | Should -BeTrue
    }

    It 'accepts a document carrying EXACTLY ONE artifact (the unwrapping trap)' {
        ($script:Good | ConvertFrom-Json -NoEnumerate).Count | Should -Be 1
        Test-JiraInterchange -Json (New-ArtifactDoc $script:Good) | Should -BeTrue
    }

    It 'accepts a document that omits artifacts entirely' {
        Test-JiraInterchange -Json (Get-Content -Raw -LiteralPath $ValidPath) | Should -BeTrue
    }

    It 'accepts an empty artifacts array' {
        Test-JiraInterchange -Json (New-ArtifactDoc '[]') | Should -BeTrue
    }

    It 'rejects an ABSOLUTE artifact path' {
        $a = '[{"path":"/Users/someone/repo/spec.md","hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":12,"attachment_name":"spec.md"}]'
        Test-JiraInterchange -Json (New-ArtifactDoc $a) 2>$null | Should -BeFalse
    }

    It 'rejects an artifact path escaping the feature directory' {
        $a = '[{"path":"../other/spec.md","hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":12,"attachment_name":"spec.md"}]'
        Test-JiraInterchange -Json (New-ArtifactDoc $a) 2>$null | Should -BeFalse
    }

    It 'rejects an artifact entry missing a required key' {
        $a = '[{"path":"spec.md","size":12,"attachment_name":"spec.md"}]'
        Test-JiraInterchange -Json (New-ArtifactDoc $a) 2>$null | Should -BeFalse
    }

    It 'rejects an artifacts value that is not an array' {
        $a = '{"spec.md":"x"}'
        Test-JiraInterchange -Json (New-ArtifactDoc $a) 2>$null | Should -BeFalse
    }

    It 'rejects a negative artifact size' {
        $a = '[{"path":"spec.md","hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":-1,"attachment_name":"spec.md"}]'
        Test-JiraInterchange -Json (New-ArtifactDoc $a) 2>$null | Should -BeFalse
    }
}
