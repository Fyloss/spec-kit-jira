# commands/Mention.psm1 — The mention command. Mirror of commands/mention.sh
# (US10, T088; FR-049/FR-050/FR-051).
#
# Adopts an existing, human-authored Jira ticket into a spec: reads the ticket's
# identity marker; if it already carries ANOTHER spec's identity it makes ZERO
# writes and refuses with an actionable message (EXIT_CONFIG 4, FR-051); otherwise
# it performs the read-only content fetch (FR-050), stamps the spec's identity
# (origin human), updates only that ticket, and logs the mutation (FR-049). Writes
# the run summary via the [Console] streams and returns ONLY its numeric exit code.
# Byte-identical to the Bash port (NFR-1).

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../lib/Cli.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../lib/Output.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../lib/Config.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../sink/jira/Identity.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../sink/jira/Discovery.psm1') -Force

function Invoke-JiraMention {
    <#
    .SYNOPSIS
      Read/edit one mentioned ticket. Writes the run summary via the [Console]
      streams and returns ONLY its numeric exit code.
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments = @())

    $parsed = Invoke-JiraCliParse -Arguments $Arguments
    $state = @{}
    foreach ($line in ($parsed -split "`n")) {
        if ($line -match '^([^=]+)=(.*)$') { $state[$Matches[1]] = $Matches[2] }
    }
    if ($state['exit'] -ne '0') {
        if ($state.ContainsKey('error') -and $state['error']) { [Console]::Error.WriteLine("mention: $($state['error'])") }
        return [int] $state['exit']
    }
    $json = $state['json'] -eq 'true'
    $dryRun = $state['dry_run'] -eq 'true'

    # The issue key is the sole required positional argument (cli-contract.md).
    $posArgs = if ($state.ContainsKey('args')) { [string]$state['args'] } else { '' }
    $issueKey = ($posArgs -split ' ')[0]
    if ([string]::IsNullOrEmpty($issueKey)) {
        [Console]::Error.WriteLine('mention: an issue key argument is required (mention PROJ-123)')
        return [int](Get-JiraExitCode 'usage')
    }

    # The resolution chokepoint (030, plan.md §Key design decision): seed
    # SPEC_KIT_JIRA_BASE_URL / JIRA_EMAIL from config.yml / personal.yml,
    # environment first.
    $chokepointRc = Resolve-JiraConnection -ConfigDir (Get-JiraConfigDirPath)
    if ($chokepointRc -ne 0) { return [int] $chokepointRc }

    $base = if ($env:SPEC_KIT_JIRA_BASE_URL) { $env:SPEC_KIT_JIRA_BASE_URL } else { '' }
    if ([string]::IsNullOrEmpty($base)) {
        [Console]::Error.WriteLine('mention: SPEC_KIT_JIRA_BASE_URL is not set')
        return [int](Get-JiraExitCode 'fail_closed')
    }

    $repo = if ($env:SPEC_KIT_JIRA_REPO) { $env:SPEC_KIT_JIRA_REPO } else { 'local/repo' }
    $slug = if ($env:SPEC_KIT_JIRA_SPEC_SLUG) { $env:SPEC_KIT_JIRA_SPEC_SLUG } else { 'spec' }
    $specRef = ConvertTo-JiraJsonValue ([ordered]@{ repo = $repo; spec_slug = $slug })

    # (1) Identity read — a fail-closed read (non-404) aborts before any write.
    $idRes = Get-JiraIdentity -IssueKey $issueKey
    if ([int]$idRes.ExitCode -ne 0) { return [int]$idRes.ExitCode }
    $marker = $idRes.Value

    # (2) FR-051: a ticket already claimed by ANOTHER spec is refused, zero writes.
    if (-not [string]::IsNullOrEmpty($marker) -and (Test-JiraIdentityClaimedByOther -MarkerJson $marker -SpecRefJson $specRef)) {
        $m = $marker | ConvertFrom-Json -Depth 100
        $mrepo = if ($m.PSObject.Properties.Name -contains 'repo' -and $null -ne $m.repo) { [string]$m.repo } else { '?' }
        $mslug = if ($m.PSObject.Properties.Name -contains 'spec_slug' -and $null -ne $m.spec_slug) { [string]$m.spec_slug } else { '?' }
        [Console]::Error.WriteLine("mention: $issueKey is already claimed by another spec ($mrepo/$mslug); reopen that spec, or proceed with a new ticket linked to $issueKey")
        $rsummary = ConvertTo-JiraJsonValue ([ordered]@{
                schema_version = '1.0'; command = 'mention'; dry_run = [bool]$dryRun
                counts         = [ordered]@{ created = 0; updated = 0; skipped = 0; warnings = 0; errors = 1 }
                mutations      = @(); exit_code = 4
            })
        if ($json) { [Console]::Out.Write($rsummary + "`n") }
        else { [Console]::Out.Write((ConvertTo-JiraSummaryProse -Json $rsummary)) }
        return [int](Get-JiraExitCode 'config')
    }

    # (3) FR-050 read-only fetch — a fail-closed read aborts before the stamp. The
    #     fetched neutral doc is materialised when SPEC_KIT_JIRA_MENTION_OUT is set.
    $fetchRes = Get-JiraMentionedFetchResult -IssueKey $issueKey
    if ([int]$fetchRes.ExitCode -ne 0) { return [int]$fetchRes.ExitCode }
    if ($env:SPEC_KIT_JIRA_MENTION_OUT -and -not $dryRun) {
        [System.IO.File]::WriteAllText($env:SPEC_KIT_JIRA_MENTION_OUT, $fetchRes.Fetch + "`n", [System.Text.UTF8Encoding]::new($false))
    }

    # (4) FR-049: stamp the spec's identity (origin human) and log the mutation. The
    #     --dry-run twin predicts the same single mutation without performing it.
    if (-not $dryRun) {
        $wr = Set-JiraIdentity -IssueKey $issueKey -SpecRefJson $specRef -Origin 'human'
        if ([int]$wr -ne 0) { return [int]$wr }
    }

    $summary = ConvertTo-JiraJsonValue ([ordered]@{
            schema_version = '1.0'; command = 'mention'; dry_run = [bool]$dryRun
            counts         = [ordered]@{ created = 0; updated = 1; skipped = 0; warnings = 0; errors = 0 }
            mutations      = @([ordered]@{ ticket = $issueKey; action = 'stamped spec identity marker' })
            exit_code      = 0
        })
    if ($json) { [Console]::Out.Write($summary + "`n") }
    else { [Console]::Out.Write((ConvertTo-JiraSummaryProse -Json $summary)) }
    return 0
}

Export-ModuleMember -Function Invoke-JiraMention
