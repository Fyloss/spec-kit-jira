# engine/Drift.psm1 — Status-category-aware drift classification. Mirror of
# engine/drift.sh (US6, T071).
#
# PURE engine module: zero Jira reads, zero writes, never imports sink/. Given a
# ticket's current status, its classification category (mapped / post-scope /
# halted / unknown), the disk-inferred target status, the operator's phase-ordered
# status sequence, and the --on-drift mode, it decides the transition's fate and
# never silently overwrites Jira-side progress. See drift.sh for the full contract.
#
# Decision object (canonical): { decision, content_writes, warnings[], remediations[] }
#   decision: "transition" | "withhold" | "halt".

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../lib/Output.psm1') -Force

function Get-JiraDriftDecision {
    <#
    .SYNOPSIS
      Classify one ticket's drift and decide its fate. Mirror of drift_evaluate.
      Input JSON: { current_status, current_category, target_status,
                    order:[status,...], on_drift:"abort"|"proceed" }. Returns the
      canonical decision object as JSON.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $InputJson)
    $in = $InputJson | ConvertFrom-Json -Depth 100

    $cur = ''
    $curMember = $in.PSObject.Properties['current_status']
    if ($null -ne $curMember -and $null -ne $curMember.Value) { $cur = [string] $curMember.Value }
    $cat = 'unknown'
    $catMember = $in.PSObject.Properties['current_category']
    if ($null -ne $catMember -and $null -ne $catMember.Value) { $cat = [string] $catMember.Value }
    $tgt = ''
    $tgtMember = $in.PSObject.Properties['target_status']
    if ($null -ne $tgtMember -and $null -ne $tgtMember.Value) { $tgt = [string] $tgtMember.Value }
    $order = @()
    $orderMember = $in.PSObject.Properties['order']
    if ($null -ne $orderMember -and $null -ne $orderMember.Value) { $order = @($orderMember.Value) }
    $onDrift = 'abort'
    $odMember = $in.PSObject.Properties['on_drift']
    if ($null -ne $odMember -and [string]$odMember.Value -eq 'proceed') { $onDrift = 'proceed' }

    # index() semantics: $null when absent so a position is only comparable when
    # both statuses appear in the operator's ordered sequence.
    $ci = $null
    $ti = $null
    for ($k = 0; $k -lt $order.Count; $k++) {
        if ($null -eq $ci -and [string]$order[$k] -eq $cur) { $ci = $k }
        if ($null -eq $ti -and [string]$order[$k] -eq $tgt) { $ti = $k }
    }

    $decision = 'transition'
    $contentWrites = $true
    $warnings = [System.Collections.Generic.List[string]]::new()
    $remediations = [System.Collections.Generic.List[string]]::new()

    if ($cat -eq 'halted') {
        $decision = 'halt'
        $contentWrites = $false
        $warnings.Add("ticket status `"$cur`" is halted; all writes to this ticket are withheld until a human resolves it")
        $remediations.Add('archive the specification')
        $remediations.Add('reopen the ticket')
    }
    elseif ($cat -eq 'unknown') {
        $decision = 'withhold'
        $warnings.Add("status `"$cur`" is unclassified; its drift cannot be evaluated — run the config command to classify it, then reconcile")
    }
    elseif ($cat -eq 'post-scope') {
        if ($null -ne $ci -and $null -ne $ti -and $ti -lt $ci) {
            if ($onDrift -eq 'proceed') {
                $decision = 'transition'
                $warnings.Add("ticket sits in post-scope status `"$cur`" but the specification regressed to `"$tgt`"; pulling it backward per --on-drift=proceed")
            }
            else {
                $decision = 'withhold'
                $warnings.Add("ticket sits in post-scope status `"$cur`" but the specification regressed to `"$tgt`"; the backward transition is withheld — pass --on-drift=proceed to pull it back")
            }
        }
    }
    else {
        # mapped
        if ($null -ne $ci -and $null -ne $ti -and $ci -gt $ti) {
            if ($onDrift -eq 'proceed') {
                $decision = 'transition'
                $warnings.Add("ticket advanced Jira-side to `"$cur`", beyond the specification's `"$tgt`"; pulling it back per --on-drift=proceed")
            }
            else {
                $decision = 'withhold'
                $warnings.Add("ticket advanced Jira-side to `"$cur`", beyond the specification's `"$tgt`"; the transition is withheld to avoid overwriting that progress (drift)")
            }
        }
    }

    $out = [ordered]@{
        decision       = $decision
        content_writes = $contentWrites
        warnings       = $warnings
        remediations   = $remediations
    }
    return (ConvertTo-JiraJsonValue $out)
}

Export-ModuleMember -Function Get-JiraDriftDecision
