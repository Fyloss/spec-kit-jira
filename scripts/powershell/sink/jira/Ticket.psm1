# sink/jira/Ticket.psm1 — Ticket read/create (SINK layer, 002 US3, FR-013).
# Mirror of sink/jira/ticket.sh.
#
# Two operations for the feature-naming ceremony, both through the existing
# transport (Client.psm1):
#
#   * Confirm-JiraTicket — READ-ONLY GET /issue/{key}?fields=project of a
#     MENTIONED key; returns the neutral {key, project} document. A fail-closed
#     read (404/5xx/network/auth) propagates the transport's mapped exit code
#     with empty Json (Constitution III) — a mentioned key never silently
#     falls back.
#
#   * New-JiraTicket — GUARDED WRITE POST /issue in the given project with the
#     CALLER's resolved story-type id (never a literal type name — Constitution
#     VII). The PASS-1 privacy guard scans the body BEFORE the POST (BLOCK ⇒
#     ExitCode 9, zero writes, Constitution IX); the created ticket is
#     identity-stamped like any bridge-created artifact. Returns the neutral
#     {key} document.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../../lib/Cli.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../../lib/Output.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Client.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PrivacyGuard.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Identity.psm1') -Force

function Confirm-JiraTicket {
    <#
    .SYNOPSIS
      Read the mentioned key's project (fields=project). Mirror of
      ticket_validate. Returns { ExitCode; Json } — Json is the canonical
      {key, project} document, empty on a fail-closed read.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Key)
    $base = $env:SPEC_KIT_JIRA_BASE_URL
    if ([string]::IsNullOrEmpty($base)) {
        [Console]::Error.WriteLine('ticket: SPEC_KIT_JIRA_BASE_URL is not set')
        return [pscustomobject]@{ ExitCode = (Get-JiraExitCode 'fail_closed'); Json = '' }
    }
    $r = Invoke-JiraRequest -Method GET -Url "$base/rest/api/3/issue/$Key`?fields=project"
    if ($r.ExitCode -ne 0) { return [pscustomobject]@{ ExitCode = [int] $r.ExitCode; Json = '' } }

    $resp = $r.Body | ConvertFrom-Json -Depth 100
    $project = $null
    if ($resp.PSObject.Properties['fields'] -and $null -ne $resp.fields -and
        $resp.fields.PSObject.Properties['project'] -and $null -ne $resp.fields.project -and
        $resp.fields.project.PSObject.Properties['key']) {
        $project = [string] $resp.fields.project.key
    }
    $doc = [ordered]@{ key = $Key; project = $project }
    return [pscustomobject]@{ ExitCode = 0; Json = (ConvertTo-JiraJsonValue $doc) }
}

function Get-JiraCreateFieldsBase {
    <#
    .SYNOPSIS
      The mandatory base every creation path must produce: {project, issuetype,
      summary} (research R3, FR-025). Mirror of jira_create_fields_base. Both
      Get-JiraTicketCreateBody and Get-JiraPlanWriteSet build on this single
      builder so the two creation paths cannot drift apart again. The issue
      type is carried by ID only (never a literal name — Constitution VII).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $ProjectKey,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Summary,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $IssueTypeId
    )
    return '{"project":{"key":' + (ConvertTo-JiraJsonString $ProjectKey) +
        '},"issuetype":{"id":' + (ConvertTo-JiraJsonString $IssueTypeId) +
        '},"summary":' + (ConvertTo-JiraJsonString $Summary) + '}'
}

function Get-JiraTicketCreateBody {
    <#
    .SYNOPSIS
      The canonical create payload. Mirror of _ticket_create_body: wraps
      Get-JiraCreateFieldsBase unchanged, matching the Bash twin byte-for-byte.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ProjectKey,
        [Parameter(Mandatory)] [string] $Summary,
        [Parameter(Mandatory)] [string] $StoryTypeId
    )
    $base = Get-JiraCreateFieldsBase -ProjectKey $ProjectKey -Summary $Summary -IssueTypeId $StoryTypeId
    return '{"fields":' + $base + '}'
}

function New-JiraTicket {
    <#
    .SYNOPSIS
      Guarded write: PASS-1 privacy guard, POST /issue, identity stamp. Mirror
      of ticket_create. Returns { ExitCode; Json } — Json is the canonical
      {key} document.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ProjectKey,
        [Parameter(Mandatory)] [string] $Summary,
        [Parameter(Mandatory)] [string] $StoryTypeId,
        [string] $SpecRefJson = ''
    )
    if ([string]::IsNullOrEmpty($SpecRefJson)) { $SpecRefJson = '{}' }
    $base = $env:SPEC_KIT_JIRA_BASE_URL
    if ([string]::IsNullOrEmpty($base)) {
        [Console]::Error.WriteLine('ticket: SPEC_KIT_JIRA_BASE_URL is not set')
        return [pscustomobject]@{ ExitCode = (Get-JiraExitCode 'fail_closed'); Json = '' }
    }

    $body = Get-JiraTicketCreateBody -ProjectKey $ProjectKey -Summary $Summary -StoryTypeId $StoryTypeId

    # (1) Pre-write gate — BLOCK ⇒ exit 9, zero writes (Constitution IX).
    $allowlist = if ($env:SPEC_KIT_JIRA_ALLOWLIST) { $env:SPEC_KIT_JIRA_ALLOWLIST } else { '[]' }
    $guard = Test-JiraPrivacyBlock -Payload $body -KnownCoordinatesJson '[]' -AllowlistJson $allowlist
    if ($guard -ne 0) { return [pscustomobject]@{ ExitCode = [int] $guard; Json = '' } }

    # (2) The create write. A failure propagates its transport exit code
    #     (non-blocking fallback lives in the command layer, never here).
    $r = Invoke-JiraRequest -Method POST -Url "$base/rest/api/3/issue" -Body $body
    if ($r.ExitCode -ne 0) { return [pscustomobject]@{ ExitCode = [int] $r.ExitCode; Json = '' } }
    $key = [string] (($r.Body | ConvertFrom-Json -Depth 100).key)

    # (3) Identity stamp — the created ticket is a bridge-created artifact.
    $stamp = Set-JiraIdentity -IssueKey $key -SpecRefJson $SpecRefJson -Origin 'bridge'
    if ($stamp -ne 0) { return [pscustomobject]@{ ExitCode = [int] $stamp; Json = '' } }

    return [pscustomobject]@{ ExitCode = 0; Json = (ConvertTo-JiraJsonValue ([ordered]@{ key = $key })) }
}

Export-ModuleMember -Function Confirm-JiraTicket, Get-JiraCreateFieldsBase, Get-JiraTicketCreateBody, New-JiraTicket
