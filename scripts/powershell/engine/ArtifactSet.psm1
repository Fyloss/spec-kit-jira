# engine/ArtifactSet.psm1 — the feature directory as the engine sees it.
# Mirror of scripts/bash/engine/artifact_set.sh.
# (036 data-model.md §1; research R4/R5/R7; FR-001, FR-005, FR-007, FR-023.)
#
# Every file the repository does not ignore, at any depth, with its content
# hash, its size, and the name it will carry as an attachment. NEUTRAL layer:
# no Jira knowledge, and it imports nothing from sink/.
#
# Two things this port must get right that the Bash one gets for free:
#
#   * NUL-SEPARATED OUTPUT. `git ls-files -z` is the only enumeration that
#     survives a path containing a space, a quote or a newline — git quotes
#     such paths in its default output, and a quoted path is not a path.
#     PowerShell's native-command pipeline decodes bytes to strings and cannot
#     carry NUL, so the process is driven through ProcessStartInfo and its raw
#     stdout stream is read as bytes. `& git … | …` silently loses the
#     separator, exactly as `$( … )` does in Bash.
#   * LINE ENDINGS. Nothing here writes text, so there is no CRLF to acquire,
#     but the JSON is emitted through the shared canonicaliser so key order and
#     spacing match the Bash port byte for byte.
#
# `git hash-object --stdin-paths` resolves a relative path against the
# REPOSITORY ROOT rather than the working directory — measured, not assumed;
# setting the process's working directory to the feature directory does not
# change it. Absolute paths are fed instead, on stdin, so no command line grows
# with the artifact set either (FR-023).

Set-StrictMode -Version Latest

# WITHOUT -Force. `Import-Module X -Force` is `Remove-Module X` +
# `Import-Module X`, so a forced nested import here would tear the shared
# Output module out of whichever caller loaded it first and rebind that caller
# to an orphaned copy. That defect has already cost this repository a whole
# investigation once (every timing phase reporting 0 requests against 123 real
# ones), and one Pester file will not reproduce it.
Import-Module (Join-Path $PSScriptRoot '../lib/Output.psm1') # ConvertTo-JiraCanonicalJson

function Convert-JiraArtifactPathToName {
    <#
    .SYNOPSIS
      The attachment name for a feature-relative path (research R7, FR-005).
    .DESCRIPTION
      A top-level artifact keeps its exact filename, because that is what a
      reader expects in the attachment panel. A nested one joins its segments
      with `__`, which reads as a path separator and cannot be produced by a
      single `/` replacement colliding with an ordinary name.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Path)
    return $Path.Replace('/', '__')
}

function Invoke-GitCapturingOutput {
    <#
    .SYNOPSIS
      Run git and return its raw stdout bytes, optionally feeding stdin.
    .DESCRIPTION
      PowerShell's native-command pipeline decodes to strings, so it cannot
      carry the NUL separator `git ls-files -z` emits. This drives the process
      directly and reads the raw stream.

      The redirected readers are closed explicitly rather than left to
      Process.Dispose(): disposing a Process does NOT close the streams it
      redirected, so each call would leak two file descriptors until the
      finalizer ran.
    #>
    param(
        [Parameter(Mandatory)][string[]] $ArgumentList,
        [string] $WorkingDirectory,
        [byte[]] $StandardInputBytes
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    foreach ($a in $ArgumentList) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $null -ne $StandardInputBytes
    $psi.UseShellExecute = $false
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        if ($null -ne $StandardInputBytes) {
            $inStream = $proc.StandardInput.BaseStream
            $inStream.Write($StandardInputBytes, 0, $StandardInputBytes.Length)
            $inStream.Flush()
            $proc.StandardInput.Close()
        }
        $mem = [System.IO.MemoryStream]::new()
        try {
            $proc.StandardOutput.BaseStream.CopyTo($mem)
            # Drain stderr so a chatty git cannot fill its pipe and deadlock.
            $null = $proc.StandardError.ReadToEnd()
            $proc.WaitForExit()
            return [pscustomobject]@{ ExitCode = $proc.ExitCode; Bytes = $mem.ToArray() }
        }
        finally { $mem.Dispose() }
    }
    finally {
        $proc.StandardOutput.Close()
        $proc.StandardError.Close()
        $proc.Dispose()
    }
}

function Get-JiraArtifactSet {
    <#
    .SYNOPSIS
      The artifact set for a feature directory, as canonical JSON sorted
      byte-wise on `path` (data-model §1).
    .DESCRIPTION
      Returns '[]' for a directory holding nothing publishable. That is a
      legitimate state — a specification whose folder holds only ignored files
      — and not an error: failing here would turn an empty feature directory
      into a failed run.
    #>
    param([Parameter(Mandatory)][string] $FeatureDirectory)

    if (-not (Test-Path -LiteralPath $FeatureDirectory -PathType Container)) { return '[]' }
    $dir = (Resolve-Path -LiteralPath $FeatureDirectory).Path

    $listed = Invoke-GitCapturingOutput -WorkingDirectory $dir -ArgumentList @(
        'ls-files', '--cached', '--others', '--exclude-standard', '-z', '--', '.'
    )
    if ($listed.ExitCode -ne 0 -or $listed.Bytes.Length -eq 0) { return '[]' }

    # Split on NUL and decode each element as UTF-8. A trailing empty element
    # is the separator after the last path, not a path.
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $rel = [System.Collections.Generic.List[string]]::new()
    $start = 0
    for ($i = 0; $i -lt $listed.Bytes.Length; $i++) {
        if ($listed.Bytes[$i] -eq 0) {
            if ($i -gt $start) { $rel.Add($utf8.GetString($listed.Bytes, $start, $i - $start)) }
            $start = $i + 1
        }
    }
    if ($start -lt $listed.Bytes.Length) {
        $rel.Add($utf8.GetString($listed.Bytes, $start, $listed.Bytes.Length - $start))
    }
    if ($rel.Count -eq 0) { return '[]' }

    # Absolute paths for the hasher, LF-separated, on stdin. Never a command
    # line: it would grow with the artifact set, and the cap that binds is
    # Windows's whole-command-line ~32767 bytes, not this host's.
    $absText = (($rel | ForEach-Object { Join-Path $dir $_ }) -join "`n") + "`n"
    $hashed = Invoke-GitCapturingOutput -ArgumentList @(
        'hash-object', '--no-filters', '--stdin-paths'
    ) -StandardInputBytes $utf8.GetBytes($absText)
    if ($hashed.ExitCode -ne 0) { return '[]' }
    $hashes = @($utf8.GetString($hashed.Bytes) -split "`n" | Where-Object { $_.Length -gt 0 } | ForEach-Object { $_.TrimEnd("`r") })

    # Sizes are read in-process. PowerShell needs no `wc`, so this port spawns
    # strictly fewer processes than the Bash one — the budget is a per-item
    # rule, and zero is inside it.
    $entries = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $rel.Count; $i++) {
        $p = $rel[$i]
        $full = Join-Path $dir $p
        $size = 0
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $size = [int64] (Get-Item -LiteralPath $full).Length
        }
        $entries.Add([ordered]@{
                path            = $p
                hash            = if ($i -lt $hashes.Count) { $hashes[$i] } else { '' }
                size            = $size
                attachment_name = (Convert-JiraArtifactPathToName -Path $p)
            })
    }

    # Byte-wise ORDINAL sort, via [string]::CompareOrdinal.
    #
    # `Sort-Object -CaseSensitive` is not enough and looks like it is: it stays
    # CULTURE-aware and merely stops folding case, so it still orders
    # 'apple.md' before 'Zebra.md' where the Bash port's LC_ALL=C comparison
    # puts 'Z' (0x5A) first. The divergence is invisible on a fixture whose
    # names are all one case — which is every fixture until someone adds a
    # capitalised artifact — and it would reorder the manifest, the comment
    # body and the multipart part list all at once.
    $entries.Sort([System.Comparison[object]] {
            param($a, $b)
            [string]::CompareOrdinal([string] $a.path, [string] $b.path)
        })
    $sorted = @($entries)

    if ($sorted.Count -eq 0) { return '[]' }
    # The canonicaliser takes a JSON STRING, not an object graph: it re-parses
    # and re-emits so key order and spacing match `jq -cS` byte for byte.
    return (ConvertTo-JiraCanonicalJson -Json (ConvertTo-Json -InputObject $sorted -Depth 10 -Compress))
}

function Get-JiraArtifactNameCollision {
    <#
    .SYNOPSIS
      One line per group of artifacts sharing an attachment name, as
      "<name>: <path> <path>"; nothing when every name is unique (FR-005).
    .DESCRIPTION
      Reachable only through a literal `__` in a real filename, which is why it
      reports and withholds rather than mangling further: a second
      disambiguation would produce a name no reader could map back to a path.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string] $SetJson)

    if ([string]::IsNullOrWhiteSpace($SetJson)) { return @() }
    $set = @($SetJson | ConvertFrom-Json)
    if ($set.Count -eq 0) { return @() }

    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($g in ($set | Group-Object -Property attachment_name)) {
        if ($g.Count -gt 1) {
            $paths = @($g.Group | ForEach-Object { $_.path }) -join ' '
            $out.Add("$($g.Name): $paths")
        }
    }
    return $out.ToArray()
}

Export-ModuleMember -Function Convert-JiraArtifactPathToName, Get-JiraArtifactSet,
Get-JiraArtifactNameCollision
