# commands/Seed.psm1 — Moment 2: `speckit.jira.seed`. Mirror of
# commands/seed.sh (027, research R1/R7, contract seed-cli-contract.md §4/§5).
#
# `-Parent`/`-Story` are accepted here too (contract §2, "feature and seed
# alike"), but only to let the operator RE-STATE the designator set as a
# safety check (S-3/S-4): when neither flag is supplied, the recorded set is
# used as-is and every ordinary decline/resume cycle needs no flags at all.
# Supplying a different set refuses REF-RESEED before any read.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../lib/Cli.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../lib/Output.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../lib/Config.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../lib/SeedState.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../engine/PinMarker.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../engine/MarkerSplice.psm1') -Force
# StoryMarker.psm1 is NOT imported directly here: SpecMarker.psm1 already
# imports it with -Global (project memory: a second direct import here would
# load a SECOND instance with its own $script:JiraStoryMarkerIdIndex, so the
# spec marker and the first story marker would both draw index 0 from the
# SPEC_KIT_JIRA_ID_SOURCE seam instead of sharing one sequence).
Import-Module (Join-Path $PSScriptRoot '../engine/SpecMarker.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../sink/jira/Identity.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../sink/jira/Designator.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../sink/jira/Adoption.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../sink/jira/Ticket.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../sink/jira/Client.psm1')    # No -Force — see project memory: powershell-import-force-clobbers-caller-scope
Import-Module (Join-Path $PSScriptRoot '../sink/jira/PrivacyGuard.psm1') -Force

function Write-JiraSeedResult {
    param([string] $Payload, [bool] $Json)
    if ($Json) {
        [Console]::Out.Write($Payload + "`n")
    }
    else {
        [Console]::Out.Write((ConvertTo-JiraSeedProse -Json $Payload))
    }
}

function Get-JiraSeedDesignatorKey {
    # The ordered array of designated keys (role=story) recorded in the seed
    # record, for Test-JiraPinMarkerValidate. Mirror of _seed_designator_keys.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RecordJson)
    $rec = $RecordJson | ConvertFrom-Json -Depth 100
    $keys = @($rec.designators | Where-Object { $_.role -eq 'story' } | ForEach-Object { $_.key })
    return (ConvertTo-JiraJsonValue $keys)
}

function Get-JiraSeedParentDesignator {
    <#
    .SYNOPSIS
      The recorded specification-role designator object, or $null when none
      is recorded. Mirror of _seed_parent_designator.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RecordJson)
    $rec = $RecordJson | ConvertFrom-Json -Depth 100
    return (@($rec.designators | Where-Object { $_.role -eq 'specification' }) | Select-Object -First 1)
}

function Get-JiraSeedPartialReport {
    <#
    .SYNOPSIS
      FR-042 (T159): the report of exactly which bindings completed and
      which did not, for the failure path of a --confirm run. `Bindings` is
      grown ONLY on a successful write, so "remaining" is everything else
      this run intended to bind: the parent designator, when `Mode` names
      one and no parent binding is in `Bindings` yet, plus every story key
      in `RemainingStoryKeysJson` not already in `Bindings`. Mirror of
      _seed_partial_report.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Bindings,
        [Parameter(Mandatory)] [string] $Mode,
        [string] $TargetKey = '',
        [string] $FreeText = '',
        [Parameter(Mandatory)] [string] $RemainingStoryKeysJson
    )
    $bindingsArr = @($Bindings)
    $doneStories = @($bindingsArr | Where-Object { $_.role -eq 'story' } | ForEach-Object { [string]$_.key })
    $parentDesig = ''
    if ($Mode -ne 'none' -and (@($bindingsArr | Where-Object { $_.role -eq 'parent' })).Count -eq 0) {
        $parentDesig = if ($Mode -eq 'create') { $FreeText } else { $TargetKey }
    }
    $remKeys = @($RemainingStoryKeysJson | ConvertFrom-Json -Depth 100)
    $remaining = [System.Collections.Generic.List[object]]::new()
    if ($parentDesig) { $remaining.Add($parentDesig) }
    foreach ($k in $remKeys) { if ($doneStories -notcontains [string]$k) { $remaining.Add([string]$k) } }
    return (ConvertTo-JiraJsonValue ([ordered]@{ bindings = $bindingsArr; remaining = $remaining }))
}

function Get-JiraSeedRefMessage {
    <#
    .SYNOPSIS
      REF-DESIGNATOR/REF-HOST/REF-DUPLICATE/REF-RESEED message +
      remediation. Mirror of _seed_ref_message.
    #>
    param([string] $Code, [string] $Detail)
    switch ($Code) {
        'REF-DESIGNATOR' { return "${Code}: $Detail — paste the issue key or the browser URL of the issue; or, for a parent to create, type its title" }
        'REF-HOST' { return "${Code}: $Detail — paste a URL from the configured site, or correct the site base URL in the configuration" }
        'REF-DUPLICATE' { return "${Code}: $Detail — remove the duplicate designator" }
        'REF-MULTIPROJECT' { return "${Code}: $Detail — name issues from one project per specification" }
        'REF-RESEED' { return "${Code}: $Detail — re-invoke with the recorded set, or create a new specification" }
        default { return "${Code}: $Detail" }
    }
}

function Get-JiraSeedDecompMessage {
    <#
    .SYNOPSIS
      One human line per FR-058 violation (P1-P4), naming the offending
      key/line. Mirror of _seed_decomp_message. A FIRST run: the drafted
      decomposition disagreed with the human's.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ViolationsJson)
    $violations = @($ViolationsJson | ConvertFrom-Json -Depth 100)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($v in $violations) {
        switch ($v.kind) {
            'missing' { $out.Add("designated key $($v.key) carries no pinning marker — add <!-- speckit-jira pin=$($v.key) --> after its user story heading, or re-invoke with a different designator set") }
            'orphan' { $out.Add("marker names $($v.key), which was not designated (line $($v.lines[0])) — remove the marker, or add $($v.key) to the designator set") }
            'split' { $out.Add("key $($v.key) carries more than one marker (line $(($v.lines -join ', '))) — keep exactly one") }
            'merge' { $out.Add("more than one marker names the same user story (line $(($v.lines -join ', '))) — one marker per user story") }
            'malformed' { $out.Add("malformed pinning marker at line $($v.line) — the pin= value must be non-empty and contain no whitespace") }
            'reorder' { $out.Add('the pinned user stories are not in the order the issues were designated — reorder them to match, or re-invoke with the current order') }
            default { $out.Add('pinning validation failed') }
        }
    }
    return $out
}

function Get-JiraSeedDraftEditMessage {
    <#
    .SYNOPSIS
      The same four properties as Get-JiraSeedDecompMessage, worded for a
      RESUME (REF-DRAFT-EDIT, FR-063): the cause is the operator's own edit
      to spec.md, not the agent's draft.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ViolationsJson)
    $violations = @($ViolationsJson | ConvertFrom-Json -Depth 100)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($v in $violations) {
        switch ($v.kind) {
            'missing' { $out.Add("the pinned user story for $($v.key) has vanished — restore its heading and the <!-- speckit-jira pin=$($v.key) --> marker, or start over with a new specification") }
            'orphan' { $out.Add("marker names $($v.key), which is no longer designated (line $($v.lines[0])) — restore the original designator set, or start over with a new specification") }
            'split' { $out.Add("the marker for $($v.key) is now duplicated (line $(($v.lines -join ', '))) — keep exactly one, or start over with a new specification") }
            'merge' { $out.Add("more than one marker now names the same user story (line $(($v.lines -join ', '))) — keep one marker per user story, or start over with a new specification") }
            'malformed' { $out.Add("the pinning marker at line $($v.line) is now malformed — restore its pin=<key> shape, or start over with a new specification") }
            'reorder' { $out.Add('a pinning marker has moved out of its designated order — restore the original order, or start over with a new specification') }
            default { $out.Add('pinning validation failed') }
        }
    }
    return $out
}

function Get-JiraSeedOverviewText {
    <#
    .SYNOPSIS
      FR-023's "drafted overview": everything from the line after the H1 (or
      the start when there is none) up to the first user-story anchor.
      Mirror of _seed_overview_text.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Content)
    $anchors = @(Get-JiraPinMarkerAnchor -Content $Content | ForEach-Object { [int]$_ })
    $end = if ($anchors.Count -gt 0) { $anchors[0] } else { 0 }
    $lines = $Content -split "`n"
    $h1 = 0
    $parts = [System.Collections.Generic.List[string]]::new()
    for ($li = 0; $li -lt $lines.Count; $li++) {
        $lineno = $li + 1
        $lc = $lines[$li].TrimEnd("`r")
        if ($end -gt 0 -and $lineno -ge $end) { break }
        if ($h1 -eq 0 -and $lc -match '^#\s') { $h1 = $lineno; continue }
        if ($h1 -eq 0 -and $end -eq 0) { continue }
        $parts.Add($lc)
    }
    return (($parts -join ' ').Trim())
}

function Get-JiraSeedBoundStoryKey {
    <#
    .SYNOPSIS
      The subset of the given keys already carrying a BOUND
      `story=<id> ticket=<KEY>` marker (R14, a partial run's completed
      bindings). Mirror of _seed_bound_story_keys.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Content, [Parameter(Mandatory)] [string] $StoryKeysJson)
    $keys = @($StoryKeysJson | ConvertFrom-Json -Depth 100)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $keys) {
        if ($Content -match "<!-- speckit-jira story=[0-9a-f]{16} ticket=$([regex]::Escape([string]$k)) -->") { $out.Add([string]$k) }
    }
    return (ConvertTo-JiraJsonValue $out)
}

function Get-JiraSeedPlanEntry {
    <#
    .SYNOPSIS
      Builds the plan entries (§5.1): an adopt/create line for the parent
      (when designated and not yet bound), an adopt line per remaining
      story, a reparent line per remaining story whose current parent
      differs from the designated one, and a note line per remaining story
      already parented when no specification role is designated at all
      (FR-061). Mirror of _seed_plan_entries.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Mode,
        [AllowEmptyString()] [string] $TargetKey,
        [AllowEmptyString()] [string] $FreeText,
        [Parameter(Mandatory)] [string] $StoryKeysJson,
        [Parameter(Mandatory)] [string] $InfosJson
    )
    $storyKeys = @($StoryKeysJson | ConvertFrom-Json -Depth 100)
    $infos = $InfosJson | ConvertFrom-Json -Depth 100
    $out = [System.Collections.Generic.List[object]]::new()

    function Get-JiraSeedInfoFor([string] $Key) {
        $p = $infos.PSObject.Properties[$Key]
        if ($p) { return $p.Value }
        return $null
    }

    if ($Mode -eq 'adopt' -and $TargetKey) {
        $info = Get-JiraSeedInfoFor $TargetKey
        $summary = if ($info -and $info.summary) { [string]$info.summary } else { '' }
        $out.Add([ordered]@{ verb = 'adopt'; key = $TargetKey; role = 'specification'; summary = $summary })
    }
    elseif ($Mode -eq 'create') {
        $out.Add([ordered]@{ verb = 'create'; key = $null; role = 'specification'; summary = $FreeText })
    }

    foreach ($k in $storyKeys) {
        $info = Get-JiraSeedInfoFor ([string]$k)
        $summary = if ($info -and $info.summary) { [string]$info.summary } else { '' }
        $out.Add([ordered]@{ verb = 'adopt'; key = $k; role = 'story'; summary = $summary })
    }

    if ($Mode -ne 'none') {
        $moves = [System.Collections.Generic.List[object]]::new()
        foreach ($k in $storyKeys) {
            $info = Get-JiraSeedInfoFor ([string]$k)
            if (-not $info -or -not $info.parent) { continue }
            $p = $info.parent
            if ($Mode -eq 'create' -or [string]$p.key -ne $TargetKey) {
                $moves.Add([pscustomobject]@{ key = $k; from_key = [string]$p.key; from_summary = [string]$p.summary; from_status = [string]$p.status })
            }
        }
        $groups = $moves | Group-Object -Property from_key
        foreach ($g in $groups) {
            $loses = $g.Count
            foreach ($m in $g.Group) {
                $out.Add([ordered]@{ verb = 'reparent'; key = $m.key; from_key = $m.from_key; from_summary = $m.from_summary; from_status = $m.from_status; loses = $loses })
            }
        }
    }
    else {
        foreach ($k in $storyKeys) {
            $info = Get-JiraSeedInfoFor ([string]$k)
            if (-not $info -or -not $info.parent) { continue }
            $p = $info.parent
            $out.Add([ordered]@{ verb = 'note'; key = $k; parent_key = [string]$p.key; parent_summary = [string]$p.summary })
        }
    }

    return (ConvertTo-JiraJsonValue $out)
}

function ConvertTo-JiraSeedPlanRendered {
    <#
    .SYNOPSIS
      contract §5.1's literal line rendering (the byte-pinned format).
      Mirror of _seed_plan_render.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $EntriesJson)
    $entries = @($EntriesJson | ConvertFrom-Json -Depth 100)
    $pad = {
        param($s, $w)
        $s = if ($null -eq $s) { '' } else { [string]$s }
        if ($s.Length -lt $w) { return $s + (' ' * ($w - $s.Length)) }
        return $s
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $entries) {
        $verb = [string]$e.verb
        $key = if ($e.PSObject.Properties.Name -contains 'key' -and $e.key) { [string]$e.key } else { '-' }
        if ($verb -eq 'adopt' -or $verb -eq 'create') {
            $summary = if ($e.PSObject.Properties.Name -contains 'summary' -and $e.summary) { [string]$e.summary } else { '' }
            $lines.Add('  ' + (& $pad $verb 10) + (& $pad $key 8) + (& $pad ([string]$e.role) 14) + $summary)
        }
        elseif ($verb -eq 'reparent') {
            $childWord = if ([int]$e.loses -eq 1) { 'child' } else { 'children' }
            $body = "from $($e.from_key) `"$($e.from_summary)`" [$($e.from_status)] - loses $($e.loses) $childWord"
            $lines.Add('! ' + (& $pad $verb 10) + (& $pad $key 8) + $body)
        }
        elseif ($verb -eq 'note') {
            $body = "stays under $($e.parent_key) `"$($e.parent_summary)`" - re-run naming a parent to group"
            $lines.Add('  ' + (& $pad $verb 10) + (& $pad $key 8) + $body)
        }
    }
    return (ConvertTo-JiraJsonValue $lines)
}

function Get-JiraSeedPlanDelta {
    <#
    .SYNOPSIS
      FR-064: which lines were added, and which have disappeared, vs the
      previously displayed plan. Mirror of _seed_plan_delta.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $OldLinesJson, [Parameter(Mandatory)] [string] $NewLinesJson)
    $old = @($OldLinesJson | ConvertFrom-Json -Depth 100)
    $new = @($NewLinesJson | ConvertFrom-Json -Depth 100)
    $added = @($new | Where-Object { $old -notcontains $_ })
    $removed = @($old | Where-Object { $new -notcontains $_ })
    return (ConvertTo-JiraJsonValue ([ordered]@{ added = $added; removed = $removed }))
}

function Get-JiraSeedScatterWarning {
    <#
    .SYNOPSIS
      FR-061: the run-summary half of the scatter disclosure. Mirror of
      _seed_scatter_warnings.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $EntriesJson)
    $entries = @($EntriesJson | ConvertFrom-Json -Depth 100)
    return @($entries | Where-Object { $_.verb -eq 'note' } | ForEach-Object {
            "$($_.key) stays under $($_.parent_key) (`"$($_.parent_summary)`") — re-run naming a parent to group it"
        })
}

function ConvertTo-JiraSeedProse {
    param([Parameter(Mandatory)] [string] $Json)
    $obj = $Json | ConvertFrom-Json -Depth 100
    $sb = [System.Text.StringBuilder]::new()
    if ($obj.PSObject.Properties.Name -contains 'confirmation_required') {
        [void]$sb.AppendLine('Seed: confirmation required')
        [void]$sb.AppendLine('Write plan')
        foreach ($line in @($obj.confirmation_required.plan)) {
            if ($line) { [void]$sb.AppendLine([string]$line) }
        }
    }
    else {
        [void]$sb.AppendLine('Seed: active')
    }
    foreach ($w in @($obj.warnings)) {
        if ($w) { [void]$sb.AppendLine("Warning: $w") }
    }
    return $sb.ToString()
}

function Invoke-JiraSeed {
    <#
    .SYNOPSIS
      The seed ceremony (contracts/seed-cli-contract.md §4/§5). Writes the
      result via the [Console] streams and returns ONLY its numeric exit
      code.
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments = @())

    $parsed = Invoke-JiraCliParse -Arguments $Arguments
    $state = @{}
    foreach ($line in ($parsed -split "`n")) {
        if ($line -match '^([^=]+)=(.*)$') { $state[$Matches[1]] = $Matches[2] }
    }
    if ($state['exit'] -ne '0') {
        if ($state.ContainsKey('error') -and $state['error']) { [Console]::Error.WriteLine("seed: $($state['error'])") }
        return [int] $state['exit']
    }
    $json = $state['json'] -eq 'true'
    $dryRun = $state['dry_run'] -eq 'true'
    $confirm = $state['confirm'] -eq 'true'
    $parentSeen = $state['parent_seen'] -eq 'true'
    $parent = if ($state.ContainsKey('parent')) { $state['parent'] } else { '' }
    $stories = if ($state.ContainsKey('stories')) { $state['stories'] } else { '' }
    $argsLine = if ($state.ContainsKey('args')) { $state['args'] } else { '' }
    $words = @($argsLine -split ' ' | Where-Object { $_ -ne '' })
    $specFile = if ($words.Count -gt 0) { $words[0] } else { '' }

    if ([string]::IsNullOrEmpty($specFile) -or -not (Test-Path -LiteralPath $specFile -PathType Leaf)) {
        [Console]::Error.WriteLine('seed: a readable spec file argument is required')
        return (Get-JiraExitCode 'usage')
    }

    # Absence distinguishes two states (seed-record.md §4): a specification
    # already carrying an identity marker is BOUND — C-13's idempotent
    # second run, zero writes, exit 0 — while one carrying neither record
    # nor identity is a crash mid-draft, REF-EXISTS.
    $record = Read-JiraSeedState -SpecPath $specFile
    if (-not $record) {
        $text = Get-Content -Raw -LiteralPath $specFile
        if ($text -match '<!-- speckit-jira story=[0-9a-f]{16} ticket=') {
            Write-JiraSeedResult -Payload (ConvertTo-JiraJsonValue ([ordered]@{ active = $true; bindings = @() })) -Json $json
            return 0
        }
        [Console]::Error.WriteLine("seed: no seeded-not-bound state was found for $specFile - REF-EXISTS: retro-seeding is out of scope; create a new specification")
        return (Get-JiraExitCode 'config')
    }

    # --- §4 step 2: compare designator sets, ONLY when the operator
    # resupplied them (S-3/S-4). ------------------------------------------
    # The resolution chokepoint (030, plan.md §Key design decision): seed
    # SPEC_KIT_JIRA_BASE_URL / JIRA_EMAIL from config.yml / personal.yml,
    # environment first.
    $chokepointRc = Resolve-JiraConnection -ConfigDir (Get-JiraConfigDirPath)
    if ($chokepointRc -ne 0) { return [int] $chokepointRc }
    $baseUrl = if ($env:SPEC_KIT_JIRA_BASE_URL) { $env:SPEC_KIT_JIRA_BASE_URL } else { '' }
    if ($parentSeen -or $stories) {
        $classified = [System.Collections.Generic.List[object]]::new()
        if ($parentSeen) {
            $classified.Add((Resolve-JiraDesignator -Role 'specification' -Raw $parent -BaseUrl $baseUrl | ConvertFrom-Json -Depth 100))
        }
        if ($stories) {
            $us = [char]0x1F
            foreach ($raw in @($stories.Split($us))) {
                $classified.Add((Resolve-JiraDesignator -Role 'story' -Raw $raw -BaseUrl $baseUrl | ConvertFrom-Json -Depth 100))
            }
        }
        $refusing = @($classified | Where-Object { $_.PSObject.Properties.Name -contains 'refuse' })
        if ($refusing.Count -gt 0) {
            foreach ($r in $refusing) {
                $detail = "designator `"$($r.raw)`" did not resolve"
                [Console]::Error.WriteLine("seed: $(Get-JiraSeedRefMessage -Code ([string]$r.refuse) -Detail $detail)")
            }
            return (Get-JiraExitCode 'config')
        }
        $allJson = ConvertTo-JiraJsonValue $classified
        $dedupe = Resolve-JiraDesignatorSet -Items $allJson | ConvertFrom-Json -Depth 100
        if (-not [bool]$dedupe.ok) {
            $dups = ($dedupe.duplicates -join ', ')
            [Console]::Error.WriteLine("seed: $(Get-JiraSeedRefMessage -Code 'REF-DUPLICATE' -Detail "issue(s) named more than once: $dups")")
            return (Get-JiraExitCode 'config')
        }
        $currentDesignators = ConvertTo-JiraJsonValue @($dedupe.designators)
        $recordedDesignators = ConvertTo-JiraJsonValue @(($record | ConvertFrom-Json -Depth 100).designators)
        if (-not (Test-JiraSeedStateDesignatorsEqual -RecordedJson $recordedDesignators -CurrentJson $currentDesignators)) {
            [Console]::Error.WriteLine("seed: $(Get-JiraSeedRefMessage -Code 'REF-RESEED' -Detail 'the supplied designator set differs from the one recorded for this specification')")
            return (Get-JiraExitCode 'config')
        }
    }

    # The record is always the authoritative designator source (order,
    # roles, keys) — a resupplied set on this invocation was only a safety
    # check, already proven equal above.
    $storyKeys = Get-JiraSeedDesignatorKey -RecordJson $record
    $parentDesignator = Get-JiraSeedParentDesignator -RecordJson $record
    $pform = if ($parentDesignator) { [string]$parentDesignator.form } else { '' }
    $pkey = ''
    $freeText = ''
    if ($pform -eq 'key' -or $pform -eq 'url') { $pkey = [string]$parentDesignator.key }
    if ($pform -eq 'free_text') { $freeText = [string]$parentDesignator.text }

    # mode: "adopt" (existing parent named), "create" (free-text parent),
    # "none" (no specification-role designator at all — FR-024/FR-061).
    $mode = 'none'
    if ($pkey) { $mode = 'adopt' }
    if ($freeText) { $mode = 'create' }

    $recObjForResume = $record | ConvertFrom-Json -Depth 100
    $resume = ($null -ne $recObjForResume.plan_digest)
    $routingJson = ConvertTo-JiraJsonValue ($recObjForResume.routing)
    if ($null -eq $recObjForResume.routing) { $routingJson = '{}' }

    # --- R14/FR-042: a partial run's completed bindings are excluded from
    # every remaining step. -----------------------------------------------
    $specContent = [System.IO.File]::ReadAllText($specFile)
    $boundKeysJson = Get-JiraSeedBoundStoryKey -Content $specContent -StoryKeysJson $storyKeys
    $boundKeys = @($boundKeysJson | ConvertFrom-Json -Depth 100)
    $storyKeysArrAll = @($storyKeys | ConvertFrom-Json -Depth 100)
    $remainingStoryKeysArr = @($storyKeysArrAll | Where-Object { $boundKeys -notcontains $_ })
    $remainingStoryKeys = ConvertTo-JiraJsonValue $remainingStoryKeysArr

    $parentInfo = Get-JiraSpecMarkerDocumentInfo -Content $specContent | ConvertFrom-Json -Depth 20
    $parentState = [string]$parentInfo.state
    $parentBoundKey = ''
    if ($parentState -eq 'bound') {
        $parentBoundKey = [string]$parentInfo.ticket
        $pkey = $parentBoundKey
        $mode = 'adopt'
    }
    elseif ($mode -eq 'create' -and $parentState -eq 'creating') {
        [Console]::Error.WriteLine('seed: a previous run began creating the parent but did not finish — check Jira for a duplicate before re-invoking; if none was created, remove the <!-- speckit-jira spec=... creating --> marker from spec.md and retry')
        return (Get-JiraExitCode 'config')
    }

    # --- §4 steps 4-5: resume-only Jira re-read + full refusal
    # re-evaluation (FR-062) — a first gate-reach issues ZERO requests. -----
    $infos = '{}'
    if ($resume) {
        $keys = [System.Collections.Generic.List[string]]::new()
        if ($pkey) { $keys.Add($pkey) }
        foreach ($k in $remainingStoryKeysArr) { $keys.Add([string]$k) }

        if ($keys.Count -gt 0) {
            $loadRc = Invoke-JiraAdoptionLoad -Keys $keys.ToArray()
            if ([int]$loadRc -ne 0) {
                [Console]::Error.WriteLine('seed: an unreliable read occurred while re-resolving the named issues on resume — the run refuses rather than proceeding without them (FR-038, FR-062)')
                return (Get-JiraExitCode 'fail_closed')
            }
        }

        $repo = if ($env:SPEC_KIT_JIRA_REPO) { $env:SPEC_KIT_JIRA_REPO } else { 'local/repo' }
        $specSlug = if ($env:SPEC_KIT_JIRA_SPEC_SLUG) { $env:SPEC_KIT_JIRA_SPEC_SLUG } else { 'spec' }
        $specRef = ConvertTo-JiraJsonValue ([ordered]@{ repo = $repo; spec_slug = $specSlug })
        $routing = $routingJson | ConvertFrom-Json -Depth 100
        # Indexer access (not `.PSObject.Properties.Name -contains`, T162
        # investigation): under Set-StrictMode, `.Name` on an ENUMERATED-EMPTY
        # PSCustomObject (routing = '{}', a legitimate resume state when no
        # project config was ever resolved) throws "property 'Name' cannot be
        # found" — the indexer form returns $null instead, safely, on the same
        # input.
        $routedProject = if ($routing.PSObject.Properties['project']) { [string]$routing.project } else { '' }
        $dts = if ($routing.PSObject.Properties['declared_type_specification']) { [string]$routing.declared_type_specification } else { '' }
        $dtst = if ($routing.PSObject.Properties['declared_type_story']) { [string]$routing.declared_type_story } else { '' }
        $term = if ($routing.PSObject.Properties['terminal_statuses_csv']) { [string]$routing.terminal_statuses_csv } else { '' }

        $evalResults = [System.Collections.Generic.List[object]]::new()
        if ($pkey) {
            $evalResults.Add((Test-JiraAdoptionEvaluate -RoutedProject $routedProject -Role 'specification' -Key $pkey -DeclaredType $dts -TerminalStatusesCsv $term -SpecRefJson $specRef | ConvertFrom-Json -Depth 100))
        }
        foreach ($skey in $remainingStoryKeysArr) {
            $evalResults.Add((Test-JiraAdoptionEvaluate -RoutedProject $routedProject -Role 'story' -Key ([string]$skey) -DeclaredType $dtst -TerminalStatusesCsv $term -SpecRefJson $specRef | ConvertFrom-Json -Depth 100))
        }
        $mp = Get-JiraAdoptionMultiprojectViolation -StoryKeysJson $remainingStoryKeys | ConvertFrom-Json -Depth 100
        if (@($mp).Count -gt 0) {
            $msg = Get-JiraSeedRefMessage -Code 'REF-MULTIPROJECT' -Detail "named story-role issues span more than one project: $(@($mp) -join ', ')"
            $evalResults.Add([pscustomobject]@{ code = 'REF-MULTIPROJECT'; key = ''; message = $msg })
        }
        $refusals = @($evalResults | Where-Object { [string]$_.code -ne '' })
        if ($refusals.Count -gt 0) {
            foreach ($r in $refusals) { [Console]::Error.WriteLine("seed: $($r.code): $($r.message)") }
            return (Get-JiraExitCode 'config')
        }

        function Get-JiraSeedParentInfoFrom($Fields) {
            if (-not $Fields.PSObject.Properties.Name -contains 'parent' -or -not $Fields.parent) { return $null }
            $pf = $Fields.parent.fields
            return [ordered]@{ key = [string]$Fields.parent.key; summary = [string]$pf.summary; status = [string]$pf.status.name }
        }

        $ij = [ordered]@{}
        if ($pkey) {
            $e = Get-JiraAdoption -Key $pkey | ConvertFrom-Json -Depth 100
            $ij[$pkey] = [ordered]@{ summary = [string]$e.fields.summary; status = [string]$e.fields.status.name; parent = (Get-JiraSeedParentInfoFrom $e.fields) }
        }
        foreach ($skey in $remainingStoryKeysArr) {
            $e = Get-JiraAdoption -Key ([string]$skey) | ConvertFrom-Json -Depth 100
            $ij[[string]$skey] = [ordered]@{ summary = [string]$e.fields.summary; status = [string]$e.fields.status.name; parent = (Get-JiraSeedParentInfoFrom $e.fields) }
        }
        $infos = ConvertTo-JiraJsonValue $ij
    }
    else {
        # First run: the seed material file moment 1 already wrote — NO
        # Jira read here (T100's one-way-read guarantee for the first
        # gate-reach). The material already carries status/parent.
        # The material is a sibling of the seed record and shares its key, so it
        # is resolved the same way — the feature directory the host created is
        # not always the name moment 1 wrote under (lib/SeedState.psm1).
        $shortName = Get-JiraSeedStateRecordKey -SpecPath $specFile
        $configDir = if ($env:JIRA_CONFIG_DIR) { $env:JIRA_CONFIG_DIR } else { '.specify/jira' }
        $materialPath = Join-Path $configDir "state/$shortName.seed-material.json"
        if (Test-Path -LiteralPath $materialPath -PathType Leaf) {
            $material = @([System.IO.File]::ReadAllText($materialPath) | ConvertFrom-Json -Depth 100)
            $ij = [ordered]@{}
            foreach ($m in $material) {
                $ij[[string]$m.key] = [ordered]@{ summary = [string]$m.summary; status = [string]$m.status; parent = $m.parent }
            }
            $infos = ConvertTo-JiraJsonValue $ij
        }
    }

    # §4 step 6: validate the pinning markers against spec.md as it now
    # stands (FR-058, FR-063), over the REMAINING (not-yet-bound) keys only.
    # First run -> REF-DECOMP; resume -> REF-DRAFT-EDIT.
    $violations = Test-JiraPinMarkerValidate -SpecPath $specFile -DesignatorsJson $remainingStoryKeys
    $violationsArr = @($violations | ConvertFrom-Json -Depth 100)
    if ($violationsArr.Count -gt 0) {
        if ($resume) {
            foreach ($msg in (Get-JiraSeedDraftEditMessage -ViolationsJson $violations)) {
                [Console]::Error.WriteLine("seed: REF-DRAFT-EDIT: $msg")
            }
        }
        else {
            foreach ($msg in (Get-JiraSeedDecompMessage -ViolationsJson $violations)) {
                [Console]::Error.WriteLine("seed: REF-DECOMP: $msg")
            }
        }
        return (Get-JiraExitCode 'config')
    }

    # FR-053: an empty/whitespace free-text parent already refuses
    # REF-DESIGNATOR at classify time. FR-023: a free-text create needs the
    # resolved type id.
    if ($mode -eq 'create' -and -not $parentBoundKey) {
        $routingObj = $routingJson | ConvertFrom-Json -Depth 100
        $ptidCheck = if ($routingObj.PSObject.Properties.Name -contains 'parent_type_id') { [string]$routingObj.parent_type_id } else { '' }
        if (-not $ptidCheck) {
            [Console]::Error.WriteLine('seed: the specification-role issue type could not be resolved for this project — run /speckit.jira.config to bind it, then re-invoke')
            return (Get-JiraExitCode 'config')
        }
    }

    # §4 step 7: compute the write plan from the CURRENT spec.md.
    $targetKey = $pkey
    $entries = Get-JiraSeedPlanEntry -Mode $mode -TargetKey $targetKey -FreeText $freeText -StoryKeysJson $remainingStoryKeys -InfosJson $infos
    $plan = ConvertTo-JiraSeedPlanRendered -EntriesJson $entries
    $scatterWarnings = Get-JiraSeedScatterWarning -EntriesJson $entries

    # §4 step 8: provenance.
    $provenance = Get-JiraPinMarkerProvenance -Content $specContent -DesignatorsJson $remainingStoryKeys
    if ($mode -ne 'none') {
        $provSrc = if ($targetKey) { $targetKey } else { 'new' }
        $provArr = @($provenance | ConvertFrom-Json -Depth 100)
        $prepended = [System.Collections.Generic.List[object]]::new()
        $prepended.Add([ordered]@{ heading = 'Overview'; source = $provSrc })
        foreach ($p in $provArr) { $prepended.Add($p) }
        $provenance = ConvertTo-JiraJsonValue $prepended
    }

    # delta vs the previously displayed plan — resume-only.
    $delta = '{}'
    if ($resume) {
        $oldSnapshot = if ($recObjForResume.PSObject.Properties.Name -contains 'plan_snapshot') { ConvertTo-JiraJsonValue @($recObjForResume.plan_snapshot) } else { '[]' }
        $delta = Get-JiraSeedPlanDelta -OldLinesJson $oldSnapshot -NewLinesJson $plan
    }

    $warningsJson = ConvertTo-JiraJsonValue @($scatterWarnings)

    if ($dryRun) {
        # Built by direct concatenation of already-canonical JSON fragments —
        # never round-tripped through native ConvertFrom-Json/ConvertTo-Json,
        # which collapses an EMPTY JSON array to $null (a real, observed
        # cross-port divergence: bash emits "warnings":[], PowerShell emitted
        # "warnings":null for the exact same empty set).
        $payload = '{"active":true,"confirmation_required":{"delta":' + $delta + ',"plan":' + $plan + ',"provenance":' + $provenance + '},"warnings":' + $warningsJson + '}'
        Write-JiraSeedResult -Payload $payload -Json $json
        return 0
    }
    if (-not $confirm) {
        # C-7/C-8: zero mutations, exit 0. The record is rewritten with the
        # freshly rendered plan (same designators, still bindings:[]) so a
        # LATER resume can compute FR-064's delta against it.
        $planLines = @($plan | ConvertFrom-Json -Depth 100) -join "`n"
        $newDigest = Get-JiraSeedStatePlanDigest -RenderedPlanText $planLines
        $recDesignatorsJson = ConvertTo-JiraJsonValue @($recObjForResume.designators)
        $doc = New-JiraSeedStateDocument -Slug ([string]$recObjForResume.slug) -DesignatorsJson $recDesignatorsJson -PlanDigest $newDigest -RoutingJson $routingJson -PlanSnapshotJson $plan
        Save-JiraSeedState -SpecPath $specFile -DocumentJson $doc

        # Built by direct concatenation of already-canonical JSON fragments —
        # never round-tripped through native ConvertFrom-Json/ConvertTo-Json,
        # which collapses an EMPTY JSON array to $null (a real, observed
        # cross-port divergence: bash emits "warnings":[], PowerShell emitted
        # "warnings":null for the exact same empty set).
        $payload = '{"active":true,"confirmation_required":{"delta":' + $delta + ',"plan":' + $plan + ',"provenance":' + $provenance + '},"warnings":' + $warningsJson + '}'
        Write-JiraSeedResult -Payload $payload -Json $json
        return 0
    }

    # --- FR-065 (T158): the two-tier pre-write privacy guard, over
    # spec.md as it now stands, again before the first Jira mutation —
    # the tier-1 scan in Feature.psm1 covers the seed material before
    # drafting; this is the second required pass. A BLOCK is zero writes
    # of any kind, local or Jira.
    $allowlistJson = if ($env:SPEC_KIT_JIRA_ALLOWLIST) { $env:SPEC_KIT_JIRA_ALLOWLIST } else { '[]' }
    $blockRc2 = Test-JiraPrivacyBlock -Payload $specContent -KnownCoordinatesJson '[]' -AllowlistJson $allowlistJson
    if ([int]$blockRc2 -ne 0) { return [int]$blockRc2 }

    # --confirm: bind every remaining named story (FR-057), adopt or create
    # the parent (FR-022/FR-023), and place/re-parent as designated
    # (FR-025/FR-026) — never when mode is "none" (FR-024, T133's scoping).
    $nl = Get-JiraMarkerSpliceDominantNl -Content $specContent

    # spec_ref.spec_slug prefers SPEC_KIT_JIRA_SPEC_SLUG (the host's own
    # numbered feature id) — never the recorded seed-state slug.
    $repo = if ($env:SPEC_KIT_JIRA_REPO) { $env:SPEC_KIT_JIRA_REPO } else { 'local/repo' }
    $specSlug = if ($env:SPEC_KIT_JIRA_SPEC_SLUG) { $env:SPEC_KIT_JIRA_SPEC_SLUG } else { 'spec' }
    $specRef = ConvertTo-JiraJsonValue ([ordered]@{ repo = $repo; spec_slug = $specSlug })

    $bindings = [System.Collections.Generic.List[object]]::new()

    if ($parentBoundKey) {
        $targetKey = $parentBoundKey
    }
    elseif ($mode -eq 'adopt') {
        # Parent adoption (US3): an operator-named existing parent is bound
        # with a new spec= marker, origin:human, role:parent — never created.
        $assigned = Set-JiraSpecMarkerAssign -Text $specContent
        $smInfo = Get-JiraSpecMarkerDocumentInfo -Content $assigned | ConvertFrom-Json -Depth 20
        $specContent = Set-JiraSpecMarkerRecordTicket -Text $assigned -Id ([string]$smInfo.id) -Key $pkey
        Write-JiraMarkerSpliceFile -Path $specFile -NewContent $specContent | Out-Null
        $rc2 = Set-JiraIdentity -IssueKey $pkey -SpecRefJson $specRef -Origin 'human' -Story '' -Role 'parent' -Summary ''
        if ([int]$rc2 -ne 0) {
            $report = Get-JiraSeedPartialReport -Bindings $bindings -Mode $mode -TargetKey $pkey -FreeText $freeText -RemainingStoryKeysJson $remainingStoryKeys
            Write-JiraSeedResult -Payload $report -Json $json
            return [int]$rc2
        }
        $bindings.Add([ordered]@{ key = $pkey; role = 'parent'; origin = 'human' })
        $targetKey = $pkey
    }
    elseif ($mode -eq 'create') {
        # Parent creation (US2, FR-023): a free-text title creates EXACTLY
        # one specification-role issue, no lookup of any kind. The marker
        # is assigned, then marked "creating" — both written to disk
        # BEFORE the POST (FR-028).
        $assigned = Set-JiraSpecMarkerAssign -Text $specContent
        $smInfo = Get-JiraSpecMarkerDocumentInfo -Content $assigned | ConvertFrom-Json -Depth 20
        $smId = [string]$smInfo.id
        $specContent = Set-JiraSpecMarkerMarkCreating -Text $assigned -Id $smId
        Write-JiraMarkerSpliceFile -Path $specFile -NewContent $specContent | Out-Null

        $routingObj = $routingJson | ConvertFrom-Json -Depth 100
        $ptid = [string]$routingObj.parent_type_id
        $routedProject2 = if ($routingObj.PSObject.Properties.Name -contains 'project') { [string]$routingObj.project } else { '' }
        $created = New-JiraTicket -ProjectKey $routedProject2 -Summary $freeText -StoryTypeId $ptid -SpecRefJson $specRef -Role 'parent'
        if ($created.ExitCode -ne 0) {
            $report = Get-JiraSeedPartialReport -Bindings $bindings -Mode $mode -TargetKey $targetKey -FreeText $freeText -RemainingStoryKeysJson $remainingStoryKeys
            Write-JiraSeedResult -Payload $report -Json $json
            return [int]$created.ExitCode
        }
        $newKey = [string](($created.Json | ConvertFrom-Json -Depth 100).key)

        $specContent = Set-JiraSpecMarkerRecordTicket -Text $specContent -Id $smId -Key $newKey
        Write-JiraMarkerSpliceFile -Path $specFile -NewContent $specContent | Out-Null
        # New-JiraTicket already identity-stamps origin:bridge with the
        # summary recorded (FR-052) — no second identity write here.
        $bindings.Add([ordered]@{ key = $newKey; role = 'parent'; origin = 'bridge' })
        $targetKey = $newKey
    }

    foreach ($key in $remainingStoryKeysArr) {
        $keyStr = [string]$key

        # Placement / re-parenting (FR-025/FR-026): fires ONLY when a
        # parent is designated (mode != none) and the current parent
        # differs.
        if ($mode -ne 'none' -and $targetKey) {
            $infosObj = $infos | ConvertFrom-Json -Depth 100
            $infoEntry = $infosObj.PSObject.Properties[$keyStr]
            $curParent = if ($infoEntry -and $infoEntry.Value.parent) { [string]$infoEntry.Value.parent.key } else { '' }
            if ($curParent -ne $targetKey) {
                $placeBody = (@{ fields = @{ parent = @{ key = $targetKey } } } | ConvertTo-Json -Depth 10 -Compress)
                $placeResult = Invoke-JiraRequest -Method PUT -Url "$($env:SPEC_KIT_JIRA_BASE_URL)/rest/api/3/issue/$keyStr" -Body $placeBody
                if ([int]$placeResult.ExitCode -ne 0) {
                    $report = Get-JiraSeedPartialReport -Bindings $bindings -Mode $mode -TargetKey $targetKey -FreeText $freeText -RemainingStoryKeysJson $remainingStoryKeys
                    Write-JiraSeedResult -Payload $report -Json $json
                    return [int]$placeResult.ExitCode
                }
            }
        }

        $sid = New-JiraStoryMarkerId
        $replacement = Format-JiraStoryMarkerLine -Id $sid -State 'bound' -Ticket $keyStr
        # The identifier is written to disk BEFORE the Jira write (FR-028,
        # docs/08-safety-model.md): an interrupted run leaves exactly the
        # completed replacements, each already recorded — nothing batched.
        $specContent = ConvertTo-JiraPinMarkerConsumed -Content $specContent -Key $keyStr -ReplacementLine $replacement -Nl $nl
        Write-JiraMarkerSpliceFile -Path $specFile -NewContent $specContent | Out-Null
        $rc = Set-JiraIdentity -IssueKey $keyStr -SpecRefJson $specRef -Origin 'human' -Story $sid -Role 'story' -Summary ''
        if ([int]$rc -ne 0) {
            $report = Get-JiraSeedPartialReport -Bindings $bindings -Mode $mode -TargetKey $targetKey -FreeText $freeText -RemainingStoryKeysJson $remainingStoryKeys
            Write-JiraSeedResult -Payload $report -Json $json
            return [int]$rc
        }
        $bindings.Add([ordered]@{ key = $keyStr; role = 'story'; origin = 'human' })
    }

    Remove-JiraSeedState -SpecPath $specFile
    Write-JiraSeedResult -Payload (ConvertTo-JiraJsonValue ([ordered]@{ active = $true; bindings = $bindings })) -Json $json
    return 0
}

Export-ModuleMember -Function Invoke-JiraSeed
