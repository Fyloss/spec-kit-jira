# sink/jira/PrivacyGuard.psm1 — Privacy guard: BLOCK tier + WARN tier and allowlist.
# Mirror of privacy_guard.sh (US11, T048 + US12, T090).
#
# Two tiers, precision over recall. BLOCK (FR-052) — zero writes, dedicated exit 9 —
# on the ATATT token prefix, a real *.atlassian.net host, or a known site/project
# coordinate. WARN (FR-053) — surfaced, never gating — on generic shapes (emails,
# UUIDs). ALLOWLIST (FR-053): Confluence links/domains from `.extensionignore`
# (gitignore syntax) or `config.privacy.allowlist` exempt INDIVIDUAL matches only
# (the match appears inside an allowlisted link, or the entry is a domain the
# match belongs to at a label boundary) — the payload is never rewritten, so a
# broad or overlapping entry can never disable detection of unrelated secrets
# (fail-closed); `.extensionignore` paths are excluded from parsing and scanning.
# The offending value is never echoed (NFR-3). Behaves identically to the Bash
# port (NFR-1).

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../../lib/Cli.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../../lib/Output.psm1') -Force

function Test-JiraPrivacyMatchAllowed {
    # True when an allowlist entry covers the matched text (FR-053): the whole
    # match appears inside the entry, or the entry is a DOMAIN the match belongs
    # to at a label boundary (`.entry` / `@entry` suffix). Mirror of
    # _privacy_match_allowed.
    param([string] $Match, [string] $AllowlistJson = '[]', [bool] $CaseInsensitive = $false)
    if ([string]::IsNullOrEmpty($Match)) { return $false }
    $cmp = if ($CaseInsensitive) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    foreach ($e in @($AllowlistJson | ConvertFrom-Json -Depth 100)) {
        $es = [string] $e
        if ($es -eq '') { continue }
        if ($es.IndexOf($Match, $cmp) -ge 0) { return $true }
        if ($Match.EndsWith(".$es", $cmp) -or $Match.EndsWith("@$es", $cmp)) { return $true }
    }
    return $false
}

function Test-JiraPrivacyRegexHit {
    # True when the payload carries at least one match of the shape that is NOT
    # covered by the allowlist. Mirror of _privacy_regex_hit.
    param([string] $Payload, [string] $Pattern, [string] $AllowlistJson = '[]', [bool] $CaseInsensitive = $false)
    $opts = if ($CaseInsensitive) { [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }
    else { [System.Text.RegularExpressions.RegexOptions]::None }
    foreach ($m in [regex]::Matches($Payload, $Pattern, $opts)) {
        if (-not (Test-JiraPrivacyMatchAllowed -Match $m.Value -AllowlistJson $AllowlistJson -CaseInsensitive $CaseInsensitive)) {
            return $true
        }
    }
    return $false
}

function Get-JiraPrivacyBlockReason {
    <#
    .SYNOPSIS
      Return the BLOCK reason for a write payload (empty when clear). The value is
      never included. The allowlist exempts individual matches only (FR-053).
      Mirror of privacy_guard_reason.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Payload,
        [string] $KnownCoordinatesJson = '[]',
        [string] $AllowlistJson = '[]'
    )
    # (1) ATATT token prefix — require token characters after the prefix so the
    #     bare word "ATATT" in prose does not false-positive.
    if (Test-JiraPrivacyRegexHit -Payload $Payload -Pattern 'ATATT[A-Za-z0-9._=+/-]{2,}' -AllowlistJson $AllowlistJson) {
        return 'Atlassian API token (ATATT prefix)'
    }

    # (2) Real *.atlassian.net host — matched case-insensitively: DNS hosts are
    #     case-insensitive, so a MiXeD-case spelling must not bypass the guard.
    if (Test-JiraPrivacyRegexHit -Payload $Payload -Pattern '[a-z0-9][a-z0-9-]*\.atlassian\.net' -AllowlistJson $AllowlistJson -CaseInsensitive $true) {
        return 'Atlassian Cloud host'
    }

    # (3) Exact match of a known coordinate (fixed-string, precision).
    $coords = @($KnownCoordinatesJson | ConvertFrom-Json -Depth 100)
    foreach ($c in $coords) {
        $cs = [string] $c
        if ([string]::IsNullOrEmpty($cs)) { continue }
        if ($Payload.Contains($cs) -and -not (Test-JiraPrivacyMatchAllowed -Match $cs -AllowlistJson $AllowlistJson)) {
            return 'known coordinate'
        }
    }

    return ''
}

function Test-JiraPrivacyBlock {
    <#
    .SYNOPSIS
      The pre-write gate. Returns EXIT_BLOCK (9) with a located reason on stderr
      when the payload carries a BLOCKED shape (after neutralising the allowlist);
      returns 0 when clear. Mirror of privacy_guard_scan.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Payload,
        [string] $KnownCoordinatesJson = '[]',
        [string] $AllowlistJson = '[]'
    )
    $reason = Get-JiraPrivacyBlockReason -Payload $Payload -KnownCoordinatesJson $KnownCoordinatesJson -AllowlistJson $AllowlistJson
    if (-not [string]::IsNullOrEmpty($reason)) {
        [Console]::Error.WriteLine("privacy: BLOCK — $reason detected in a write payload; zero writes performed (FR-052)")
        return (Get-JiraExitCode 'block')
    }
    return 0
}

function Get-JiraPrivacyWarnReason {
    <#
    .SYNOPSIS
      Return the WARN reason for a generic shape (empty when clear). The allowlist
      exempts individual matches only (FR-053). WARN never gates a write. Mirror of
      privacy_guard_warn_reason.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Payload,
        [string] $AllowlistJson = '[]'
    )
    if (Test-JiraPrivacyRegexHit -Payload $Payload -Pattern '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' -AllowlistJson $AllowlistJson -CaseInsensitive $true) {
        return 'email address'
    }
    if (Test-JiraPrivacyRegexHit -Payload $Payload -Pattern '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' -AllowlistJson $AllowlistJson -CaseInsensitive $true) {
        return 'UUID'
    }
    return ''
}

function Get-JiraPrivacyAllowlist {
    <#
    .SYNOPSIS
      Build the canonical allow-pattern array (FR-053): the non-empty, non-comment,
      trimmed lines of `.extensionignore` merged with the config's privacy.allowlist,
      de-duplicated. Mirror of privacy_allowlist_load.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $IgnorePath, [string] $ConfigAllowlistJson = '[]')
    $lines = @()
    if (Test-Path -LiteralPath $IgnorePath) {
        foreach ($raw in (Get-Content -LiteralPath $IgnorePath)) {
            $line = ([string] $raw).Trim()
            if ($line -eq '' -or $line.StartsWith('#')) { continue }
            $lines += $line
        }
    }
    $cfg = @($ConfigAllowlistJson | ConvertFrom-Json -Depth 100)
    # De-duplicate + sort ORDINALLY and case-sensitively, matching jq `unique`
    # (Sort-Object -Unique is culture-sensitive and case-insensitive: it would
    # both diverge from the Bash port and COLLAPSE case-variant entries).
    $set = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($x in @($lines + @($cfg | ForEach-Object { [string] $_ }))) {
        if ($x -ne '') { [void]$set.Add($x) }
    }
    return (ConvertTo-JiraJsonValue @($set))
}

function Test-JiraPrivacyPathExcluded {
    <#
    .SYNOPSIS
      True when the path is excluded from parsing and scanning by an
      `.extensionignore` rule (directory prefix, `*.ext` glob, or exact path).
      Mirror of privacy_path_excluded.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $IgnorePath)
    if (-not (Test-Path -LiteralPath $IgnorePath)) { return $false }
    foreach ($raw in (Get-Content -LiteralPath $IgnorePath)) {
        $line = ([string] $raw).Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line.EndsWith('/')) {
            if ($Path.StartsWith($line) -or $Path -eq $line.TrimEnd('/')) { return $true }
            continue
        }
        if ($line.StartsWith('*')) {
            $leaf = Split-Path -Leaf $Path
            if ($Path -like $line -or $leaf -like $line) { return $true }
            continue
        }
        if ($Path -eq $line -or $Path.StartsWith("$line/")) { return $true }
    }
    return $false
}

function ConvertTo-JiraScannablePayload {
    <#
    .SYNOPSIS
      Read a file's raw bytes and return a payload the matcher will speak about.
      Mirror of _privacy_normalise_bytes.
    .DESCRIPTION
      The Bash port needs this because passing raw binary through a shell
      variable makes `grep` stop reporting matches altogether. This port has no
      grep, but it MUST perform the identical transformation anyway: the two
      ports have to reach the same verdict on the same bytes (Constitution VI),
      and a decoder that silently replaced invalid UTF-8 with U+FFFD would break
      a match the Bash port still finds — or find one it does not.

      So: NUL bytes are dropped, every other non-printable byte becomes a space,
      and the bytes are read as Latin-1 so each one maps to exactly one
      character and nothing is lost to a decoding guess.

      Mapping non-printables to spaces cannot hide a BLOCKED shape, because all
      three of them are printable ASCII — the token prefix, the host, and a
      known coordinate.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $sb = [System.Text.StringBuilder]::new($bytes.Length)
    foreach ($b in $bytes) {
        if ($b -eq 0) { continue }
        # 0x20-0x7E is printable ASCII; LF is kept as itself, everything else
        # becomes a space. Matches `tr -c '[:print:]\n' ' '` in the C locale.
        if (($b -ge 0x20 -and $b -le 0x7E) -or $b -eq 0x0A) {
            [void] $sb.Append([char] $b)
        }
        else {
            [void] $sb.Append(' ')
        }
    }
    return $sb.ToString()
}

function Get-JiraArtifactPrivacyReason {
    <#
    .SYNOPSIS
      "<path>: <reason>" for the first artifact carrying a BLOCKED shape; empty
      when the whole set is clear. Mirror of privacy_guard_artifact_reason
      (036 C5.2, FR-016).
    .DESCRIPTION
      ONE PASS over the concatenated set, not one per artifact (C5.4).
      Attribution — working out WHICH artifact carried the shape — costs a
      second pass and is paid only on the failure path, where the run is
      aborting anyway and a message naming the file is worth far more than the
      cycles. The clear path, which is every ordinary run, stays at one pass.

      Binary artifacts are scanned with no special case (research R12).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $FeatureDirectory,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $SetJson,
        [string] $KnownCoordinatesJson = '[]',
        [string] $AllowlistJson = '[]'
    )

    if (-not (Test-Path -LiteralPath $FeatureDirectory -PathType Container)) { return '' }
    if ([string]::IsNullOrWhiteSpace($SetJson)) { return '' }
    $set = @($SetJson | ConvertFrom-Json -Depth 100)
    if ($set.Count -eq 0) { return '' }

    $sb = [System.Text.StringBuilder]::new()
    foreach ($entry in $set) {
        $full = Join-Path $FeatureDirectory $entry.path
        # NO separator between artifacts. That is not an oversight: the Bash
        # port concatenates with `xargs -0 cat`, which inserts nothing, and the
        # two ports must reach the same verdict on the same bytes
        # (Constitution VI). Adding one here would make this port miss a shape
        # the Bash port finds across a file boundary.
        #
        # The boundary case that costs is a shape FORGED by adjacency — file A
        # ending mid-token, file B beginning with its completion. Both ports
        # handle it identically and fail closed: the concatenated scan matches,
        # the per-artifact pass then finds no single owner, and the reason comes
        # back as "(across the artifact set)" rather than naming an innocent
        # file or waving the run through.
        [void] $sb.Append((ConvertTo-JiraScannablePayload -Path $full))
    }

    $reason = Get-JiraPrivacyBlockReason -Payload $sb.ToString() `
        -KnownCoordinatesJson $KnownCoordinatesJson -AllowlistJson $AllowlistJson
    if ([string]::IsNullOrEmpty($reason)) { return '' }

    # Failure path only: name the artifact.
    foreach ($entry in $set) {
        $full = Join-Path $FeatureDirectory $entry.path
        $per = Get-JiraPrivacyBlockReason -Payload (ConvertTo-JiraScannablePayload -Path $full) `
            -KnownCoordinatesJson $KnownCoordinatesJson -AllowlistJson $AllowlistJson
        if (-not [string]::IsNullOrEmpty($per)) { return "$($entry.path): $per" }
    }

    # The blob matched but no single artifact did: the shape straddles a file
    # boundary. Report it without naming a file rather than letting the run
    # proceed — fail closed on the ambiguous case.
    return "(across the artifact set): $reason"
}

function Test-JiraArtifactPrivacy {
    <#
    .SYNOPSIS
      The pre-write gate for artifact content. Returns EXIT_BLOCK (9) with a
      located reason on stderr when any artifact carries a BLOCKED shape;
      returns 0 when the set is clear. Mirror of privacy_guard_scan_artifacts
      (036 C5.1, C5.3, C5.5, FR-016).
    .DESCRIPTION
      On a non-zero return the caller must perform ZERO writes of EVERY kind —
      not merely zero attachments. Publication runs after the description and
      story writes, so a guard placed beside the upload could only refuse the
      upload while the rest had already landed; this one runs at the pre-write
      sweep instead.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $FeatureDirectory,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $SetJson,
        [string] $KnownCoordinatesJson = '[]',
        [string] $AllowlistJson = '[]'
    )
    $reason = Get-JiraArtifactPrivacyReason -FeatureDirectory $FeatureDirectory -SetJson $SetJson `
        -KnownCoordinatesJson $KnownCoordinatesJson -AllowlistJson $AllowlistJson
    if (-not [string]::IsNullOrEmpty($reason)) {
        [Console]::Error.WriteLine("privacy: BLOCK — $reason detected in a feature artifact; zero writes performed (FR-016)")
        return (Get-JiraExitCode 'block')
    }
    return 0
}

Export-ModuleMember -Function Get-JiraPrivacyBlockReason, Test-JiraPrivacyBlock, `
    Get-JiraPrivacyWarnReason, Get-JiraPrivacyAllowlist, Test-JiraPrivacyPathExcluded, `
    Test-JiraPrivacyMatchAllowed, ConvertTo-JiraScannablePayload, `
    Get-JiraArtifactPrivacyReason, Test-JiraArtifactPrivacy
