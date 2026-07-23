# lib/Output.psm1 — Canonical serialisation + run-summary rendering.
# Mirror of lib/output.sh.
#
# The canonical serialiser is the byte-parity contract (Constitution VI, NFR-1,
# research §11). ConvertTo-Json does NOT match jq's formatting/escaping/ordering,
# so this port reimplements the same canonical form directly:
#   - keys sorted by Unicode code point (ordinal), compact, no whitespace
#   - raw UTF-8 (no \u escaping of non-ASCII), no trailing newline
#   - escapes only " \ and the control set \b \f \n \r \t, else \u00XX
#
# Port infrastructure only: NO Jira knowledge.

Set-StrictMode -Version Latest

function ConvertTo-JiraJsonString {
    # Escape a string exactly as jq does for a JSON string value.
    param([string] $Value)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('"')
    foreach ($ch in $Value.ToCharArray()) {
        $code = [int][char]$ch
        switch ($ch) {
            '"' { [void]$sb.Append('\"'); continue }
            '\' { [void]$sb.Append('\\'); continue }
            "`b" { [void]$sb.Append('\b'); continue }
            "`f" { [void]$sb.Append('\f'); continue }
            "`n" { [void]$sb.Append('\n'); continue }
            "`r" { [void]$sb.Append('\r'); continue }
            "`t" { [void]$sb.Append('\t'); continue }
            default {
                if ($code -lt 0x20) {
                    [void]$sb.Append(('\u{0:x4}' -f $code))
                }
                else {
                    [void]$sb.Append($ch)
                }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-JiraJsonValue {
    # Recursively emit a parsed JSON value in canonical form.
    param($Value)

    if ($null -eq $Value) { return 'null' }

    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [string]) { return ConvertTo-JiraJsonString $Value }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int64] -or
        $Value -is [double] -or $Value -is [decimal] -or $Value -is [single] -or
        $Value -is [bigint]) {
        return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0}', $Value)
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($k in $Value.Keys) { $names.Add([string]$k) }
        $names.Sort([System.StringComparer]::Ordinal)
        $parts = foreach ($n in $names) {
            (ConvertTo-JiraJsonString $n) + ':' + (ConvertTo-JiraJsonValue $Value[$n])
        }
        return '{' + ($parts -join ',') + '}'
    }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($p in $Value.PSObject.Properties) { $names.Add([string]$p.Name) }
        $names.Sort([System.StringComparer]::Ordinal)
        $parts = foreach ($n in $names) {
            (ConvertTo-JiraJsonString $n) + ':' + (ConvertTo-JiraJsonValue $Value.$n)
        }
        return '{' + ($parts -join ',') + '}'
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = foreach ($item in $Value) { ConvertTo-JiraJsonValue $item }
        return '[' + ($parts -join ',') + ']'
    }

    # Fallback: treat as string.
    return ConvertTo-JiraJsonString ([string]$Value)
}

function ConvertTo-JiraCanonicalJson {
    <#
    .SYNOPSIS
      Emit a JSON document in the canonical form (byte-identical to `jq -cS`).
    .PARAMETER Json
      A JSON string to canonicalise.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Json)
    $parsed = $Json | ConvertFrom-Json -Depth 100
    return ConvertTo-JiraJsonValue $parsed
}

function ConvertTo-JiraUriComponent {
    <#
    .SYNOPSIS
      Percent-encode a query component exactly as `jq @uri` does, then apply the
      %20->+ normalisation (research §11). Unreserved set matches jq/encodeURIComponent.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Value)
    $unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
    $sb = [System.Text.StringBuilder]::new()
    foreach ($b in [System.Text.Encoding]::UTF8.GetBytes($Value)) {
        $ch = [char]$b
        if ($b -lt 128 -and $unreserved.IndexOf($ch) -ge 0) {
            [void]$sb.Append($ch)
        }
        else {
            [void]$sb.Append('%')
            [void]$sb.Append($b.ToString('X2'))
        }
    }
    return $sb.ToString().Replace('%20', '+')
}

function Write-JiraWarning {
    # The WARNING channel (NFR-5). Always to stderr so it never contaminates a
    # --json summary on stdout.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Message)
    [Console]::Error.WriteLine("WARNING: $Message")
}

function New-JiraSummaryJson {
    <#
    .SYNOPSIS
      Build the canonical --json run summary (run-summary.schema.json). Byte-identical
      to the Bash port's summary_build_json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Command,
        [bool] $DryRun = $false,
        [int] $Created = 0,
        [int] $Updated = 0,
        [int] $Skipped = 0,
        [int] $Warnings = 0,
        [int] $Errors = 0,
        [int] $ExitCode = 0
    )
    $obj = @{
        schema_version = '1.0'
        command        = $Command
        dry_run        = [bool]$DryRun
        counts         = @{
            created  = $Created
            updated  = $Updated
            skipped  = $Skipped
            warnings = $Warnings
            errors   = $Errors
        }
        exit_code      = $ExitCode
    }
    return ConvertTo-JiraJsonValue $obj
}

function ConvertTo-JiraSummaryProse {
    <#
    .SYNOPSIS
      Render a run-summary JSON document as human prose. Byte-identical to the
      Bash port's summary_render_prose.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Json)
    $s = $Json | ConvertFrom-Json
    $suffix = if ($s.dry_run) { ' (dry-run)' } else { '' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Command: $($s.command)$suffix")
    $lines.Add("Created: $($s.counts.created), Updated: $($s.counts.updated), Skipped: $($s.counts.skipped)")
    $lines.Add("Warnings: $($s.counts.warnings), Errors: $($s.counts.errors)")
    # The config ceremony's three effects, reported separately (FR-054), in a
    # fixed order (discovery, hooks, readme) so both ports match byte-for-byte.
    if ($s.PSObject.Properties.Name -contains 'effects') {
        $lines.Add('Effects:')
        foreach ($effect in @('discovery', 'hooks', 'readme')) {
            $e = $s.effects.$effect
            if ($null -eq $e) { continue }
            $status = $e.status
            if ([string]::IsNullOrEmpty($status)) { continue }
            $detail = if ($e.PSObject.Properties.Name -contains 'detail') { [string]$e.detail } else { '' }
            $line = "  ${effect}: $status"
            if (-not [string]::IsNullOrEmpty($detail)) { $line = "$line — $detail" }
            $lines.Add($line)
        }
    }
    $lines.Add("Exit: $($s.exit_code)")
    return (($lines -join "`n") + "`n")
}

Export-ModuleMember -Function ConvertTo-JiraCanonicalJson, ConvertTo-JiraUriComponent, `
    ConvertTo-JiraJsonValue, ConvertTo-JiraJsonString, Write-JiraWarning, `
    New-JiraSummaryJson, ConvertTo-JiraSummaryProse
