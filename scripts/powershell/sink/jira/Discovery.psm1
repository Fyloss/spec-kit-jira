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
    # Map the detected style to its logical value (research §1). next-gen /
    # simplified -> team_managed; classic -> company_managed; neither -> company.
    param($Project)
    $style = [string](Get-DiscProp $Project 'style')
    $simplified = Get-DiscProp $Project 'simplified'
    if ($style -eq 'next-gen' -or $simplified -eq $true) { return 'team_managed' }
    if ($style -eq 'classic' -or $simplified -eq $false) { return 'company_managed' }
    return 'company_managed'
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

        # (3) Project field schema (estimation candidates + flagged field source).
        $meta = & $get "$api/issue/createmeta/$ProjectKey/issuetypes/$firstType"

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

    $prio = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $priorities) {
        $prio.Add([ordered]@{ logical_name = $p.name; id = $p.id })
    }

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
        style                 = $style
        issue_types           = $issueTypes
        statuses              = $statuses
        priorities            = $prio
        fields                = $fieldList
        estimation_candidates = [System.Collections.Generic.List[object]]::new($sortedCands)
        flagged_field         = $flagged
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
    Get-JiraDiscoveryFlaggedField, Get-JiraMentionedFetch, Get-JiraMentionedFetchResult
