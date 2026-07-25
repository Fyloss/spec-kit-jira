# lib/Config.psm1 — Team config storage. Mirror of lib/config.sh.
#
# The config files are YAML; the PowerShell port has no YAML cmdlet at runtime,
# so it parses the SAME deliberately-restricted YAML subset the Bash port parses
# (2-space block indentation, `key: value` mappings, `- ` sequences, plain /
# single- / double-quoted scalars, true/false/null, `#` comments). The YAML->JSON
# output is byte-identical to the Bash port's `config_yaml_to_json` (proven in
# bats), reusing the canonical serialiser in Output.psm1. Validation encodes the
# same contracts/config.schema.json rules and emits identical error strings; a
# credential-shaped value is refused with exit 4 and its value never echoed.
#
# Import-JiraConfig returns a result object { ExitCode; Json; Errors } — the same
# asymmetric-shape-but-identical-behaviour convention as the REST client.
#
# Port infrastructure only: NO Jira knowledge.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Output.psm1') -Force

$script:ExitConfig = 4

# =============================================================================
# Version single-source (T032, FR-021/FR-022)
# =============================================================================

function Get-JiraExtensionYmlPath {
    if ($env:SPEC_KIT_JIRA_EXTENSION_YML) { return $env:SPEC_KIT_JIRA_EXTENSION_YML }
    return (Join-Path $PSScriptRoot '../../../extension.yml')
}

function Get-JiraConfigDirPath {
    if ($env:JIRA_CONFIG_DIR) { return $env:JIRA_CONFIG_DIR }
    return '.specify/jira'
}

function Get-JiraExtensionVersion {
    <#
    .SYNOPSIS
      Print the single source-of-truth version string, read from the `version:`
      field of extension.yml. Byte-identical to the Bash port.
    #>
    [CmdletBinding()]
    param()
    $yml = Get-JiraExtensionYmlPath
    if (-not (Test-Path -LiteralPath $yml)) {
        [Console]::Error.WriteLine("config: extension metadata not found: $yml")
        return $script:ExitConfig
    }
    # The official manifest schema nests the field under the `extension:` block
    # (indented), so only an INDENTED `version:` matches — the top-level
    # `schema_version:` and `requires.speckit_version:` never can.
    foreach ($line in Get-Content -LiteralPath $yml) {
        if ($line -cmatch '^\s+version:\s*(.*)$') {
            $value = $Matches[1].Trim()
            if ($value.Length -ge 2 -and $value[0] -eq '"' -and $value[-1] -eq '"') { $value = $value.Substring(1, $value.Length - 2) }
            elseif ($value.Length -ge 2 -and $value[0] -eq "'" -and $value[-1] -eq "'") { $value = $value.Substring(1, $value.Length - 2) }
            return $value
        }
    }
    [Console]::Error.WriteLine("config: no version field in $yml")
    return $script:ExitConfig
}

function Assert-JiraSingleVersionSource {
    <#
    .SYNOPSIS
      Refuse any hand-maintained version marker outside the extension (FR-022).
      Returns 4 if one is found, else 0.
    #>
    [CmdletBinding()]
    param()
    $stray = Join-Path (Get-JiraConfigDirPath) 'VERSION'
    if (Test-Path -LiteralPath $stray) {
        [Console]::Error.WriteLine("config: a stray version marker exists at $stray — the version is single-sourced from extension.yml (FR-022); remove it.")
        return $script:ExitConfig
    }
    return 0
}

# =============================================================================
# YAML subset -> structure / JSON (T030)
# =============================================================================

# Parser state (script-scoped; recursive parsers share the cursor, no subshell
# concerns as in the Bash port).
$script:CfgLines = @()
$script:CfgIndents = @()
$script:CfgN = 0
$script:CfgI = 0

function Remove-CfgInlineComment {
    param([string] $Line)
    $out = [System.Text.StringBuilder]::new()
    $inS = $false; $inD = $false; $prev = ''
    foreach ($ch in $Line.ToCharArray()) {
        if ($ch -eq "'" -and -not $inD) { $inS = -not $inS }
        elseif ($ch -eq '"' -and -not $inS) { $inD = -not $inD }
        elseif ($ch -eq '#' -and -not $inS -and -not $inD -and ($prev -eq '' -or $prev -eq ' ' -or $prev -eq "`t")) { break }
        [void]$out.Append($ch)
        $prev = $ch
    }
    return $out.ToString().TrimEnd()
}

function Initialize-CfgBuffer {
    param([string] $Path)
    $script:CfgLines = [System.Collections.Generic.List[string]]::new()
    $script:CfgIndents = [System.Collections.Generic.List[int]]::new()
    $script:CfgI = 0
    foreach ($raw0 in [System.IO.File]::ReadAllLines($Path)) {
        $raw = $raw0.TrimEnd("`r")
        $body = $raw.TrimStart(' ')
        if ($body -eq '') { continue }
        if ($body.StartsWith('#')) { continue }
        $indent = $raw.Length - $body.Length
        $body = Remove-CfgInlineComment $body
        if ($body -eq '') { continue }
        $script:CfgIndents.Add($indent)
        $script:CfgLines.Add($body)
    }
    $script:CfgN = $script:CfgLines.Count
}

function Test-CfgMapEntry {
    param([string] $Content)
    return ($Content -match '^[A-Za-z0-9_. -]+:(\s.*)?$')
}

function Convert-CfgScalar {
    param([string] $Raw)
    $s = $Raw.Trim()
    if ($s.Length -ge 2 -and $s[0] -eq '"' -and $s[-1] -eq '"') { return $s.Substring(1, $s.Length - 2) }
    if ($s.Length -ge 2 -and $s[0] -eq "'" -and $s[-1] -eq "'") { return $s.Substring(1, $s.Length - 2) }
    switch ($s) {
        'true' { return $true }
        'false' { return $false }
        'null' { return $null }
        '~' { return $null }
        '' { return $null }
        default { return $s }
    }
}

# The recursive parsers return their fragment through $script:CfgRet (mirroring
# the Bash port's global-return convention) to avoid array-unwrapping surprises.
$script:CfgRet = $null

function Read-CfgValue {
    if ($script:CfgI -ge $script:CfgN) { $script:CfgRet = $null; return }
    $ind = $script:CfgIndents[$script:CfgI]
    $content = $script:CfgLines[$script:CfgI]
    if ($content -eq '-' -or $content.StartsWith('- ')) { Read-CfgSequence $ind } else { Read-CfgMapping $ind }
}

function Read-CfgMapping {
    param([int] $Ind)
    $map = [ordered]@{}
    while ($script:CfgI -lt $script:CfgN) {
        if ($script:CfgIndents[$script:CfgI] -ne $Ind) { break }
        $content = $script:CfgLines[$script:CfgI]
        if ($content -eq '-' -or $content.StartsWith('- ')) { break }
        if (-not (Test-CfgMapEntry $content)) { break }
        $colon = $content.IndexOf(':')
        $key = $content.Substring(0, $colon).Trim()
        $rest = $content.Substring($colon + 1).TrimStart(' ')
        $script:CfgI++
        if ($rest -ne '') {
            $map[$key] = Convert-CfgScalar $rest
        }
        elseif ($script:CfgI -lt $script:CfgN -and $script:CfgIndents[$script:CfgI] -gt $Ind) {
            Read-CfgValue
            $map[$key] = $script:CfgRet
        }
        else {
            $map[$key] = $null
        }
    }
    $script:CfgRet = $map
}

function Read-CfgSequence {
    param([int] $Ind)
    $items = [System.Collections.Generic.List[object]]::new()
    while ($script:CfgI -lt $script:CfgN) {
        if ($script:CfgIndents[$script:CfgI] -ne $Ind) { break }
        $content = $script:CfgLines[$script:CfgI]
        if (-not ($content -eq '-' -or $content.StartsWith('- '))) { break }
        $rest = if ($content -eq '-') { '' } else { $content.Substring(2) }
        if ($rest -eq '') {
            $script:CfgI++
            if ($script:CfgI -lt $script:CfgN -and $script:CfgIndents[$script:CfgI] -gt $Ind) {
                Read-CfgValue
                $items.Add($script:CfgRet)
            }
            else { $items.Add($null) }
        }
        elseif (Test-CfgMapEntry $rest) {
            # The dash introduces a mapping whose first key sits at column Ind+2.
            $script:CfgLines[$script:CfgI] = $rest
            $script:CfgIndents[$script:CfgI] = $Ind + 2
            Read-CfgMapping ($Ind + 2)
            $items.Add($script:CfgRet)
        }
        else {
            $script:CfgI++
            $items.Add((Convert-CfgScalar $rest))
        }
    }
    # Assigning to a script-scoped variable preserves single-element arrays
    # (no pipeline unwrapping), so downstream consumers see a real array.
    $script:CfgRet = $items.ToArray()
}

function Read-JiraConfigYamlObject {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "config: file not found: $Path" }
    Initialize-CfgBuffer $Path
    Read-CfgValue
    return $script:CfgRet
}

function ConvertFrom-JiraConfigYaml {
    <#
    .SYNOPSIS
      Parse the YAML subset and return canonical JSON, byte-identical to the Bash
      port's config_yaml_to_json.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    $obj = Read-JiraConfigYamlObject -Path $Path
    return (ConvertTo-JiraJsonValue $obj)
}

# =============================================================================
# JSON -> canonical YAML (T044) — the deterministic writer. Mirror of
# config_to_yaml; emits byte-identical output.
# =============================================================================

function Write-CfgYamlScalar {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [string]) { return '"' + $Value + '"' }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or
        $Value -is [decimal] -or $Value -is [single]) {
        return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0}', $Value)
    }
    return '"' + [string]$Value + '"'
}

function Write-CfgYamlNode {
    # Recursively emit a parsed value as canonical YAML lines (2-space indent,
    # sorted object keys ordinal, `- ` sequences). Returns the joined lines with
    # no trailing newline — byte-identical to the Bash emitter's jq program.
    param($Node, [string] $Ind)

    if ($Node -is [System.Collections.IDictionary] -or $Node -is [System.Management.Automation.PSCustomObject]) {
        $map = [ordered]@{}
        if ($Node -is [System.Collections.IDictionary]) {
            foreach ($k in $Node.Keys) { $map[[string]$k] = $Node[$k] }
        }
        else {
            foreach ($p in $Node.PSObject.Properties) { $map[[string]$p.Name] = $p.Value }
        }
        # Sort keys by Unicode code point (ordinal) — the same order as the
        # canonical JSON serialiser, so both ports converge to identical bytes.
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($k in $map.Keys) { $names.Add([string]$k) }
        $names.Sort([System.StringComparer]::Ordinal)
        $lines = foreach ($k in $names) {
            $v = $map[$k]
            if ($v -is [System.Collections.IDictionary] -or $v -is [System.Management.Automation.PSCustomObject]) {
                $childCount = @($(if ($v -is [System.Collections.IDictionary]) { $v.Keys } else { $v.PSObject.Properties })).Count
                if ($childCount -eq 0) { "$Ind${k}: {}" }
                else { "$Ind${k}:`n" + (Write-CfgYamlNode $v ($Ind + '  ')) }
            }
            elseif (($v -is [System.Collections.IEnumerable]) -and ($v -isnot [string])) {
                if (@($v).Count -eq 0) { "$Ind${k}: []" }
                else { "$Ind${k}:`n" + (Write-CfgYamlNode $v ($Ind + '  ')) }
            }
            else { "$Ind${k}: " + (Write-CfgYamlScalar $v) }
        }
        return ($lines -join "`n")
    }

    if (($Node -is [System.Collections.IEnumerable]) -and ($Node -isnot [string])) {
        $lines = foreach ($item in $Node) {
            $isObj = $item -is [System.Collections.IDictionary] -or $item -is [System.Management.Automation.PSCustomObject]
            $isArr = ($item -is [System.Collections.IEnumerable]) -and ($item -isnot [string])
            if ($isObj -or $isArr) { "$Ind-`n" + (Write-CfgYamlNode $item ($Ind + '  ')) }
            else { "$Ind- " + (Write-CfgYamlScalar $item) }
        }
        return ($lines -join "`n")
    }

    return [string]$Node
}

function ConvertTo-JiraConfigYaml {
    <#
    .SYNOPSIS
      Emit a JSON value as canonical YAML (no trailing newline), byte-identical to
      the Bash port's config_to_yaml. The caller adds exactly one trailing newline.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Json)
    $obj = $Json | ConvertFrom-Json -Depth 100
    return (Write-CfgYamlNode $obj '')
}

# =============================================================================
# Credential-shape rejection (T031, FR-023)
# =============================================================================

function Get-JiraCredentialPathError {
    # Walk a parsed structure yielding "<disppath>: <reason>" for each
    # credential-shaped string value. privacy.* is exempt (FR-053). The value is
    # never included. Path format mirrors jq's disppath used by the Bash port.
    param($Node, [string] $Path, [System.Collections.Generic.List[string]] $Acc)

    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($k in ($Node.Keys | Sort-Object { [string]$_ } -Culture Ordinal)) {
            $seg = if ($Path -eq '') { [string]$k } else { "$Path.$k" }
            Get-JiraCredentialPathError $Node[$k] $seg $Acc
        }
    }
    elseif ($Node -is [string]) {
        # Skip the whole privacy subtree.
        if ($Path -like 'privacy*') { return }
        $reason = $null
        if ($Node -cmatch '^ATATT') { $reason = 'Atlassian API token' }
        elseif ($Node -cmatch '[a-z0-9][a-z0-9-]*\.atlassian\.net') { $reason = 'Atlassian Cloud host' }
        elseif ($Node -cmatch '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') { $reason = 'email address' }
        if ($reason) { $Acc.Add("${Path}: $reason") }
    }
    elseif ($Node -is [System.Collections.IEnumerable]) {
        $i = 0
        foreach ($item in $Node) {
            $seg = if ($Path -eq '') { "[$i]" } else { "$Path[$i]" }
            Get-JiraCredentialPathError $item $seg $Acc
            $i++
        }
    }
}

function Get-JiraConfigCredentialError {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Object)
    $acc = [System.Collections.Generic.List[string]]::new()
    Get-JiraCredentialPathError $Object '' $acc
    return $acc.ToArray()
}

# =============================================================================
# Schema validation (T030)
# =============================================================================

function Get-CfgProp {
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    return $null
}

function Test-JiraTeamConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Object)
    $errs = [System.Collections.Generic.List[string]]::new()

    $projects = Get-CfgProp $Object 'projects'
    $isArray = ($projects -is [System.Collections.IEnumerable]) -and ($projects -isnot [string])
    if (-not $isArray -or @($projects).Count -lt 1) {
        $errs.Add('projects must be a non-empty array')
    }

    $rd = Get-CfgProp $Object 'routing_default'
    if ($rd -isnot [string] -or ($rd -cnotmatch '^[A-Z][A-Z0-9_]+$')) {
        $errs.Add('routing_default must be a valid project key')
    }

    $allowedTop = @('version_compat', 'projects', 'routing', 'routing_default', 'privacy')
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($k in ($Object.Keys | Sort-Object { [string]$_ } -Culture Ordinal)) {
            if ($allowedTop -cnotcontains [string]$k) { $errs.Add("unknown top-level key: $k") }
        }
    }

    if ($isArray) {
        $i = 0
        foreach ($p in $projects) {
            $key = Get-CfgProp $p 'key'
            if (($key -isnot [string]) -or ($key -cnotmatch '^[A-Z][A-Z0-9_]+$')) { $errs.Add("projects[$i].key is not a valid project key") }
            $style = Get-CfgProp $p 'style'
            if (@('company_managed', 'team_managed') -cnotcontains $style) { $errs.Add("projects[$i].style is invalid") }
            $es = Get-CfgProp $p 'epic_strategy'
            if (@('per_repo', 'per_feature') -cnotcontains $es) { $errs.Add("projects[$i].epic_strategy is invalid") }
            $ts = Get-CfgProp $p 'task_strategy'
            if (@('subtask', 'linked_story') -cnotcontains $ts) { $errs.Add("projects[$i].task_strategy is invalid") }
            $lt = Get-CfgProp $p 'link_type'
            if ($ts -eq 'linked_story' -and [string]::IsNullOrEmpty([string]$lt)) { $errs.Add("projects[$i].link_type is required when task_strategy=linked_story") }
            $i++
        }
    }
    return $errs.ToArray()
}

function Test-JiraLocalConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Object)
    $errs = [System.Collections.Generic.List[string]]::new()
    $allowed = @('site_alias', 'resolved_ids', 'overrides')
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($k in ($Object.Keys | Sort-Object { [string]$_ } -Culture Ordinal)) {
            if ($allowed -cnotcontains [string]$k) { $errs.Add("unknown config.local key: $k") }
        }
    }
    return $errs.ToArray()
}

# =============================================================================
# Load / merge orchestration (T030)
# =============================================================================

function Merge-CfgProjectList {
    # Merge the local `projects` override into the team list PER ENTRY, BY KEY —
    # a wholesale array replacement would silently DROP every project the local
    # override does not repeat. Unmatched team entries survive; unmatched
    # override entries are appended in their own order. Mirror of the jq merge
    # in config_load.
    param($TeamList, $OverrideList)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($p in @($TeamList)) {
        $pk = [string](Get-CfgProp $p 'key')
        $ov = $null
        foreach ($o in @($OverrideList)) {
            if ([string]::Equals([string](Get-CfgProp $o 'key'), $pk, [System.StringComparison]::Ordinal)) { $ov = $o; break }
        }
        if ($null -eq $ov) { $out.Add($p) } else { $out.Add((Merge-CfgObject $p $ov)) }
    }
    foreach ($o in @($OverrideList)) {
        $ok = [string](Get-CfgProp $o 'key')
        $seen = $false
        foreach ($p in @($TeamList)) {
            if ([string]::Equals([string](Get-CfgProp $p 'key'), $ok, [System.StringComparison]::Ordinal)) { $seen = $true; break }
        }
        if (-not $seen) { $out.Add($o) }
    }
    return $out.ToArray()
}

function Merge-CfgObject {
    # Recursive object merge mirroring jq's `*`: for keys in both where both are
    # objects, merge recursively; otherwise the right value wins — except the
    # top-level `projects` arrays, which merge per-entry by key (see
    # Merge-CfgProjectList).
    param($Left, $Right)
    if ($Left -is [System.Collections.IDictionary] -and $Right -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($k in $Left.Keys) { $out[[string]$k] = $Left[$k] }
        foreach ($k in $Right.Keys) {
            $ks = [string]$k
            if ($out.Contains($ks) -and ($out[$ks] -is [System.Collections.IDictionary]) -and ($Right[$k] -is [System.Collections.IDictionary])) {
                $out[$ks] = Merge-CfgObject $out[$ks] $Right[$k]
            }
            elseif ([string]::Equals($ks, 'projects', [System.StringComparison]::Ordinal) -and $out.Contains($ks) -and
                ($out[$ks] -is [System.Collections.IList]) -and ($Right[$k] -is [System.Collections.IList])) {
                $out[$ks] = Merge-CfgProjectList $out[$ks] $Right[$k]
            }
            else { $out[$ks] = $Right[$k] }
        }
        return $out
    }
    return $Right
}

function Import-JiraConfig {
    <#
    .SYNOPSIS
      Load config.yml (+ optional config.local.yml), credential-scan and
      schema-validate both layers, merge local overrides over the team config,
      and return { ExitCode; Json; Errors }. ExitCode is 4 on any violation.
    #>
    [CmdletBinding()]
    param([string] $ConfigDir = (Get-JiraConfigDirPath))

    $errors = [System.Collections.Generic.List[string]]::new()
    $team = Join-Path $ConfigDir 'config.yml'
    $localF = Join-Path $ConfigDir 'config.local.yml'

    if (-not (Test-Path -LiteralPath $team)) {
        $errors.Add("config: $team not found — run /speckit.jira.config first.")
        [Console]::Error.WriteLine($errors[-1])
        return [pscustomobject]@{ ExitCode = $script:ExitConfig; Json = ''; Errors = $errors.ToArray() }
    }

    $fail = {
        param($label, $file, $lines)
        $any = $false
        foreach ($l in $lines) {
            if ([string]::IsNullOrEmpty($l)) { continue }
            $any = $true
            $msg = "config: $label ($file): $l"
            $errors.Add($msg)
            [Console]::Error.WriteLine($msg)
        }
        return $any
    }

    try { $teamObj = Read-JiraConfigYamlObject -Path $team }
    catch {
        $errors.Add("config: $team is not valid config YAML")
        [Console]::Error.WriteLine($errors[-1])
        return [pscustomobject]@{ ExitCode = $script:ExitConfig; Json = ''; Errors = $errors.ToArray() }
    }

    if (& $fail 'credential' $team (Get-JiraConfigCredentialError $teamObj)) { return [pscustomobject]@{ ExitCode = $script:ExitConfig; Json = ''; Errors = $errors.ToArray() } }
    if (& $fail 'schema' $team (Test-JiraTeamConfig $teamObj)) { return [pscustomobject]@{ ExitCode = $script:ExitConfig; Json = ''; Errors = $errors.ToArray() } }

    $merged = $teamObj
    if (Test-Path -LiteralPath $localF) {
        try { $localObj = Read-JiraConfigYamlObject -Path $localF }
        catch {
            $errors.Add("config: $localF is not valid config YAML")
            [Console]::Error.WriteLine($errors[-1])
            return [pscustomobject]@{ ExitCode = $script:ExitConfig; Json = ''; Errors = $errors.ToArray() }
        }
        if (& $fail 'credential' $localF (Get-JiraConfigCredentialError $localObj)) { return [pscustomobject]@{ ExitCode = $script:ExitConfig; Json = ''; Errors = $errors.ToArray() } }
        if (& $fail 'schema' $localF (Test-JiraLocalConfig $localObj)) { return [pscustomobject]@{ ExitCode = $script:ExitConfig; Json = ''; Errors = $errors.ToArray() } }
        $overrides = Get-CfgProp $localObj 'overrides'
        if ($null -eq $overrides) { $overrides = [ordered]@{} }
        $merged = Merge-CfgObject $teamObj $overrides
    }

    return [pscustomobject]@{ ExitCode = 0; Json = (ConvertTo-JiraJsonValue $merged); Errors = @() }
}

# =============================================================================
# Status classification + phase->status mapping (T039, FR-011/FR-034)
# Mirror of config_classify_statuses / config_phase_status_targets.
# =============================================================================

function Get-JiraStatusClassification {
    <#
    .SYNOPSIS
      Classify each discovered status into mapped|post-scope|halted|unknown,
      seeded from statusCategory and refined by the operator (research §4). No
      built-in default table (FR-012). Returns the canonical {name:category} JSON.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StatusesJson,
        [string] $PhaseStatusMapJson = '{}',
        [string] $HaltedJson = '[]'
    )
    $statuses = $StatusesJson | ConvertFrom-Json -Depth 100
    $pm = $PhaseStatusMapJson | ConvertFrom-Json -Depth 100
    $halted = @($HaltedJson | ConvertFrom-Json -Depth 100)

    $targets = [System.Collections.Generic.List[string]]::new()
    if ($pm -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $pm.PSObject.Properties) { $targets.Add([string] $p.Value) }
    }
    $haltedSet = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($h in $halted) { [void]$haltedSet.Add([string] $h) }

    $out = [ordered]@{}
    foreach ($s in $statuses) {
        $name = [string] $s.name
        $category =
            if ($targets.Contains($name)) { 'mapped' }
            elseif ($haltedSet.Contains($name)) { 'halted' }
            elseif ($s.status_category -eq 'done') { 'post-scope' }
            else { 'unknown' }
        $out[$name] = $category
    }
    return (ConvertTo-JiraJsonValue $out)
}

function Get-JiraPhaseStatusTargetSet {
    <#
    .SYNOPSIS
      The DISTINCT statuses a phase->status map resolves to (many-to-one collapses
      to a single target, FR-011). Returns the canonical sorted-unique JSON array.
    #>
    [CmdletBinding()]
    param([string] $PhaseStatusMapJson = '{}')
    $pm = $PhaseStatusMapJson | ConvertFrom-Json -Depth 100
    $values = [System.Collections.Generic.List[string]]::new()
    if ($pm -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $pm.PSObject.Properties) { $values.Add([string] $p.Value) }
    }
    # `unique` in jq sorts ascending; mirror with an ordinal sort of distinct values.
    $distinct = [System.Collections.Generic.List[object]]::new()
    foreach ($v in ($values | Sort-Object -Culture Ordinal -Unique)) { $distinct.Add($v) }
    return (ConvertTo-JiraJsonValue $distinct)
}

Export-ModuleMember -Function Get-JiraExtensionVersion, Assert-JiraSingleVersionSource, `
    ConvertFrom-JiraConfigYaml, ConvertTo-JiraConfigYaml, Read-JiraConfigYamlObject, `
    Get-JiraConfigCredentialError, Test-JiraTeamConfig, Test-JiraLocalConfig, Import-JiraConfig, `
    Get-JiraStatusClassification, Get-JiraPhaseStatusTargetSet
