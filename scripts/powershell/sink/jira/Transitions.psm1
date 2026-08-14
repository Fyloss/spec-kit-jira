# sink/jira/Transitions.psm1 — read a ticket's available moves and resolve
# them by destination NAME, never by category (023, contracts/transition-
# resolution.md). Mirror of sink/jira/transitions.sh. This is the tier that
# reads the declared step and decides how to reach it;
# Get-JiraDiscoveryTaskTransitionResult (Discovery.psm1) keeps its own,
# unrelated rule — selection by destination statusCategory — for the task
# tier's done/not-done question (research D3).
#
# Branch C (research R1, decided 2026-08-13): one GET per ticket due a move —
# `GET /issue/{key}/transitions?expand=transitions.fields`, the exact
# spelling Get-JiraDiscoveryTaskTransitionResult already uses in production.
# There is no bulk form: 021's dogfood-verified bulkfetch shape names no
# `expand` member and no `transitions` array, so branch A has no measured
# evidence and branch C — already proven against the real instance — is
# what this module implements.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../../lib/Output.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Client.psm1')    # No -Force — see project's PowerShell import note

# lower-cased key -> canonical availability record (data-model.md §3,
# extended with each move's own `name` — needed by the ambiguous outcome's
# candidate list, contract §4 — never used in the decision itself, contract
# §3 M1). Reset-JiraTransitionsCache exists so tests never leak state across
# cases.
$script:JiraTransitionsMap = @{}

function Reset-JiraTransitionsCache {
    <#
    .SYNOPSIS
      Empties the map. Test support (contract §2).
    #>
    [CmdletBinding()]
    param()
    $script:JiraTransitionsMap = @{}
}

function Import-JiraTransitions {
    <#
    .SYNOPSIS
      One GET per key (branch C), populating the map. Returns 0 on full
      success. On ANY read failure (retries exhausted) returns the failing
      request's own exit code immediately, without reading the remaining
      keys — the authoritative read fails closed for the WHOLE specification
      (contract §2 F2), matching Get-JiraDiscoveryTaskTransitionResult's
      existing treatment of the identical read. There is no bulk form to
      fall back from (F1 is vacuous under branch C).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Names the module: it reads and caches the set of tickets'' available transitions; a singular name would misdescribe it.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string[]] $Key)

    Reset-JiraTransitionsCache
    if ($Key.Count -eq 0) { return 0 }

    $base = $env:SPEC_KIT_JIRA_BASE_URL
    $api = "$base/rest/api/3"
    foreach ($k in $Key) {
        $r = Invoke-JiraRequest -Method GET -Url "$api/issue/$k/transitions?expand=transitions.fields"
        if ($r.ExitCode -ne 0) { return [int] $r.ExitCode }
        $resp = $r.Body | ConvertFrom-Json -Depth 100
        $moves = @()
        foreach ($t in @($resp.transitions)) {
            $gatedField = $null
            $fields = $t.fields
            $requiredEntry = $null
            if ($null -ne $fields) {
                foreach ($prop in $fields.PSObject.Properties) {
                    if ([bool]($prop.Value.required)) { $requiredEntry = $prop; break }
                }
            }
            if ($null -ne $requiredEntry) {
                $logicalName = $requiredEntry.Value.name
                if (-not $logicalName) { $logicalName = $requiredEntry.Name }
                $gatedField = [ordered]@{ logical_name = $logicalName; field_id = $requiredEntry.Name }
            }
            # $t.to.name accessed via .PSObject.Properties, never dot access:
            # a candidate classified only by statusCategory (no name) is a
            # real shape (023, task-role due set sharing a mock config with
            # 012's category-only completion pass) and StrictMode throws on
            # a missing property via dot access.
            $toName = $null
            $toMember = $t.to.PSObject.Properties['name']
            if ($null -ne $toMember) { $toName = $toMember.Value }
            $moves += [ordered]@{ id = $t.id; name = $t.name; to = $toName; gated_field = $gatedField }
        }
        $entry = [ordered]@{ key = $k; moves = $moves }
        $script:JiraTransitionsMap[$k.ToLowerInvariant()] = (ConvertTo-JiraJsonValue $entry)
    }
    return 0
}

function Get-JiraTransitionRecord {
    <#
    .SYNOPSIS
      The cached availability record (data-model.md §3), matched back to the
      requested key case-insensitively, never by position (F3). Returns
      $null on a miss; never issues a read itself — the caller must have
      called Import-JiraTransitions first.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Key)
    $lower = $Key.ToLowerInvariant()
    if (-not $script:JiraTransitionsMap.ContainsKey($lower)) { return $null }
    return $script:JiraTransitionsMap[$lower]
}

function Resolve-JiraTransition {
    <#
    .SYNOPSIS
      The pure rule of contract §3: exactly one of four outcomes
      (data-model.md §4). Comparison against DeclaredStep is exact string
      equality (M2) — a difference in case or spacing is a different step,
      never accepted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RecordJson,
        [Parameter(Mandatory)] [string] $DeclaredStep
    )
    $record = $RecordJson | ConvertFrom-Json -Depth 100
    $moves = @($record.moves)
    # -ceq, never -eq: PowerShell's -eq is case-INsensitive by default, which
    # would accept "in progress" for a declared "In Progress" — exactly the
    # M2 violation contract §3 forbids.
    $cands = @($moves | Where-Object { [string]$_.to -ceq $DeclaredStep })
    $n = $cands.Count

    if ($n -eq 1 -and $null -eq $cands[0].gated_field) {
        $out = [ordered]@{ outcome = 'move'; transition_id = $cands[0].id }
    }
    elseif ($n -eq 1) {
        $out = [ordered]@{ outcome = 'gated'; gated_field = $cands[0].gated_field }
    }
    elseif ($n -ge 2) {
        $candidateList = @($cands | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name } })
        $out = [ordered]@{ outcome = 'ambiguous'; candidates = $candidateList }
    }
    else {
        $reachable = @($moves | ForEach-Object { [string]$_.to })
        $out = [ordered]@{ outcome = 'unreachable'; reachable = $reachable }
    }
    return (ConvertTo-JiraJsonValue $out)
}

Export-ModuleMember -Function Reset-JiraTransitionsCache, Import-JiraTransitions, `
    Get-JiraTransitionRecord, Resolve-JiraTransition
