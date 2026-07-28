# sink/jira/Adoption.psm1 — Adoption discovery against Jira. Mirror of
# sink/jira/adoption.sh (003 US1).
#
# The JQL label search and its cursor pagination, the per-candidate context read,
# the identity claim read, and the issue-key SHAPE validation for `--bind` all
# live here — the only layer permitted to carry a key-shaped literal (research §9).
#
# Discovery is READ-ONLY. The single write kind adoption emits is the identity
# entity-property stamp; its URL and payload are composed here from the SAME
# Get-JiraIdentityUrl / Get-JiraIdentityMarker the `mention` command uses, and the
# ordered set is executed by the existing Invoke-JiraApplyWriteSet (research §7),
# which is how the privacy guard and the abort ladder are inherited.
#
# Pagination loops on `nextPageToken` until the response omits it: a truncated
# candidate list would turn a two-candidate ambiguity (which must be refused) into
# a one-candidate binding (which would be applied) — NFR-6, research §2.

Set-StrictMode -Version Latest

$SinkRoot = $PSScriptRoot
$ScriptsRoot = Split-Path -Parent (Split-Path -Parent $SinkRoot)
Import-Module (Join-Path $ScriptsRoot 'lib/Cli.psm1') -Force
Import-Module (Join-Path $ScriptsRoot 'lib/Output.psm1') -Force
Import-Module (Join-Path $SinkRoot 'Client.psm1') -Force
Import-Module (Join-Path $SinkRoot 'Identity.psm1') -Force

# Page size requested from the search endpoint; the loop honours what the server
# actually returns.
$script:AdoptSearchPageSize = 100
# The fields the candidate context needs, and the only ones ever requested.
$script:AdoptFields = 'labels,parent,project'

function Get-AdoptSinkProp {
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
        return $null
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    return $null
}

function Get-AdoptApiBase {
    if ([string]::IsNullOrEmpty($env:SPEC_KIT_JIRA_BASE_URL)) {
        [Console]::Error.WriteLine('adopt: SPEC_KIT_JIRA_BASE_URL is not set')
        return ''
    }
    return "$($env:SPEC_KIT_JIRA_BASE_URL)/rest/api/3"
}

function ConvertTo-AdoptCandidate {
    # The neutral candidate shape the engine consumes as opaque JSON
    # (data-model §4). `identity` starts null; the claim read fills it.
    param($Issue)
    $fields = Get-AdoptSinkProp $Issue 'fields'
    $project = Get-AdoptSinkProp $fields 'project'
    $parent = Get-AdoptSinkProp $fields 'parent'
    $labels = @()
    $raw = Get-AdoptSinkProp $fields 'labels'
    if ($null -ne $raw) { $labels = [string[]]@($raw | ForEach-Object { [string]$_ }) }
    return [ordered]@{
        key         = [string](Get-AdoptSinkProp $Issue 'key')
        project_key = $(if ($null -eq $project) { '' } else { [string](Get-AdoptSinkProp $project 'key') })
        labels      = $labels
        parent_key  = $(if ($null -eq $parent) { $null } else { [string](Get-AdoptSinkProp $parent 'key') })
        identity    = $null
    }
}

function Get-JiraAdoptionCandidate {
    <#
    .SYNOPSIS
      One paginated JQL label search per DISTINCT routed project (never one per
      spec folder), over the union of that project's derived label values —
      including the SUPPRESSED short forms, so an ambiguous label stays
      discoverable and reportable. Mirror of adopt_search_candidates; returns
      { ExitCode; Json }.
    #>
    [CmdletBinding()]
    param([string] $TargetsJson = '[]')

    $api = Get-AdoptApiBase
    if ([string]::IsNullOrEmpty($api)) {
        return [pscustomobject]@{ ExitCode = [int](Get-JiraExitCode 'fail_closed'); Json = '' }
    }

    $byProject = @{}
    foreach ($t in @($TargetsJson | ConvertFrom-Json -Depth 100)) {
        $p = [string](Get-AdoptSinkProp $t 'project_key')
        if (-not $byProject.ContainsKey($p)) {
            $byProject[$p] = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
        }
        foreach ($l in @(Get-AdoptSinkProp $t 'labels')) { [void]$byProject[$p].Add([string]$l) }
        foreach ($l in @(Get-AdoptSinkProp $t 'probe_labels')) { [void]$byProject[$p].Add([string]$l) }
    }

    $projects = [string[]]@($byProject.Keys | ForEach-Object { [string]$_ })
    [System.Array]::Sort($projects, [System.StringComparer]::Ordinal)

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($project in $projects) {
        $values = (@($byProject[$project] | ForEach-Object { "`"$_`"" })) -join ', '
        $jql = "project = `"$project`" AND labels IN ($values)"
        $token = ''
        $prevToken = ''
        while ($true) {
            $url = "$api/search/jql?jql=$(ConvertTo-JiraUriComponent $jql)&fields=$($script:AdoptFields)&maxResults=$($script:AdoptSearchPageSize)"
            if (-not [string]::IsNullOrEmpty($token)) {
                $url = "$url&nextPageToken=$(ConvertTo-JiraUriComponent $token)"
            }
            $r = Invoke-JiraRequest -Method GET -Url $url
            if ([int]$r.ExitCode -ne 0) { return [pscustomobject]@{ ExitCode = [int]$r.ExitCode; Json = '' } }
            $page = $r.Body | ConvertFrom-Json -Depth 100
            $issues = @(Get-AdoptSinkProp $page 'issues')
            foreach ($issue in $issues) {
                if ($null -eq $issue) { continue }
                $out.Add((ConvertTo-AdoptCandidate $issue))
            }
            $prevToken = $token
            $nt = Get-AdoptSinkProp $page 'nextPageToken'
            $token = $(if ($null -eq $nt) { '' } else { [string]$nt })
            # The absence of a token is the ONLY stop condition the contract
            # offers; an empty page, or a server repeating a cursor, also ends
            # the loop so a misbehaving endpoint cannot spin forever.
            if ([string]::IsNullOrEmpty($token) -or $token -ceq $prevToken -or $issues.Count -eq 0) { break }
        }
    }

    $keys = [string[]]@($out | ForEach-Object { [string]$_['key'] })
    [System.Array]::Sort($keys, [System.StringComparer]::Ordinal)
    $sorted = [System.Collections.Generic.List[object]]::new()
    foreach ($k in $keys) {
        foreach ($c in $out) { if ([string]$c['key'] -ceq $k -and -not $sorted.Contains($c)) { $sorted.Add($c); break } }
    }
    return [pscustomobject]@{ ExitCode = 0; Json = (ConvertTo-JiraJsonValue $sorted.ToArray()) }
}

function Test-JiraAdoptionIssueKey {
    <#
    .SYNOPSIS
      The issue-key SHAPE check for `--bind` (research §9). It lives here, and
      only here, because the sink is the one layer permitted to carry a
      key-shaped literal. Mirror of adopt_valid_issue_key.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Key)
    return ($Key -cmatch '^[A-Z][A-Z0-9_]*-[0-9]+$')
}

function Get-JiraAdoptionPinnedContext {
    <#
    .SYNOPSIS
      Read the context of explicitly pinned issue keys so a pin is validated
      through the IDENTICAL path a discovered candidate is (FR-020). A malformed
      key is refused before any request; an unreadable key propagates its mapped
      exit code. Mirror of adopt_fetch_pinned; returns { ExitCode; Json }.
    #>
    [CmdletBinding()]
    param([string] $KeysJson = '[]')

    $keys = [string[]]@($KeysJson | ConvertFrom-Json -Depth 100 | ForEach-Object { [string]$_ })
    if ($keys.Count -eq 0) { return [pscustomobject]@{ ExitCode = 0; Json = '[]' } }

    $api = Get-AdoptApiBase
    if ([string]::IsNullOrEmpty($api)) {
        return [pscustomobject]@{ ExitCode = [int](Get-JiraExitCode 'fail_closed'); Json = '' }
    }

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($key in $keys) {
        if (-not (Test-JiraAdoptionIssueKey -Key $key)) {
            [Console]::Error.WriteLine("adopt: malformed issue key in --bind: $key")
            return [pscustomobject]@{ ExitCode = [int](Get-JiraExitCode 'usage'); Json = '' }
        }
        $r = Invoke-JiraRequest -Method GET -Url "$api/issue/$key`?fields=$($script:AdoptFields)"
        if ([int]$r.ExitCode -ne 0) { return [pscustomobject]@{ ExitCode = [int]$r.ExitCode; Json = '' } }
        $out.Add((ConvertTo-AdoptCandidate ($r.Body | ConvertFrom-Json -Depth 100)))
    }
    $sortKeys = [string[]]@($out | ForEach-Object { [string]$_['key'] })
    [System.Array]::Sort($sortKeys, [System.StringComparer]::Ordinal)
    $sorted = [System.Collections.Generic.List[object]]::new()
    foreach ($k in $sortKeys) {
        foreach ($c in $out) { if ([string]$c['key'] -ceq $k -and -not $sorted.Contains($c)) { $sorted.Add($c); break } }
    }
    return [pscustomobject]@{ ExitCode = 0; Json = (ConvertTo-JiraJsonValue $sorted.ToArray()) }
}

function Get-JiraAdoptionCandidateIdentity {
    <#
    .SYNOPSIS
      One identity read per candidate, surfacing the stored marker onto the
      candidate. A 404 means "unclaimed" and is NOT a failure; any other
      transport failure propagates its mapped code and aborts before any write.
      Mirror of adopt_read_candidate_identity; returns { ExitCode; Json }.
    #>
    [CmdletBinding()]
    param([string] $CandidatesJson = '[]')

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($c in @($CandidatesJson | ConvertFrom-Json -Depth 100)) {
        $key = [string](Get-AdoptSinkProp $c 'key')
        $r = Get-JiraIdentity -IssueKey $key
        if ([int]$r.ExitCode -ne 0) { return [pscustomobject]@{ ExitCode = [int]$r.ExitCode; Json = '' } }
        $identity = $null
        if (-not [string]::IsNullOrEmpty([string]$r.Value)) {
            $identity = [string]$r.Value | ConvertFrom-Json -Depth 100
        }
        $labels = @()
        $raw = Get-AdoptSinkProp $c 'labels'
        if ($null -ne $raw) { $labels = [string[]]@($raw | ForEach-Object { [string]$_ }) }
        $parent = Get-AdoptSinkProp $c 'parent_key'
        $out.Add([ordered]@{
                key         = $key
                project_key = [string](Get-AdoptSinkProp $c 'project_key')
                labels      = $labels
                parent_key  = $(if ($null -eq $parent) { $null } else { [string]$parent })
                identity    = $identity
            })
    }
    return [pscustomobject]@{ ExitCode = 0; Json = (ConvertTo-JiraJsonValue $out.ToArray()) }
}

function Get-JiraAdoptionStampAction {
    <#
    .SYNOPSIS
      The ONLY write adoption ever emits, one per binding whose status is
      `adopt`: a PUT of the identity entity property carrying origin `human`. An
      already-adopted binding produces NO action at all — it is skipped, not
      re-stamped (FR-027). Mirror of adopt_stamp_actions.
    #>
    [CmdletBinding()]
    param([string] $BindingsJson = '[]', [AllowEmptyString()] [string] $Repo = '')

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($b in @($BindingsJson | ConvertFrom-Json -Depth 100)) {
        if ([string](Get-AdoptSinkProp $b 'status') -cne 'adopt') { continue }
        $key = [string](Get-AdoptSinkProp $b 'issue_key')
        $folder = [string](Get-AdoptSinkProp $b 'spec_folder')
        $specRef = ConvertTo-JiraJsonValue ([ordered]@{ repo = $Repo; spec_slug = $folder })
        $marker = Get-JiraIdentityMarker -SpecRefJson $specRef -Origin 'human'
        $out.Add([ordered]@{
                method = 'PUT'
                url    = (Get-JiraIdentityUrl $key)
                body   = ($marker | ConvertFrom-Json -Depth 100)
            })
    }
    return (ConvertTo-JiraJsonValue $out.ToArray())
}

Export-ModuleMember -Function Get-JiraAdoptionCandidate, Get-JiraAdoptionCandidateIdentity, `
    Get-JiraAdoptionStampAction, Test-JiraAdoptionIssueKey, Get-JiraAdoptionPinnedContext
