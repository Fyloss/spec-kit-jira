# hooks/RegisterHooks.psm1 — The hook registry READER (003 FR-021 – FR-025, FR-028).
# Mirror of hooks/register_hooks.sh; both ports produce the SAME report for the
# same registry content (Constitution VI).
#
# The consuming repository's `.specify/extensions.yml` has exactly ONE writer and
# it is not us: `specify extension add` writes it from the manifest's top-level
# `hooks:` block. This module reads that file, recognises which entries are ours,
# classifies every declared event, and reports. It never opens the file for
# anything but reading (FR-022, SC-011) — there is no writer here, and adding one
# back would fail tests/powershell/ci/NoRegistryWrite.Tests.ps1.
#
# Recognition has two rules, and they are not the same rule:
#   * ours     — the entry carries `extension: jira-mirror`, the ownership key
#                the host install writes and matches on when it purges and
#                re-adds;
#   * leftover — the entry carries one of our commands and NO `extension` field:
#                the four-field shape every pre-manifest version of this
#                extension wrote. The install's purge predicate never matches it,
#                so the install adds a SECOND entry beside it rather than
#                replacing it (research R2). Neither the host nor we can remove
#                it — it is reported, with the manual edit (FR-028).

Set-StrictMode -Version Latest

# No -Force: this module is imported -Global and LAST by callers that already
# hold lib/Config.psm1 in session scope, and -Force is a Remove-Module +
# Import-Module pair that would tear that copy out of their scope and
# re-attach it to this module's, taking ConvertFrom-JiraConfigYaml with it.
Import-Module (Join-Path $PSScriptRoot '../lib/Config.psm1') # YAML reader (READ only)
Import-Module (Join-Path $PSScriptRoot '../lib/Output.psm1') -Force # canonical serialiser

# The owning-extension id the host writes into every entry it registers for us.
$script:HookExtensionId = 'jira-mirror'

# The reconcile command the six after_* events fire.
$script:HookCommand = 'speckit.jira-mirror.reconcile'

# The feature-naming command the before_specify event fires (002 US3, FR-013).
$script:HookBeforeEvent = 'before_specify'
$script:HookBeforeCommand = 'speckit.jira-mirror.feature'

$script:HookExitConfig = 4

# The remedies the report names. Each literal is runnable exactly as spelled —
# tests/powershell/ci/MessageCommandLiterals.Tests.ps1 asserts it (FR-018).
$script:HookInstallCommand = 'specify extension add jira-mirror --from https://github.com/Fyloss/spec-kit-jira-mirror/releases/latest/download/spec-kit-jira-mirror.zip --force'
$script:HookReleaseCommand = '/speckit.jira-mirror.config --enable-hook'

function Get-JiraHookEventList {
    <#
    .SYNOPSIS
      The seven declared lifecycle events (research R9) — one closed set, in
      manifest declaration order. The set has ONE source per port: lib/Config.psm1
      declares it as the `hooks.disabled` enum of config.local.schema.json, and
      this module consumes it rather than redeclaring it.
    #>
    return (Get-JiraHookEventNameList)
}

function Get-JiraHookCommandFor {
    <#
    .SYNOPSIS
      The command the event must name. Mirror of register_hooks_command_for.
    #>
    param([Parameter(Mandatory)] [string] $LifecycleEvent)
    if ($LifecycleEvent -ceq $script:HookBeforeEvent) { return $script:HookBeforeCommand }
    return $script:HookCommand
}

function Get-JiraHookCommandList {
    # Our two commands. This is the "one of ours" set the leftover predicate
    # matches on. Mirror of register_hooks_commands_json.
    return @($script:HookBeforeCommand, $script:HookCommand)
}

function Get-JiraHookProp {
    # $null-safe property read (an entry may be any shape).
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
    }
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
    return $null
}

function Test-JiraHookProp {
    # Whether the entry CARRIES the field at all — distinct from its value being
    # $null, which is exactly the distinction `condition: null` turns on.
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Management.Automation.PSCustomObject]) { return ($null -ne $Object.PSObject.Properties[$Name]) }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
    return $false
}

function Test-JiraHookEntryOwnership {
    <#
    .SYNOPSIS
      $true when the entry carries our ownership key. This is how we RECOGNISE
      our entries; it is not a licence to edit them. Mirror of
      register_hooks_entry_is_ours.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $EntryJson)
    $e = $EntryJson | ConvertFrom-Json -Depth 100
    # Case-SENSITIVE like the Bash twin's jq `==` (NFR-1).
    return ((Get-JiraHookProp $e 'extension') -ceq $script:HookExtensionId)
}

function Test-JiraHookEntryIsLeftover {
    <#
    .SYNOPSIS
      $true when the entry names one of our commands and carries NO owning
      extension: the pre-manifest shape the install cannot purge (FR-028,
      research R2). Mirror of register_hooks_entry_is_leftover.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $EntryJson)
    $e = $EntryJson | ConvertFrom-Json -Depth 100
    if (Test-JiraHookProp $e 'extension') { return $false }
    return ((Get-JiraHookCommandList) -ccontains (Get-JiraHookProp $e 'command'))
}

function Get-JiraHookEntryShapeError {
    <#
    .SYNOPSIS
      Every deviation from the canonical eight-field shape
      (contracts/hook-registry-entry.md), newline-joined; $null when the entry is
      canonical. We ASSERT the shape when we read and REPORT a deviation; we never
      correct one, because correcting it would mean writing the file.
      Mirror of register_hooks_entry_shape_errors.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $EntryJson)

    $e = $EntryJson | ConvertFrom-Json -Depth 100
    $errs = [System.Collections.Generic.List[string]]::new()

    foreach ($f in @('extension', 'command', 'enabled', 'optional', 'priority', 'prompt', 'description', 'condition')) {
        if (-not (Test-JiraHookProp $e $f)) { $errs.Add("missing field: $f") }
    }
    if ((Test-JiraHookProp $e 'extension') -and ((Get-JiraHookProp $e 'extension') -cne $script:HookExtensionId)) {
        $errs.Add("extension is not $($script:HookExtensionId)")
    }
    if ((Test-JiraHookProp $e 'enabled') -and ((Get-JiraHookProp $e 'enabled') -isnot [bool])) {
        $errs.Add('enabled is not a boolean')
    }
    if ((Test-JiraHookProp $e 'optional') -and ((Get-JiraHookProp $e 'optional') -ne $false)) {
        $errs.Add('optional must be false — a true entry is offered, not performed')
    }
    if (Test-JiraHookProp $e 'priority') {
        $p = Get-JiraHookProp $e 'priority'
        if (-not (($p -is [int]) -or ($p -is [long]) -or ($p -is [double]) -or ($p -is [decimal]))) {
            $errs.Add('priority is not a number')
        }
    }
    # `prompt` is the fussy one on purpose: the host builds its default with an
    # f-string, `f"Execute {command}?"`, so the file receives the EXPANDED string
    # and never a literal `{command}` placeholder (research R2, verified at
    # specify_cli/extensions/__init__.py:3866). An entry carrying the unexpanded
    # template did not come from the host, and saying so is the point of reading it.
    if ((Test-JiraHookProp $e 'prompt') -and (Test-JiraHookProp $e 'command')) {
        $cmd = Get-JiraHookProp $e 'command'
        $want = "Execute $cmd" + '?'
        if ((Get-JiraHookProp $e 'prompt') -cne $want) {
            $errs.Add("prompt is not the host default `"$want`" — the host expands it with an f-string, so a {command} placeholder never reaches the file")
        }
    }
    if ((Test-JiraHookProp $e 'description') -and ((Get-JiraHookProp $e 'description') -isnot [string])) {
        $errs.Add('description is not a string')
    }
    if ((Test-JiraHookProp $e 'condition') -and ($null -ne (Get-JiraHookProp $e 'condition'))) {
        $errs.Add('condition is set — a non-empty condition makes agent-driven dispatch skip the hook entirely')
    }

    if ($errs.Count -eq 0) { return $null }
    return ($errs -join "`n")
}

function Get-CfgUnsupportedConstruct {
    <#
    .SYNOPSIS
      Name the YAML construct that puts the file outside this reader's subset, or
      return ''. Mirror of _register_hooks_unsupported_construct.

      The reader is lenient rather than strict: it would happily parse
      `key: &anchor` as the string "&anchor", producing a confidently WRONG
      classification. FR-024 requires the opposite — say we cannot read it, and
      name what defeated us — so the constructs are detected explicitly here
      rather than inferred from a parse failure that never comes.

      `[]` and `{}` are excluded: ConvertTo-JiraConfigYaml emits exactly those for
      empty collections, and calling our own output unreadable would be absurd.
    #>
    param([Parameter(Mandatory)] [string] $Path)

    foreach ($raw in ((Get-Content -Raw -LiteralPath $Path) -split "`r?`n")) {
        $body = $raw.TrimStart()
        if ([string]::IsNullOrEmpty($body) -or $body.StartsWith('#')) { continue }
        if ($body.StartsWith('<<:')) { return 'a YAML merge key (<<:)' }

        $value = ''
        $sep = $body.IndexOf(': ')
        if ($sep -ge 0) { $value = $body.Substring($sep + 2) }
        elseif ($body.StartsWith('- ')) { $value = $body.Substring(2) }
        $value = $value.TrimStart()
        if ([string]::IsNullOrEmpty($value)) { continue }

        $first = $value.Split(' ')[0]
        if ($value.StartsWith('&')) { return "a YAML anchor ($first)" }
        if ($value.StartsWith('*')) { return "a YAML alias ($first)" }
        if ($value -eq '{}' -or $value -eq '[]') { continue }
        if ($value.StartsWith('{')) { return 'a flow collection ({…)' }
        if ($value.StartsWith('[')) { return 'a flow collection ([…)' }
    }
    return ''
}

function New-JiraHookUnreadable {
    # The FR-024 result: `unreadable` true, the three partition lists EMPTY, and a
    # hint naming the file and, where determinable, the construct. It MUST NOT
    # claim the hooks are missing: we have no evidence either way, and "your hooks
    # are missing" about a file we merely failed to parse is exactly the false,
    # expensive guidance FR-024 forbids. Mirror of _register_hooks_unreadable.
    param([string] $Path, [string] $Detail)
    $hint = "unreadable: $Path could not be read"
    if ($Detail) { $hint += " ($Detail)" }
    $hint += ' — no claim is made about the hooks; fix the file, then re-run /speckit.jira-mirror.config'
    return (ConvertTo-JiraJsonValue ([ordered]@{
                present       = @()
                missing       = @()
                disabled      = @()
                held_disabled = @()
                duplicated    = @()
                unreadable    = $true
                repair_hint   = $hint
            }))
}

function Get-JiraHookRepairHint {
    # The repair hint, naming the remedy for whatever is not `present` —
    # literally, because every literal it contains is checked by the
    # message↔command CI check (FR-018). The three remedies are genuinely
    # different in kind:
    #   * missing    — the official install DOES register it (one command);
    #   * held       — the release flag on the configuration command;
    #   * duplicated — a manual edit, because neither the host nor this extension
    #                  can remove an entry the host does not recognise as ours.
    #                  That is the one place Constitution X's "one-command repair"
    #                  cannot be offered honestly (plan.md § Complexity Tracking).
    # Mirror of _register_hooks_hint.
    param([string[]] $Missing, [string[]] $Held, [string[]] $Duplicated, [string] $Path)

    $clauses = [System.Collections.Generic.List[string]]::new()
    if ($Missing.Count -gt 0) {
        $clauses.Add("missing: $($Missing -join ', ') — register them with: $($script:HookInstallCommand)")
    }
    if ($Held.Count -gt 0) {
        $clauses.Add("held disabled: $($Held -join ', ') — no bridge step runs for these, whatever the registry says; release one with: $($script:HookReleaseCommand) $($Held[0])")
    }
    if ($Duplicated.Count -gt 0) {
        # Forward-slash the path even on Windows: this is a copy-pasteable,
        # human-read instruction, not a filesystem call, and every other
        # user-facing message in this port names paths with '/' — the form the
        # Bash twin always produces (Constitution VI, NFR-1).
        $displayPath = $Path -replace '\\', '/'
        $clauses.Add("duplicated: $($Duplicated -join ', ') — a pre-manifest entry names our command with no owning extension, so the official install adds a second entry beside it instead of replacing it; remove the entry that has no `"extension: jira-mirror`" field under each named event, by hand, from $displayPath")
    }
    if ($clauses.Count -eq 0) { return '' }
    return ($clauses -join '; ')
}

function Get-JiraHookHealth {
    <#
    .SYNOPSIS
      READ-ONLY classification of all seven declared events for the run summary.
      Returns the canonical hook_health object of run-summary.schema.json:
      { present; missing; disabled; held_disabled; duplicated; unreadable;
        repair_hint? }.

      `present`, `missing` and `disabled` partition the seven events ONLY when
      `unreadable` is false. `held_disabled` and `duplicated` are cross-cutting
      ANNOTATIONS, not further partitions: an event may be `present` and
      `held_disabled` (an install re-enabled it and the operator has not released
      it), or `present` and `duplicated` (the canonical entry exists beside a
      leftover one).

      Computing this writes NOTHING — not to the registry, not anywhere. The
      operator disable record is written by the ceremony, not by this
      classification (research R5 step 1). Mirror of register_hooks_health.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $DisabledJson = '[]'
    )

    $events = @(Get-JiraHookEventList)
    $root = $null

    if (Test-Path -LiteralPath $Path) {
        $construct = Get-CfgUnsupportedConstruct -Path $Path
        if ($construct) { return (New-JiraHookUnreadable -Path $Path -Detail $construct) }
        try { $root = ConvertFrom-JiraConfigYaml -Path $Path | ConvertFrom-Json -Depth 100 }
        catch { return (New-JiraHookUnreadable -Path $Path -Detail $_.Exception.Message) }

        # Parsing succeeding is not the same as the file being a registry. The
        # reader is lenient by design, so a genuinely broken file can parse into a
        # confidently WRONG structure — `- broken` under an event becomes the
        # string "broken" where a mapping belongs. Checking the shape of what came
        # back is how a broken file is distinguished from an unsupported construct
        # (FR-024), and it is checked only for the events we classify: another
        # extension's event is none of our business.
        # `@(...)` normalises the two forms the host accepts for an event — a
        # single mapping and a list of mappings (`coerce_hook_entries`, research
        # R1) — into one list. Here it is also unavoidable: PowerShell unwraps a
        # single-element array on return, so a one-entry event arrives as a bare
        # mapping whatever the file said. The Bash twin normalises the same way,
        # which is what keeps the two reports identical (Constitution VI).
        $hooks = Get-JiraHookProp $root 'hooks'
        if ((Test-JiraHookProp $root 'hooks') -and ($hooks -isnot [System.Management.Automation.PSCustomObject])) {
            return (New-JiraHookUnreadable -Path $Path -Detail 'hooks is not a mapping')
        }
        foreach ($e in $events) {
            if (-not (Test-JiraHookProp $hooks $e)) { continue }
            $v = Get-JiraHookProp $hooks $e
            if ($null -eq $v) { continue }
            foreach ($x in @($v)) {
                if ($x -isnot [System.Management.Automation.PSCustomObject]) {
                    return (New-JiraHookUnreadable -Path $Path -Detail "hooks.$e carries an entry that is not a mapping")
                }
            }
        }
    }

    # An absent registry is NOT unreadable: we read it successfully and found no
    # entries. Every declared event is genuinely missing, and the official install
    # is the remedy.
    $hooks = Get-JiraHookProp $root 'hooks'
    $ourCommands = Get-JiraHookCommandList

    $present = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    $disabled = [System.Collections.Generic.List[string]]::new()
    $duplicated = [System.Collections.Generic.List[string]]::new()

    foreach ($e in $events) {
        $cmd = Get-JiraHookCommandFor -LifecycleEvent $e
        $all = @()
        $v = Get-JiraHookProp $hooks $e
        if ($null -ne $v) { $all = @($v) }

        $ours = [System.Collections.Generic.List[object]]::new()
        $leftovers = 0
        foreach ($x in $all) {
            # Case-SENSITIVE like the Bash twin's jq `==` (NFR-1).
            $xExt = Get-JiraHookProp $x 'extension'
            $xCmd = Get-JiraHookProp $x 'command'
            if (($xExt -ceq $script:HookExtensionId) -and ($xCmd -ceq $cmd)) { $ours.Add($x); continue }
            if ((-not (Test-JiraHookProp $x 'extension')) -and ($ourCommands -ccontains $xCmd)) { $leftovers++ }
        }
        if ($leftovers -gt 0) { $duplicated.Add($e) }

        if ($ours.Count -eq 0) { $missing.Add($e); continue }
        $enabled = $false
        foreach ($x in $ours) {
            $en = Get-JiraHookProp $x 'enabled'
            if (-not (($en -is [bool]) -and ($en -eq $false))) { $enabled = $true; break }
        }
        if ($enabled) { $present.Add($e) } else { $disabled.Add($e) }
    }

    $held = [System.Collections.Generic.List[string]]::new()
    foreach ($x in @($DisabledJson | ConvertFrom-Json -Depth 100)) {
        $s = [string]$x
        if (($events -ccontains $s) -and (-not $held.Contains($s))) { $held.Add($s) }
    }
    $heldArr = [string[]]@($held)
    [System.Array]::Sort($heldArr, [System.StringComparer]::Ordinal)

    # The "held disabled" clause covers BOTH sources of a withheld event: an entry
    # the registry currently shows as `enabled: false`, and an event in the
    # operator record that the last install re-enabled in the file. They are one
    # situation from the operator's point of view — no bridge step runs — and one
    # flag releases either, so they are reported as one list rather than two.
    $heldClause = [System.Collections.Generic.List[string]]::new()
    foreach ($s in (@($disabled) + @($heldArr))) { if (-not $heldClause.Contains($s)) { $heldClause.Add($s) } }
    $heldClauseArr = [string[]]@($heldClause)
    [System.Array]::Sort($heldClauseArr, [System.StringComparer]::Ordinal)

    $out = [ordered]@{
        present       = $present.ToArray()
        missing       = $missing.ToArray()
        disabled      = $disabled.ToArray()
        held_disabled = $heldArr
        duplicated    = $duplicated.ToArray()
        unreadable    = $false
    }

    # `repair_hint` appears only when something is not `present` — a healthy run
    # says nothing, so a hint in the summary always means there is work to do.
    $hint = Get-JiraHookRepairHint -Missing $missing.ToArray() -Held $heldClauseArr -Duplicated $duplicated.ToArray() -Path $Path
    if ($hint) { $out['repair_hint'] = $hint }

    return (ConvertTo-JiraJsonValue $out)
}

Export-ModuleMember -Function Get-JiraHookHealth, Get-JiraHookEventList, Get-JiraHookCommandFor, `
    Get-JiraHookCommandList, Test-JiraHookEntryOwnership, Test-JiraHookEntryIsLeftover, `
    Get-JiraHookEntryShapeError
