# sink/jira/Adoption.psm1 — The resolution read (027, research R4/R5,
# contract seed-cli-contract.md §6). Mirror of sink/jira/adoption.sh.
#
# A SECOND bulk-read module, distinct from Prefetch.psm1 (research R4):
# Prefetch.psm1 is deliberately fail-OPEN, and this module inverts that
# posture. FR-038 requires a run that named issues to REFUSE on an
# unreliable read rather than degrade. Do NOT modify Prefetch.psm1.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../../lib/Output.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Client.psm1')    # No -Force — see project memory: powershell-import-force-clobbers-caller-scope

function Get-JiraAdoptionIdentityKey {
    if ($env:SPEC_KIT_JIRA_IDENTITY_KEY) { return $env:SPEC_KIT_JIRA_IDENTITY_KEY }
    return 'spec-kit-jira'
}

# The R5 field union — six named fields, nothing else.
$script:JiraAdoptionFields = 'summary,description,status,issuetype,project,parent'

# JiraAdoptionMap: lower-cased key -> canonical {"fields":{...},"marker":...} JSON.
$script:JiraAdoptionMap = @{}

function Reset-JiraAdoption {
    $script:JiraAdoptionMap = @{}
}

function Get-JiraAdoptionSafe {
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $m = $Object.PSObject.Properties[$Name]
    if ($null -eq $m) { return $null }
    return $m.Value
}

function Invoke-JiraAdoptionLoad {
    <#
    .SYNOPSIS
      Chunks the keys at 100, issues one POST /issue/bulkfetch per chunk,
      populates the map. FAIL-CLOSED (research R4): a chunk failure empties
      the map and returns the mapped transport exit code.
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)] [string[]] $Keys = @())

    Reset-JiraAdoption
    if ($Keys.Count -eq 0) { return 0 }

    $base = if ($env:SPEC_KIT_JIRA_BASE_URL) { $env:SPEC_KIT_JIRA_BASE_URL } else { '' }
    $url = "$base/rest/api/3/issue/bulkfetch"
    $idKey = Get-JiraAdoptionIdentityKey
    $fieldsArr = @($script:JiraAdoptionFields -split ',')

    $offset = 0
    while ($offset -lt $Keys.Count) {
        $end = [Math]::Min($offset + 99, $Keys.Count - 1)
        $chunk = @($Keys[$offset..$end])
        $offset += 100

        $bodyObj = @{ issueIdsOrKeys = @($chunk); fields = $fieldsArr; properties = @($idKey) }
        $body = $bodyObj | ConvertTo-Json -Depth 20 -Compress

        $r = Invoke-JiraRequest -Method POST -Url $url -Body $body
        if ([int]$r.ExitCode -ne 0) {
            Reset-JiraAdoption
            return [int]$r.ExitCode
        }

        $resp = $null
        try { $resp = $r.Body | ConvertFrom-Json -Depth 100 } catch { $resp = $null }
        $respIssues = Get-JiraAdoptionSafe $resp 'issues'
        $issues = if ($respIssues) { @($respIssues) } else { @() }
        foreach ($issue in $issues) {
            $key = Get-JiraAdoptionSafe $issue 'key'
            if ([string]::IsNullOrEmpty($key)) { continue }
            $props = Get-JiraAdoptionSafe $issue 'properties'
            $marker = Get-JiraAdoptionSafe $props $idKey
            $fields = Get-JiraAdoptionSafe $issue 'fields'
            if ($null -eq $fields) { $fields = [pscustomobject]@{} }
            $entryObj = @{ fields = $fields; marker = $marker }
            $entryJson = ConvertTo-JiraCanonicalJson ($entryObj | ConvertTo-Json -Depth 100 -Compress)
            $script:JiraAdoptionMap[$key.ToLowerInvariant()] = $entryJson
        }
    }
    return 0
}

function Get-JiraAdoption {
    <#
    .SYNOPSIS
      The resolved entry (case-insensitive key match), or $null on a miss.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Key)
    $lower = $Key.ToLowerInvariant()
    if (-not $script:JiraAdoptionMap.ContainsKey($lower)) { return $null }
    return $script:JiraAdoptionMap[$lower]
}

function Get-JiraAdoptionDescriptionText {
    <#
    .SYNOPSIS
      Plain text from a description field that may be a bare string, null,
      or a full ADF document (Jira Cloud's real shape) — every `.text` leaf,
      concatenated, regardless of nesting depth. Mirror of adoption.sh's
      inline `adf_text` jq filter.
    #>
    [CmdletBinding()]
    param($Description)
    if ($null -eq $Description) { return '' }
    if ($Description -is [string]) { return $Description }
    $parts = [System.Collections.Generic.List[string]]::new()
    function Get-Texts($node) {
        if ($null -eq $node) { return }
        if ($node -is [System.Management.Automation.PSCustomObject]) {
            $textProp = $node.PSObject.Properties['text']
            if ($textProp -and $textProp.Value -is [string]) { $parts.Add($textProp.Value) }
            foreach ($p in $node.PSObject.Properties) { Get-Texts $p.Value }
        }
        elseif ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
            foreach ($item in $node) { Get-Texts $item }
        }
    }
    Get-Texts $Description
    return ($parts -join ' ')
}

function Test-JiraAdoptionEvaluate {
    <#
    .SYNOPSIS
      The six per-key refusal classes (REF-UNRESOLVED, REF-ROLE,
      REF-ROUTING, REF-TERMINAL, REF-CLAIMED, REF-THIN), evaluated in that
      order. Mirror of adoption_evaluate. Prints canonical JSON
      {"code":"...","key":"...","message":"..."}, code empty when clean.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $RoutedProject,
        [Parameter(Mandatory)] [string] $Role,
        [Parameter(Mandatory)] [string] $Key,
        [AllowEmptyString()] [string] $DeclaredType = '',
        [AllowEmptyString()] [string] $TerminalStatusesCsv = '',
        [AllowEmptyString()] [string] $SpecRefJson = ''
    )

    $entry = Get-JiraAdoption -Key $Key
    if (-not $entry) {
        $msg = "designator $Key was not found in the read — check the key, then check that the credentials can open it in a browser"
        return (ConvertTo-JiraJsonValue ([ordered]@{ code = 'REF-UNRESOLVED'; key = $Key; message = $msg }))
    }
    $e = $entry | ConvertFrom-Json -Depth 100
    $fields = Get-JiraAdoptionSafe $e 'fields'
    $itypeName = Get-JiraAdoptionSafe (Get-JiraAdoptionSafe $fields 'issuetype') 'name'
    $projectKey = Get-JiraAdoptionSafe (Get-JiraAdoptionSafe $fields 'project') 'key'
    $statusName = Get-JiraAdoptionSafe (Get-JiraAdoptionSafe $fields 'status') 'name'
    $desc = Get-JiraAdoptionDescriptionText (Get-JiraAdoptionSafe $fields 'description')
    $marker = Get-JiraAdoptionSafe $e 'marker'
    if ($null -eq $itypeName) { $itypeName = '' }
    if ($null -eq $projectKey) { $projectKey = '' }
    if ($null -eq $statusName) { $statusName = '' }
    if ($null -eq $desc) { $desc = '' }

    if ($DeclaredType -and $itypeName -ne $DeclaredType) {
        $msg = "issue $Key has type $itypeName, not the declared $DeclaredType for the $Role role"
        return (ConvertTo-JiraJsonValue ([ordered]@{ code = 'REF-ROLE'; key = $Key; message = $msg }))
    }

    if ($RoutedProject -and $projectKey -ne $RoutedProject) {
        $msg = "issue $Key belongs to project $projectKey, not the routed project $RoutedProject"
        return (ConvertTo-JiraJsonValue ([ordered]@{ code = 'REF-ROUTING'; key = $Key; message = $msg }))
    }

    if ($TerminalStatusesCsv) {
        foreach ($t in ($TerminalStatusesCsv -split ',')) {
            if ($statusName -eq $t) {
                $msg = "issue $Key is in the terminal status $statusName — reopen it, or name a different one"
                return (ConvertTo-JiraJsonValue ([ordered]@{ code = 'REF-TERMINAL'; key = $Key; message = $msg }))
            }
        }
    }

    if ($SpecRefJson -and $null -ne $marker) {
        $s = $SpecRefJson | ConvertFrom-Json -Depth 100
        $sRepo = if ($s.PSObject.Properties.Name -contains 'repo') { [string]$s.repo } else { '' }
        $sSlug = if ($s.PSObject.Properties.Name -contains 'spec_slug') { [string]$s.spec_slug } else { '' }
        $mRepo = Get-JiraAdoptionSafe $marker 'repo'
        $mSlug = Get-JiraAdoptionSafe $marker 'spec_slug'
        if ($mRepo -ne $sRepo -or $mSlug -ne $sSlug) {
            $msg = "issue $Key already carries an identity marker for another specification"
            return (ConvertTo-JiraJsonValue ([ordered]@{ code = 'REF-CLAIMED'; key = $Key; message = $msg }))
        }
    }

    if ([string]::IsNullOrEmpty($desc.Trim())) {
        $msg = "the description of issue $Key has no non-whitespace character — write it in Jira, or do not name it"
        return (ConvertTo-JiraJsonValue ([ordered]@{ code = 'REF-THIN'; key = $Key; message = $msg }))
    }

    return (ConvertTo-JiraJsonValue ([ordered]@{ code = ''; key = $Key }))
}

function Get-JiraAdoptionMultiprojectViolation {
    <#
    .SYNOPSIS
      REF-MULTIPROJECT: the distinct set of resolved project keys among the
      given story-role keys, when more than one; an empty array otherwise.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $StoryKeysJson)
    $keys = @($StoryKeysJson | ConvertFrom-Json -Depth 100)
    $projects = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $keys) {
        $entry = Get-JiraAdoption -Key $k
        if (-not $entry) { continue }
        $e = $entry | ConvertFrom-Json -Depth 100
        $p = Get-JiraAdoptionSafe (Get-JiraAdoptionSafe $e 'fields') 'project'
        $pk = Get-JiraAdoptionSafe $p 'key'
        if ($pk -and -not $projects.Contains($pk)) { $projects.Add($pk) }
    }
    if ($projects.Count -gt 1) { return (ConvertTo-JiraJsonValue $projects) }
    return '[]'
}

function Get-JiraAdoptionAggregateRefusals {
    <#
    .SYNOPSIS
      Filters to only the refusing entries (Principle XVI, C-4).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Items)
    $arr = @($Items | ConvertFrom-Json -Depth 100)
    $out = @($arr | Where-Object { $_.code -ne '' })
    return (ConvertTo-JiraJsonValue $out)
}

Export-ModuleMember -Function Reset-JiraAdoption, Invoke-JiraAdoptionLoad, Get-JiraAdoption, Test-JiraAdoptionEvaluate, `
    Get-JiraAdoptionMultiprojectViolation, Get-JiraAdoptionAggregateRefusals, Get-JiraAdoptionDescriptionText
