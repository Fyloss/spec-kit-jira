# engine/Naming.psm1 — Pure feature-naming engine. Mirror of engine/naming.sh
# (002 US3, FR 015).
#
# NEUTRAL engine module: four pure string operations, no tracker knowledge, no
# reads, no writes. A pattern's `/` is preserved verbatim (branch hierarchy
# only); the folder short-name is always a single flat component.

Set-StrictMode -Version Latest

function Get-JiraTicketNumber {
    <#
    .SYNOPSIS
      The number component of an opaque key: everything after the leading
      upper-case project prefix and its separating hyphen. A value that is not
      prefix-shaped is returned unchanged. Mirror of naming_ticket_number.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Key)
    if ($Key -cmatch '^[A-Z].*-') {
        return ($Key -replace '^.*-', '')
    }
    return $Key
}

function Expand-JiraBranchPattern {
    <#
    .SYNOPSIS
      Substitute the two placeholders <ID> and <FEATURE_NAME>; every other
      character (including `/`) is preserved verbatim. Mirror of
      naming_expand_pattern.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Pattern,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Id,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $FeatureName
    )
    $out = $Pattern.Replace('<ID>', $Id)
    $out = $out.Replace('<FEATURE_NAME>', $FeatureName)
    return $out
}

function Get-JiraFeatureSlug {
    <#
    .SYNOPSIS
      Lower-case, collapse every run of non-alphanumeric characters to a single
      hyphen, and trim leading/trailing hyphens. Mirror of naming_slug.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Description)
    $s = $Description.ToLowerInvariant()
    $s = [regex]::Replace($s, '[^a-z0-9]+', '-')
    $s = $s -replace '^-+', ''
    $s = $s -replace '-+$', ''
    return $s
}

function Get-JiraShortName {
    <#
    .SYNOPSIS
      The flat folder component: the prefix followed by the slug, unless the slug
      already begins with the prefix (the prefix is never duplicated). Mirror of
      naming_short_name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $FolderPrefix,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Slug
    )
    if ($Slug.StartsWith($FolderPrefix, [System.StringComparison]::Ordinal)) {
        return $Slug
    }
    return "$FolderPrefix$Slug"
}

Export-ModuleMember -Function Get-JiraTicketNumber, Expand-JiraBranchPattern, Get-JiraFeatureSlug, Get-JiraShortName
