# engine/MarkerSplice.psm1 — Byte-offset, line-ending, atomic-write and
# line-replacement primitives shared by every marker kind spliced into a
# specification file (T064). Mirror of engine/marker_splice.sh.
# StoryMarker.psm1 and SpecMarker.psm1 both build on these; neither owns
# them, so a second marker key never duplicates a splice routine
# (contracts/parent-marker.md).

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ManagedSection.psm1') -Force

function Get-JiraMarkerSpliceOffsetAfterLine {
    # Byte offset immediately after the terminating newline of 1-based line
    # <N> (the start of line N+1); or the length of <Content> when the file
    # has fewer than <N> newlines. Mirror of marker_splice_offset_after_line.
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Content, [Parameter(Mandatory)] [int] $N)
    $rest = $Content
    $consumed = 0
    $count = 0
    while ($count -lt $N -and $rest.Contains("`n")) {
        $idx = $rest.IndexOf("`n")
        $consumed += $idx + 1
        $rest = $rest.Substring($idx + 1)
        $count++
    }
    if ($count -lt $N) { return $Content.Length }
    return $consumed
}

function Get-JiraMarkerSpliceLineCount {
    # The total number of lines (an unterminated final line still counts).
    # Mirror of marker_splice_line_count.
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Content)
    return ($Content -split "`n").Count
}

function Add-JiraMarkerSpliceAfterLine {
    # Insert <Text> as a new line immediately after 1-based line <N> (N=0:
    # before line 1). Mirror of marker_splice_insert_after_line.
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Content, [Parameter(Mandatory)] [int] $N, [Parameter(Mandatory)] [string] $Text, [Parameter(Mandatory)] [string] $Nl)
    if ($N -eq 0) {
        return "$Text$Nl$Content"
    }
    $off = Get-JiraMarkerSpliceOffsetAfterLine -Content $Content -N $N
    if ($off -eq $Content.Length -and $Content.Length -gt 0 -and -not $Content.EndsWith("`n")) {
        return "$Content$Nl$Text"
    }
    return $Content.Substring(0, $off) + $Text + $Nl + $Content.Substring($off)
}

function Set-JiraMarkerSpliceReplaceLine {
    # Replace the WHOLE of 1-based line <N> (its text and terminator) with
    # <Text><Nl>, preserving every other byte exactly. Mirror of
    # marker_splice_replace_line.
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Content, [Parameter(Mandatory)] [int] $N, [Parameter(Mandatory)] [string] $Text, [Parameter(Mandatory)] [string] $Nl)
    $startOff = Get-JiraMarkerSpliceOffsetAfterLine -Content $Content -N ($N - 1)
    $endOff = Get-JiraMarkerSpliceOffsetAfterLine -Content $Content -N $N
    $before = $Content.Substring(0, $startOff)
    $after = $Content.Substring($endOff)
    return "$before$Text$Nl$after"
}

function Get-JiraMarkerSpliceDominantNl {
    # The literal newline to use for a written/rewritten marker line. Mirror
    # of marker_splice_dominant_nl_token.
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Content)
    $token = Get-JiraManagedSectionLineEnding -Text $Content
    if ($token -eq 'CRLF') { return "`r`n" }
    return "`n"
}

function Write-JiraMarkerSpliceFile {
    <#
    .SYNOPSIS
      Write <NewContent> to <Path> ONLY IF it differs from the file's current
      bytes, atomically (a temporary file in the SAME directory, renamed over
      the original). Prints 'written' or 'unchanged'. Mirror of
      marker_splice_write_file.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [AllowEmptyString()] [string] $NewContent)
    $current = if (Test-Path -LiteralPath $Path) { Get-Content -Raw -LiteralPath $Path } else { '' }
    if ($null -eq $current) { $current = '' }
    if ($current -eq $NewContent) { return 'unchanged' }
    if (-not $PSCmdlet.ShouldProcess($Path, 'write marker')) { return 'unchanged' }
    $dir = Split-Path -Parent (Resolve-Path -LiteralPath $Path).Path
    $tmp = Join-Path $dir ([System.IO.Path]::GetRandomFileName())
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($tmp, $NewContent, $utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
    return 'written'
}

Export-ModuleMember -Function Get-JiraMarkerSpliceOffsetAfterLine, Get-JiraMarkerSpliceLineCount, `
    Add-JiraMarkerSpliceAfterLine, Set-JiraMarkerSpliceReplaceLine, Get-JiraMarkerSpliceDominantNl, `
    Write-JiraMarkerSpliceFile
