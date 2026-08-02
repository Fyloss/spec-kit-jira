# lib/Cli.psm1 — CLI arg parsing + the shared exit-code table. Mirror of lib/cli.sh.
#
# Emits the same machine-readable key=value lines in the same fixed order as the
# Bash port so the two are byte-identical (NFR-1). Lines are LF-separated; parse
# never terminates the process (the dispatcher reads `exit=`).
#
# Port infrastructure only: NO Jira knowledge.

Set-StrictMode -Version Latest

# Exit-code table (monotonically escalating — Constitution III).
$script:ExitCodes = @{
    ok          = 0
    usage       = 1
    fail_closed = 2
    auth        = 3
    config      = 4
    prereq      = 5
    block       = 9
}

function Get-JiraExitCode {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Symbol)
    if (-not $script:ExitCodes.ContainsKey($Symbol)) {
        throw "unknown exit-code symbol: $Symbol"
    }
    return $script:ExitCodes[$Symbol]
}

function Invoke-JiraCliParse {
    [CmdletBinding()]
    param([string[]] $Arguments = @())

    $command = ''
    $dryRun = 'false'
    $json = 'false'
    $onDrift = 'abort'
    $verbose = 'false'
    $help = 'false'
    $parseError = ''
    $useTeam = ''
    $positional = [System.Collections.Generic.List[string]]::new()
    $styles = [System.Collections.Generic.List[string]]::new()
    $childTypes = [System.Collections.Generic.List[string]]::new()
    $issueTypes = [System.Collections.Generic.List[string]]::new()
    $enableHooks = [System.Collections.Generic.List[string]]::new()

    for ($idx = 0; $idx -lt $Arguments.Count; $idx++) {
        $arg = $Arguments[$idx]
        switch -Regex ($arg) {
            '^(config|reconcile|mention|feature)$' {
                if ([string]::IsNullOrEmpty($command)) { $command = $arg } else { $positional.Add($arg) }
                break
            }
            '^--dry-run$' { $dryRun = 'true'; break }
            '^--json$' { $json = 'true'; break }
            '^--verbose$' { $verbose = 'true'; break }
            '^(--help|-h)$' { $help = 'true'; break }
            '^--style$' {
                # Repeatable operator answer to the closed style question (002 US1).
                if ($idx + 1 -ge $Arguments.Count) {
                    $parseError = '--style requires a value (--style KEY=VALUE)'
                }
                else {
                    $idx++
                    $v = $Arguments[$idx]
                    if ($v -cmatch '^[A-Z][A-Z0-9_]+=(company_managed|team_managed)$') { $styles.Add($v) }
                    else { $parseError = "invalid --style value: $v (expected <PROJECT_KEY>=company_managed|team_managed)" }
                }
                break
            }
            '^--child-type$' {
                # Repeatable operator answer to the child-type closed
                # question (008 T044, research R1/R2), asked only when the
                # child hierarchy level holds several candidates. The
                # logical name is opaque text (Constitution VII). Kept as
                # the accepted alias for --issue-type KEY=story=<name> (010,
                # contract §2.2, research R2).
                if ($idx + 1 -ge $Arguments.Count) {
                    $parseError = '--child-type requires a value (--child-type KEY=<logical name>)'
                }
                else {
                    $idx++
                    $v = $Arguments[$idx]
                    if ($v -cmatch '^[A-Z][A-Z0-9_]+=\S+$') {
                        $childTypes.Add($v)
                        $eq = $v.IndexOf('=')
                        $issueTypes.Add("$($v.Substring(0, $eq))=story=$($v.Substring($eq + 1))")
                    }
                    else { $parseError = "invalid --child-type value: $v (expected <PROJECT_KEY>=<logical name>, no whitespace)" }
                }
                break
            }
            '^--issue-type$' {
                # Repeatable operator answer to the closed role question
                # (010, contract §2.2): --issue-type KEY=role=<logical
                # name>, last occurrence per (KEY, role) wins. <role> is the
                # closed set specification|story|task.
                if ($idx + 1 -ge $Arguments.Count) {
                    $parseError = '--issue-type requires a value (--issue-type KEY=role=<logical name>)'
                }
                else {
                    $idx++
                    $v = $Arguments[$idx]
                    if ($v -cmatch '^[A-Z][A-Z0-9_]+=(specification|story|task)=\S+$') { $issueTypes.Add($v) }
                    else { $parseError = "invalid --issue-type value: $v (expected <PROJECT_KEY>=<specification|story|task>=<logical name>, no whitespace)" }
                }
                break
            }
            '^--use-team$' {
                # The answer to the cross-team closed confirmation (002 US3, FR-014).
                if ($idx + 1 -ge $Arguments.Count) {
                    $parseError = '--use-team requires a value (--use-team <id>)'
                }
                else {
                    $idx++
                    $useTeam = $Arguments[$idx]
                }
                break
            }
            '^--enable-hook$' {
                # The operator's explicit release of a held lifecycle event (003
                # FR-007, FR-029). Repeatable. It exists because `specify
                # extension add` rewrites `enabled: true` unconditionally, so the
                # extension cannot tell an operator's re-enable from the
                # install's — and guessing would silently discard a deliberate
                # choice (research R5). One explicit flag, named in the
                # ceremony's own report, is the honest mechanism.
                if ($idx + 1 -ge $Arguments.Count) {
                    $parseError = '--enable-hook requires a lifecycle event (--enable-hook <event>)'
                }
                else {
                    $idx++
                    $enableHooks.Add($Arguments[$idx])
                }
                break
            }
            '^--on-drift=' {
                $onDrift = $arg.Substring($arg.IndexOf('=') + 1)
                if ($onDrift -ne 'abort' -and $onDrift -ne 'proceed') {
                    $parseError = "invalid --on-drift value: $onDrift (expected abort|proceed)"
                }
                break
            }
            '^--on-drift$' { $parseError = '--on-drift requires a value (--on-drift=abort|proceed)'; break }
            '^--' { $parseError = "unknown flag: $arg"; break }
            default { $positional.Add($arg); break }
        }
        if ($parseError) { break }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    if ($parseError) {
        $lines.Add("exit=$($script:ExitCodes.usage)")
        $lines.Add("error=$parseError")
    }
    else {
        $lines.Add("command=$command")
        $lines.Add("dry_run=$dryRun")
        $lines.Add("json=$json")
        $lines.Add("on_drift=$onDrift")
        $lines.Add("verbose=$verbose")
        $lines.Add("help=$help")
        $lines.Add("styles=$($styles -join ' ')")
        $lines.Add("child_types=$($childTypes -join ' ')")
        $lines.Add("issue_types=$($issueTypes -join ' ')")
        $lines.Add("use_team=$useTeam")
        $lines.Add("enable_hooks=$($enableHooks -join ' ')")
        $lines.Add("args=$($positional -join ' ')")
        $lines.Add("exit=$($script:ExitCodes.ok)")
    }
    # Return the LF-joined state (with a trailing LF). Callers that need real
    # stdout wrap this in [Console]::Out.Write; command substitution strips the
    # trailing newline on both ports so bytes match (NFR-1).
    return (($lines -join "`n") + "`n")
}

Export-ModuleMember -Function Get-JiraExitCode, Invoke-JiraCliParse
