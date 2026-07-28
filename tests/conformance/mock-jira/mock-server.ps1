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
# Optional per-issue corpus (003): the candidate universe a JQL label search and
# a per-issue context read are served from. Keyed by issue key; each entry may
# carry `labels` (array), `parent` (issue key) and `project` (defaults to the
# key's own prefix). Only these three fields exist — adoption reads nothing else.
$Issues     = if ($cfg.ContainsKey('issues'))   { $cfg.issues }   else { @{} }
# Optional page-size cap for GET /project/search and GET /search/jql: lets a
# scenario with a handful of results exercise real pagination (the transports ask
# for maxResults=50 and 100 respectively).
$SearchPageSize = if ($cfg.ContainsKey('pageSize')) { [int]$cfg.pageSize } else { 0 }
# Optional issue key returned by POST /rest/api/3/issue (feature-creation tests
# derive the branch <ID> from the created key's number).
$CreatedKey = if ($cfg.ContainsKey('createdKey')) { [string]$cfg.createdKey } else { '' }

# --- Helpers ----------------------------------------------------------------

function Get-Style {
    param([string]$Path)
    foreach ($key in $Projects.Keys) {
        if ($Path -match "/$([regex]::Escape($key))(/|$)") { return $Projects[$key] }
    }
    return 'company'
}

function Get-MetaStyle {
    # The metadata fixtures (createmeta / statuses) exist only for the two real
    # styles; an ambiguous/contradictory project reuses the company set — those
    # tests exercise the style signal, never the metadata content.
    param([string]$Style)
    if ($Style -in @('company', 'team')) { return $Style }
    return 'company'
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

function Get-QueryParam {
    # One decoded query-string value, or '' when the parameter is absent. The
    # transports percent-encode with the @uri rule and normalise %20 to '+', so
    # '+' is decoded back to a space before unescaping.
    param([string]$Query, [string]$Name)
    foreach ($pair in ($Query -split '&')) {
        $eq = $pair.IndexOf('=')
        if ($eq -lt 0) { continue }
        if ($pair.Substring(0, $eq) -ceq $Name) {
            return [System.Uri]::UnescapeDataString($pair.Substring($eq + 1).Replace('+', ' '))
        }
    }
    return ''
}

function Get-IssueProjectKey {
    # An issue's project: the configured `project`, else the key's own prefix.
    param([string]$Key, $Entry)
    if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains('project')) {
        return [string]$Entry['project']
    }
    return ($Key -split '-')[0]
}

function New-IssueBody {
    # The candidate shape adoption consumes: key plus labels / parent / project
    # ONLY (contracts/jira-endpoints-delta.md). `parent` is omitted entirely when
    # the issue has none, which is what makes "no parent" distinguishable.
    param([string]$Key, $Entry)
    $labels = @()
    if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains('labels')) {
        $labels = [string[]]@($Entry['labels'])
    }
    $fields = [ordered]@{ labels = $labels }
    if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains('parent') -and $Entry['parent']) {
        $fields['parent'] = [ordered]@{ key = [string]$Entry['parent'] }
    }
    $fields['project'] = [ordered]@{ key = (Get-IssueProjectKey -Key $Key -Entry $Entry) }
    return [ordered]@{ key = $Key; fields = $fields }
}

function Get-JqlSearchPage {
    # JQL-aware GET /rest/api/3/search/jql over the configured issues corpus
    # (003 research §1/§2). The JQL is assembled by the sink from derived label
    # values only, so exactly two terms are honoured:
    #   project = "<KEY>"   and   labels IN ("<a>", "<b>", ...)
    # Matching is case-sensitive (Jira labels are). Results are ordered by key
    # ascending and paginated by a `nextPageToken` cursor which is OMITTED on the
    # last page — the only stop condition the sink's loop may rely on.
    param([string]$Query)

    $jql = Get-QueryParam -Query $Query -Name 'jql'
    $maxResults = 50
    $mr = Get-QueryParam -Query $Query -Name 'maxResults'
    if ($mr -match '^\d+$') { $maxResults = [int]$mr }
    if ($SearchPageSize -gt 0 -and $SearchPageSize -lt $maxResults) { $maxResults = $SearchPageSize }
    $startAt = 0
    $token = Get-QueryParam -Query $Query -Name 'nextPageToken'
    if ($token -match '^\d+$') { $startAt = [int]$token }

    $project = ''
    if ($jql -match 'project\s*=\s*"([^"]*)"') { $project = $Matches[1] }
    $wanted = [System.Collections.Generic.List[string]]::new()
    if ($jql -match 'labels\s+IN\s+\(([^)]*)\)') {
        foreach ($m in [regex]::Matches($Matches[1], '"([^"]*)"')) { $wanted.Add($m.Groups[1].Value) }
    }

    $keys = [string[]]@($Issues.Keys)
    [System.Array]::Sort($keys, [System.StringComparer]::Ordinal)
    $matched = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $keys) {
        $entry = $Issues[$k]
        if ($project -and (Get-IssueProjectKey -Key $k -Entry $entry) -cne $project) { continue }
        if ($wanted.Count -gt 0) {
            $labels = @()
            if ($entry -is [System.Collections.IDictionary] -and $entry.Contains('labels')) {
                $labels = [string[]]@($entry['labels'])
            }
            $hit = $false
            foreach ($l in $labels) { if ($wanted -ccontains $l) { $hit = $true; break } }
            if (-not $hit) { continue }
        }
        $matched.Add($k)
    }

    $end = [Math]::Min($startAt + $maxResults, $matched.Count)
    $values = [System.Collections.Generic.List[object]]::new()
    for ($i = $startAt; $i -lt $end; $i++) {
        $k = $matched[$i]
        $values.Add((New-IssueBody -Key $k -Entry $Issues[$k]))
    }
    $page = [ordered]@{ issues = $values.ToArray() }
    if ($end -lt $matched.Count) {
        $page['nextPageToken'] = "$end"
        $page['isLast'] = $false
    } else {
        $page['isLast'] = $true
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

# Entity properties written during THIS run, keyed by request path. A PUT stores
# the body; the next GET of the same path serves it back. Without this a scenario
# could never observe its own stamp, and "run adopt twice, the second writes
# nothing" would be unprovable against the double (003 US3, FR-019).
$WrittenProperties = @{}

function Get-IdentityMarker {
    # Return the stored identity property body ({key,value}) for an issue: first
    # anything this run wrote, then any pre-configured marker, else $null
    # (unclaimed).
    param([string]$Path)
    if ($WrittenProperties.ContainsKey($Path)) {
        $propKey = ($Path -split '/')[-1]
        $wrapped = @{ key = $propKey; value = ($WrittenProperties[$Path] | ConvertFrom-Json -AsHashtable) }
        return ($wrapped | ConvertTo-Json -Depth 20 -Compress)
    }
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
    $metaStyle = Get-MetaStyle -Style $style
    switch -regex ($Path) {
        '^/__mock/health$'                                           { return @{ status = 200; body = '{"ok":true}' } }
        '^/rest/api/3/project/search$'                                { if ($Method -eq 'GET') { return (Get-ProjectSearchPage -Query $Query) } }
        '^/rest/api/3/project/[^/]+/statuses$'                        { return (Read-FixtureBody "statuses-$metaStyle") }
        '^/rest/api/3/project/[^/]+$'                                 { return (Read-FixtureBody "project-$style") }
        '^/rest/api/3/issue/createmeta/[^/]+/issuetypes/[^/]+$'       { return (Read-FixtureBody "createmeta-fields-$metaStyle") }
        '^/rest/api/3/issue/createmeta/[^/]+/issuetypes$'            { return (Read-FixtureBody "createmeta-issuetypes-$metaStyle") }
        '^/rest/api/3/priority$'                                      { return (Read-FixtureBody 'priority') }
        '^/rest/api/3/field$'                                         { return (Read-FixtureBody 'field') }
        '^/rest/api/3/issue$'                                         {
            if ($Method -eq 'POST') {
                if ($CreatedKey) {
                    return @{ status = 201; body = "{`"id`":`"99001`",`"key`":`"$CreatedKey`",`"self`":`"/rest/api/3/issue/99001`"}" }
                }
                $b = Read-FixtureBody 'issue-created'; $b.status = 201; return $b
            }
        }
        '^/rest/api/3/issue/[^/]+/transitions$'                       { if ($Method -eq 'POST') { return @{ status = 204; body = '' } } }
        '^/rest/api/3/issue/[^/]+/remotelink$'                        { if ($Method -eq 'GET') { return (Read-FixtureBody 'remotelinks') } }
        '^/rest/api/3/(search|search/jql)$' {
            if ($Method -eq 'GET') {
                # A scenario carrying an issues corpus gets the real JQL-aware,
                # cursor-paginated handler (003); without one the fixed sibling
                # fixture still serves `fetch_mentioned`.
                if ($Issues.Count -gt 0) { return (Get-JqlSearchPage -Query $Query) }
                return (Read-FixtureBody 'search-siblings')
            }
        }
        '^/rest/api/3/issue/[^/]+/properties/[^/]+$' {
            if ($Method -eq 'PUT') {
                # Remember the stamp so a later GET of the same property returns
                # it — that is what lets a scenario run adopt twice and observe
                # the second run recognising its own first stamp.
                if ($Body) { $WrittenProperties[$Path] = $Body }
                return @{ status = 204; body = '' }
            }
            if ($Method -eq 'GET') {
                $marker = Get-IdentityMarker -Path $Path
                if ($marker) { return @{ status = 200; body = $marker } }
                $b = Read-FixtureBody 'issue-property'
                if ($b.status -eq 500) { return @{ status = 404; body = '{"errorMessages":["not found"],"errors":{}}' } }
                return $b
            }
        }
        '^/rest/api/3/issue/[^/]+$' {
            # A content update on an existing issue: Jira answers 204 No Content.
            # Needed by any scenario that reconciles a ticket that already exists
            # (003 US3 drives adopt -> reconcile -> reconcile end to end).
            if ($Method -eq 'PUT') { return @{ status = 204; body = '' } }
            if ($Method -eq 'GET') {
                # Pinned-candidate context read (003 US4): a scenario carrying an
                # issues corpus serves labels/parent/project from it, and a key
                # absent from the corpus is a 404 (fail-closed, FR-008).
                if ($Issues.Count -gt 0 -and $Query -match '(^|&)fields=') {
                    $ikey = ($Path -split '/')[-1]
                    if ($Issues.ContainsKey($ikey)) {
                        # NOT `$body`: PowerShell variable names are
                        # case-insensitive, so that would assign into the
                        # [string] $Body PARAMETER and stringify the object.
                        $issueBody = New-IssueBody -Key $ikey -Entry $Issues[$ikey]
                        return @{ status = 200; body = (ConvertTo-Json -InputObject $issueBody -Depth 10 -Compress) }
                    }
                    return @{ status = 404; body = '{"errorMessages":["not found"],"errors":{}}' }
                }
                # Mentioned-ticket validation (fields=project): the issue's project
                # is its key prefix; an unconfigured project is a 404 (fail-closed).
                if ($Query -match '(^|&)fields=project(&|$)') {
                    $ikey = ($Path -split '/')[-1]
                    $pkey = ($ikey -split '-')[0]
                    if ($Projects.ContainsKey($pkey)) {
                        return @{ status = 200; body = "{`"key`":`"$ikey`",`"fields`":{`"project`":{`"key`":`"$pkey`"}}}" }
                    }
                    return @{ status = 404; body = '{"errorMessages":["not found"],"errors":{}}' }
                }
                return (Read-FixtureBody 'issue-mentioned')
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
            if ($fault) {
                if ($fault.ContainsKey('network') -and $fault.network) {
                    # Simulate a dropped connection: close without responding.
                    continue
                }
                $status = [int]$fault.status
                $extra = @{}
                if ($fault.ContainsKey('retryAfter')) { $extra['Retry-After'] = "$($fault.retryAfter)" }
                Write-Response -Stream $stream -Status $status -Body "{`"errorMessages`":[`"injected fault $status`"]}" -Extra $extra
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
