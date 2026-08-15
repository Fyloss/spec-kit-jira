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
Import-Module (Join-Path $PSScriptRoot 'Client.psm1')    # No -Force — see project memory: powershell-import-force-clobbers-caller-scope
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
      summary} (research R3, FR-025), plus (011, research R2) any recorded
      defaults for the type actually being created. Mirror of
      jira_create_fields_base. Both Get-JiraTicketCreateBody and
      Get-JiraPlanWriteSet build on this single builder so the two creation
      paths cannot drift apart again. The issue type is carried by ID only
      (never a literal name — Constitution VII).

      FieldDefaultsByTypeJson is the WHOLE plan-context map, {type_id:
      {field_id: value}} — this function itself scopes the merge to
      IssueTypeId, so a caller cannot get FR-018 wrong by passing the wrong
      sub-map. Omitted or empty ⇒ the merge is a no-op (FR-028, research R6),
      and the output is byte-identical to before this feature.

      Provenance (017, contracts/provenance-label.md §2) is OPTIONAL and
      passed by Get-JiraPlanWriteSet (the mirror) ONLY — Get-JiraTicketCreateBody
      (the feature ceremony) never passes it, for the same reason its Bash
      twin does not (see that function's own comment). When given, it is
      merged into `labels` AFTER the field-defaults spread, as a union with
      whatever default the type records, so a recorded `labels` default is
      preserved rather than overwritten. When empty, no `labels` key is
      produced at all.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $ProjectKey,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Summary,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $IssueTypeId,
        [string] $FieldDefaultsByTypeJson = '',
        [string] $Provenance = ''
    )
    $merged = [ordered]@{
        project   = [ordered]@{ key = $ProjectKey }
        issuetype = [ordered]@{ id = $IssueTypeId }
        summary   = $Summary
    }
    $defaultsForType = $null
    if (-not [string]::IsNullOrEmpty($FieldDefaultsByTypeJson) -and -not [string]::IsNullOrEmpty($IssueTypeId)) {
        $dbt = $FieldDefaultsByTypeJson | ConvertFrom-Json -Depth 100
        $typeProp = $dbt.PSObject.Properties[$IssueTypeId]
        if ($null -ne $typeProp -and $null -ne $typeProp.Value) { $defaultsForType = $typeProp.Value }
    }
    if ($null -ne $defaultsForType) {
        foreach ($p in $defaultsForType.PSObject.Properties) { $merged[$p.Name] = $p.Value }
    }
    if (-not [string]::IsNullOrEmpty($Provenance)) {
        $existingLabels = @()
        if ($null -ne $defaultsForType) {
            $labelsProp = $defaultsForType.PSObject.Properties['labels']
            if ($null -ne $labelsProp -and $null -ne $labelsProp.Value) { $existingLabels = @($labelsProp.Value) }
        }
        $labels = [string[]]@(@($existingLabels) + @($Provenance) | ForEach-Object { [string]$_ } | Select-Object -Unique)
        [System.Array]::Sort($labels, [System.StringComparer]::Ordinal)
        $merged['labels'] = $labels
    }
    return (ConvertTo-JiraJsonValue $merged)
}

function Get-JiraTicketFieldRejectionMessage {
    <#
    .SYNOPSIS
      011, contract §3.7, FR-019: when Jira rejects a creation because a value
      THIS RUN sent — from a recorded default or a this-run answer — is no
      longer valid, translate Jira's raw error body into one line per
      rejected field, naming it by its Jira label and the value that was
      sent, and the rejection in Jira's own words — never the raw API body.
      Mirror of ticket_field_rejection_message.

      Only a field that (a) this run actually sent in the action's own body
      and (b) is one of the type's defaultable_fields is reported here — a
      rejection on a bridge-supplied field is a different defect and is left
      to the existing generic failure path. Returns one line per rejected
      field, newline-joined, empty when Jira's rejected fields do not
      overlap anything this run defaulted.
    #>
    [CmdletBinding()]
    param(
        [string] $DefaultableFieldsByTypeJson = '{}',
        [Parameter(Mandatory)] [string] $ActionJson,
        [string] $ErrorBodyJson = '{}'
    )
    if ([string]::IsNullOrEmpty($DefaultableFieldsByTypeJson)) { $DefaultableFieldsByTypeJson = '{}' }
    if ([string]::IsNullOrEmpty($ErrorBodyJson)) { $ErrorBodyJson = '{}' }
    $df = $DefaultableFieldsByTypeJson | ConvertFrom-Json -Depth 100
    $action = $ActionJson | ConvertFrom-Json -Depth 100
    $errBody = $null
    try { $errBody = $ErrorBodyJson | ConvertFrom-Json -Depth 100 } catch { $null = $_ }
    if ($null -eq $errBody) { return '' }

    $fields = $action.body.fields
    $typeId = if ($fields -and $fields.PSObject.Properties['issuetype']) { [string] $fields.issuetype.id } else { '' }
    $fieldMeta = @()
    $typeProp = $df.PSObject.Properties[$typeId]
    if ($null -ne $typeProp) { $fieldMeta = @($typeProp.Value) }

    $errorsProp = $errBody.PSObject.Properties['errors']
    if ($null -eq $errorsProp -or $null -eq $errorsProp.Value) { return '' }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($ep in $errorsProp.Value.PSObject.Properties) {
        $fieldId = $ep.Name
        $reason = $ep.Value
        if (-not ($fields.PSObject.Properties.Name -contains $fieldId)) { continue }
        $meta = $null
        foreach ($f in $fieldMeta) { if ([string] $f.field_id -eq $fieldId) { $meta = $f; break } }
        if ($null -eq $meta) { continue }
        $raw = $fields.$fieldId
        # jq's `tostring` on the Bash twin: identity for a string, compact JSON
        # for anything else — matched here so both ports print the same text.
        $sentValue = if ($raw -is [string]) { $raw } else { ConvertTo-JiraJsonValue $raw }
        $lines.Add("reconcile: Jira rejected the value for `"$($meta.logical_name)`" — sent $sentValue, rejected because: $reason. Nothing was substituted and the creation was not retried.")
    }
    return ($lines -join "`n")
}

function Get-JiraTicketCreateBody {
    <#
    .SYNOPSIS
      The canonical create payload. Mirror of _ticket_create_body: wraps
      Get-JiraCreateFieldsBase unchanged, matching the Bash twin byte-for-byte.
      Deliberately passes NO Provenance argument (017, contract §2): the
      feature ceremony's single-item creation stays unlabelled at creation,
      and its specification's first reconcile back-fills the label like any
      other unlabelled ticket.
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
      {key} document. -Role (027, FR-023) is optional and empty by default —
      a seed-created parent passes 'parent' so reconcile's own recognition
      can tell a bridge-created parent from any other bridge-created issue.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ProjectKey,
        [Parameter(Mandatory)] [string] $Summary,
        [Parameter(Mandatory)] [string] $StoryTypeId,
        [string] $SpecRefJson = '',
        [string] $Role = ''
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
    # The summary this create sent becomes the LAST-WRITTEN summary record
    # (018, contracts/summary-record.md §1/§2): a later reconcile compares
    # against it, never against the text that seeded the create.
    $stamp = Set-JiraIdentity -IssueKey $key -SpecRefJson $SpecRefJson -Origin 'bridge' -Story '' -Role $Role -Summary $Summary
    if ($stamp -ne 0) { return [pscustomobject]@{ ExitCode = [int] $stamp; Json = '' } }

    return [pscustomobject]@{ ExitCode = 0; Json = (ConvertTo-JiraJsonValue ([ordered]@{ key = $key })) }
}

Export-ModuleMember -Function Confirm-JiraTicket, Get-JiraCreateFieldsBase, Get-JiraTicketCreateBody, New-JiraTicket, `
    Get-JiraTicketFieldRejectionMessage
