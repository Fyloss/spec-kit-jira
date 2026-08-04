# sink/jira/Discovery.psm1 — Project metadata discovery. Mirror of discovery.sh.
#
# Get-JiraDiscoveryBinding(Result) assembles the neutral Project Binding for one
# project by LOGICAL name (Constitution VII). Style is DETECTED FIRST (research
# §1); the per-style scheme-based path follows (research §2/§3). The estimation
# field is RANKED not assumed, and the flagged field is discovered by shape
# (research §15). The emitted binding is byte-identical to the Bash port (NFR-1):
# arrays keep discovered order and ConvertTo-JiraJsonValue sorts object keys, so
# both runtimes converge to the same `jq -cS` bytes.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../../lib/Cli.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../../lib/Output.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Client.psm1') -Force

function Get-DiscProp {
    # StrictMode-safe optional property read: $null when the property is absent.
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $p = $Object.PSObject.Properties[$Name]
        if ($p) { return $p.Value }
    }
    elseif ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    }
    return $null
}

function Get-JiraDiscoveryStyle {
    # THREE-VALUED style mapping (002 research §2, FR-001/FR-002). Mirror of
    # _disc_style: a style is returned ONLY on an explicit, non-contradictory
    # signal; both absent or contradictory returns '' — the sink never
    # substitutes a default (the binding carries style: null).
    param($Project)
    $style = [string](Get-DiscProp $Project 'style')
    $simplified = Get-DiscProp $Project 'simplified'
    # Case-SENSITIVE like the bash twin's `case` — "Classic" is no signal.
    $sSig = switch -CaseSensitive ($style) {
        'next-gen' { 'team_managed' }
        'classic' { 'company_managed' }
        default { '' }
    }
    # jq tostring semantics like the bash twin: the boolean AND the exact JSON
    # string "true"/"false" count; any other shape (including "True") does not.
    $fStr = ''
    if ($simplified -is [bool]) { $fStr = if ($simplified) { 'true' } else { 'false' } }
    elseif ($null -ne $simplified) { $fStr = [string]$simplified }
    $fSig = switch -CaseSensitive ($fStr) {
        'true' { 'team_managed' }
        'false' { 'company_managed' }
        default { '' }
    }
    if ($sSig -and $fSig) {
        if ($sSig -eq $fSig) { return $sSig }
        return ''
    }
    return "$sSig$fSig"
}

function Get-JiraDiscoveryProjectList {
    <#
    .SYNOPSIS
      The accessible-projects list (002 US2, FR-004c). Mirror of
      discovery_list_projects: paginated GET /project/search, each value mapped
      to {key, name, style} with the three-valued style rule (null when
      ambiguous). Returns { ExitCode; List } — List is the canonical JSON array
      (empty string on a fail-closed read or zero visible projects).
    #>
    [CmdletBinding()]
    param()

    $base = $env:SPEC_KIT_JIRA_BASE_URL
    if (-not $base) {
        [Console]::Error.WriteLine('discovery: SPEC_KIT_JIRA_BASE_URL is not set')
        return [pscustomobject]@{ ExitCode = (Get-JiraExitCode 'fail_closed'); List = '' }
    }
    $api = "$base/rest/api/3"

    $list = [System.Collections.Generic.List[object]]::new()
    $start = 0
    while ($true) {
        $r = Invoke-JiraRequest -Method GET -Url "$api/project/search?startAt=$start&maxResults=50"
        if ($r.ExitCode -ne 0) { return [pscustomobject]@{ ExitCode = [int] $r.ExitCode; List = '' } }
        $page = $r.Body | ConvertFrom-Json -Depth 100
        # A page without `values` must stay an EMPTY list: @($null) is a
        # one-element array that would fabricate a phantom {null,null,null}
        # project and bypass the zero-results fail-closed guard below.
        $values = Get-DiscProp $page 'values'
        if ($null -eq $values) { $values = @() } else { $values = @($values) }
        foreach ($v in $values) {
            $style = Get-JiraDiscoveryStyle $v
            $list.Add([ordered]@{
                key   = (Get-DiscProp $v 'key')
                name  = (Get-DiscProp $v 'name')
                style = $(if ($style -eq '') { $null } else { $style })
            })
        }
        $isLast = Get-DiscProp $page 'isLast'
        if ($null -eq $isLast) { $isLast = $true }
        $total = Get-DiscProp $page 'total'
        if ($null -eq $total) { $total = 0 }
        $start += $values.Count
        if ($isLast -eq $true -or $start -ge [int]$total -or $values.Count -eq 0) { break }
    }
    if ($list.Count -eq 0) {
        [Console]::Error.WriteLine('discovery: the configured credentials can browse no visible project (project/search returned zero results)')
        return [pscustomobject]@{ ExitCode = (Get-JiraExitCode 'fail_closed'); List = '' }
    }
    return [pscustomobject]@{ ExitCode = 0; List = (ConvertTo-JiraJsonValue $list) }
}

function Get-JiraDiscoveryPrioritiesForProject {
    <#
    .SYNOPSIS
      Derive the priorities a resolved project actually accepts, from its OWN
      create metadata against the site-wide identifier catalogue (research R4,
      004 US4, FR-030/FR-031). Mirror of discovery_priorities_for_project.
      Three branches, never a rule keyed on project style (FR-028):
        1. no `priority` field at all             -> []
        2. `priority` field WITH allowedValues    -> only those, resolved by
           id against the catalogue
        3. `priority` field WITHOUT allowedValues -> the whole catalogue
           (today's behaviour, preserved for a site that omits allowedValues)
    #>
    [CmdletBinding()]
    param([object[]] $Fields, [object[]] $Catalogue)
    $result = [System.Collections.Generic.List[object]]::new()
    $priorityField = $null
    foreach ($f in $Fields) {
        if ([string](Get-DiscProp $f 'fieldId') -eq 'priority') { $priorityField = $f; break }
    }
    if ($null -eq $priorityField) { return $result }

    $allowed = Get-DiscProp $priorityField 'allowedValues'
    if ($null -ne $allowed) {
        foreach ($av in @($allowed)) {
            $id = [string](Get-DiscProp $av 'id')
            foreach ($p in $Catalogue) {
                if ([string]$p.id -eq $id) { $result.Add([ordered]@{ logical_name = $p.name; id = $p.id }); break }
            }
        }
        return $result
    }

    foreach ($p in $Catalogue) { $result.Add([ordered]@{ logical_name = $p.name; id = $p.id }) }
    return $result
}

function Get-JiraDiscoveryHierarchyCandidates {
    <#
    .SYNOPSIS
      The SOLE-candidate child and parent type ids, when the level is
      unambiguous (research R1/R2). No refusal here: an ambiguous level
      simply yields no candidate for that tier. The full derivation and its
      refusals (no-parent-level, parent-level-ambiguous) live in
      sink/jira/Hierarchy.psm1 (Phase 4, US1); this is only enough to know
      which types' create metadata discovery can usefully fetch before the
      child type has been resolved by the ceremony. Mirror of
      _disc_hierarchy_candidates.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Names the set of hierarchy candidates it derives; a singular name would misdescribe the value.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $IssueTypes)
    $cand = @($IssueTypes | Where-Object { -not [bool]$_.subtask })
    if ($cand.Count -eq 0) { return [pscustomobject]@{ Child = $null; Parent = $null } }
    $childLevel = ($cand | ForEach-Object { [int]$_.hierarchyLevel } | Measure-Object -Minimum).Minimum
    $childCands = @($cand | Where-Object { [int]$_.hierarchyLevel -eq $childLevel })
    $above = @($cand | Where-Object { [int]$_.hierarchyLevel -gt $childLevel })
    $parentCands = @()
    if ($above.Count -gt 0) {
        $parentLevel = ($above | ForEach-Object { [int]$_.hierarchyLevel } | Measure-Object -Minimum).Minimum
        $parentCands = @($above | Where-Object { [int]$_.hierarchyLevel -eq $parentLevel })
    }
    return [pscustomobject]@{
        Child  = $(if ($childCands.Count -eq 1) { $childCands[0].id } else { $null })
        Parent = $(if ($parentCands.Count -eq 1) { $parentCands[0].id } else { $null })
    }
}

function Get-JiraDiscoveryRequiredFields {
    <#
    .SYNOPSIS
      Every field this type's create metadata marks required, by its Jira
      NAME (never a customfield_NNNNN id) — the mandatory-field gate of
      contracts/hierarchy-resolution.md §5 (Phase 6, US3). Mirror of
      _disc_required_fields.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Names the set of required fields it derives; a singular name would misdescribe the value.')]
    [CmdletBinding()]
    param($Fields)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($f in @($Fields)) {
        if ([bool] $f.required) { $out.Add([ordered]@{ logical_name = $f.name; field_id = $f.fieldId }) }
    }
    return $out
}

function Get-JiraDiscoveryDefaultableFields {
    <#
    .SYNOPSIS
      Every field this type's create metadata reports that the bridge does
      NOT itself supply (011, research R3, contract §2.1), required or not
      (FR-004). Mirror of _disc_defaultable_fields. The bridge-supplied
      constant is never a candidate for a recorded default (contract §1.1)
      and is simply absent from the output. `defaultable: false` only for a
      shape that cannot be a single recorded scalar — array or issuelink —
      carrying an `undefaultable_reason` (FR-010).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Names the set of defaultable-field descriptors it derives; a singular name would misdescribe the value.')]
    [CmdletBinding()]
    param($Fields)
    $bridgeSupplied = @('summary', 'description', 'issuetype', 'project', 'priority', 'reporter', 'parent')
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($f in @($Fields)) {
        $fid = [string] $f.fieldId
        if ($bridgeSupplied -contains $fid) { continue }
        $schema = Get-DiscProp $f 'schema'
        $st = [string] (Get-DiscProp $schema 'type')
        $reason = $null
        if ($st -eq 'array') { $reason = 'a list of values cannot be expressed as a single recorded value' }
        elseif ($st -eq 'issuelink') { $reason = 'an issue link cannot be expressed as a recorded value' }
        $allowed = [System.Collections.Generic.List[string]]::new()
        $avRaw = Get-DiscProp $f 'allowedValues'
        if ($null -ne $avRaw) {
            foreach ($av in @($avRaw)) {
                $v = Get-DiscProp $av 'value'
                if ($null -eq $v) { $v = Get-DiscProp $av 'name' }
                $allowed.Add([string] $v)
            }
        }
        $entry = [ordered]@{
            logical_name = $f.name
            field_id     = $fid
            schema_type  = $st
            required     = [bool] $f.required
            defaultable  = ($null -eq $reason)
            allowed_values = $allowed
        }
        if ($null -ne $reason) { $entry.undefaultable_reason = $reason }
        $out.Add($entry)
    }
    return $out
}

function Get-JiraDiscoveryTypeMetadataResult {
    <#
    .SYNOPSIS
      One issue type's required fields, defaultable fields, and parent-link
      availability (010, T050/T051; 011 adds DefaultableFields), fetched on
      demand for a role the resolver selected but
      Get-JiraDiscoveryBindingResult's own single-candidate prefetch
      (research R1/R2) did not already cover. Mirror of
      discovery_type_metadata. Returns { ExitCode; RequiredFields;
      ParentLinkAvailable; DefaultableFields }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ProjectKey, [Parameter(Mandatory)][string] $TypeId)

    $base = $env:SPEC_KIT_JIRA_BASE_URL
    if (-not $base) {
        [Console]::Error.WriteLine('discovery: SPEC_KIT_JIRA_BASE_URL is not set')
        return [pscustomobject]@{ ExitCode = (Get-JiraExitCode 'fail_closed'); RequiredFields = @(); ParentLinkAvailable = $false; DefaultableFields = @() }
    }
    $api = "$base/rest/api/3"
    $r = Invoke-JiraRequest -Method GET -Url "$api/issue/createmeta/$ProjectKey/issuetypes/$TypeId"
    if ($r.ExitCode -ne 0) {
        return [pscustomobject]@{ ExitCode = [int]$r.ExitCode; RequiredFields = @(); ParentLinkAvailable = $false; DefaultableFields = @() }
    }
    $tmeta = $r.Body | ConvertFrom-Json -Depth 100
    $rf = @(Get-JiraDiscoveryRequiredFields -Fields $tmeta.fields)
    $pla = [bool]@($tmeta.fields | Where-Object { $_.fieldId -eq 'parent' }).Count
    $df = @(Get-JiraDiscoveryDefaultableFields -Fields $tmeta.fields)
    return [pscustomobject]@{ ExitCode = 0; RequiredFields = $rf; ParentLinkAvailable = $pla; DefaultableFields = $df }
}

function Get-JiraDiscoveryBindingResult {
    <#
    .SYNOPSIS
      Discover one project's Project Binding. Returns { ExitCode; Binding } where
      Binding is the canonical JSON string (empty on a fail-closed read). Mirrors
      discover_binding: nothing emitted on failure, the transport's mapped code.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ProjectKey)

    $base = $env:SPEC_KIT_JIRA_BASE_URL
    if (-not $base) {
        [Console]::Error.WriteLine('discovery: SPEC_KIT_JIRA_BASE_URL is not set')
        return [pscustomobject]@{ ExitCode = (Get-JiraExitCode 'fail_closed'); Binding = '' }
    }
    $api = "$base/rest/api/3"

    # A fail-closed read short-circuits the whole discovery: the sentinel carries
    # the transport's mapped exit code out through the catch (research §8).
    $get = {
        param($url)
        $r = Invoke-JiraRequest -Method GET -Url $url
        if ($r.ExitCode -ne 0) { throw ([pscustomobject]@{ FailClosed = $true; ExitCode = [int] $r.ExitCode }) }
        return ($r.Body | ConvertFrom-Json -Depth 100)
    }

    try {
        # (1) Style — the first Jira call.
        $proj = & $get "$api/project/$ProjectKey"
        $style = Get-JiraDiscoveryStyle $proj

        # (2) Issue types + hierarchy levels.
        $itypes = & $get "$api/issue/createmeta/$ProjectKey/issuetypes"
        $firstType = if (@($itypes.issueTypes).Count -gt 0) { $itypes.issueTypes[0].id } else { '' }

        # (2b) The child/parent candidates resolvable without asking
        # (research R1/R2) — used only to pick which type(s) get a per-type
        # createmeta fetch (T017/T018, contract §4).
        $hier = Get-JiraDiscoveryHierarchyCandidates -IssueTypes @($itypes.issueTypes)
        $childId = $hier.Child
        $parentId = $hier.Parent

        # (3) Project field schema (estimation candidates + flagged field
        # source). Sourced from the CHILD type when resolvable — the type
        # this bridge actually writes — falling back to the old arbitrary-
        # first-type fetch only when the child level is itself ambiguous.
        $metaTypeId = if ($childId) { $childId } else { $firstType }
        $meta = & $get "$api/issue/createmeta/$ProjectKey/issuetypes/$metaTypeId"

        # (3b) required_fields and parent-link availability, per written
        # type actually resolvable at this point (T017–T020, contract §4) —
        # reusing the (3) fetch when a type coincides with it. Parent-link
        # availability is READ from the type's own metadata, never assumed
        # from project style (R4).
        $requiredFields = [ordered]@{}
        $parentLinkAvailable = [ordered]@{}
        $defaultableFields = [ordered]@{}
        foreach ($tid in @($childId, $parentId)) {
            if (-not $tid) { continue }
            if ($requiredFields.Contains([string]$tid)) { continue }
            $tmeta = if ($tid -eq $metaTypeId) { $meta } else { & $get "$api/issue/createmeta/$ProjectKey/issuetypes/$tid" }
            $requiredFields[[string]$tid] = @(Get-JiraDiscoveryRequiredFields -Fields $tmeta.fields)
            $parentLinkAvailable[[string]$tid] = [bool]@($tmeta.fields | Where-Object { $_.fieldId -eq 'parent' }).Count
            $defaultableFields[[string]$tid] = @(Get-JiraDiscoveryDefaultableFields -Fields $tmeta.fields)
        }

        # (4) Statuses + statusCategory.
        $statusGroups = & $get "$api/project/$ProjectKey/statuses"

        # (5) Priorities.
        $priorities = & $get "$api/priority"

        # (6) Field catalogue.
        $fields = & $get "$api/field"
    }
    catch {
        $sentinel = $_.TargetObject
        if ($sentinel -is [pscustomobject] -and (Get-DiscProp $sentinel 'FailClosed')) {
            return [pscustomobject]@{ ExitCode = [int] $sentinel.ExitCode; Binding = '' }
        }
        throw
    }

    # --- Assemble the neutral binding (arrays in discovered order) --------------
    $issueTypes = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $itypes.issueTypes) {
        $issueTypes.Add([ordered]@{
            logical_name    = $t.name
            id              = $t.id
            subtask         = [bool] $t.subtask
            hierarchy_level = $t.hierarchyLevel
        })
    }

    $statuses = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($grp in $statusGroups) {
        foreach ($s in $grp.statuses) {
            if ($seen.Add([string] $s.id)) {
                $statuses.Add([ordered]@{
                    name            = $s.name
                    id              = $s.id
                    status_category = $s.statusCategory.key
                })
            }
        }
    }

    # @() guards against PowerShell unwrapping an EMPTY List returned across a
    # function boundary into $null (a team-managed project with no priority
    # field must still serialise as [], not null).
    $prio = @(Get-JiraDiscoveryPrioritiesForProject -Fields $meta.fields -Catalogue $priorities)

    $fieldList = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $fields) {
        $schema = Get-DiscProp $f 'schema'
        $fieldList.Add([ordered]@{
            logical_name = $f.name
            id           = $f.id
            schema_type  = (Get-DiscProp $schema 'type')
            custom       = $f.custom
        })
    }

    $cands = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $meta.fields) {
        $schema = Get-DiscProp $f 'schema'
        if ((Get-DiscProp $schema 'type') -ne 'number') { continue }
        $custom = [string](Get-DiscProp $schema 'custom')
        $score = 2
        if ($custom -imatch 'float|gh-sprint|story-point') { $score += 2 }
        if ([string] $f.name -imatch 'estimat|point|effort|story') { $score += 1 }
        $cands.Add([ordered]@{
            logical_name = $f.name
            id           = $f.fieldId
            schema_type  = (Get-DiscProp $schema 'type')
            score        = $score
        })
    }
    $sortedCands = @($cands | Sort-Object @{ Expression = { $_.score }; Descending = $true }, @{ Expression = { [string] $_.id }; Descending = $false })

    # The flagged field resolves by name, then by shape (locale-independent).
    $flagged = Get-JiraDiscoveryFlaggedField -FieldsJson (ConvertTo-JiraJsonValue @($meta.fields))

    $binding = [ordered]@{
        style                 = $(if ($style -eq '') { $null } else { $style })
        issue_types           = $issueTypes
        statuses              = $statuses
        priorities            = $prio
        fields                = $fieldList
        estimation_candidates = [System.Collections.Generic.List[object]]::new($sortedCands)
        flagged_field         = $flagged
        required_fields       = $requiredFields
        parent_link_available = $parentLinkAvailable
        defaultable_fields    = $defaultableFields
    }

    return [pscustomobject]@{ ExitCode = 0; Binding = (ConvertTo-JiraJsonValue $binding) }
}

function Get-JiraDiscoveryFlaggedField {
    <#
    .SYNOPSIS
      Resolve the project's Flagged/impediment field, the input of
      flagged-withholding lifecycle safety (FR-036). LOCALE-INDEPENDENT: the
      English name (`Impediment`/`Flagged`) is only a first-chance match; a
      localized or renamed site resolves by SHAPE — the Flagged field is an
      array-of-options checkbox custom field — and only an unambiguous single
      shape candidate is accepted (precision over recall). Returns the
      {logical_name,id} map, or $null. Mirror of discovery_flagged_field.
    #>
    [CmdletBinding()]
    param([string] $FieldsJson = '[]')
    $fields = @($FieldsJson | ConvertFrom-Json -Depth 100)

    foreach ($f in $fields) {
        if ([string](Get-DiscProp $f 'name') -imatch 'impediment|flag') {
            return [ordered]@{ logical_name = $f.name; id = $f.fieldId }
        }
    }

    $shape = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $fields) {
        $schema = Get-DiscProp $f 'schema'
        if (-not [string]::Equals([string](Get-DiscProp $schema 'type'), 'array', [System.StringComparison]::Ordinal)) { continue }
        if ([string](Get-DiscProp $schema 'custom') -inotmatch 'multicheckboxes|gh-flagged') { continue }
        $shape.Add([ordered]@{ logical_name = $f.name; id = $f.fieldId })
    }
    if ($shape.Count -eq 1) { return $shape[0] }
    return $null
}

function Get-JiraDiscoveryBinding {
    <#
    .SYNOPSIS
      Convenience wrapper returning just the canonical binding JSON string (empty
      on a fail-closed read). Use Get-JiraDiscoveryBindingResult for the exit code.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ProjectKey)
    return (Get-JiraDiscoveryBindingResult -ProjectKey $ProjectKey).Binding
}

function Add-JiraAdfText {
    # Collect every ADF text-node value under a node in document (pre-order) order,
    # mirroring jq's `[.. | .text?]` recursive descent so both ports build the same
    # content/criteria strings.
    param($Node, [System.Collections.Generic.List[string]] $Acc)
    if ($null -eq $Node) { return }
    if ($Node -is [string]) { return }
    if ($Node -is [System.Collections.IEnumerable]) {
        foreach ($item in $Node) { Add-JiraAdfText $item $Acc }
        return
    }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        $t = Get-DiscProp $Node 'text'
        if ($t -is [string]) { $Acc.Add($t) }
        foreach ($p in $Node.PSObject.Properties) {
            if ($p.Name -eq 'text') { continue }
            Add-JiraAdfText $p.Value $Acc
        }
    }
}

function Get-JiraAdfSection {
    # Join the top-level description content nodes (panels or non-panels, per the
    # $Panels switch) into one string: text per node concatenated, empty nodes
    # dropped, nodes joined with LF. Mirrors fetch_mentioned's content/criteria.
    param($Description, [bool] $Panels)
    $out = [System.Collections.Generic.List[string]]::new()
    $content = Get-DiscProp $Description 'content'
    if ($null -ne $content) {
        foreach ($node in $content) {
            $isPanel = ((Get-DiscProp $node 'type') -eq 'panel')
            if ($isPanel -ne $Panels) { continue }
            $acc = [System.Collections.Generic.List[string]]::new()
            Add-JiraAdfText $node $acc
            $joined = -join $acc
            if ($joined -ne '') { $out.Add($joined) }
        }
    }
    return ($out -join "`n")
}

function Get-JiraMentionedFetchResult {
    <#
    .SYNOPSIS
      Read-only fetch of a mentioned ticket (US10, FR-050). Mirror of fetch_mentioned:
      returns { ExitCode; Fetch } where Fetch is the canonical neutral fetch JSON
      (empty with the transport's mapped exit code on a fail-closed read of the ticket).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $IssueKey)

    $base = $env:SPEC_KIT_JIRA_BASE_URL
    if (-not $base) {
        [Console]::Error.WriteLine('fetch_mentioned: SPEC_KIT_JIRA_BASE_URL is not set')
        return [pscustomobject]@{ ExitCode = (Get-JiraExitCode 'fail_closed'); Fetch = '' }
    }
    $api = "$base/rest/api/3"
    $flaggedId = $env:SPEC_KIT_JIRA_FLAGGED_FIELD_ID

    # (1) The ticket itself — the only read that must succeed (fail-closed).
    $r = Invoke-JiraRequest -Method GET -Url "$api/issue/$IssueKey"
    if ($r.ExitCode -ne 0) { return [pscustomobject]@{ ExitCode = [int] $r.ExitCode; Fetch = '' } }
    $issue = $r.Body | ConvertFrom-Json -Depth 100
    $f = Get-DiscProp $issue 'fields'

    # (2) Remote links — supplementary; a failure degrades to "no linked pages".
    $remote = @()
    $rl = Invoke-JiraRequest -Method GET -Url "$api/issue/$IssueKey/remotelink"
    if ($rl.ExitCode -eq 0 -and $rl.Body) { $remote = @($rl.Body | ConvertFrom-Json -Depth 100) }

    # (3) Siblings — only when the ticket has a parent (JQL over the parent's children).
    $siblingIssues = @()
    $parent = Get-DiscProp $f 'parent'
    if ($null -ne $parent) {
        $pkey = Get-DiscProp $parent 'key'
        $jql = [uri]::EscapeDataString("parent=$pkey")
        $sr = Invoke-JiraRequest -Method GET -Url "$api/search?jql=$jql&fields=summary,status"
        if ($sr.ExitCode -eq 0 -and $sr.Body) {
            $sd = $sr.Body | ConvertFrom-Json -Depth 100
            $si = Get-DiscProp $sd 'issues'
            if ($null -ne $si) { $siblingIssues = @($si) }
        }
    }

    # --- Assemble the neutral fetch (arrays in Jira order) ----------------------
    $description = Get-DiscProp $f 'description'
    $priority = Get-DiscProp $f 'priority'
    $status = Get-DiscProp $f 'status'

    $labels = Get-DiscProp $f 'labels'
    if ($null -eq $labels) { $labels = @() }

    $flagged = $false
    if ($flaggedId) {
        $fv = Get-DiscProp $f $flaggedId
        if ($null -ne $fv) {
            if ($fv -is [System.Collections.IEnumerable] -and $fv -isnot [string]) { $flagged = (@($fv).Count -gt 0) }
            else { $flagged = $true }
        }
    }

    $links = [System.Collections.Generic.List[object]]::new()
    $issuelinks = Get-DiscProp $f 'issuelinks'
    if ($null -ne $issuelinks) {
        foreach ($lk in $issuelinks) {
            $type = Get-DiscProp $lk 'type'
            $outward = Get-DiscProp $lk 'outwardIssue'
            $inward = Get-DiscProp $lk 'inwardIssue'
            if ($null -ne $outward) {
                $lf = Get-DiscProp $outward 'fields'
                $links.Add([ordered]@{
                    type = (Get-DiscProp $type 'name'); direction = (Get-DiscProp $type 'outward')
                    key = (Get-DiscProp $outward 'key'); title = (Get-DiscProp $lf 'summary')
                    status = (Get-DiscProp (Get-DiscProp $lf 'status') 'name')
                })
            }
            elseif ($null -ne $inward) {
                $lf = Get-DiscProp $inward 'fields'
                $links.Add([ordered]@{
                    type = (Get-DiscProp $type 'name'); direction = (Get-DiscProp $type 'inward')
                    key = (Get-DiscProp $inward 'key'); title = (Get-DiscProp $lf 'summary')
                    status = (Get-DiscProp (Get-DiscProp $lf 'status') 'name')
                })
            }
        }
    }

    $confluence = [System.Collections.Generic.List[object]]::new()
    foreach ($link in $remote) {
        $app = Get-DiscProp $link 'application'
        $appType = [string](Get-DiscProp $app 'type')
        $globalId = [string](Get-DiscProp $link 'globalId')
        if ($appType -imatch 'confluence' -or $globalId -imatch 'confluence') {
            $obj = Get-DiscProp $link 'object'
            $confluence.Add([ordered]@{ title = (Get-DiscProp $obj 'title'); url = (Get-DiscProp $obj 'url') })
        }
    }

    $parentContext = $null
    if ($null -ne $parent) {
        $pf = Get-DiscProp $parent 'fields'
        $parentContext = [ordered]@{
            key = (Get-DiscProp $parent 'key'); title = (Get-DiscProp $pf 'summary')
            status = (Get-DiscProp (Get-DiscProp $pf 'status') 'name')
        }
    }

    $siblings = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $siblingIssues) {
        $sf = Get-DiscProp $s 'fields'
        $siblings.Add([ordered]@{
            key = (Get-DiscProp $s 'key'); title = (Get-DiscProp $sf 'summary')
            status = (Get-DiscProp (Get-DiscProp $sf 'status') 'name')
        })
    }

    $doc = [ordered]@{
        key                 = $IssueKey
        content             = (Get-JiraAdfSection $description $false)
        acceptance_criteria = (Get-JiraAdfSection $description $true)
        priority_logical    = (Get-DiscProp $priority 'name')
        labels              = $labels
        status              = (Get-DiscProp $status 'name')
        flagged             = $flagged
        links               = $links
        confluence_pages    = $confluence
        parent_context      = $parentContext
        siblings            = $siblings
    }

    return [pscustomobject]@{ ExitCode = 0; Fetch = (ConvertTo-JiraJsonValue $doc) }
}

function Get-JiraDiscoveryTaskTransitionResult {
    <#
    .SYNOPSIS
      The task tier's only new read (012, research R5, contract §6). Mirror of
      discovery_task_transition: reads the sub-task's available transitions and
      selects a destination by the destination's own statusCategory alone —
      never a status name, in any spelling (Constitution VII; FR-030). Direction
      "forward" selects statusCategory "done" destinations; "backward" selects
      everything else (FR-032's operator-authorised pull back). Returns
      { ExitCode; Transition } where Transition is the canonical
      { candidates; transition_id; withheld_field } JSON string.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $IssueKey, [string] $Direction = 'forward')

    $base = $env:SPEC_KIT_JIRA_BASE_URL
    if (-not $base) {
        [Console]::Error.WriteLine('discovery: SPEC_KIT_JIRA_BASE_URL is not set')
        return [pscustomobject]@{ ExitCode = (Get-JiraExitCode 'fail_closed'); Transition = '' }
    }
    $api = "$base/rest/api/3"
    $r = Invoke-JiraRequest -Method GET -Url "$api/issue/$IssueKey/transitions?expand=transitions.fields"
    if ($r.ExitCode -ne 0) { return [pscustomobject]@{ ExitCode = [int] $r.ExitCode; Transition = '' } }
    $resp = $r.Body | ConvertFrom-Json -Depth 100
    $transitions = @(Get-DiscProp $resp 'transitions')

    $matching = @($transitions | Where-Object {
        $cat = [string](Get-DiscProp (Get-DiscProp $_ 'to') 'statusCategory' | ForEach-Object { Get-DiscProp $_ 'key' })
        ($cat -eq 'done') -eq ($Direction -eq 'forward')
    })
    $candidates = @($matching | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name } })

    $transitionId = $null
    $withheldField = $null
    if ($candidates.Count -eq 1) {
        $fields = Get-DiscProp $matching[0] 'fields'
        $requiredEntry = $null
        if ($null -ne $fields) {
            foreach ($prop in $fields.PSObject.Properties) {
                if ([bool](Get-DiscProp $prop.Value 'required')) { $requiredEntry = $prop; break }
            }
        }
        if ($null -eq $requiredEntry) {
            $transitionId = $matching[0].id
        }
        else {
            $logicalName = Get-DiscProp $requiredEntry.Value 'name'
            if (-not $logicalName) { $logicalName = $requiredEntry.Name }
            $withheldField = [ordered]@{ logical_name = $logicalName; field_id = $requiredEntry.Name }
        }
    }

    $doc = [ordered]@{ candidates = $candidates; transition_id = $transitionId; withheld_field = $withheldField }
    return [pscustomobject]@{ ExitCode = 0; Transition = (ConvertTo-JiraJsonValue $doc) }
}

function Get-JiraMentionedFetch {
    <#
    .SYNOPSIS
      Convenience wrapper returning just the canonical fetch JSON string (empty on a
      fail-closed read). Use Get-JiraMentionedFetchResult for the exit code.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $IssueKey)
    return (Get-JiraMentionedFetchResult -IssueKey $IssueKey).Fetch
}

Export-ModuleMember -Function Get-JiraDiscoveryBinding, Get-JiraDiscoveryBindingResult, `
    Get-JiraDiscoveryStyle, Get-JiraDiscoveryFlaggedField, Get-JiraDiscoveryProjectList, `
    Get-JiraDiscoveryPrioritiesForProject, Get-JiraDiscoveryDefaultableFields, `
    Get-JiraMentionedFetch, Get-JiraMentionedFetchResult, Get-JiraDiscoveryTypeMetadataResult, `
    Get-JiraDiscoveryTaskTransitionResult
