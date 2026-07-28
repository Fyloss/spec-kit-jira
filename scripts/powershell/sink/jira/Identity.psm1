# sink/jira/Identity.psm1 — Ticket identity marker. Mirror of sink/jira/identity.sh
# (US3, T057; research §5).
#
# Identity lives in a server-side entity property (never a user-editable label,
# Constitution II), recording origin + spec ref and surviving spec-folder renames.
# The spec ref is the discriminator for "claimed by another spec" (US10/FR-051).
# The property key is a constant OURS: `spec-kit-jira`.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../../lib/Cli.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../../lib/Output.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Client.psm1') -Force

function Get-JiraIdentityKey {
    if ($env:SPEC_KIT_JIRA_IDENTITY_KEY) { return $env:SPEC_KIT_JIRA_IDENTITY_KEY }
    return 'spec-kit-jira'
}

function Get-JiraIdentityMarker {
    <#
    .SYNOPSIS
      Build the canonical marker value. Mirror of identity_marker.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SpecRefJson, [Parameter(Mandatory)] [string] $Origin)
    $s = $SpecRefJson | ConvertFrom-Json -Depth 100
    $repo = if ($s.PSObject.Properties.Name -contains 'repo' -and $null -ne $s.repo) { [string]$s.repo } else { '' }
    $slug = if ($s.PSObject.Properties.Name -contains 'spec_slug' -and $null -ne $s.spec_slug) { [string]$s.spec_slug } else { '' }
    return (ConvertTo-JiraJsonValue ([ordered]@{ origin = $Origin; repo = $repo; spec_slug = $slug }))
}

function Test-JiraIdentityClaimedByOther {
    <#
    .SYNOPSIS
      True when the stored marker belongs to a DIFFERENT spec. Mirror of
      identity_claimed_by_other.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $MarkerJson, [Parameter(Mandatory)] [string] $SpecRefJson)
    $m = $MarkerJson | ConvertFrom-Json -Depth 100
    $s = $SpecRefJson | ConvertFrom-Json -Depth 100
    $repo = if ($s.PSObject.Properties.Name -contains 'repo' -and $null -ne $s.repo) { [string]$s.repo } else { '' }
    $slug = if ($s.PSObject.Properties.Name -contains 'spec_slug' -and $null -ne $s.spec_slug) { [string]$s.spec_slug } else { '' }
    return -not (($m.repo -eq $repo) -and ($m.spec_slug -eq $slug))
}

function Get-JiraIdentityUrl {
    param([string] $IssueKey)
    $base = if ($env:SPEC_KIT_JIRA_BASE_URL) { $env:SPEC_KIT_JIRA_BASE_URL } else { '' }
    return "$base/rest/api/3/issue/$IssueKey/properties/$(Get-JiraIdentityKey)"
}

function Get-JiraIdentity {
    <#
    .SYNOPSIS
      Return the stored marker value, or an empty string when the ticket is
      unclaimed (404 is not a failure). Mirror of identity_read. Returns a
      pscustomobject { ExitCode; Value }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $IssueKey)
    if ([string]::IsNullOrEmpty($env:SPEC_KIT_JIRA_BASE_URL)) {
        [Console]::Error.WriteLine('identity: SPEC_KIT_JIRA_BASE_URL is not set')
        return [pscustomobject]@{ ExitCode = [int](Get-JiraExitCode 'fail_closed'); Value = '' }
    }
    $r = Invoke-JiraRequest -Method GET -Url (Get-JiraIdentityUrl $IssueKey)
    if ([int]$r.ExitCode -eq 0) {
        $body = $r.Body | ConvertFrom-Json -Depth 100
        $value = ''
        if ($body.PSObject.Properties.Name -contains 'value' -and $null -ne $body.value) {
            $value = ConvertTo-JiraJsonValue $body.value
        }
        return [pscustomobject]@{ ExitCode = 0; Value = $value }
    }
    if ([string]$r.Status -eq '404') {
        return [pscustomobject]@{ ExitCode = 0; Value = '' }
    }
    return [pscustomobject]@{ ExitCode = [int]$r.ExitCode; Value = '' }
}

function Set-JiraIdentity {
    <#
    .SYNOPSIS
      Stamp the identity marker on the ticket via the entity property. Mirror of
      identity_write. Returns the transport exit code.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $IssueKey, [Parameter(Mandatory)] [string] $SpecRefJson, [Parameter(Mandatory)] [string] $Origin)
    if ([string]::IsNullOrEmpty($env:SPEC_KIT_JIRA_BASE_URL)) {
        [Console]::Error.WriteLine('identity: SPEC_KIT_JIRA_BASE_URL is not set')
        return [int](Get-JiraExitCode 'fail_closed')
    }
    if (-not $PSCmdlet.ShouldProcess($IssueKey, 'write identity property')) { return 0 }
    $marker = Get-JiraIdentityMarker -SpecRefJson $SpecRefJson -Origin $Origin
    $r = Invoke-JiraRequest -Method PUT -Url (Get-JiraIdentityUrl $IssueKey) -Body $marker
    return [int]$r.ExitCode
}

# Get-JiraIdentityUrl is exported so the adoption sink composes the SAME property
# URL this module writes to, rather than a second spelling of it (003 research §7).
Export-ModuleMember -Function Get-JiraIdentityMarker, Test-JiraIdentityClaimedByOther, Get-JiraIdentity, Set-JiraIdentity, Get-JiraIdentityUrl
