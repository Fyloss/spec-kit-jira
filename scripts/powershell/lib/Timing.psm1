# lib/Timing.psm1 — Per-phase wall time and request count (spec FR-001…FR-006,
# contracts/timing-report.md). Mirror of lib/timing.sh.
#
# Off by default: SPEC_KIT_JIRA_TIMING unset or empty makes every function
# here a no-op, so the mode costs nothing when nobody asked for it. On, it
# marks the eight fixed phases of data-model.md §2 and prints one line per
# phase reached plus a total, to stderr only, in the fixed-width shape the
# corpus diffs byte-for-byte across ports under an injected clock.
#
# Unlike the Bash port there is no clock-tier chain here (research R1):
# [datetime]::UtcNow.Ticks is always available and never forks, so there is
# no probed fallback and no degraded-clock banner to emit.
#
# The Bash twin reads a shared JIRA_REQUEST_COUNT global directly; a
# PowerShell module has no equivalent shared namespace to reach into (T013's
# counter is $script:-scoped inside Client.psm1), so the request count is
# instead an explicit -RequestCount parameter the caller supplies at both
# Start-JiraTimingPhase and Stop-JiraTimingPhase — the delta between the two
# is what gets reported.
#
# Port infrastructure only: NO Jira knowledge.

Set-StrictMode -Version Latest

# The eight phases, in the one fixed order data-model.md §2 requires.
# Write-JiraTimingReport iterates this list and skips whatever was not
# reached — it never sorts by call order, so a phase begun out of sequence
# still prints in its canonical place.
$script:TimingPhaseOrder = @('prereq', 'state', 'config', 'parse', 'gate', 'recognition', 'plan', 'apply')

$script:TimingStartMs = @{}
$script:TimingElapsedMs = @{}
$script:TimingReqs = @{}
$script:TimingFakeClockIdx = 0

<#
.SYNOPSIS
  True when SPEC_KIT_JIRA_TIMING is set to any non-empty value.
#>
function Test-JiraTimingEnabled {
    [CmdletBinding()]
    param()
    return [bool]$env:SPEC_KIT_JIRA_TIMING
}

# Get-TimingFakeClockNext — consume one whitespace-separated reading from
# $env:_TIMING_FAKE_CLOCK, in order. Returns the last reading again once
# exhausted rather than throwing (contracts/timing-report.md §4): an
# under-supplied fixture shows 0 ms phases instead of crashing a run.
function Get-TimingFakeClockNext {
    [CmdletBinding()]
    param()
    $readings = @($env:_TIMING_FAKE_CLOCK -split '\s+' | Where-Object { $_ -ne '' })
    $n = $readings.Count
    # A set-but-empty fixture supplies zero readings, which would clamp the
    # cursor to -1 and index an empty array — an IndexOutOfRangeException under
    # Set-StrictMode -Version Latest, crashing the run rather than degrading.
    # §4's "degrade, never crash" has to hold at zero too. Mirror of the bash
    # port's own zero-readings guard.
    if ($n -eq 0) { return [int64]0 }
    $idx = $script:TimingFakeClockIdx
    if ($idx -ge $n) { $idx = $n - 1 }
    if ($idx -lt $n - 1) { $script:TimingFakeClockIdx = $idx + 1 }
    return [int64]$readings[$idx]
}

# Get-TimingClockReading — the current reading, in milliseconds. $env:_TIMING_FAKE_CLOCK,
# when set, always wins: no real clock is read, which is what keeps a timing
# scenario's stderr byte-identical across runs and across ports.
function Get-TimingClockReading {
    [CmdletBinding()]
    param()
    if ($env:_TIMING_FAKE_CLOCK) {
        return Get-TimingFakeClockNext
    }
    return [int64]([datetime]::UtcNow.Ticks / 10000)
}

<#
.SYNOPSIS
  Mark the start of one phase. A no-op when timing is off. Mirror of
  timing_phase_begin.
#>
function Start-JiraTimingPhase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Phase,
        [int] $RequestCount = 0
    )
    if (-not (Test-JiraTimingEnabled)) { return }
    $script:TimingStartMs[$Phase] = Get-TimingClockReading
    $script:TimingReqs[$Phase] = -$RequestCount
}

<#
.SYNOPSIS
  Mark the end of one phase, recording elapsed wall time and the RequestCount
  delta since the matching Start-JiraTimingPhase. A no-op when timing is off,
  and silently ignored if there is no matching start (never errors the run it
  is instrumenting). Mirror of timing_phase_end.
#>
function Stop-JiraTimingPhase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Phase,
        [int] $RequestCount = 0
    )
    if (-not (Test-JiraTimingEnabled)) { return }
    if (-not $script:TimingStartMs.ContainsKey($Phase)) { return }
    $start = $script:TimingStartMs[$Phase]
    $script:TimingElapsedMs[$Phase] = (Get-TimingClockReading) - $start
    $script:TimingReqs[$Phase] = $script:TimingReqs[$Phase] + $RequestCount
}

<#
.SYNOPSIS
  Print one line per phase reached, in fixed order, plus a total, to stderr.
  A no-op when timing is off or no phase was reached. Mirror of timing_report.
#>
function Write-JiraTimingReport {
    [CmdletBinding()]
    param()
    if (-not (Test-JiraTimingEnabled)) { return }

    $reached = $script:TimingPhaseOrder | Where-Object { $script:TimingElapsedMs.ContainsKey($_) }
    if (-not $reached) { return }

    $totalMs = 0
    $totalReq = 0
    foreach ($phase in $reached) {
        $ms = $script:TimingElapsedMs[$phase]
        $req = $script:TimingReqs[$phase]
        [Console]::Error.WriteLine(('timing: {0,-11} {1,6} ms {2,4} requests' -f $phase, $ms, $req))
        $totalMs += $ms
        $totalReq += $req
    }
    [Console]::Error.WriteLine(('timing: {0,-11} {1,6} ms {2,4} requests' -f 'total', $totalMs, $totalReq))
}

Export-ModuleMember -Function Test-JiraTimingEnabled, Start-JiraTimingPhase, Stop-JiraTimingPhase, Write-JiraTimingReport
