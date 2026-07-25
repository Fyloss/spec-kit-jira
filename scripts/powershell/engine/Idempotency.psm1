# engine/Idempotency.psm1 — Zero-churn idempotency diff. Mirror of
# engine/idempotency.sh (US6, T072).
#
# PURE engine module: zero Jira reads, zero writes, never imports sink/. A re-run
# on an unchanged corpus must produce zero writes of any kind (FR 030,
# Constitution II). These primitives decide whether a would-be write is churn so
# the caller can drop no-op actions before anything reaches Jira. See
# idempotency.sh for the full contract.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../lib/Output.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ManagedSection.psm1') -Force

function Test-JiraIdempotentEqual {
    # Ordinal byte equality — the primitive both ports share for a raw-bytes
    # decision. Mirror of idempotency_equal. Returns $true when identical.
    param([AllowEmptyString()] [string] $A, [AllowEmptyString()] [string] $B)
    return [System.String]::Equals($A, $B, [System.StringComparison]::Ordinal)
}

function Get-JiraIdempotentFieldStatus {
    <#
    .SYNOPSIS
      Compare the fields a write would set against the ticket's current fields.
      Returns "unchanged" iff every desired key is already present with a
      structurally equal value; otherwise "changed". Mirror of
      idempotency_field_status.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $CurrentFieldsJson, [Parameter(Mandatory)] [string] $DesiredFieldsJson)
    $cur = $CurrentFieldsJson | ConvertFrom-Json -Depth 100
    $des = $DesiredFieldsJson | ConvertFrom-Json -Depth 100

    # Canonical serialisation is order-independent (sorted keys), so comparing the
    # canonical form of each desired value against the current value gives jq's
    # content equality without depending on property order.
    $changed = $false
    if ($des -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $des.PSObject.Properties) {
            $curMember = if ($cur -is [System.Management.Automation.PSCustomObject]) { $cur.PSObject.Properties[$p.Name] } else { $null }
            $curVal = if ($null -eq $curMember) { $null } else { $curMember.Value }
            $desCanon = ConvertTo-JiraJsonValue $p.Value
            $curCanon = if ($null -eq $curVal) { 'null' } else { ConvertTo-JiraJsonValue $curVal }
            if (-not [System.String]::Equals($desCanon, $curCanon, [System.StringComparison]::Ordinal)) {
                $changed = $true
                break
            }
        }
    }
    if ($changed) { return 'changed' } else { return 'unchanged' }
}

function Get-JiraIdempotentManagedStatus {
    <#
    .SYNOPSIS
      Splice $NewBlock into $Text and compare byte-for-byte with $Text: returns
      "unchanged" for a no-op splice (zero churn), else "changed". Returns
      { ExitCode; Status } — ExitCode 4 with empty Status when the host markers are
      malformed (the splice's own contract). Mirror of idempotency_managed_status.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $BeginToken,
        [Parameter(Mandatory)] [string] $EndToken,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $NewBlock,
        [AllowEmptyString()] [string] $Text = ''
    )
    $spliced = Invoke-JiraManagedSectionSplice -Text $Text -BeginToken $BeginToken -EndToken $EndToken -NewBlock $NewBlock
    if ($spliced.ExitCode -ne 0) {
        return [pscustomobject]@{ ExitCode = [int]$spliced.ExitCode; Status = '' }
    }
    $status = if ([System.String]::Equals($Text, $spliced.Content, [System.StringComparison]::Ordinal)) { 'unchanged' } else { 'changed' }
    return [pscustomobject]@{ ExitCode = 0; Status = $status }
}

Export-ModuleMember -Function Test-JiraIdempotentEqual, Get-JiraIdempotentFieldStatus, Get-JiraIdempotentManagedStatus
