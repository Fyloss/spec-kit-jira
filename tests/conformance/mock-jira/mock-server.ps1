#!/usr/bin/env pwsh
# T008 — Mocked Jira Cloud REST v3 double.
#
# A single-threaded loopback HTTP server both ports' transports target via base
# URL. Implemented over a raw System.Net.Sockets.TcpListener (NOT HttpListener)
# so it needs no admin rights or urlacl reservation on Windows and no Python.
#
# Serves canned company-managed + team-managed discovery responses (non-default
# metadata, Constitution VII) and injects 401 / 404 / 429-exhausted / network
# faults keyed by project. Every request (method + target, query included) is
# appended LF-terminated to the call log so callers can assert the exact Jira
# API call sequence for byte-identical cross-port comparison (NFR-1).
#
# Startup: picks a free ephemeral port (Port 0), writes the chosen port to
# ReadyFile once listening, then serves until the process is killed.

[CmdletBinding()]
param(
    [int]$Port = 0,
    [string]$ConfigPath,
    [string]$FixtureDir = (Join-Path $PSScriptRoot 'fixtures'),
    [Parameter(Mandatory)][string]$CallLogPath,
    [Parameter(Mandatory)][string]$ReadyFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

if (-not (Test-Path -LiteralPath $FixtureDir)) {
    throw "fixture directory not found: $FixtureDir"
}

$ReasonPhrase = @{
    200 = 'OK'; 201 = 'Created'; 204 = 'No Content'; 401 = 'Unauthorized'; 404 = 'Not Found'
    429 = 'Too Many Requests'; 500 = 'Internal Server Error'
}

# --- Config -----------------------------------------------------------------

$cfg = if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)) {
    Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json -AsHashtable
} else { @{} }
$Projects   = if ($cfg.ContainsKey('projects')) { $cfg.projects } else { @{} }
$Faults     = if ($cfg.ContainsKey('faults'))   { $cfg.faults }   else { @{} }
$GlobalFault = if ($cfg.ContainsKey('fault'))   { $cfg.fault }    else { $null }
# Optional per-issue-key identity markers (US10): when a GET of an issue's identity
# property matches a configured key, the mock returns that stored marker instead of
# a 404 — this is how the "claimed by another spec" case (FR-051) is exercised.
$Identity   = if ($cfg.ContainsKey('identity')) { $cfg.identity } else { @{} }
# Optional page-size cap for GET /project/search: lets a scenario with a handful
# of projects exercise real pagination (the transport asks for maxResults=50).
$SearchPageSize = if ($cfg.ContainsKey('pageSize')) { [int]$cfg.pageSize } else { 0 }
# Optional issue key returned by POST /rest/api/3/issue (feature-creation tests
# derive the branch <ID> from the created key's number).
$CreatedKey = if ($cfg.ContainsKey('createdKey')) { [string]$cfg.createdKey } else { '' }
# Optional per-project issue-type-hierarchy override (T001/T004): a non-default
# Jira (French, SAFe, non-Latin, flat, ambiguous) still answers GET
# /project/{key} and .../statuses as an ordinary company- or team-managed
# project — only its issue-type NAMES differ. This map lets the createmeta
# issuetypes/fields routes select the dedicated hierarchy fixture without
# inventing a parallel project/statuses fixture per hierarchy.
$IssueTypeStyle = if ($cfg.ContainsKey('issueTypeStyle')) { $cfg.issueTypeStyle } else { @{} }

# Optional per-project status-name style (012, T006a): a non-English Jira
# reports its own status names rather than the Atlassian defaults "To Do" /
# statusCategory "new". Keyed off the same $IssueTypeStyle map issue-type
# names already use, since a French project's statuses are French for the
# same reason its issue types are.
function Get-DefaultStatus {
    param([string]$ProjectKey)
    $metaStyle = if ($IssueTypeStyle.ContainsKey($ProjectKey)) { $IssueTypeStyle[$ProjectKey] } else { $null }
    if ($metaStyle -eq 'french') { return @{ name = 'À faire'; statusCategory = @{ key = 'new' } } }
    return @{ name = 'To Do'; statusCategory = @{ key = 'new' } }
}

# Optional label -> [keys] map (017, duplicate_probe): a jql search keyed on
# `labels = "<label>"` (the duplicate probe's own query shape, distinct from
# discovery's `parent=<key>` sibling search, which keeps reading the static
# search-siblings fixture unchanged). Unconfigured or unmatched -> zero
# issues (the "clear" verdict) -- today's behaviour for every test that
# never sets it.
$LabelSearch = if ($cfg.ContainsKey('labelSearch')) { $cfg.labelSearch } else { @{} }

# --- Stateful issue store (Phase 1, T001-T004) -------------------------------
#
# The double was write-only and stateless, so it could not express "the ticket
# exists now" — the reason duplicate creation was invisible to the test suite.
# Every created issue's fields and entity properties now live here for the
# lifetime of this ONE mock process, so a scenario's two runs share the same
# ticket and a fresh scenario starts clean. Keyed by issue key.
$script:Issues = [System.Collections.Generic.Dictionary[string, object]]::new()
$script:IssueCounters = @{}

# Optional pre-seeded issues (a scenario's fixture: a ticket that already
# exists before its first reconcile call, e.g. repo-with-mirrored-spec).
if ($cfg.ContainsKey('issues')) {
    foreach ($k in $cfg.issues.Keys) {
        $seed = $cfg.issues[$k]
        $fields = @{
            summary     = if ($seed.ContainsKey('summary')) { $seed.summary } else { '' }
            description = if ($seed.ContainsKey('description')) { $seed.description } else { $null }
            priority    = if ($seed.ContainsKey('priority')) { $seed.priority } else { $null }
            status      = if ($seed.ContainsKey('status')) { $seed.status } else { Get-DefaultStatus -ProjectKey ($k -replace '-[0-9]+$', '') }
            issuelinks  = if ($seed.ContainsKey('issuelinks')) { $seed.issuelinks } else { @() }
            parent      = if ($seed.ContainsKey('parent')) { $seed.parent } else { $null }
            issuetype   = if ($seed.ContainsKey('issuetype')) { $seed.issuetype } else { $null }
        }
        if ($seed.ContainsKey('flagged') -and $seed.flagged) {
            $fields['Flagged'] = @(@{ value = 'Impediment' })
        }
        $props = @{}
        if ($seed.ContainsKey('properties')) { $props = $seed.properties }
        $script:Issues[$k] = @{ fields = $fields; properties = $props }
    }
}

function Get-MockRequestProjectKey {
    # The project key a POST /rest/api/3/issue body creates in, or 'COMP' when
    # the body carries none (keeps the transport smoke test's single-call
    # expectation — tests/bash/sink/test_client.bats — while still being
    # genuinely sequential across multiple calls in one mock session).
    param([string]$Body)
    if ($Body -match '"project"\s*:\s*\{\s*"key"\s*:\s*"([^"]+)"') { return $Matches[1] }
    return 'COMP'
}

function New-MockIssueKey {
    # A distinct, sequential key per project (T001): the defect this feature
    # fixes was invisible precisely because every creation returned the SAME
    # fixed key, so a second creation could not be told apart from the first.
    param([string]$ProjectKey)
    if (-not $script:IssueCounters.ContainsKey($ProjectKey)) { $script:IssueCounters[$ProjectKey] = 0 }
    $script:IssueCounters[$ProjectKey]++
    return "$ProjectKey-$($script:IssueCounters[$ProjectKey])"
}
# Optional per-project createmeta-fields fixture override (US4 research R4
# branch 2): lets a scenario exercise a company-managed project whose create
# metadata declares `allowedValues` on its priority field, without touching
# Get-Style/Get-MetaStyle or either of the two existing style-keyed fixtures.
$CreateMetaFields = if ($cfg.ContainsKey('createmetaFields')) { $cfg.createmetaFields } else { @{} }
# Optional per-issue-key available-transitions override (012, T001): keyed by
# exact issue key, the array of transition objects GET .../transitions
# returns verbatim. Unconfigured means an empty list (the "none" case
# contract §6 distinguishes) — nothing is assumed for a key not listed.
$Transitions = if ($cfg.ContainsKey('transitions')) { $cfg.transitions } else { @{} }

function Get-IssueTypeStyleName {
    param([string]$Path, [string]$DefaultStyle)
    foreach ($key in $IssueTypeStyle.Keys) {
        if ($Path -match "/$([regex]::Escape($key))(/|$)") { return $IssueTypeStyle[$key] }
    }
    return $DefaultStyle
}

# --- Helpers ----------------------------------------------------------------

function Get-Style {
    param([string]$Path)
    foreach ($key in $Projects.Keys) {
        if ($Path -match "/$([regex]::Escape($key))(/|$)") { return $Projects[$key] }
    }
    return 'company'
}

function Get-MetaStyle {
    # The metadata fixtures (createmeta / statuses) exist for the two default
    # styles plus the non-default hierarchies this feature adds (T001/T004);
    # an ambiguous/contradictory project reuses the company set — those tests
    # exercise the style signal, never the metadata content.
    param([string]$Style)
    # 'hier-ambiguous', not 'ambiguous': the latter is already the project-
    # style-CONTRADICTION fixture's style token (project-ambiguous.json,
    # test_config_style.bats) — a completely different concept from this
    # feature's parent-level-ambiguous hierarchy fixture. Reusing it would
    # silently reroute every style-ambiguity test onto a hierarchy fixture
    # that has nothing to do with what they exercise.
    if ($Style -in @('company', 'team', 'french', 'safe', 'nonlatin', 'flat', 'hier-ambiguous', 'consumer', 'linebreak', 'taskm')) { return $Style }
    return 'company'
}

function Get-CreateMetaFieldsName {
    # The fixture basename for the createmeta/{key}/issuetypes/{typeId} route
    # (T001): a configured per-project override wins; else a per-issue-type
    # fixture named createmeta-fields-<style>-<typeId> when one exists, so two
    # different types can return two different field sets; else the existing
    # style-keyed default (createmeta-fields-company / createmeta-fields-team).
    param([string]$Path, [string]$MetaStyle)
    foreach ($key in $CreateMetaFields.Keys) {
        if ($Path -match "/$([regex]::Escape($key))(/|$)") { return "createmeta-fields-$($CreateMetaFields[$key])" }
    }
    if ($Path -match '/issuetypes/([^/]+)$') {
        $typeId = $Matches[1]
        $perType = "createmeta-fields-$MetaStyle-$typeId"
        if (Test-Path -LiteralPath (Join-Path $FixtureDir "$perType.json")) { return $perType }
    }
    return "createmeta-fields-$MetaStyle"
}

function Get-ProjectSearchPage {
    # Paginated GET /rest/api/3/project/search over the configured projects,
    # honouring startAt/maxResults (optionally capped by pageSize) with
    # isLast/total. Values carry key/name plus the style signals mapped from the
    # configured style: company -> classic/false, team -> next-gen/true,
    # contradictory -> classic/true, ambiguous -> neither field.
    param([string]$Query)
    $startAt = 0; $maxResults = 50
    foreach ($pair in ($Query -split '&')) {
        if ($pair -match '^startAt=(\d+)$') { $startAt = [int]$Matches[1] }
        elseif ($pair -match '^maxResults=(\d+)$') { $maxResults = [int]$Matches[1] }
    }
    if ($SearchPageSize -gt 0 -and $SearchPageSize -lt $maxResults) { $maxResults = $SearchPageSize }

    $keys = [string[]]@($Projects.Keys)
    [System.Array]::Sort($keys, [System.StringComparer]::Ordinal)
    $total = $keys.Count
    $values = [System.Collections.Generic.List[object]]::new()
    $end = [Math]::Min($startAt + $maxResults, $total)
    for ($i = $startAt; $i -lt $end; $i++) {
        $k = $keys[$i]
        $entry = [ordered]@{ key = $k; name = "$k project" }
        switch ([string]$Projects[$k]) {
            'company'       { $entry['style'] = 'classic';  $entry['simplified'] = $false }
            'team'          { $entry['style'] = 'next-gen'; $entry['simplified'] = $true }
            'contradictory' { $entry['style'] = 'classic';  $entry['simplified'] = $true }
            default { }
        }
        $values.Add($entry)
    }
    $page = [ordered]@{
        startAt    = $startAt
        maxResults = $maxResults
        total      = $total
        isLast     = (($startAt + $maxResults) -ge $total)
        values     = $values.ToArray()
    }
    return @{ status = 200; body = ($page | ConvertTo-Json -Depth 10 -Compress) }
}

function Get-Fault {
    param([string]$Path)
    foreach ($key in $Faults.Keys) {
        if ($Path -match "/$([regex]::Escape($key))(/|-|$)") { return $Faults[$key] }
    }
    return $GlobalFault
}

function Get-IssueBulkfetch {
    # 021 US4, contracts/recognition-prefetch.md T046: composes its response
    # from the SAME per-key store `/rest/api/3/issue/{key}` already serves,
    # honouring `fields`/`properties`, and returning issues in the store's own
    # (insertion) order — never request order (P4: matched by key, never
    # position). A key is omitted when it is absent from the store (deleted)
    # or faulted on its own per-key path (not visible) — deleted and
    # forbidden are equally "not returned", reusing the SAME fault config a
    # direct per-key GET already uses, never a second source of truth.
    param([string]$Body)
    $reqIds = @()
    $fieldsCsv = ''
    $propsCsv = ''
    try {
        $bodyObj = $Body | ConvertFrom-Json -AsHashtable
        if ($bodyObj) {
            if ($bodyObj.ContainsKey('issueIdsOrKeys')) { $reqIds = @($bodyObj.issueIdsOrKeys) }
            if ($bodyObj.ContainsKey('fields')) { $fieldsCsv = ($bodyObj.fields -join ',') }
            if ($bodyObj.ContainsKey('properties')) { $propsCsv = ($bodyObj.properties -join ',') }
        }
    }
    catch { }
    $wantSubtasks = ",$fieldsCsv," -like '*,subtasks,*'
    $wantFields = @()
    if ($fieldsCsv) { $wantFields = $fieldsCsv -split ',' }
    $propNames = @()
    if ($propsCsv) { $propNames = $propsCsv -split ',' }

    $issues = New-Object System.Collections.Generic.List[object]
    foreach ($reqKey in $reqIds) {
        $matchKey = $null
        foreach ($k in $script:Issues.Keys) {
            if ($k.ToLowerInvariant() -eq $reqKey.ToLowerInvariant()) { $matchKey = $k; break }
        }
        if (-not $matchKey) { continue }
        $fault = Get-Fault -Path "/rest/api/3/issue/$matchKey"
        if ($fault) { continue }

        $issue = $script:Issues[$matchKey]
        $flds = $issue.fields.Clone()
        if ($wantSubtasks) {
            $subtasks = @()
            foreach ($ck in $script:Issues.Keys) {
                $cf = $script:Issues[$ck].fields
                if ($cf.ContainsKey('parent') -and $cf.parent -and $cf.parent.key -eq $matchKey) {
                    $it = if ($cf.ContainsKey('issuetype') -and $cf.issuetype) { $cf.issuetype } else { @{ id = $null } }
                    $subtasks += @{ key = $ck; fields = @{ issuetype = $it } }
                }
            }
            $flds['subtasks'] = $subtasks
        }
        if ($wantFields.Count -gt 0) {
            $projected = @{}
            foreach ($fk in $wantFields) { if ($flds.ContainsKey($fk)) { $projected[$fk] = $flds[$fk] } }
            $flds = $projected
        }
        $entry = @{ key = $matchKey; fields = $flds }
        if ($propNames.Count -gt 0) {
            $propsOut = @{}
            foreach ($pn in $propNames) { if ($issue.properties.ContainsKey($pn)) { $propsOut[$pn] = $issue.properties[$pn] } }
            $entry['properties'] = $propsOut
        }
        $issues.Add($entry)
    }
    $resp = @{ issues = $issues.ToArray(); issueErrors = @() }
    return @{ status = 200; body = ($resp | ConvertTo-Json -Depth 20 -Compress) }
}

function Get-LabelSearchResult {
    # 017, contracts/duplicate-probe.md §3/§4: decode the jql query's
    # `labels = "<label>"` clause and look it up in $LabelSearch. Mirror of
    # the bash shim's _shim_label_search.
    param([string]$Query)
    # `+` is form-encoding for space (jq's @uri normalisation this port's
    # ConvertTo-JiraUriComponent mirrors) — UnescapeDataString alone leaves a
    # literal `+` in place, so replace it first.
    $decoded = [System.Uri]::UnescapeDataString(($Query -replace '\+', ' '))
    $keys = @()
    if ($decoded -match 'labels = "([^"]*)"') {
        $label = $Matches[1]
        if ($LabelSearch.ContainsKey($label)) { $keys = @($LabelSearch[$label]) }
    }
    $issues = @($keys | ForEach-Object { @{ key = $_ } })
    return @{ status = 200; body = (@{ issues = $issues } | ConvertTo-Json -Depth 10 -Compress) }
}

function Get-IdentityMarker {
    # Return the stored identity property body ({key,value}) for an issue whose key
    # matches a configured identity entry, or $null when no entry matches (unclaimed).
    param([string]$Path)
    foreach ($key in $Identity.Keys) {
        if ($Path -match "/rest/api/3/issue/$([regex]::Escape($key))/properties/") {
            $marker = $Identity[$key]
            $value = @{}
            foreach ($k in $marker.Keys) { $value[$k] = $marker[$k] }
            $wrapped = @{ key = 'spec-kit-jira'; value = $value }
            return ($wrapped | ConvertTo-Json -Depth 20 -Compress)
        }
    }
    return $null
}

function Read-FixtureBody {
    param([string]$Name)
    $file = Join-Path $FixtureDir "$Name.json"
    if (-not (Test-Path -LiteralPath $file)) {
        return @{ status = 500; body = "{`"error`":`"missing fixture $Name`"}" }
    }
    return @{ status = 200; body = (Get-Content -Raw -LiteralPath $file) }
}

function Resolve-Route {
    param([string]$Method, [string]$Path, [string]$Query = '', [string]$Body = '')
    $style = Get-Style -Path $Path
    $metaStyle = Get-MetaStyle -Style (Get-IssueTypeStyleName -Path $Path -DefaultStyle $style)
    # 012, T006a: the same per-project override issue-type names use also
    # picks the project statuses fixture, when a dedicated one exists — so a
    # non-default Jira (French) is French in both places — falling back to
    # the base style otherwise, so every pre-existing override without its
    # own statuses fixture keeps behaving exactly as before.
    $statusStyle = if (Test-Path -LiteralPath (Join-Path $FixtureDir "statuses-$metaStyle.json")) { $metaStyle } else { Get-MetaStyle -Style $style }
    switch -regex ($Path) {
        '^/__mock/health$'                                           { return @{ status = 200; body = '{"ok":true}' } }
        '^/rest/api/3/project/search$'                                { if ($Method -eq 'GET') { return (Get-ProjectSearchPage -Query $Query) } }
        '^/rest/api/3/project/[^/]+/statuses$'                        { return (Read-FixtureBody "statuses-$statusStyle") }
        '^/rest/api/3/project/[^/]+$'                                 { return (Read-FixtureBody "project-$style") }
        '^/rest/api/3/issue/createmeta/[^/]+/issuetypes/[^/]+$'       { return (Read-FixtureBody (Get-CreateMetaFieldsName -Path $Path -MetaStyle $metaStyle)) }
        '^/rest/api/3/issue/createmeta/[^/]+/issuetypes$'            { return (Read-FixtureBody "createmeta-issuetypes-$metaStyle") }
        '^/rest/api/3/priority$'                                      { return (Read-FixtureBody 'priority') }
        '^/rest/api/3/field$'                                         { return (Read-FixtureBody 'field') }
        '^/rest/api/3/issue$'                                         {
            if ($Method -eq 'POST') {
                $projKey = Get-MockRequestProjectKey -Body $Body
                if ($CreatedKey) {
                    $key = $CreatedKey
                }
                else {
                    $key = New-MockIssueKey -ProjectKey $projKey
                }
                $suppliedFields = @{}
                try {
                    $bodyObj = $Body | ConvertFrom-Json -AsHashtable
                    if ($bodyObj -and $bodyObj.ContainsKey('fields')) { $suppliedFields = $bodyObj.fields }
                }
                catch { }
                $fields = @{
                    summary     = if ($suppliedFields.ContainsKey('summary')) { $suppliedFields.summary } else { '' }
                    description = if ($suppliedFields.ContainsKey('description')) { $suppliedFields.description } else { $null }
                    priority    = if ($suppliedFields.ContainsKey('priority')) { $suppliedFields.priority } else { $null }
                    status      = Get-DefaultStatus -ProjectKey $projKey
                    issuelinks  = @()
                    parent      = if ($suppliedFields.ContainsKey('parent')) { $suppliedFields.parent } else { $null }
                    issuetype   = if ($suppliedFields.ContainsKey('issuetype')) { $suppliedFields.issuetype } else { $null }
                    labels      = if ($suppliedFields.ContainsKey('labels')) { @($suppliedFields.labels) } else { @() }
                }
                $script:Issues[$key] = @{ fields = $fields; properties = @{} }
                return @{ status = 201; body = "{`"id`":`"99001`",`"key`":`"$key`",`"self`":`"/rest/api/3/issue/99001`"}" }
            }
        }
        '^/rest/api/3/issue/bulkfetch$' {
            if ($Method -eq 'POST') { return (Get-IssueBulkfetch -Body $Body) }
        }
        '^/rest/api/3/issue/[^/]+/transitions$' {
            if ($Method -eq 'POST') { return @{ status = 204; body = '' } }
            if ($Method -eq 'GET') {
                $ikey = ($Path -split '/')[-2]
                # `$list = if (...) {...} else {@()}` unrolls a one-element
                # array to a bare object on assignment (PowerShell flattens a
                # script block's implicit output) — direct assignment inside
                # each branch avoids that.
                if ($Transitions.ContainsKey($ikey)) { $list = @($Transitions[$ikey]) } else { $list = @() }
                $resp = @{ expand = 'transitions'; transitions = $list }
                return @{ status = 200; body = ($resp | ConvertTo-Json -Depth 20 -Compress) }
            }
        }
        '^/rest/api/3/issue/[^/]+/remotelink$'                        { if ($Method -eq 'GET') { return (Read-FixtureBody 'remotelinks') } }
        '^/rest/api/3/(search|search/jql)$'                           {
            if ($Method -eq 'GET' -and $Query -match 'labels') { return (Get-LabelSearchResult -Query $Query) }
            if ($Method -eq 'GET') { return (Read-FixtureBody 'search-siblings') }
        }
        '^/rest/api/3/issue/[^/]+/properties/[^/]+$' {
            $ikey = ($Path -split '/')[-3]
            $propKey = ($Path -split '/')[-1]
            if ($Method -eq 'PUT') {
                if ($script:Issues.ContainsKey($ikey)) {
                    $val = $null
                    try { $val = $Body | ConvertFrom-Json -AsHashtable } catch { $val = $Body }
                    $script:Issues[$ikey].properties[$propKey] = $val
                }
                return @{ status = 204; body = '' }
            }
            if ($Method -eq 'GET') {
                if ($script:Issues.ContainsKey($ikey) -and $script:Issues[$ikey].properties.ContainsKey($propKey)) {
                    $wrapped = @{ key = $propKey; value = $script:Issues[$ikey].properties[$propKey] }
                    return @{ status = 200; body = ($wrapped | ConvertTo-Json -Depth 20 -Compress) }
                }
                $marker = Get-IdentityMarker -Path $Path
                if ($marker) { return @{ status = 200; body = $marker } }
                $b = Read-FixtureBody 'issue-property'
                if ($b.status -eq 500) { return @{ status = 404; body = '{"errorMessages":["not found"],"errors":{}}' } }
                return $b
            }
        }
        '^/rest/api/3/issue/[^/]+$' {
            $ikey = ($Path -split '/')[-1]
            if ($Method -eq 'GET') {
                # Mentioned-ticket validation (fields=project): the issue's project
                # is its key prefix; an unconfigured project is a 404 (fail-closed).
                if ($Query -match '(^|&)fields=project(&|$)') {
                    $pkey = ($ikey -split '-')[0]
                    if ($Projects.ContainsKey($pkey)) {
                        return @{ status = 200; body = "{`"key`":`"$ikey`",`"fields`":{`"project`":{`"key`":`"$pkey`"}}}" }
                    }
                    return @{ status = 404; body = '{"errorMessages":["not found"],"errors":{}}' }
                }
                if ($script:Issues.ContainsKey($ikey)) {
                    $issue = $script:Issues[$ikey]
                    $flds = $issue.fields
                    if ($Query -match '(^|&)fields=([^&]+)' -and (",$($Matches[2])," -like '*,subtasks,*')) {
                        $subtasks = @()
                        foreach ($ck in $script:Issues.Keys) {
                            $cf = $script:Issues[$ck].fields
                            if ($cf.ContainsKey('parent') -and $cf.parent -and $cf.parent.key -eq $ikey) {
                                $it = if ($cf.ContainsKey('issuetype') -and $cf.issuetype) { $cf.issuetype } else { @{ id = $null } }
                                $subtasks += @{ key = $ck; fields = @{ issuetype = $it } }
                            }
                        }
                        $flds = $flds.Clone()
                        $flds['subtasks'] = $subtasks
                    }
                    $resp = @{ key = $ikey; fields = $flds }
                    if ($Query -match '(^|&)properties=([^&]+)') {
                        $propNames = $Matches[2] -split ','
                        $propsOut = @{}
                        foreach ($pn in $propNames) {
                            if ($issue.properties.ContainsKey($pn)) { $propsOut[$pn] = $issue.properties[$pn] }
                        }
                        $resp['properties'] = $propsOut
                    }
                    return @{ status = 200; body = ($resp | ConvertTo-Json -Depth 20 -Compress) }
                }
                # Unseeded / unknown key: the legacy default fixture, for
                # existing mention/discovery tests that never created a
                # stateful issue.
                return (Read-FixtureBody 'issue-mentioned')
            }
            if ($Method -eq 'PUT') {
                if ($script:Issues.ContainsKey($ikey)) {
                    $suppliedFields = @{}
                    try {
                        $bodyObj = $Body | ConvertFrom-Json -AsHashtable
                        if ($bodyObj -and $bodyObj.ContainsKey('fields')) { $suppliedFields = $bodyObj.fields }
                    }
                    catch { }
                    foreach ($k in $suppliedFields.Keys) { $script:Issues[$ikey].fields[$k] = $suppliedFields[$k] }
                }
                return @{ status = 204; body = '' }
            }
        }
        default { }
    }
    return @{ status = 404; body = '{"errorMessages":["not found"],"errors":{}}' }
}

function Write-Response {
    param([System.IO.Stream]$Stream, [int]$Status, [string]$Body, [hashtable]$Extra = @{})
    $bodyBytes = $Utf8NoBom.GetBytes($Body)
    $reason = if ($ReasonPhrase.ContainsKey($Status)) { $ReasonPhrase[$Status] } else { 'Unknown' }
    $head = "HTTP/1.1 $Status $reason`r`n"
    $head += "Content-Type: application/json`r`n"
    $head += "Content-Length: $($bodyBytes.Length)`r`n"
    foreach ($k in $Extra.Keys) { $head += "$k`: $($Extra[$k])`r`n" }
    $head += "Connection: close`r`n`r`n"
    $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($headBytes, 0, $headBytes.Length)
    $Stream.Write($bodyBytes, 0, $bodyBytes.Length)
    $Stream.Flush()
}

function Read-RequestHead {
    param([System.IO.Stream]$Stream)
    # Read bytes until CRLFCRLF (end of headers); return the full header text so
    # the caller can parse the request line AND Content-Length (for POST bodies).
    $bytes = New-Object System.Collections.Generic.List[byte]
    $one = New-Object byte[] 1
    while ($bytes.Count -lt 65536) {
        $n = $Stream.Read($one, 0, 1)
        if ($n -le 0) { break }
        $bytes.Add($one[0])
        $c = $bytes.Count
        if ($c -ge 4 -and $bytes[$c - 4] -eq 13 -and $bytes[$c - 3] -eq 10 -and $bytes[$c - 2] -eq 13 -and $bytes[$c - 1] -eq 10) { break }
    }
    if ($bytes.Count -eq 0) { return $null }
    return [System.Text.Encoding]::ASCII.GetString($bytes.ToArray())
}

# --- Listen -----------------------------------------------------------------

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
$actualPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
[System.IO.File]::WriteAllText($ReadyFile, "$actualPort", $Utf8NoBom)

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 5000
            $head = Read-RequestHead -Stream $stream
            if (-not $head) { continue }
            $headLines = $head -split "`r`n"
            $line = $headLines[0]
            $parts = $line -split ' '
            $method = $parts[0]
            $target = if ($parts.Count -ge 2) { $parts[1] } else { '/' }
            $path = ($target -split '\?')[0]

            # Read the request body when present (Content-Length) — POST /issue
            # carries the project the ticket is created in, needed for faults.
            $contentLength = 0
            foreach ($h in $headLines) {
                if ($h -match '^(?i)Content-Length:\s*(\d+)\s*$') { $contentLength = [int]$Matches[1] }
            }
            $body = ''
            if ($contentLength -gt 0) {
                $buf = New-Object byte[] $contentLength
                $read = 0
                while ($read -lt $contentLength) {
                    $r = $stream.Read($buf, $read, $contentLength - $read)
                    if ($r -le 0) { break }
                    $read += $r
                }
                $body = $Utf8NoBom.GetString($buf, 0, $read)
            }

            [System.IO.File]::AppendAllText($CallLogPath, "$method $target`n", $Utf8NoBom)

            # Fault selection is path-keyed by project; POST /issue has no project
            # in its path, so a create fault is keyed by the body's project key.
            $faultPath = $path
            if ($method -eq 'POST' -and $path -eq '/rest/api/3/issue' -and $body -match '"project"\s*:\s*\{\s*"key"\s*:\s*"([^"]+)"') {
                $faultPath = "/$($Matches[1])"
            }
            $fault = Get-Fault -Path $faultPath
            # ifFieldPresent (018, T069, FR-011): mirrors curl-shim.sh — a
            # fault only fires while the request body's `.fields` still
            # carries the named key, so a retry with that field stripped
            # succeeds.
            if ($fault -and $fault.ContainsKey('ifFieldPresent')) {
                $ifField = [string]$fault.ifFieldPresent
                $hasField = $false
                try {
                    $parsedBody = $body | ConvertFrom-Json -AsHashtable
                    if ($parsedBody -and $parsedBody.ContainsKey('fields') -and $parsedBody.fields.ContainsKey($ifField)) {
                        $hasField = $true
                    }
                } catch {}
                if (-not $hasField) { $fault = $null }
            }
            if ($fault) {
                if ($fault.ContainsKey('network') -and $fault.network) {
                    # Simulate a dropped connection: close without responding.
                    continue
                }
                $status = [int]$fault.status
                $extra = @{}
                if ($fault.ContainsKey('retryAfter')) { $extra['Retry-After'] = "$($fault.retryAfter)" }
                # errors (011, FR-019): an optional field-validation body,
                # {field_id: reason}, so a fault can exercise the
                # recorded-default-rejected path — mirrors curl-shim.sh.
                $errs = if ($fault.ContainsKey('errors')) { $fault.errors } else { @{} }
                $errsJson = ($errs | ConvertTo-Json -Compress -Depth 100)
                Write-Response -Stream $stream -Status $status -Body "{`"errorMessages`":[`"injected fault $status`"],`"errors`":$errsJson}" -Extra $extra
                continue
            }

            $query = if (($target -split '\?').Count -ge 2) { ($target -split '\?')[1] } else { '' }
            $route = Resolve-Route -Method $method -Path $path -Query $query -Body $body
            Write-Response -Stream $stream -Status ([int]$route.status) -Body ([string]$route.body)
        }
        finally {
            $client.Close()
        }
    }
}
finally {
    $listener.Stop()
}
