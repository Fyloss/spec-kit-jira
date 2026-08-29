# lib/UrlOrigin.psm1 — URL origin parsing and comparison (032,
# contracts/origin-pinning.md §C1). Byte-equivalent twin of lib/url_origin.sh.
#
# An "origin" is scheme + host + port. Two URLs address the same origin when
# their canonical forms are identical; path, query and fragment never
# distinguish them.
#
# Port infrastructure only: NO Jira knowledge. It lives in lib/ rather than
# sink/ because Constitution VIII forbids lib/ from depending on sink/, and the
# connection chokepoint needs the comparison. sink/jira/Designator.psm1 is
# re-expressed on top of it, so the tree holds one origin grammar.
#
# Three rules, each measured rather than assumed (research.md §R5):
#
#   * The case fold is an EXPLICIT ASCII mapping, NOT ToLowerInvariant().
#     Measured: 'İSTANBUL.X'.ToLowerInvariant() is 'İstanbul.x' while bash's
#     ${x,,} yields 'istanbul.x'. A host is attacker-supplied here, so a
#     culture- or Unicode-table-dependent fold diverges on exactly the input
#     this feature exists to catch. Spelling the 26 mappings out is the point.
#   * Exactly ONE trailing dot is removed, NOT TrimEnd('.') which removes all.
#     Measured: 'https://a.b..' vs 'https://a.b.' matched here and not in bash.
#   * A bracketed IPv6 authority splits at the closing bracket, never with
#     Split(':', 2). That yielded host '[' and port ':1]:8080' — equally wrong
#     in both ports, so conformance stayed green while a value the base-URL
#     validator explicitly admits parsed to garbage.
#
# [System.Uri] is forbidden here: it lowercases the host by its own rules,
# elides default ports, inserts a trailing slash, and punycode-encodes IDN.
# The Bash port reproduces none of that, so using it would break FR-009 on the
# first non-trivial input.

Set-StrictMode -Version Latest

function Convert-JiraUrlOriginFold {
    <#
    .SYNOPSIS
      Lower-case the ASCII letters A-Z and nothing else. Mirror of
      _url_origin_fold. Every mapped character is spelled out so the character
      set is stated here rather than delegated to a culture or Unicode table.
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Value)
    $s = $Value
    $s = $s.Replace('A', 'a'); $s = $s.Replace('B', 'b'); $s = $s.Replace('C', 'c')
    $s = $s.Replace('D', 'd'); $s = $s.Replace('E', 'e'); $s = $s.Replace('F', 'f')
    $s = $s.Replace('G', 'g'); $s = $s.Replace('H', 'h'); $s = $s.Replace('I', 'i')
    $s = $s.Replace('J', 'j'); $s = $s.Replace('K', 'k'); $s = $s.Replace('L', 'l')
    $s = $s.Replace('M', 'm'); $s = $s.Replace('N', 'n'); $s = $s.Replace('O', 'o')
    $s = $s.Replace('P', 'p'); $s = $s.Replace('Q', 'q'); $s = $s.Replace('R', 'r')
    $s = $s.Replace('S', 's'); $s = $s.Replace('T', 't'); $s = $s.Replace('U', 'u')
    $s = $s.Replace('V', 'v'); $s = $s.Replace('W', 'w'); $s = $s.Replace('X', 'x')
    $s = $s.Replace('Y', 'y'); $s = $s.Replace('Z', 'z')
    return $s
}

function Get-JiraUrlOriginPart {
    <#
    .SYNOPSIS
      Return an object carrying Scheme / UrlHost / Port, or $null when the URL
      carries no scheme or an empty authority. Mirror of url_origin_parts.
    .NOTES
      The property is UrlHost, not Host: $host is a PowerShell automatic
      variable and a property named Host invites the collision at every call
      site.
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Url)

    # Strip a single trailing CR, matching the Bash port's ${url%$'\r'}.
    $u = $Url
    if ($u.EndsWith("`r")) { $u = $u.Substring(0, $u.Length - 1) }

    if ($u -cnotmatch '^([a-zA-Z][a-zA-Z0-9+.-]*)://([^/?#]+)') { return $null }
    $scheme = $Matches[1]
    $hostport = $Matches[2]
    $h = ''
    $port = ''

    if ($hostport.StartsWith('[')) {
        $close = $hostport.IndexOf(']')
        if ($close -lt 0) { return $null }
        $h = $hostport.Substring(0, $close + 1)
        $rest = $hostport.Substring($close + 1)
        if ($rest.Length -gt 0) {
            if (-not $rest.StartsWith(':')) { return $null }
            $port = $rest.Substring(1)
        }
    }
    elseif ($hostport.Contains(':')) {
        $idx = $hostport.IndexOf(':')
        $h = $hostport.Substring(0, $idx)
        $port = $hostport.Substring($idx + 1)
    }
    else {
        $h = $hostport
    }

    if ([string]::IsNullOrEmpty($h)) { return $null }

    # One trailing dot, and one only.
    if ($h.EndsWith('.')) { $h = $h.Substring(0, $h.Length - 1) }

    return [pscustomobject]@{
        Scheme  = (Convert-JiraUrlOriginFold -Value $scheme)
        UrlHost = (Convert-JiraUrlOriginFold -Value $h)
        Port    = $port
    }
}

function Get-JiraUrlOriginDefaultPort {
    <#
    .SYNOPSIS
      The scheme's default port, or '' when the scheme has none.
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Scheme)
    switch ($Scheme) {
        'https' { return '443' }
        'http' { return '80' }
        default { return '' }
    }
}

function Get-JiraUrlOriginCanonical {
    <#
    .SYNOPSIS
      'scheme://host[:port]', omitting the port when it is the scheme's
      default. Returns $null when the URL does not parse. This is the form
      recorded on disk, so its bytes are a cross-port obligation.
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Url)
    $p = Get-JiraUrlOriginPart -Url $Url
    if ($null -eq $p) { return $null }
    $port = $p.Port
    if ($port -ne '' -and $port -eq (Get-JiraUrlOriginDefaultPort -Scheme $p.Scheme)) { $port = '' }
    if ($port -ne '') { return "$($p.Scheme)://$($p.UrlHost):$port" }
    return "$($p.Scheme)://$($p.UrlHost)"
}

function Test-JiraUrlOriginEqual {
    <#
    .SYNOPSIS
      $true when both URLs parse to the same origin. An unparseable operand
      never matches anything, including another unparseable one: refusing is
      the safe answer for a value that decides whether a credential travels.
    #>
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $First,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Second
    )
    $a = Get-JiraUrlOriginCanonical -Url $First
    if ($null -eq $a) { return $false }
    $b = Get-JiraUrlOriginCanonical -Url $Second
    if ($null -eq $b) { return $false }
    return ($a -ceq $b)
}

Export-ModuleMember -Function Convert-JiraUrlOriginFold, Get-JiraUrlOriginPart,
Get-JiraUrlOriginDefaultPort, Get-JiraUrlOriginCanonical, Test-JiraUrlOriginEqual
