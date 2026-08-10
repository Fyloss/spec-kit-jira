# lib/Cli.psm1 — CLI arg parsing + the shared exit-code table. Mirror of lib/cli.sh.
#
# Emits the same machine-readable key=value lines in the same fixed order as the
# Bash port so the two are byte-identical (NFR-1). Lines are LF-separated; parse
# never terminates the process (the dispatcher reads `exit=`).
#
# Port infrastructure only: NO Jira knowledge.

Set-StrictMode -Version Latest

# NOT -Force: a -Force reimport here is Remove-Module + Import-Module, which
# can tear Output.psm1 out of a caller that already imported it in this
# session and re-scope it to this module instead (a documented landmine —
# see the project memory on lib module imports from a nested module).
Import-Module (Join-Path $PSScriptRoot 'Output.psm1') # ConvertTo-JiraJsonValue — Get-JiraFieldAnswersFor's canonical output

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

function Test-JiraFieldFlagShape {
    <#
    .SYNOPSIS
      Shape check for --field-default/--field-value (011, T017/T019): split
      on the FIRST THREE `=` separators only — the value (fourth segment) may
      itself contain `=` or whitespace and is never split further. Mirror of
      _cli_field_flag_parts (used here only for its true/false shape verdict;
      the bash twin's tab-joined parts are not needed by this port's callers).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Value)
    $rest = $Value
    $eq = $rest.IndexOf('=')
    if ($eq -lt 0) { return $false }
    $pkey = $rest.Substring(0, $eq); $rest = $rest.Substring($eq + 1)
    $eq = $rest.IndexOf('=')
    if ($eq -lt 0) { return $false }
    $itype = $rest.Substring(0, $eq); $rest = $rest.Substring($eq + 1)
    $eq = $rest.IndexOf('=')
    if ($eq -lt 0) { return $false }
    $label = $rest.Substring(0, $eq)
    if ([string]::IsNullOrEmpty($pkey) -or [string]::IsNullOrEmpty($itype) -or [string]::IsNullOrEmpty($label)) { return $false }
    return ($pkey -cmatch '^[A-Z][A-Z0-9_]+$')
}

function Get-JiraFieldFlagPart {
    <#
    .SYNOPSIS
      Split a --field-default/--field-value VALUE on the FIRST THREE `=`
      separators only (011, T017/T019). Mirror of _cli_field_flag_parts.
      Returns $null when malformed; otherwise a pscustomobject
      {ProjectKey; IssueType; Label; Value}.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Value)
    $rest = $Value
    $eq = $rest.IndexOf('=')
    if ($eq -lt 0) { return $null }
    $pkey = $rest.Substring(0, $eq); $rest = $rest.Substring($eq + 1)
    $eq = $rest.IndexOf('=')
    if ($eq -lt 0) { return $null }
    $itype = $rest.Substring(0, $eq); $rest = $rest.Substring($eq + 1)
    $eq = $rest.IndexOf('=')
    if ($eq -lt 0) { return $null }
    $label = $rest.Substring(0, $eq); $value = $rest.Substring($eq + 1)
    if ([string]::IsNullOrEmpty($pkey) -or [string]::IsNullOrEmpty($itype) -or [string]::IsNullOrEmpty($label)) { return $null }
    if ($pkey -cnotmatch '^[A-Z][A-Z0-9_]+$') { return $null }
    return [pscustomobject]@{ ProjectKey = $pkey; IssueType = $itype; Label = $label; Value = $value }
}

function Get-JiraFieldAnswersFor {
    <#
    .SYNOPSIS
      One project's --field-default/--field-value answers for this run (011,
      contract §2.4/§3.5), reduced to an array of {type; label; value} in
      argv order. FieldFlags is Invoke-JiraCliParse's \x1f-joined
      field_defaults/field_values stream (NOT space-joined — a field VALUE
      may itself contain spaces). Shared by the config ceremony and the
      reconcile command, so a malformed token is parsed identically wherever
      it is answered.
    #>
    [CmdletBinding()]
    param([string] $ProjectKey, [string] $FieldFlags)
    $out = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrEmpty($FieldFlags)) { return (ConvertTo-JiraJsonValue $out) }
    $us = [char]0x1F
    foreach ($tok in $FieldFlags.Split($us)) {
        if ([string]::IsNullOrEmpty($tok)) { continue }
        $parts = Get-JiraFieldFlagPart -Value $tok
        if ($null -eq $parts) { continue }
        if ($parts.ProjectKey -ne $ProjectKey) { continue }
        $out.Add([ordered]@{ type = $parts.IssueType; label = $parts.Label; value = $parts.Value })
    }
    return (ConvertTo-JiraJsonValue $out)
}

function Invoke-JiraCliParse {
    [CmdletBinding()]
    param([string[]] $Arguments = @())

    $command = ''
    $dryRun = 'false'
    $force = 'false'
    $json = 'false'
    $onDrift = 'abort'
    $verbose = 'false'
    $help = 'false'
    $parseError = ''
    $useTeam = ''
    $acceptDefaults = 'false'
    $positional = [System.Collections.Generic.List[string]]::new()
    $styles = [System.Collections.Generic.List[string]]::new()
    $childTypes = [System.Collections.Generic.List[string]]::new()
    $issueTypes = [System.Collections.Generic.List[string]]::new()
    $enableHooks = [System.Collections.Generic.List[string]]::new()
    $fieldDefaults = [System.Collections.Generic.List[string]]::new()
    $fieldValues = [System.Collections.Generic.List[string]]::new()
    $taskMirrors = [System.Collections.Generic.List[string]]::new()

    for ($idx = 0; $idx -lt $Arguments.Count; $idx++) {
        $arg = $Arguments[$idx]
        switch -Regex ($arg) {
            '^(config|reconcile|mention|feature)$' {
                if ([string]::IsNullOrEmpty($command)) { $command = $arg } else { $positional.Add($arg) }
                break
            }
            '^--dry-run$' { $dryRun = 'true'; break }
            '^--force$' { $force = 'true'; break }
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
            '^--field-default$' {
                # The recording flag of FR-006/contract §2.4: repeatable
                # <PROJECT_KEY>=<Type>=<Label>=<Value>. A malformed shape is a
                # usage error here; an empty/disallowed VALUE is the
                # ceremony's content refusal (§2.4), not this one's.
                if ($idx + 1 -ge $Arguments.Count) {
                    $parseError = '--field-default requires a value (--field-default KEY=Type=Label=Value)'
                }
                else {
                    $idx++
                    $v = $Arguments[$idx]
                    if (Test-JiraFieldFlagShape -Value $v) { $fieldDefaults.Add($v) }
                    else { $parseError = "invalid --field-default value: $v (expected <PROJECT_KEY>=<Type>=<Label>=<Value>)" }
                }
                break
            }
            '^--field-value$' {
                # The per-run answer of FR-012/contract §3.5 — same shape,
                # applied for this run only rather than persisted.
                if ($idx + 1 -ge $Arguments.Count) {
                    $parseError = '--field-value requires a value (--field-value KEY=Type=Label=Value)'
                }
                else {
                    $idx++
                    $v = $Arguments[$idx]
                    if (Test-JiraFieldFlagShape -Value $v) { $fieldValues.Add($v) }
                    else { $parseError = "invalid --field-value value: $v (expected <PROJECT_KEY>=<Type>=<Label>=<Value>)" }
                }
                break
            }
            '^--task-mirror$' {
                # The recording flag of contract §4 (022): repeatable
                # <PROJECT_KEY>=<subtask|checklist>, accepted by the config
                # command only.
                if ($idx + 1 -ge $Arguments.Count) {
                    $parseError = '--task-mirror requires a value (--task-mirror KEY=<subtask|checklist>)'
                }
                else {
                    $idx++
                    $v = $Arguments[$idx]
                    if ($v -cmatch '^[A-Z][A-Z0-9_]+=(subtask|checklist)$') { $taskMirrors.Add($v) }
                    else { $parseError = "invalid --task-mirror value: $v (expected <PROJECT_KEY>=<subtask|checklist>)" }
                }
                break
            }
            '^--accept-defaults$' {
                # Contract §3.3/§3.10 — proceed with the recorded defaults,
                # asking no consolidated question this run.
                $acceptDefaults = 'true'
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
        $lines.Add("force=$force")
        $lines.Add("json=$json")
        $lines.Add("on_drift=$onDrift")
        $lines.Add("verbose=$verbose")
        $lines.Add("help=$help")
        $lines.Add("styles=$($styles -join ' ')")
        $lines.Add("child_types=$($childTypes -join ' ')")
        $lines.Add("issue_types=$($issueTypes -join ' ')")
        $lines.Add("use_team=$useTeam")
        $lines.Add("enable_hooks=$($enableHooks -join ' ')")
        # Joined with ASCII Unit Separator (\x1f, not a space — mirror of
        # cli.sh's field_defaults_joined/field_values_joined): a VALUE may
        # itself contain spaces (011, T017).
        $usJoin = [char]0x1F
        $lines.Add("field_defaults=$($fieldDefaults -join $usJoin)")
        $lines.Add("field_values=$($fieldValues -join $usJoin)")
        $lines.Add("task_mirrors=$($taskMirrors -join ' ')")
        $lines.Add("accept_defaults=$acceptDefaults")
        $lines.Add("args=$($positional -join ' ')")
        $lines.Add("exit=$($script:ExitCodes.ok)")
    }
    # Return the LF-joined state (with a trailing LF). Callers that need real
    # stdout wrap this in [Console]::Out.Write; command substitution strips the
    # trailing newline on both ports so bytes match (NFR-1).
    return (($lines -join "`n") + "`n")
}

Export-ModuleMember -Function Get-JiraExitCode, Invoke-JiraCliParse, Test-JiraFieldFlagShape, Get-JiraFieldFlagPart, `
    Get-JiraFieldAnswersFor
