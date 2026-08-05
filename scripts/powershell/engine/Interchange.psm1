# engine/Interchange.psm1 — Neutral interchange document validation.
# Mirror of engine/interchange.sh.
#
# Validates the neutral document (contracts/neutral-interchange.schema.json)
# BEFORE any write (Constitution VIII). A failure means ZERO writes.
#
# NEUTRAL layer: zero Jira identifiers, never imports sink/.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../lib/Output.psm1') -Force # canonical serialiser only — lib/, never sink/

function Test-JiraInterchangeProp {
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $false }
    return ($Object.PSObject.Properties.Name -contains $Name)
}

function Get-JiraInterchangeProp {
    param($Object, [string] $Name)
    if (Test-JiraInterchangeProp $Object $Name) { return $Object.$Name }
    return $null
}

function Get-JiraArrayCount {
    # Count an array-valued property WITHOUT triggering PowerShell's single- and
    # empty-collection unwrapping (which a plain `return` would). -1 = absent.
    param($Object, [string] $Name)
    if (-not (Test-JiraInterchangeProp $Object $Name)) { return -1 }
    $value = $Object.$Name
    if ($null -eq $value) { return 0 }
    return @($value).Count
}

function Get-JiraMarkErrors {
    <#
    .SYNOPSIS
      data-model.md §5 rule 4: mark.kind in the enum, href present iff
      kind == 'link'. Mirror of interchange.sh's mark_errors.
    #>
    param($Mark)
    $errors = [System.Collections.Generic.List[string]]::new()
    $kind = [string](Get-JiraInterchangeProp $Mark 'kind')
    if (@('bold', 'italic', 'monospace', 'strikethrough', 'link') -cnotcontains $kind) {
        $errors.Add('mark.kind is invalid')
    }
    $hasHref = Test-JiraInterchangeProp $Mark 'href'
    if ($kind -eq 'link') {
        if (-not $hasHref) { $errors.Add('mark.href is required for a link mark') }
        elseif ([string](Get-JiraInterchangeProp $Mark 'href') -notmatch '^https?://\S+$') {
            $errors.Add('mark.href must be an absolute http(s) URL')
        }
    }
    elseif ($hasHref) {
        $errors.Add('mark.href is forbidden for a non-link mark')
    }
    return $errors
}

function Get-JiraSpanErrors {
    <#
    .SYNOPSIS
      data-model.md §5 rule 3: every span has text (string) and marks (array).
      Mirror of interchange.sh's span_errors.
    #>
    param($Span)
    $errors = [System.Collections.Generic.List[string]]::new()
    if ((Get-JiraInterchangeProp $Span 'text') -isnot [string]) { $errors.Add('span.text is required') }
    if (-not (Test-JiraInterchangeProp $Span 'marks')) { $errors.Add('span.marks is required') }
    foreach ($m in @(Get-JiraInterchangeProp $Span 'marks')) {
        if ($null -eq $m) { continue }
        foreach ($e in (Get-JiraMarkErrors $m)) { $errors.Add($e) }
    }
    return $errors
}

function Get-JiraInlineErrors {
    <# data-model.md §5: every span in an inline sequence. #>
    param($Inline)
    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($s in @($Inline)) {
        if ($null -eq $s) { continue }
        foreach ($e in (Get-JiraSpanErrors $s)) { $errors.Add($e) }
    }
    return $errors
}

function Get-JiraBlockErrors {
    <#
    .SYNOPSIS
      data-model.md §5 rules 1-2: block-type enum (including ordered_list) and
      the per-type required field. Mirror of interchange.sh's block_errors.
    #>
    param($Block)
    $errors = [System.Collections.Generic.List[string]]::new()
    $t = [string](Get-JiraInterchangeProp $Block 'type')
    if (@('heading', 'paragraph', 'bullet_list', 'ordered_list', 'code', 'panel_ref') -cnotcontains $t) {
        $errors.Add('block.type is invalid')
    }
    if ($t -eq 'heading' -or $t -eq 'paragraph') {
        if (-not (Test-JiraInterchangeProp $Block 'spans')) { $errors.Add("block.spans is required for a $t block") }
        else { foreach ($e in (Get-JiraInlineErrors (Get-JiraInterchangeProp $Block 'spans'))) { $errors.Add($e) } }
    }
    if ($t -eq 'bullet_list' -or $t -eq 'ordered_list') {
        if (-not (Test-JiraInterchangeProp $Block 'items')) { $errors.Add("block.items is required for a $t block") }
        else {
            foreach ($item in @(Get-JiraInterchangeProp $Block 'items')) {
                foreach ($e in (Get-JiraInlineErrors $item)) { $errors.Add($e) }
            }
        }
    }
    if ($t -eq 'code' -and -not (Test-JiraInterchangeProp $Block 'text')) { $errors.Add('block.text is required for a code block') }
    if ($t -eq 'panel_ref' -and -not (Test-JiraInterchangeProp $Block 'ref')) { $errors.Add('block.ref is required for a panel_ref block') }
    return $errors
}

function Get-JiraBlocksErrors {
    <# data-model.md §5: walk a content_blocks value's blocks[]. #>
    param($Description)
    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($b in @(Get-JiraInterchangeProp $Description 'blocks')) {
        if ($null -eq $b) { continue }
        foreach ($e in (Get-JiraBlockErrors $b)) { $errors.Add($e) }
    }
    return $errors
}

function Test-JiraInterchange {
    <#
    .SYNOPSIS
      Validate a neutral interchange document. Returns $true when valid; writes
      each error to stderr and returns $false otherwise.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Json)

    try { $d = $Json | ConvertFrom-Json -Depth 100 }
    catch { [Console]::Error.WriteLine('interchange: input is not valid JSON'); return $false }

    $errors = [System.Collections.Generic.List[string]]::new()

    if ((Get-JiraInterchangeProp $d 'schema_version') -ne '1.0') {
        $errors.Add('schema_version must be "1.0"')
    }

    $specRef = Get-JiraInterchangeProp $d 'spec_ref'
    if ($null -eq $specRef) {
        $errors.Add('spec_ref is required')
    }
    else {
        if ([string]::IsNullOrEmpty([string](Get-JiraInterchangeProp $specRef 'repo'))) { $errors.Add('spec_ref.repo is required') }
        if ([string]::IsNullOrEmpty([string](Get-JiraInterchangeProp $specRef 'folder'))) { $errors.Add('spec_ref.folder is required') }
        $slug = [string](Get-JiraInterchangeProp $specRef 'spec_slug')
        if ($slug -notmatch '^[0-9]{3}-[a-z0-9-]+$') { $errors.Add('spec_ref.spec_slug is malformed') }
    }

    $routing = Get-JiraInterchangeProp $d 'routing'
    $projectKey = [string](Get-JiraInterchangeProp $routing 'project_key')
    if ($projectKey -notmatch '^[A-Z][A-Z0-9_]+$') { $errors.Add('routing.project_key is invalid') }

    $epic = Get-JiraInterchangeProp $d 'epic'
    if ($null -eq $epic) {
        $errors.Add('epic is required')
    }
    else {
        if ([string]::IsNullOrEmpty([string](Get-JiraInterchangeProp $epic 'title'))) { $errors.Add('epic.title is required') }
        if ((Get-JiraArrayCount (Get-JiraInterchangeProp $epic 'description') 'blocks') -lt 1) { $errors.Add('epic.description.blocks must be non-empty') }
        foreach ($e in (Get-JiraBlocksErrors (Get-JiraInterchangeProp $epic 'description'))) { $errors.Add($e) }
        $marker = Get-JiraInterchangeProp $epic 'marker'
        $markerState = [string](Get-JiraInterchangeProp $marker 'state')
        if ([string]::IsNullOrEmpty($markerState)) { $markerState = 'absent' }
        if ($markerState -ne 'absent') {
            $epicLocalId = [string](Get-JiraInterchangeProp $epic 'local_id')
            if ($epicLocalId -notmatch '^[0-9a-f]{16}$') {
                $errors.Add('epic.local_id is required and must be 16 hex characters unless the marker state is absent')
            }
        }
    }

    if ((Get-JiraArrayCount $d 'stories') -lt 1) {
        $errors.Add('stories must be a non-empty array')
    }
    else {
        foreach ($s in @($d.stories)) {
            if ([string]::IsNullOrEmpty([string](Get-JiraInterchangeProp $s 'local_id'))) { $errors.Add('story.local_id is required') }
            if ([string]::IsNullOrEmpty([string](Get-JiraInterchangeProp $s 'title'))) { $errors.Add('story.title is required') }
            if (@('P1', 'P2', 'P3') -cnotcontains (Get-JiraInterchangeProp $s 'priority_logical')) { $errors.Add('story.priority_logical is invalid') }
            if ((Get-JiraArrayCount (Get-JiraInterchangeProp $s 'description') 'blocks') -lt 1) { $errors.Add('story.description.blocks must be non-empty') }
            foreach ($e in (Get-JiraBlocksErrors (Get-JiraInterchangeProp $s 'description'))) { $errors.Add($e) }
            foreach ($ac in @(Get-JiraInterchangeProp $s 'acceptance_criteria')) {
                if ($null -eq $ac) { continue }
                foreach ($clauseSet in @('given', 'when', 'then')) {
                    foreach ($clause in @(Get-JiraInterchangeProp $ac $clauseSet)) {
                        if ($null -eq $clause) { continue }
                        foreach ($e in (Get-JiraInlineErrors $clause)) { $errors.Add($e) }
                    }
                }
            }
            foreach ($d2 in @(Get-JiraInterchangeProp $s 'design')) {
                if ($null -eq $d2 -or (Get-JiraInterchangeProp $d2 'kind') -ne 'guidance') { continue }
                foreach ($e in (Get-JiraInlineErrors (Get-JiraInterchangeProp $d2 'value'))) { $errors.Add($e) }
            }
        }
    }

    # Phase 2, T026/T028, data-model.md §3: the task tier — validated only
    # for a story that carries a "tasks" property at all (its absence is the
    # off switch, FR-011).
    $allTaskLocalIds = [System.Collections.Generic.List[string]]::new()
    foreach ($s in @((Get-JiraInterchangeProp $d 'stories'))) {
        if (-not (Test-JiraInterchangeProp $s 'tasks')) { continue }
        # Direct property access, NOT Get-JiraInterchangeProp: that helper's
        # `return $Object.$Name` triggers PowerShell's single-element-array
        # unwrapping (the exact hazard Get-JiraArrayCount above exists to
        # avoid), which would turn a genuine one-task array into a scalar
        # PSCustomObject and misreport it as "not an array".
        $tasksVal = $s.tasks
        # Twin of the Bash rule `has("tasks") and ((.tasks | type) != "array")`
        # (interchange.sh): once the key is present, EVERY non-array type is
        # refused. Testing only for PSCustomObject let `null` and scalars reach
        # the per-task loop below, where `@($null)` yields a ONE-element array
        # holding $null — the story-level error went missing and three bogus
        # task-level ones took its place, while a numeric value threw outright
        # (Copilot review, PR #17). $null is already caught by -isnot, but is
        # named explicitly because it is the case that actually shipped.
        if ($null -eq $tasksVal -or $tasksVal -isnot [System.Array]) {
            $errors.Add('story.tasks must be an array')
            continue
        }
        foreach ($tk in @($tasksVal)) {
            $marker = Get-JiraInterchangeProp $tk 'marker'
            $markerState = [string](Get-JiraInterchangeProp $marker 'state')
            if ([string]::IsNullOrEmpty($markerState)) { $markerState = 'absent' }
            $taskLocalId = [string](Get-JiraInterchangeProp $tk 'local_id')
            if ($markerState -ne 'absent' -and $taskLocalId -notmatch '^[0-9a-f]{16}$') {
                $errors.Add('task.local_id is required and must be 16 hex characters unless the marker state is absent')
            }
            if ([string]::IsNullOrEmpty([string](Get-JiraInterchangeProp $tk 'title'))) { $errors.Add('task.title is required') }
            if ((Get-JiraArrayCount (Get-JiraInterchangeProp $tk 'description') 'blocks') -lt 1) { $errors.Add('task.description.blocks must be non-empty') }
            # 016, FR-019: a task description obeys the SAME inline model every
            # other description position obeys. Without this rule the task tier
            # was the one place a pre-016 raw-string paragraph could pass
            # validation and render as literal punctuation.
            foreach ($e in (Get-JiraBlocksErrors (Get-JiraInterchangeProp $tk 'description'))) { $errors.Add($e) }
            $doneVal = Get-JiraInterchangeProp $tk 'done'
            if ($doneVal -isnot [bool]) { $errors.Add('task.done must be a boolean') }
            if (-not [string]::IsNullOrEmpty($taskLocalId)) { $allTaskLocalIds.Add($taskLocalId) }
        }
    }
    if ($allTaskLocalIds.Count -ne (@($allTaskLocalIds | Select-Object -Unique)).Count) {
        $errors.Add('two tasks share a local_id')
    }

    if ($errors.Count -eq 0) { return $true }
    foreach ($e in $errors) { [Console]::Error.WriteLine("interchange: $e") }
    return $false
}

function Build-JiraNeutralDocument {
    <#
    .SYNOPSIS
      Assemble the neutral document from the parse output plus routing/strategy
      decisions, then validate it. Mirror of interchange_build (US3, T055).
      Returns a pscustomobject { Valid; Document }; Document is the canonical JSON
      when valid, empty otherwise. A validation failure blocks downstream writes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ParseJson, [Parameter(Mandatory)] [string] $ContextJson)
    $parse = $ParseJson | ConvertFrom-Json -Depth 100
    $ctx = $ContextJson | ConvertFrom-Json -Depth 100

    $projectKey = [string](Get-JiraInterchangeProp $ctx 'project_key')
    $specRef = Get-JiraInterchangeProp $ctx 'spec_ref'
    $epic = Get-JiraInterchangeProp $parse 'epic'
    $epicTitle = [string](Get-JiraInterchangeProp $epic 'title')
    $epicDesc = Get-JiraInterchangeProp $epic 'description'
    if ($null -eq $epicDesc) { $epicDesc = [ordered]@{ blocks = @() } }
    $epicLocalId = [string](Get-JiraInterchangeProp $epic 'local_id')
    $epicMarker = Get-JiraInterchangeProp $epic 'marker'
    if ($null -eq $epicMarker) { $epicMarker = [ordered]@{ state = 'absent'; id = ''; lines = @() } }
    $stories = Get-JiraInterchangeProp $parse 'stories'
    if ($null -eq $stories) { $stories = @() }

    # epic.strategy is gone (008 T026, FR-030): the field, its validation
    # rule, and the epic_strategy context key are retired together.
    $doc = [ordered]@{
        schema_version = '1.0'
        spec_ref       = $specRef
        routing        = [ordered]@{ project_key = $projectKey }
        epic           = [ordered]@{ title = $epicTitle; description = $epicDesc; local_id = $epicLocalId; marker = $epicMarker }
        stories        = @($stories)
    }
    $json = ConvertTo-JiraJsonValue $doc

    if (-not (Test-JiraInterchange $json)) {
        return [pscustomobject]@{ Valid = $false; Document = '' }
    }
    return [pscustomobject]@{ Valid = $true; Document = $json }
}

function Resolve-JiraRouting {
    <#
    .SYNOPSIS
      Resolve the ONE project a spec reconciles against (US8, FR 041, FR 042).
      Mirror of routing_resolve. Inputs: the spec folder's basename, the labels
      declared in the spec (a JSON array), and the team config's `routing` rules
      plus `routing_default`. First matching rule wins; a rule matches only when
      EVERY condition it declares holds. An unmatched spec falls back to
      routing_default; no match with no default is refused with exit 4. PURE: no
      Jira reads or writes. Returns { ExitCode; ProjectKey } (the asymmetric-shape
      convention shared with the sink client).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $FolderName,
        [Parameter(Mandatory)] [string] $LabelsJson,
        [Parameter(Mandatory)] [string] $RoutingConfigJson
    )
    $cfg = $RoutingConfigJson | ConvertFrom-Json -Depth 100
    $labels = @($LabelsJson | ConvertFrom-Json -Depth 100)

    $rules = @()
    if ((Test-JiraInterchangeProp $cfg 'routing')) { $rules = @($cfg.routing) }

    foreach ($rule in $rules) {
        $m = Get-JiraInterchangeProp $rule 'match'
        if ($m -isnot [System.Management.Automation.PSCustomObject]) { continue }
        # An empty-string condition counts as undeclared (twin of the bash jq
        # `// "" != ""` guards): the shipped template's placeholder rule must
        # not become a match-everything rule shadowing the implicit team route.
        $prefixVal = [string](Get-JiraInterchangeProp $m 'folder_prefix')
        $labelVal = [string](Get-JiraInterchangeProp $m 'spec_label')
        $hasPrefix = -not [string]::IsNullOrEmpty($prefixVal)
        $hasLabel = -not [string]::IsNullOrEmpty($labelVal)
        if (-not $hasPrefix -and -not $hasLabel) { continue }

        $ok = $true
        if ($hasPrefix -and -not $FolderName.StartsWith($prefixVal, [System.StringComparison]::Ordinal)) { $ok = $false }
        if ($hasLabel) {
            # Ordinal, CASE-SENSITIVE label match — the Bash twin uses jq index(),
            # so "Backend" must not satisfy a "backend" rule (NFR 1).
            $labelHit = $false
            foreach ($l in $labels) {
                if ([string]::Equals([string]$l, $labelVal, [System.StringComparison]::Ordinal)) { $labelHit = $true; break }
            }
            if (-not $labelHit) { $ok = $false }
        }
        if ($ok) {
            return [pscustomobject]@{ ExitCode = 0; ProjectKey = [string](Get-JiraInterchangeProp $rule 'project') }
        }
    }

    # Implicit team→project route (US3 scenario 6): after the numbering
    # component, a folder carrying a catalogue team's folder_prefix routes to
    # that team's project — before routing_default. The catalogue is opaque
    # data; the engine keeps zero tracker knowledge.
    $flat = $FolderName -creplace '^[0-9]+-', ''
    if ((Test-JiraInterchangeProp $cfg 'teams')) {
        foreach ($t in @($cfg.teams)) {
            $prefix = [string](Get-JiraInterchangeProp $t 'folder_prefix')
            if (-not [string]::IsNullOrEmpty($prefix) -and $flat.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
                return [pscustomobject]@{ ExitCode = 0; ProjectKey = [string](Get-JiraInterchangeProp $t 'project') }
            }
        }
    }

    $default = [string](Get-JiraInterchangeProp $cfg 'routing_default')
    if (-not [string]::IsNullOrEmpty($default)) {
        return [pscustomobject]@{ ExitCode = 0; ProjectKey = $default }
    }

    [Console]::Error.WriteLine('routing: no routing rule matched and no routing_default is configured')
    return [pscustomobject]@{ ExitCode = 4; ProjectKey = '' }
}

Export-ModuleMember -Function Test-JiraInterchange, Build-JiraNeutralDocument, Resolve-JiraRouting
