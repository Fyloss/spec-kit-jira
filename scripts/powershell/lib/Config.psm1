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

# The template's literal placeholder project key (templates/config.yml.template):
# a configured key equal to it is treated as UNSET (002 US2, FR-005).
$script:PlaceholderKey = if ($env:JIRA_CONFIG_PLACEHOLDER_KEY) { $env:JIRA_CONFIG_PLACEHOLDER_KEY } else { 'PROJ' }

function Test-JiraPlaceholderKey {
    # The FR-005 placeholder rule. Mirror of config_key_is_placeholder.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Key)
    return ($Key -ceq $script:PlaceholderKey)
}

function Get-JiraPlaceholderKey {
    [CmdletBinding()]
    param()
    return $script:PlaceholderKey
}

function Get-JiraOrdinalSorted {
    # Sort strings by Unicode code point (ordinal), matching the Bash port's jq
    # ordering. `-Culture Ordinal` is NOT a valid CultureInfo, so we sort via
    # [StringComparer]::Ordinal instead. With -Unique, collapses duplicates
    # ordinally like jq `unique`.
    param([object[]] $Items, [switch] $Unique)
    $arr = [string[]]@(foreach ($it in $Items) { [string]$it })
    [System.Array]::Sort($arr, [System.StringComparer]::Ordinal)
    if (-not $Unique) { return $arr }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $arr) { if ($seen.Add($s)) { $out.Add($s) } }
    return $out.ToArray()
}

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
$script:CfgLineNos = @()
$script:CfgN = 0
$script:CfgI = 0
$script:CfgFile = $null

# $script:CfgErr — the formatted parse-failure message (contracts/
# parse-failure.md §2), or $null when clear. Set by New-CfgParseFailure /
# New-CfgDuplicateKeyFailure; every parser loop below returns immediately once
# it is set — a flag, not a `throw` per frame, so control flow is identical to
# the Bash port's mirrored flag (Constitution VI: a throw on one side and a
# global on the other would unwind differently and reorder stderr).
$script:CfgErr = $null

function ConvertFrom-CfgEscape {
    <#
    .SYNOPSIS
      Undo the writer's escaping (contracts/yaml-string-escaping.md §2.1): a
      left-to-right walk where `\"` becomes `"` and `\\` becomes `\`; any
      other backslash, including one at the end of the body, is kept literal
      (FR-012) rather than treated as a parse failure. Mirror of
      _cfg_decode_escapes.
    #>
    param([string] $Body)
    if ($Body.IndexOf('\') -lt 0) { return $Body }
    $out = [System.Text.StringBuilder]::new()
    $n = $Body.Length
    $i = 0
    while ($i -lt $n) {
        $ch = $Body[$i]
        if ($ch -eq '\' -and ($i + 1) -lt $n -and ($Body[$i + 1] -eq '"' -or $Body[$i + 1] -eq '\')) {
            [void]$out.Append($Body[$i + 1])
            $i += 2
            continue
        }
        [void]$out.Append($ch)
        $i++
    }
    return $out.ToString()
}

function Remove-CfgInlineComment {
    param([string] $Line)
    $out = [System.Text.StringBuilder]::new()
    $inS = $false; $inD = $false; $prev = ''
    $n = $Line.Length
    $i = 0
    while ($i -lt $n) {
        $ch = $Line[$i]
        if ($inD -and $ch -eq '\') {
            # Escape-aware (contracts/yaml-string-escaping.md §2.3): a `\`
            # inside a double-quoted region consumes the following character
            # without changing quote state, so an escaped `"` cannot close
            # the region.
            $nxt = if (($i + 1) -lt $n) { $Line[$i + 1] } else { $null }
            [void]$out.Append($ch)
            if ($null -ne $nxt) { [void]$out.Append($nxt) }
            $prev = if ($null -ne $nxt) { $nxt } else { '' }
            $i += 2
            continue
        }
        if ($ch -eq "'" -and -not $inD) { $inS = -not $inS }
        elseif ($ch -eq '"' -and -not $inS) { $inD = -not $inD }
        elseif ($ch -eq '#' -and -not $inS -and -not $inD -and ($prev -eq '' -or $prev -eq ' ' -or $prev -eq "`t")) { break }
        [void]$out.Append($ch)
        $prev = $ch
        $i++
    }
    return $out.ToString().TrimEnd()
}

function Initialize-CfgBuffer {
    param([string] $Path)
    $script:CfgFile = $Path
    $script:CfgLines = [System.Collections.Generic.List[string]]::new()
    $script:CfgIndents = [System.Collections.Generic.List[int]]::new()
    $script:CfgLineNos = [System.Collections.Generic.List[int]]::new()
    $script:CfgI = 0
    $script:CfgErr = $null
    $lineno = 0
    foreach ($raw0 in [System.IO.File]::ReadAllLines($Path)) {
        $lineno++
        $raw = $raw0.TrimEnd("`r")
        $body = $raw.TrimStart(' ')
        if ($body -eq '') { continue }
        if ($body.StartsWith('#')) { continue }
        $indent = $raw.Length - $body.Length
        $body = Remove-CfgInlineComment $body
        if ($body -eq '') { continue }
        $script:CfgIndents.Add($indent)
        $script:CfgLines.Add($body)
        $script:CfgLineNos.Add($lineno)
    }
    $script:CfgN = $script:CfgLines.Count
}

function Protect-CfgLine {
    <#
    .SYNOPSIS
      Replace every credential-shaped substring with [redacted] before a
      parse-failure line is formatted (contracts/parse-failure.md §2.1): the
      BLOCK-tier shapes the privacy guard recognises (an Atlassian API token
      prefix, a real *.atlassian.net host) and the WARN-tier email shape
      (Constitution IX). Applied to the WHOLE line, mirror of
      _cfg_redact_line.
    #>
    param([string] $Line)
    $Line = [regex]::Replace($Line, 'ATATT[A-Za-z0-9._=+/-]{2,}', '[redacted]')
    $Line = [regex]::Replace($Line, '[a-z0-9][a-z0-9-]*\.atlassian\.net', '[redacted]', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $Line = [regex]::Replace($Line, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '[redacted]', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    return $Line
}

function New-CfgParseFailure {
    <#
    .SYNOPSIS
      Set $script:CfgErr to the three-line message of
      contracts/parse-failure.md §2 for the retained line at the given cursor
      index. Mirror of _cfg_raise_parse_failure.
    #>
    param([int] $Index)
    $line = $script:CfgLineNos[$Index]
    $content = Protect-CfgLine $script:CfgLines[$Index]
    $script:CfgErr = "config: ${script:CfgFile}:${line}: cannot parse this line as a mapping entry: $content`n" +
    'config: a key must be followed by ": " — quote the key if it contains a colon, e.g. "Blocked: waiting": "10001"' + "`n" +
    "config: re-run /speckit.jira.config to regenerate ${script:CfgFile} from the Jira instance."
}

function New-CfgDuplicateKeyFailure {
    <#
    .SYNOPSIS
      Set $script:CfgErr to the duplicate-key message of
      contracts/parse-failure.md §1 (FR-016). Mirror of
      _cfg_raise_duplicate_key.
    #>
    param([int] $Index, [string] $Key, [int] $FirstLine)
    $line = $script:CfgLineNos[$Index]
    $redactedKey = Protect-CfgLine $Key
    $script:CfgErr = "config: ${script:CfgFile}:${line}: duplicate key ${redactedKey} — already defined at line ${FirstLine}`n" +
    'config: two entries cannot claim the same name; delete or rename one of them.' + "`n" +
    "config: re-run /speckit.jira.config to regenerate ${script:CfgFile} from the Jira instance."
}

$script:CfgKey = $null
$script:CfgRestText = $null

function Get-CfgMapEntryKey {
    <#
    .SYNOPSIS
      Locate a mapping entry's DELIMITER COLON by structure, not by an
      enumerated key charset (contracts/yaml-key-grammar.md §1). Mirror of
      _cfg_map_entry_key: sets $script:CfgKey / $script:CfgRestText and
      returns $true on success; clears both and returns $false when the line
      is not a mapping entry (no delimiter colon found, or the key is empty
      after trimming).
    #>
    param([string] $Content)
    $script:CfgKey = $null
    $script:CfgRestText = $null
    $n = $Content.Length
    if ($n -eq 0) { return $false }
    $first = $Content[0]
    if ($first -eq '"' -or $first -eq "'") {
        # Quoted key (§1.1): bounded by the NEXT occurrence of the same quote
        # character. When that quote is `"`, the scan is escape-aware
        # (contracts/yaml-string-escaping.md §2.3): a `\` consumes the
        # following character without ending the key, so the closing quote is
        # the next `"` not preceded by an escaping backslash. A single-quoted
        # key has no escape sequences at all (§2.2). The delimiter colon must
        # immediately follow the closing quote, then whitespace or EOL.
        $q = $first
        $close = -1
        if ($q -eq '"') {
            for ($i = 1; $i -lt $n; $i++) {
                if ($Content[$i] -eq '\') { $i++; continue }
                if ($Content[$i] -eq $q) { $close = $i; break }
            }
        }
        else {
            for ($i = 1; $i -lt $n; $i++) {
                if ($Content[$i] -eq $q) { $close = $i; break }
            }
        }
        if ($close -lt 0) { return $false }
        $colonIdx = $close + 1
        if ($colonIdx -ge $n -or $Content[$colonIdx] -ne ':') { return $false }
        $afterIdx = $colonIdx + 1
        $nxt = if ($afterIdx -lt $n) { $Content[$afterIdx] } else { $null }
        if ($null -ne $nxt -and $nxt -ne ' ' -and $nxt -ne "`t") { return $false }
        $key = $Content.Substring(1, $close - 1)
        if ($key -eq '') { return $false }
        if ($q -eq '"') { $key = ConvertFrom-CfgEscape $key }
        $script:CfgKey = $key
        $tail = if ($afterIdx -lt $n) { $Content.Substring($afterIdx) } else { '' }
        $script:CfgRestText = $tail.TrimStart()
        return $true
    }
    # Bare key (§1.2): scan left to right for the first `:` followed by
    # whitespace or end of line. Deliberately NOT quote-aware — `Won't Do: "1"`
    # must parse, and a quote-aware scan would open a single-quote region at
    # the apostrophe and never find the delimiter (research R1).
    for ($i = 0; $i -lt $n; $i++) {
        if ($Content[$i] -ne ':') { continue }
        $afterIdx = $i + 1
        $nxt = if ($afterIdx -lt $n) { $Content[$afterIdx] } else { $null }
        if ($null -eq $nxt -or $nxt -eq ' ' -or $nxt -eq "`t") {
            $key = $Content.Substring(0, $i).TrimEnd()
            if ($key -eq '') { return $false }
            $script:CfgKey = $key
            $tail = if ($afterIdx -lt $n) { $Content.Substring($afterIdx) } else { '' }
            $script:CfgRestText = $tail.TrimStart()
            return $true
        }
    }
    return $false
}

function Test-CfgMapEntry {
    <#
    .SYNOPSIS
      True when the line opens a mapping entry (contracts/yaml-key-grammar.md
      §1). Also used as a non-fatal DISPATCH by Read-CfgSequence to decide
      whether `- x` opens a mapping or is a plain scalar item (§1.4) — a
      $false here must never be treated as an error.
    #>
    param([string] $Content)
    return (Get-CfgMapEntryKey $Content)
}

function Convert-CfgScalar {
    param([string] $Raw)
    $s = $Raw.Trim()
    if ($s.Length -ge 2 -and $s[0] -eq '"' -and $s[-1] -eq '"') {
        return (ConvertFrom-CfgEscape ($s.Substring(1, $s.Length - 2)))
    }
    if ($s.Length -ge 2 -and $s[0] -eq "'" -and $s[-1] -eq "'") { return $s.Substring(1, $s.Length - 2) }
    switch ($s) {
        'true' { return $true }
        'false' { return $false }
        'null' { return $null }
        '~' { return $null }
        '' { return $null }
        # The two EMPTY flow forms, and only those. They are in the subset
        # because ConvertTo-JiraConfigYaml emits exactly them for an empty
        # collection, and the writer is documented as a fixed point of this
        # reader — without these, a file this module wrote reads back with the
        # strings "[]" and "{}" where it wrote collections. Non-empty flow
        # collections stay out of scope. Mirror of _cfg_scalar_json.
        '[]' { return , @() }
        '{}' { return [ordered]@{} }
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
    # A key repeated at THIS mapping's own level is malformed (FR-016,
    # yaml-key-grammar.md §1.5) — the same name at a DIFFERENT level is legal,
    # so $seen is local to this call, freshly scoped by every recursive call.
    $seen = [System.Collections.Generic.Dictionary[string, int]]::new()
    while ($script:CfgI -lt $script:CfgN) {
        if ($script:CfgIndents[$script:CfgI] -ne $Ind) { break }
        $content = $script:CfgLines[$script:CfgI]
        if ($content -eq '-' -or $content.StartsWith('- ')) { break }
        if (-not (Get-CfgMapEntryKey $content)) {
            New-CfgParseFailure -Index $script:CfgI
            return
        }
        $key = $script:CfgKey
        $rest = $script:CfgRestText
        if ($seen.ContainsKey($key)) {
            New-CfgDuplicateKeyFailure -Index $script:CfgI -Key $key -FirstLine $seen[$key]
            return
        }
        $seen[$key] = $script:CfgLineNos[$script:CfgI]
        $script:CfgI++
        if ($rest -ne '') {
            $map[$key] = Convert-CfgScalar $rest
        }
        elseif ($script:CfgI -lt $script:CfgN -and $script:CfgIndents[$script:CfgI] -gt $Ind) {
            Read-CfgValue
            if ($script:CfgErr) { return }
            $map[$key] = $script:CfgRet
        }
        elseif ($script:CfgI -lt $script:CfgN -and $script:CfgIndents[$script:CfgI] -eq $Ind -and
                ($script:CfgLines[$script:CfgI] -eq '-' -or $script:CfgLines[$script:CfgI].StartsWith('- '))) {
            # A block sequence may sit at its PARENT KEY's indentation rather than
            # under it. Both forms are valid YAML and this one is PyYAML's default
            # — which matters because PyYAML is what `specify extension add`
            # serialises the hook registry with:
            #
            #     hooks:
            #       before_specify:
            #       - extension: jira        <- same indent as the key
            #
            # Requiring a greater indent made this reader stop at the key and
            # return null for its value, so the registry of every real
            # installation parsed as `{"installed":null}` and hook health called a
            # healthy repository unreadable (003 T011).
            Read-CfgSequence $Ind
            if ($script:CfgErr) { return }
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
                if ($script:CfgErr) { return }
                $items.Add($script:CfgRet)
            }
            else { $items.Add($null) }
        }
        elseif (Test-CfgMapEntry $rest) {
            # The dash introduces a mapping whose first key sits at column Ind+2.
            $script:CfgLines[$script:CfgI] = $rest
            $script:CfgIndents[$script:CfgI] = $Ind + 2
            Read-CfgMapping ($Ind + 2)
            if ($script:CfgErr) { return }
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
    <#
    .SYNOPSIS
      Parse the YAML subset into a structure. Throws the located
      parse-failure message (contracts/parse-failure.md §2/§1) when a line
      cannot be interpreted as a mapping entry, or a key repeats at its own
      mapping level (FR-016) — the message text is byte-identical to the Bash
      port's, minus the trailing exit code, which the Bash function returns
      separately.
    #>
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "config: file not found: $Path" }
    Initialize-CfgBuffer $Path
    Read-CfgValue
    if ($script:CfgErr) { throw $script:CfgErr }
    return $script:CfgRet
}

function ConvertFrom-JiraConfigYaml {
    <#
    .SYNOPSIS
      Parse the YAML subset and return canonical JSON, byte-identical to the Bash
      port's config_yaml_to_json. On a parse failure, prints the located message
      to stderr (mirroring config_yaml_to_json's own print) and re-throws —
      nothing is returned on stdout for a document this reader cannot interpret
      in full (contracts/parse-failure.md §4).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    try {
        $obj = Read-JiraConfigYamlObject -Path $Path
    }
    catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        throw
    }
    return (ConvertTo-JiraJsonValue $obj)
}

# =============================================================================
# JSON -> canonical YAML (T044) — the deterministic writer. Mirror of
# config_to_yaml; emits byte-identical output.
# =============================================================================

function ConvertTo-CfgEscape {
    <#
    .SYNOPSIS
      Encode a string for emission inside double quotes (contracts/
      yaml-string-escaping.md §1.1): backslash first, then quote. Reversing
      the order double-escapes the backslash the first replacement introduces.
      Mirror of the Bash writer's `yesc` jq def.
    #>
    param([string] $Value)
    return $Value.Replace('\', '\\').Replace('"', '\"')
}

function Write-CfgYamlScalar {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [string]) { return '"' + (ConvertTo-CfgEscape $Value) + '"' }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or
        $Value -is [decimal] -or $Value -is [single]) {
        return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0}', $Value)
    }
    return '"' + [string]$Value + '"'
}

function Test-CfgUnrepresentable {
    # True when a string contains LF or CR, which cannot be represented on a
    # single line — mirror of the Bash writer's badchars jq def (contract
    # yaml-string-escaping.md §1.4).
    param([string] $Value)
    return ($Value.IndexOf("`n") -ge 0 -or $Value.IndexOf("`r") -ge 0)
}

function Get-CfgWriteRefusalError {
    <#
    .SYNOPSIS
      Walk a parsed structure and return every deduplicated "<path>: <reason>"
      for a key or string value the writer cannot represent (contract §2.3),
      sorted so both ports report offending paths in the same order. The
      value itself is never included — only the path at which it occurred.
      Mirror of _cfg_write_refusal_errors (bash's `unique | .[]`).
    #>
    param($Node, [string] $Path)

    $errors = [System.Collections.Generic.List[string]]::new()
    Get-CfgWriteRefusalErrors -Node $Node -Path $Path -Errors $errors
    if ($errors.Count -eq 0) { return $null }
    $sorted = $errors | Sort-Object -Unique
    return ($sorted -join "`n")
}

function Get-CfgWriteRefusalErrors {
    param($Node, [string] $Path, [System.Collections.Generic.List[string]] $Errors)

    if ($Node -is [System.Collections.IDictionary] -or $Node -is [System.Management.Automation.PSCustomObject]) {
        $map = [ordered]@{}
        if ($Node -is [System.Collections.IDictionary]) { foreach ($k in $Node.Keys) { $map[[string]$k] = $Node[$k] } }
        else { foreach ($p in $Node.PSObject.Properties) { $map[[string]$p.Name] = $p.Value } }
        foreach ($k in $map.Keys) {
            $childPath = if ($Path -eq '') { [string]$k } else { "$Path.$k" }
            if (Test-CfgUnrepresentable ([string]$k)) {
                $Errors.Add("${Path}: a key here contains a line break, which this writer cannot represent")
                continue
            }
            Get-CfgWriteRefusalErrors -Node $map[$k] -Path $childPath -Errors $Errors
        }
        return
    }
    if (($Node -is [System.Collections.IEnumerable]) -and ($Node -isnot [string])) {
        $i = 0
        foreach ($item in $Node) {
            Get-CfgWriteRefusalErrors -Node $item -Path "$Path[$i]" -Errors $Errors
            $i++
        }
        return
    }
    if ($Node -is [string] -and (Test-CfgUnrepresentable $Node)) {
        $Errors.Add("${Path}: a string value here contains a line break, which this writer cannot represent")
    }
}

function Write-CfgYamlNode {
    # Recursively emit a parsed value as canonical YAML lines (2-space indent,
    # sorted object keys ordinal, `- ` sequences, every key double-quoted).
    # Returns the joined lines with no trailing newline — byte-identical to the
    # Bash emitter's jq program.
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
            $qk = '"' + (ConvertTo-CfgEscape $k) + '"'
            if ($v -is [System.Collections.IDictionary] -or $v -is [System.Management.Automation.PSCustomObject]) {
                $childCount = @($(if ($v -is [System.Collections.IDictionary]) { $v.Keys } else { $v.PSObject.Properties })).Count
                if ($childCount -eq 0) { "$Ind${qk}: {}" }
                else { "$Ind${qk}:`n" + (Write-CfgYamlNode $v ($Ind + '  ')) }
            }
            elseif (($v -is [System.Collections.IEnumerable]) -and ($v -isnot [string])) {
                if (@($v).Count -eq 0) { "$Ind${qk}: []" }
                else { "$Ind${qk}:`n" + (Write-CfgYamlNode $v ($Ind + '  ')) }
            }
            else { "$Ind${qk}: " + (Write-CfgYamlScalar $v) }
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
      Every key is quoted unconditionally (contract yaml-key-grammar.md §2.1).
      `"` and `\` are escaped rather than refused (research R3). Throws when a
      key or string value contains a line break, which this writer cannot
      represent (research R5/R8) — the value itself never appears in the
      exception message (Constitution IV).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Json)
    $obj = $Json | ConvertFrom-Json -Depth 100
    $refusal = Get-CfgWriteRefusalError $obj ''
    if ($refusal) {
        $prefixed = ($refusal -split "`n") | ForEach-Object { "config: $_" }
        throw ($prefixed -join "`n")
    }
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
        foreach ($k in (Get-JiraOrdinalSorted $Node.Keys)) {
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

function Test-JiraBranchPattern {
    # A branch_pattern (002 US3, FR-010) contains <ID> and <FEATURE_NAME> exactly
    # once each; every other character is in [a-z0-9/_-]. Mirror of the Bash
    # port's `branchpattern` jq def.
    param($Pattern)
    if ($Pattern -isnot [string]) { return $false }
    $idCount = ([regex]::Matches($Pattern, '<ID>')).Count
    $fnCount = ([regex]::Matches($Pattern, '<FEATURE_NAME>')).Count
    if ($idCount -ne 1 -or $fnCount -ne 1) { return $false }
    $stripped = $Pattern.Replace('<ID>', '').Replace('<FEATURE_NAME>', '')
    return ($stripped -cmatch '^[a-z0-9/_-]*$')
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

    $allowedTop = @('version_compat', 'projects', 'routing', 'routing_default', 'privacy', 'teams', 'field_defaults')
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($k in (Get-JiraOrdinalSorted $Object.Keys)) {
            if ($allowedTop -cnotcontains [string]$k) { $errs.Add("unknown top-level key: $k") }
        }
    }

    # field_defaults (011, research R1, data-model.md §1): project -> issue
    # type -> label -> value, with a per-project `ask` switch. Mirror of the
    # Bash port's _CFG_TEAM_ERRORS_JQ addition. Issue-type/field-label
    # existence is the ceremony's job, not this schema check's (data-model.md
    # §1 "Validation").
    $declaredKeys = [System.Collections.Generic.List[string]]::new()
    if ($isArray) { foreach ($p in $projects) { $declaredKeys.Add([string](Get-CfgProp $p 'key')) } }
    $fieldDefaults = Get-CfgProp $Object 'field_defaults'
    if ($fieldDefaults -is [System.Collections.IDictionary]) {
        foreach ($pk in (Get-JiraOrdinalSorted $fieldDefaults.Keys)) {
            $pv = $fieldDefaults[[string]$pk]
            if (-not $declaredKeys.Contains([string]$pk)) {
                $errs.Add("field_defaults.$pk names a project key that is not declared in projects[]")
                continue
            }
            if ($pv -isnot [System.Collections.IDictionary]) {
                $errs.Add("field_defaults.$pk must be a mapping")
                continue
            }
            if ($pv.Contains('ask') -and ($pv['ask'] -isnot [bool])) {
                $errs.Add("field_defaults.$pk.ask must be a boolean")
            }
            foreach ($ftype in (Get-JiraOrdinalSorted $pv.Keys)) {
                if ([string]$ftype -ceq 'ask') { continue }
                $fields = $pv[[string]$ftype]
                if ($fields -isnot [System.Collections.IDictionary]) {
                    $errs.Add("field_defaults.$pk.$ftype must be a mapping of field label to value")
                    continue
                }
                foreach ($label in (Get-JiraOrdinalSorted $fields.Keys)) {
                    $v = $fields[[string]$label]
                    $isScalar = ($v -is [string]) -or ($v -is [bool]) -or ($v -is [int]) -or ($v -is [long]) -or ($v -is [double])
                    if (-not $isScalar -or ($v -ceq '')) {
                        $errs.Add("field_defaults.$pk.$ftype.$label must be a non-empty value")
                    }
                }
            }
        }
    }

    # Team convention catalogue (002 US3, FR-010/FR-018) — optional. Mirror of the
    # Bash port's _CFG_TEAM_ERRORS_JQ: per-entry field validation then id /
    # folder_prefix uniqueness. Error strings are byte-identical across ports.
    $teams = Get-CfgProp $Object 'teams'
    $teamsIsArray = ($teams -is [System.Collections.IEnumerable]) -and ($teams -isnot [string])
    if ($teamsIsArray) {
        $seenIds = [System.Collections.Generic.List[string]]::new()
        $seenPrefixes = [System.Collections.Generic.List[string]]::new()
        $ti = 0
        foreach ($t in $teams) {
            $tid = [string](Get-CfgProp $t 'id')
            if ($tid -cnotmatch '^[a-z][a-z0-9]*$') { $errs.Add("teams[$ti].id is invalid") }
            $tproj = [string](Get-CfgProp $t 'project')
            if ($tproj -cnotmatch '^[A-Z][A-Z0-9_]+$') { $errs.Add("teams[$ti].project is not a valid project key") }
            $tprefix = [string](Get-CfgProp $t 'folder_prefix')
            if ($tprefix -cnotmatch '^[a-z0-9][a-z0-9-]*-$') { $errs.Add("teams[$ti].folder_prefix is invalid") }
            $tpat = Get-CfgProp $t 'branch_pattern'
            if (-not (Test-JiraBranchPattern $tpat)) { $errs.Add("teams[$ti].branch_pattern is invalid") }
            if ($seenIds.Contains($tid)) { $errs.Add("teams[$ti].id duplicates an earlier team id") }
            if ($seenPrefixes.Contains($tprefix)) { $errs.Add("teams[$ti].folder_prefix duplicates an earlier folder_prefix") }
            $seenIds.Add($tid)
            $seenPrefixes.Add($tprefix)
            $ti++
        }
    }

    if ($isArray) {
        $i = 0
        foreach ($p in $projects) {
            $key = Get-CfgProp $p 'key'
            if (($key -isnot [string]) -or ($key -cnotmatch '^[A-Z][A-Z0-9_]+$')) { $errs.Add("projects[$i].key is not a valid project key") }
            $hasStyle = ($p -is [System.Collections.IDictionary]) -and $p.Contains('style')
            if ($hasStyle) {
                $style = Get-CfgProp $p 'style'
                if (@('company_managed', 'team_managed') -cnotcontains $style) { $errs.Add("projects[$i].style is invalid") }
            }
            # epic_strategy, task_strategy and link_type are retired (008
            # T029/T032a, FR-030/FR-031) and the link-type requirement they
            # carried retires with them.
            foreach ($retired in @('epic_strategy', 'task_strategy', 'link_type')) {
                if (($p -is [System.Collections.IDictionary]) -and $p.Contains($retired)) {
                    $errs.Add("projects[$i] declares ``$retired``, which this version of spec-kit-jira no longer uses. Delete the line")
                }
            }
            if (($p -is [System.Collections.IDictionary]) -and $p.Contains('phase_status_map')) {
                $psm = Get-CfgProp $p 'phase_status_map'
                $psmValid = $psm -is [System.Collections.IDictionary]
                if ($psmValid) { foreach ($v in $psm.Values) { if ($v -isnot [string]) { $psmValid = $false } } }
                if (-not $psmValid) { $errs.Add("projects[$i].phase_status_map must be a mapping of lifecycle-event name to status name") }
            }
            # halted_statuses is normally an array, but the team-config YAML
            # reader does not parse an inline flow-style list ("[Blocked]") —
            # only a block-style one — so a declaration written that way
            # arrives here as a plain string; _reconcile_halted_statuses (the
            # Bash mirror: Get-JiraReconcileHaltedStatuses) already recovers
            # it. A string is therefore accepted here too, not just an array.
            if (($p -is [System.Collections.IDictionary]) -and $p.Contains('halted_statuses')) {
                $hs = Get-CfgProp $p 'halted_statuses'
                $hsValid = ($hs -is [string]) -or (($hs -is [System.Collections.IEnumerable]) -and ($hs -isnot [System.Collections.IDictionary]))
                if (-not $hsValid) { $errs.Add("projects[$i].halted_statuses must be a list of status names") }
            }
            # hierarchy (010, data-model.md §2): the committed declaration —
            # role -> issue type NAME. Mirror of the Bash port's
            # _CFG_TEAM_ERRORS_JQ hierarchy clause.
            if (($p -is [System.Collections.IDictionary]) -and $p.Contains('hierarchy')) {
                $h = Get-CfgProp $p 'hierarchy'
                if ($h -isnot [System.Collections.IDictionary]) {
                    $errs.Add("projects[$i].hierarchy must be a mapping of role to issue type name")
                }
                else {
                    foreach ($role in (Get-JiraOrdinalSorted $h.Keys)) {
                        if ($script:JiraRoleNames -cnotcontains [string]$role) {
                            $errs.Add("projects[$i].hierarchy declares unknown role ``$role``; the roles are specification, story, task")
                        }
                    }
                    foreach ($role in (Get-JiraOrdinalSorted $h.Keys)) {
                        $v = $h[[string]$role]
                        if (($v -isnot [string]) -or ($v -ceq '')) {
                            $errs.Add("projects[$i].hierarchy.$role must be a non-empty issue type name")
                        }
                    }
                }
            }
            $i++
        }
    }
    return $errs.ToArray()
}

function Test-JiraLocalConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Object)
    $errs = [System.Collections.Generic.List[string]]::new()
    $allowed = @('site_alias', 'resolved_ids', 'overrides', 'hooks')
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($k in (Get-JiraOrdinalSorted $Object.Keys)) {
            if ($allowed -cnotcontains [string]$k) { $errs.Add("unknown config.local key: $k") }
        }
    }
    # The operator disable record (003 FR-029). Only the SHAPE is validated
    # here: an event name outside the closed set is reported and ignored at read
    # time, not refused, because this file is human-editable and a typo must not
    # break mirroring. Same error strings as the Bash port's jq program.
    $hooks = Get-CfgProp $Object 'hooks'
    if ($null -ne $hooks) {
        if ($hooks -isnot [System.Collections.IDictionary]) { $errs.Add('hooks must be a mapping') }
        else {
            foreach ($k in (Get-JiraOrdinalSorted $hooks.Keys)) {
                if ([string]$k -cne 'disabled') { $errs.Add("unknown hooks key: $k") }
            }
            if ($hooks.Contains('disabled')) {
                $d = $hooks['disabled']
                if (($d -is [string]) -or (($null -ne $d) -and ($d -isnot [System.Collections.IEnumerable]))) {
                    $errs.Add('hooks.disabled must be a list of lifecycle event names')
                }
            }
        }
    }
    # Per-project style provenance keys (002 US1): when present under a
    # resolved_ids entry they must carry the enum values — same error strings as
    # the Bash port's jq program.
    $rids = Get-CfgProp $Object 'resolved_ids'
    if ($rids -is [System.Collections.IDictionary]) {
        foreach ($k in (Get-JiraOrdinalSorted $rids.Keys)) {
            $v = $rids[[string]$k]
            if ($v -isnot [System.Collections.IDictionary]) { continue }
            if ($v.Contains('style') -and (@('company_managed', 'team_managed') -cnotcontains $v['style'])) {
                $errs.Add("resolved_ids.$k.style is invalid")
            }
            if ($v.Contains('style_source') -and (@('api', 'operator') -cnotcontains $v['style_source'])) {
                $errs.Add("resolved_ids.$k.style_source is invalid")
            }
            # roles (010, data-model.md §3): the resolved role binding.
            # Mirror of the Bash port's _CFG_LOCAL_ERRORS_JQ roles clause.
            if ($v.Contains('roles')) {
                $roles = $v['roles']
                if ($roles -isnot [System.Collections.IDictionary]) {
                    $errs.Add("resolved_ids.$k.roles must be a mapping")
                }
                else {
                    foreach ($role in (Get-JiraOrdinalSorted $roles.Keys)) {
                        if ($script:JiraRoleNames -cnotcontains [string]$role) {
                            $errs.Add("resolved_ids.$k.roles declares unknown role ``$role``")
                        }
                        $rv = $roles[[string]$role]
                        if (($rv -is [System.Collections.IDictionary]) -and $rv.Contains('source')) {
                            if (@('declared', 'operator', 'derived') -cnotcontains $rv['source']) {
                                $errs.Add("resolved_ids.$k.roles.$role.source is invalid")
                            }
                        }
                    }
                }
            }
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
        $errors.Add($_.Exception.Message)
        [Console]::Error.WriteLine($errors[-1])
        return [pscustomobject]@{ ExitCode = $script:ExitConfig; Json = ''; Errors = $errors.ToArray() }
    }

    if (& $fail 'credential' $team (Get-JiraConfigCredentialError $teamObj)) { return [pscustomobject]@{ ExitCode = $script:ExitConfig; Json = ''; Errors = $errors.ToArray() } }
    if (& $fail 'schema' $team (Test-JiraTeamConfig $teamObj)) { return [pscustomobject]@{ ExitCode = $script:ExitConfig; Json = ''; Errors = $errors.ToArray() } }

    $merged = $teamObj
    if (Test-Path -LiteralPath $localF) {
        try { $localObj = Read-JiraConfigYamlObject -Path $localF }
        catch {
            $errors.Add($_.Exception.Message)
            [Console]::Error.WriteLine($errors[-1])
            return [pscustomobject]@{ ExitCode = $script:ExitConfig; Json = ''; Errors = $errors.ToArray() }
        }
        # An EMPTY local binding parses to $null, and that is a legitimate state,
        # not an error: releasing the last held event leaves the file with nothing
        # in it. Refusing here would mean clearing the last disabled hook broke
        # every subsequent run of the ceremony. The Bash port tolerates it by
        # construction (jq treats the null document as having no keys); this makes
        # the two ports agree explicitly rather than by luck (Constitution VI).
        if ($null -eq $localObj) { $localObj = [ordered]@{} }
        if (& $fail 'credential' $localF (Get-JiraConfigCredentialError $localObj)) { return [pscustomobject]@{ ExitCode = $script:ExitConfig; Json = ''; Errors = $errors.ToArray() } }
        if (& $fail 'schema' $localF (Test-JiraLocalConfig $localObj)) { return [pscustomobject]@{ ExitCode = $script:ExitConfig; Json = ''; Errors = $errors.ToArray() } }
        $overrides = Get-CfgProp $localObj 'overrides'
        if ($null -eq $overrides) { $overrides = [ordered]@{} }
        $merged = Merge-CfgObject $teamObj $overrides
    }

    return [pscustomobject]@{ ExitCode = 0; Json = (ConvertTo-JiraJsonValue $merged); Errors = @() }
}

function Test-JiraPersonalObject {
    # Personal-file schema (002 US3) — mirror of _CFG_PERSONAL_ERRORS_JQ.
    param([Parameter(Mandatory)] $Object)
    $errs = [System.Collections.Generic.List[string]]::new()
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($k in (Get-JiraOrdinalSorted $Object.Keys)) {
            if (@('team', 'override') -cnotcontains [string]$k) { $errs.Add("unknown personal key: $k") }
        }
    }
    $team = [string](Get-CfgProp $Object 'team')
    if ($team -cnotmatch '^[a-z][a-z0-9]*$') { $errs.Add('team is invalid') }
    $override = Get-CfgProp $Object 'override'
    if ($null -ne $override -and $override -is [System.Collections.IDictionary]) {
        foreach ($k in (Get-JiraOrdinalSorted $override.Keys)) {
            if (@('folder_prefix', 'branch_pattern') -cnotcontains [string]$k) { $errs.Add("unknown override key: $k") }
        }
        if ($override.Contains('folder_prefix')) {
            $fp = [string](Get-CfgProp $override 'folder_prefix')
            if ($fp -cnotmatch '^[a-z0-9][a-z0-9-]*-$') { $errs.Add('override.folder_prefix is invalid') }
        }
        if ($override.Contains('branch_pattern')) {
            if (-not (Test-JiraBranchPattern (Get-CfgProp $override 'branch_pattern'))) { $errs.Add('override.branch_pattern is invalid') }
        }
    }
    return $errs.ToArray()
}

function Import-JiraPersonalConfig {
    <#
    .SYNOPSIS
      Load the human-owned personal team selection (.specify/jira/personal.yml).
      NEVER writes the file. Absent file => {active:false}. An invalid file or an
      unknown team fails closed (ExitCode 4). Mirror of config_personal_load.
      Returns { ExitCode; Json; Errors }.
    #>
    [CmdletBinding()]
    param(
        [string] $ConfigDir = (Get-JiraConfigDirPath),
        [string] $MergedJson = '{}'
    )
    $errors = [System.Collections.Generic.List[string]]::new()
    $pf = Join-Path $ConfigDir 'personal.yml'
    if (-not (Test-Path -LiteralPath $pf)) {
        return [pscustomobject]@{ ExitCode = 0; Json = '{"active":false}'; Errors = $errors }
    }

    $fail = {
        param($line)
        $errors.Add($line)
        [Console]::Error.WriteLine($line)
        return [pscustomobject]@{ ExitCode = $script:ExitConfig; Json = ''; Errors = $errors }
    }

    try { $pObj = Read-JiraConfigYamlObject -Path $pf }
    catch {
        return (& $fail $_.Exception.Message)
    }

    $emit = {
        param($label, $lines)
        $any = $false
        foreach ($l in $lines) {
            if ([string]::IsNullOrEmpty($l)) { continue }
            $any = $true
            $errors.Add("config: $label ($pf): $l")
            [Console]::Error.WriteLine("config: $label ($pf): $l")
        }
        return $any
    }
    if (& $emit 'credential' (Get-JiraConfigCredentialError $pObj)) { return [pscustomobject]@{ ExitCode = $script:ExitConfig; Json = ''; Errors = $errors } }
    if (& $emit 'personal' (Test-JiraPersonalObject $pObj)) { return [pscustomobject]@{ ExitCode = $script:ExitConfig; Json = ''; Errors = $errors } }

    $cfg = $MergedJson | ConvertFrom-Json -Depth 100
    $team = [string](Get-CfgProp $pObj 'team')
    $ids = [System.Collections.Generic.List[string]]::new()
    if ($cfg.PSObject.Properties['teams'] -and $null -ne $cfg.teams) {
        foreach ($t in @($cfg.teams)) { if ($t.PSObject.Properties['id']) { $ids.Add([string]$t.id) } }
    }
    if (-not $ids.Contains($team)) {
        $list = if ($ids.Count -gt 0) { $ids -join ', ' } else { '(none)' }
        return (& $fail "config: personal ($pf): unknown team `"$team`" — valid teams: $list")
    }

    $override = Get-CfgProp $pObj 'override'
    $result = [ordered]@{ active = $true; team = $team; override = $override }
    return [pscustomobject]@{ ExitCode = 0; Json = (ConvertTo-JiraJsonValue $result); Errors = $errors }
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
    foreach ($v in (Get-JiraOrdinalSorted $values -Unique)) { $distinct.Add($v) }
    return (ConvertTo-JiraJsonValue $distinct)
}

# =============================================================================
# The operator disable record (003 T013, FR-007/FR-029). Mirror of the
# config_hooks_disabled_* functions in lib/config.sh.
# =============================================================================
#
# `specify extension add` writes `enabled: true` unconditionally for every entry
# it re-adds, with no read of the existing value (003 research R5). So the hook
# registry CANNOT remember that the operator disabled an event: the next install
# or upgrade silently re-enables it. Constitution X forbids that outcome, and
# FR-022 forbids the obvious fix of writing the value back.
#
# The decision is therefore recorded here instead, in the gitignored local
# binding, which lives outside `.specify/extensions/` and survives a reinstall by
# Principle V — and it is honoured at DISPATCH, so it holds even in the window
# between an install that re-enabled the entry and the next ceremony.

# The closed set of seven lifecycle events — the `hooks.disabled` enum of
# contracts/config.local.schema.json. Declared here because this module encodes
# that schema; hooks/RegisterHooks.psm1 consumes it rather than redeclaring it,
# so the set has exactly one source per port (data-model § Lifecycle event).
$script:JiraHookEventNames = @(
    'before_specify', 'after_specify', 'after_clarify', 'after_plan',
    'after_tasks', 'after_implement', 'after_analyze'
)

# =============================================================================
# The role set (010, data-model.md §1) — closed, three, engine-side
# =============================================================================
#
# The repository's own artifact vocabulary — specification, story, task —
# never Jira's. Declared once per port, following the JiraHookEventNames
# precedent, so the closed set has exactly one source; sink/jira/
# Hierarchy.psm1 consumes it rather than redeclaring it.
$script:JiraRoleNames = @('specification', 'story', 'task')

function Get-JiraHookEventNameList {
    return $script:JiraHookEventNames
}

function Get-JiraRoleNameList {
    return $script:JiraRoleNames
}

function Get-JiraFieldDefaultsFor {
    <#
    .SYNOPSIS
      One project's `field_defaults` entry (011, data-model.md §1): {ask;
      <Type>: {<Label>: <Value>}, ...}. `ask` defaults to $true when the
      project records none at all (FR-014). A project with no field_defaults
      entry gets {ask=$true} and nothing else (research R6: absence is the
      off switch). Mirror of config_field_defaults_for.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ProjectKey, [Parameter(Mandatory)] [string] $ConfigJson)
    # $cfg is a PSCustomObject (ConvertFrom-Json), not the IDictionary
    # Get-CfgProp expects from the YAML reader's internal shape — property
    # access here is direct rather than through that helper.
    $cfg = $ConfigJson | ConvertFrom-Json -Depth 100
    $fd = [ordered]@{}
    $all = $cfg.PSObject.Properties['field_defaults']
    if ($null -ne $all -and $null -ne $all.Value) {
        $entryProp = $all.Value.PSObject.Properties[$ProjectKey]
        if ($null -ne $entryProp -and $null -ne $entryProp.Value) {
            foreach ($p in $entryProp.Value.PSObject.Properties) { $fd[$p.Name] = $p.Value }
        }
    }
    $ask = $true
    if ($fd.Contains('ask')) { $ask = [bool] $fd['ask']; $fd.Remove('ask') }
    $result = [ordered]@{ ask = $ask }
    foreach ($k in $fd.Keys) { $result[$k] = $fd[$k] }
    return (ConvertTo-JiraJsonValue $result)
}

function Get-JiraFieldDefaultsYaml {
    <#
    .SYNOPSIS
      The canonical YAML text of the whole top-level `field_defaults:`
      mapping (011, T042). Mirror of config_field_defaults_yaml — reuses
      ConvertTo-JiraConfigYaml's scalar quoting/refusal rules rather than a
      second renderer. No trailing newline; the caller adds exactly one.
    #>
    [CmdletBinding()]
    param([string] $MapJson = '{}')
    if ([string]::IsNullOrEmpty($MapJson)) { $MapJson = '{}' }
    $wrapped = ConvertTo-JiraJsonValue ([ordered]@{ field_defaults = ($MapJson | ConvertFrom-Json -Depth 100) })
    return (ConvertTo-JiraConfigYaml -Json $wrapped)
}

function Get-CfgLocalPath {
    param([string] $ConfigDir = (Get-JiraConfigDirPath))
    return (Join-Path $ConfigDir 'config.local.yml')
}

function Get-CfgLocalObject {
    <#
    .SYNOPSIS
      The local binding as a parsed object. An ABSENT file yields an empty
      map (never bound). A PRESENT-but-unreadable file THROWS the located
      parse-failure message: an unreadable binding is not evidence of an
      empty one, and swallowing it here was the defect this feature closes
      (research R5). Mirror of _cfg_local_json.
    #>
    param([string] $ConfigDir = (Get-JiraConfigDirPath))
    $f = Get-CfgLocalPath -ConfigDir $ConfigDir
    if (-not (Test-Path -LiteralPath $f)) { return [ordered]@{} }
    $o = Read-JiraConfigYamlObject -Path $f
    if ($o -isnot [System.Collections.IDictionary]) { return [ordered]@{} }
    return $o
}

function Get-JiraHooksDisabled {
    <#
    .SYNOPSIS
      The recorded set as a canonical JSON array of event names, sorted and
      deduplicated. An absent record is the empty set. A name outside the closed
      set is REPORTED on stderr and ignored rather than failing the run: this
      file is human-editable and a typo must not stop the mirror.
      Mirror of config_hooks_disabled_read.
    #>
    [CmdletBinding()]
    param([string] $ConfigDir = (Get-JiraConfigDirPath))

    $obj = Get-CfgLocalObject -ConfigDir $ConfigDir
    $hooks = Get-CfgProp $obj 'hooks'
    $raw = @()
    if ($hooks -is [System.Collections.IDictionary] -and $hooks.Contains('disabled')) {
        $d = $hooks['disabled']
        if (($null -ne $d) -and ($d -isnot [string]) -and ($d -is [System.Collections.IEnumerable])) { $raw = @($d) }
    }

    $known = [System.Collections.Generic.List[string]]::new()
    $unknown = [System.Collections.Generic.List[string]]::new()
    foreach ($x in $raw) {
        $s = [string]$x
        if ($script:JiraHookEventNames -ccontains $s) {
            if (-not $known.Contains($s)) { $known.Add($s) }
        }
        elseif (-not $unknown.Contains($s)) { $unknown.Add($s) }
    }
    foreach ($u in ($unknown | Sort-Object)) {
        [Console]::Error.WriteLine("config: $(Get-CfgLocalPath -ConfigDir $ConfigDir): unknown lifecycle event in hooks.disabled: $u — ignored")
    }
    $sorted = [string[]]@($known)
    [System.Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    return (ConvertTo-JiraJsonValue $sorted)
}

function Set-CfgHooksDisabled {
    # Persist the record, preserving every other key the operator owns
    # (site_alias, overrides) and every machine-owned key (resolved_ids). Writes
    # through the canonical serialiser, so a re-run producing the same set writes
    # byte-identical bytes. Mirror of _cfg_hooks_disabled_set.
    param([string] $ConfigDir, [bool] $DryRun, [string[]] $NewSet)
    if ($DryRun) { return }

    $obj = Get-CfgLocalObject -ConfigDir $ConfigDir
    $map = [ordered]@{}
    foreach ($k in $obj.Keys) { $map[[string]$k] = $obj[$k] }

    $hooks = [ordered]@{}
    if ($map.Contains('hooks') -and ($map['hooks'] -is [System.Collections.IDictionary])) {
        foreach ($k in $map['hooks'].Keys) { if ([string]$k -cne 'disabled') { $hooks[[string]$k] = $map['hooks'][$k] } }
    }
    if ($NewSet.Count -gt 0) { $hooks['disabled'] = $NewSet }

    if ($hooks.Count -eq 0) { $map.Remove('hooks') } else { $map['hooks'] = $hooks }

    $yaml = ConvertTo-JiraConfigYaml -Json (ConvertTo-JiraJsonValue $map)
    if (-not (Test-Path -LiteralPath $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
    [System.IO.File]::WriteAllText((Get-CfgLocalPath -ConfigDir $ConfigDir), $yaml + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Add-JiraHooksDisabled {
    <#
    .SYNOPSIS
      Record the operator's decision to disable one event. Returns `recorded`,
      `unchanged`, or `ignored` (an unknown name). Under -DryRun the status is
      computed and nothing is written (Constitution XI). Never fails the run.
      Mirror of config_hooks_disabled_add.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $LifecycleEvent,
        [string] $ConfigDir = (Get-JiraConfigDirPath),
        [bool] $DryRun = $false
    )
    if ($script:JiraHookEventNames -cnotcontains $LifecycleEvent) {
        [Console]::Error.WriteLine("config: not a lifecycle event: $LifecycleEvent — nothing recorded")
        return 'ignored'
    }
    $current = @((Get-JiraHooksDisabled -ConfigDir $ConfigDir) | ConvertFrom-Json)
    if ($current -ccontains $LifecycleEvent) { return 'unchanged' }
    $next = [string[]]@(@($current) + @($LifecycleEvent))
    [System.Array]::Sort($next, [System.StringComparer]::Ordinal)
    Set-CfgHooksDisabled -ConfigDir $ConfigDir -DryRun $DryRun -NewSet $next
    return 'recorded'
}

function Remove-JiraHooksDisabled {
    <#
    .SYNOPSIS
      The operator's explicit release (FR-029: removable only by an explicit
      operator action). Returns `released` or `unrecorded`. Under -DryRun the
      status is computed and nothing is written (Constitution XI).
      Mirror of config_hooks_disabled_remove.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $LifecycleEvent,
        [string] $ConfigDir = (Get-JiraConfigDirPath),
        [bool] $DryRun = $false
    )
    $current = @((Get-JiraHooksDisabled -ConfigDir $ConfigDir) | ConvertFrom-Json)
    if ($current -cnotcontains $LifecycleEvent) { return 'unrecorded' }
    $next = [string[]]@($current | Where-Object { $_ -cne $LifecycleEvent })
    Set-CfgHooksDisabled -ConfigDir $ConfigDir -DryRun $DryRun -NewSet $next
    return 'released'
}

Export-ModuleMember -Function Get-JiraExtensionVersion, Assert-JiraSingleVersionSource, `
    ConvertFrom-JiraConfigYaml, ConvertTo-JiraConfigYaml, Read-JiraConfigYamlObject, `
    Get-JiraConfigCredentialError, Test-JiraTeamConfig, Test-JiraLocalConfig, Import-JiraConfig, `
    Import-JiraPersonalConfig, `
    Get-JiraStatusClassification, Get-JiraPhaseStatusTargetSet, `
    Test-JiraPlaceholderKey, Get-JiraPlaceholderKey, `
    Get-JiraHookEventNameList, Get-JiraHooksDisabled, Add-JiraHooksDisabled, Remove-JiraHooksDisabled, `
    Get-CfgLocalPath, Get-CfgLocalObject, Get-JiraRoleNameList, Get-JiraFieldDefaultsFor, `
    Get-JiraFieldDefaultsYaml
