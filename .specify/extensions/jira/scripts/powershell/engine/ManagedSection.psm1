# engine/ManagedSection.psm1 — Generic managed-section byte-splice. Mirror of
# engine/managed_section.sh (US5, T063).
#
# Replaces only the region between (and including) the begin/end markers,
# preserves every byte outside it, renders the region with the host's dominant
# line ending, appends the region once when absent, and refuses malformed marker
# configurations with a located error and no content.
#
# NEUTRAL layer: zero Jira identifiers, never imports sink/. The marker tokens are
# PARAMETERS — the module knows nothing about README files or the extension.

Set-StrictMode -Version Latest

function Get-JiraManagedSectionLineEnding {
    <#
    .SYNOPSIS
      Return the dominant line-ending token, 'CRLF' or 'LF'. A file with more
      CRLF than bare-LF terminators is CRLF; everything else (including an empty
      file) is LF, so a new file always uses LF. Byte-identical to the Bash port.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $crlf = ([regex]::Matches($Text, "`r`n")).Count
    $lfTotal = ([regex]::Matches($Text, "`n")).Count
    $lfOnly = $lfTotal - $crlf
    if ($crlf -gt $lfOnly) { return 'CRLF' }
    return 'LF'
}

function Get-JiraManagedSectionLineNumber {
    # 1-based line numbers of every occurrence of $Token in $Text. Located-error
    # reporting only.
    param([string] $Text, [string] $Token)
    $nums = @()
    $idx = 0
    while (($p = $Text.IndexOf($Token, $idx)) -ge 0) {
        $nums += ($Text.Substring(0, $p) -split "`n").Count
        $idx = $p + $Token.Length
    }
    return ($nums -join ' ')
}

function Invoke-JiraManagedSectionSplice {
    <#
    .SYNOPSIS
      Splice a managed section into $Text. Returns { ExitCode; Content } — the
      same asymmetric-shape-but-identical-behaviour convention as the REST client.
      ExitCode 0 with the new bytes in Content on success; ExitCode 4 with empty
      Content (and a located error on stderr) when the markers are malformed.
    .DESCRIPTION
      $NewBlock is the full replacement region including its markers, LF-joined and
      without a trailing newline; the splice re-renders it with the host's dominant
      line ending. Every byte outside the region is preserved verbatim.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text,
        [Parameter(Mandatory)] [string] $BeginToken,
        [Parameter(Mandatory)] [string] $EndToken,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $NewBlock
    )

    $eol = Get-JiraManagedSectionLineEnding -Text $Text
    $nl = if ($eol -eq 'CRLF') { "`r`n" } else { "`n" }
    $rblock = $NewBlock.Replace("`n", $nl)

    $bcount = ([regex]::Matches($Text, [regex]::Escape($BeginToken))).Count
    $ecount = ([regex]::Matches($Text, [regex]::Escape($EndToken))).Count

    # --- Absent: append the region once at the end of the file ----------------
    if ($bcount -eq 0 -and $ecount -eq 0) {
        if ($Text.Length -eq 0) {
            return [pscustomobject]@{ ExitCode = 0; Content = ($rblock + $nl) }
        }
        $sep = ''
        if (-not $Text.EndsWith("`n")) { $sep = $nl }
        $sep = $sep + $nl
        return [pscustomobject]@{ ExitCode = 0; Content = ($Text + $sep + $rblock + $nl) }
    }

    # --- Malformed: anything other than exactly one well-ordered pair ---------
    $beginIdx = $Text.IndexOf($BeginToken)
    $endIdx = $Text.IndexOf($EndToken)
    if ($bcount -ne 1 -or $ecount -ne 1 -or $beginIdx -ge $endIdx) {
        $bl = Get-JiraManagedSectionLineNumber -Text $Text -Token $BeginToken
        $el = Get-JiraManagedSectionLineNumber -Text $Text -Token $EndToken
        if ($bcount -ge 1 -and $ecount -eq 0) {
            [Console]::Error.WriteLine("managed section: begin marker at line(s) $bl with no matching end marker")
        }
        elseif ($ecount -ge 1 -and $bcount -eq 0) {
            [Console]::Error.WriteLine("managed section: end marker at line(s) $el with no matching begin marker")
        }
        elseif ($bcount -eq 1 -and $ecount -eq 1) {
            [Console]::Error.WriteLine("managed section: end marker at line $el precedes begin marker at line $bl")
        }
        else {
            [Console]::Error.WriteLine("managed section: malformed markers — begin at line(s) $bl, end at line(s) $el (expected exactly one of each)")
        }
        return [pscustomobject]@{ ExitCode = 4; Content = '' }
    }

    # --- Present: replace the region, preserving every byte outside it --------
    $prefix = $Text.Substring(0, $beginIdx)
    $lastNl = $prefix.LastIndexOf("`n")
    $before = if ($lastNl -ge 0) { $prefix.Substring(0, $lastNl + 1) } else { '' }

    $afterStart = $endIdx + $EndToken.Length
    $rest = $Text.Substring($afterStart)
    $firstNl = $rest.IndexOf("`n")
    $after = if ($firstNl -ge 0) { $rest.Substring($firstNl + 1) } else { '' }

    return [pscustomobject]@{ ExitCode = 0; Content = ($before + $rblock + $nl + $after) }
}

Export-ModuleMember -Function Get-JiraManagedSectionLineEnding, Invoke-JiraManagedSectionSplice
