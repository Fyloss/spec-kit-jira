# commands/Adopt.psm1 — The adopt command. Mirror of commands/adopt.sh
# (003 US1…US6).
#
# Strictly two-phase (FR-006): a read-only discovery that prints the plan without
# writing anything, then — only after confirmation — one identity property stamp
# per binding, executed through the existing Invoke-JiraApplyWriteSet so the
# BLOCK-tier privacy guard and the fail-closed abort ladder are inherited
# (FR-028, FR-008). Adoption emits NO other write kind (FR-007).
#
# Confirmation (research §6): --yes pre-confirms; a terminal is prompted; a
# decline is an operator CHOICE and exits 0. With neither a terminal nor --yes
# the run collapses onto its own --dry-run path and names --yes as the way to
# proceed. SPEC_KIT_JIRA_ADOPT_ANSWER supplies that answer where no terminal
# exists (the conformance corpus).
#
# Per the dispatcher contract this module writes user output via the [Console]
# streams and returns ONLY its numeric exit code. Every byte it emits is
# identical to the Bash port's for identical state (NFR-1, SC-008).

Set-StrictMode -Version Latest

$ScriptsRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $ScriptsRoot 'lib/Cli.psm1') -Force
Import-Module (Join-Path $ScriptsRoot 'lib/Output.psm1') -Force
Import-Module (Join-Path $ScriptsRoot 'lib/Config.psm1') -Force
Import-Module (Join-Path $ScriptsRoot 'engine/Parse.psm1') -Force
Import-Module (Join-Path $ScriptsRoot 'engine/Adoption.psm1') -Force
Import-Module (Join-Path $ScriptsRoot 'sink/jira/Adoption.psm1') -Force
Import-Module (Join-Path $ScriptsRoot 'sink/jira/PlanApply.psm1') -Force

# The plan's column geometry, shared by both ports so the printed plan is
# byte-identical for identical state (SC-008).
$script:AdoptColTarget = 36
$script:AdoptColKey = 9
$script:AdoptColStatus = 15

function Get-AdoptCmdProp {
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
        return $null
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    return $null
}

function Get-AdoptConfigDir {
    # Mirror of the Bash port's JIRA_CONFIG_DIR default. Config.psm1 keeps its own
    # resolver private, so the twin spells the same rule here.
    if ($env:JIRA_CONFIG_DIR) { return $env:JIRA_CONFIG_DIR }
    return '.specify/jira'
}

function Get-AdoptSpecsDir {
    if ($env:SPEC_KIT_JIRA_SPECS_DIR) { return $env:SPEC_KIT_JIRA_SPECS_DIR }
    return 'specs'
}

function Get-AdoptSpecFolder {
    # Every spec folder on disk, sorted ordinally. A folder is a directory under
    # the specs root; nothing else in the tree is ever considered.
    $root = Get-AdoptSpecsDir
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    $names = [string[]]@(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name })
    [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
    return $names
}

function Get-AdoptStoryOrdinal {
    # The ordinals of the user stories the spec declares. They are the ones the
    # bridge ALREADY assigns in the parser, so the label grammar introduces no
    # new identifier.
    param([string] $Folder)
    $file = Join-Path (Get-AdoptSpecsDir) (Join-Path $Folder 'spec.md')
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    try {
        $text = Get-Content -Raw -LiteralPath $file
        $parsed = Get-JiraParsedSpec -Text $text -FolderSlug $Folder | ConvertFrom-Json -Depth 100
    }
    catch { return @() }
    $stories = @(Get-AdoptCmdProp $parsed 'stories')
    $out = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $stories.Count; $i++) { $out.Add($i + 1) }
    return $out.ToArray()
}

function New-AdoptAdoptionBlock {
    # The adoption summary block (contracts/adoption-plan.schema.json). It is
    # also exactly the --dry-run report, which is why FR-023's "identical action
    # set" is a structural guarantee rather than a behavioural promise.
    param([bool] $Enabled, [string] $Prefix, [bool] $Confirmed,
        [string] $BindingsJson, [string] $RefusalsJson, [string] $OutOfScopeJson)
    $obj = [ordered]@{
        enabled      = $Enabled
        label_prefix = $Prefix
        confirmed    = $Confirmed
        bindings     = @($BindingsJson | ConvertFrom-Json -Depth 100)
        refusals     = @($RefusalsJson | ConvertFrom-Json -Depth 100)
        out_of_scope = @($OutOfScopeJson | ConvertFrom-Json -Depth 100)
    }
    return (ConvertTo-JiraJsonValue $obj)
}

function New-AdoptSummary {
    param([bool] $DryRun, [string] $AdoptionJson, [string] $ActionsJson,
        [int] $Updated, [int] $Skipped, [int] $Errors, [int] $ExitCode)
    $obj = [ordered]@{
        schema_version = '1.0'
        command        = 'adopt'
        dry_run        = $DryRun
        counts         = [ordered]@{ created = 0; updated = $Updated; skipped = $Skipped; warnings = 0; errors = $Errors }
        actions        = @($ActionsJson | ConvertFrom-Json -Depth 100)
        adoption       = ($AdoptionJson | ConvertFrom-Json -Depth 100)
        exit_code      = $ExitCode
    }
    return (ConvertTo-JiraJsonValue $obj)
}

function Format-AdoptPlanLine {
    # `  <target padded>  <arrow> <key padded> <status padded> (<detail>)` — the
    # exact geometry the Bash port's printf produces.
    param([string] $Display, [string] $Arrow, [string] $Key, [string] $Status, [string] $Detail)
    $t = $Display.PadRight($script:AdoptColTarget)
    $k = $Key.PadRight($script:AdoptColKey)
    $s = $Status.PadRight($script:AdoptColStatus)
    return "  $t$Arrow $k $s ($Detail)"
}

function Write-AdoptPlan {
    # The prose plan (Principle XVI, default output), printed BEFORE any write.
    param([string] $AdoptionJson)
    $ad = $AdoptionJson | ConvertFrom-Json -Depth 100
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add("Adoption plan (adoption.enabled: $(if ($ad.enabled) { 'true' } else { 'false' }), label prefix: $($ad.label_prefix))")
    $out.Add('')

    # Spec Edge Cases: an empty plan is a success, but never a silent one.
    # Without this line the operator reads a bare header and has to infer that
    # nothing happened (Constitution XVI).
    if (@($ad.bindings).Count -eq 0 -and @($ad.refusals).Count -eq 0 -and @($ad.out_of_scope).Count -eq 0) {
        $out.Add('  nothing was found: no spec folder is in scope, so nothing was searched for and nothing will be written')
    }

    foreach ($b in @($ad.bindings)) {
        $ordText = $(if ($null -eq $b.story_ordinal) { '' } else { [string][int]$b.story_ordinal })
        $display = Get-JiraAdoptionDisplayName -Folder ([string]$b.spec_folder) -Level ([string]$b.level) -Ordinal $ordText
        if ([string]$b.status -ceq 'already-adopted') {
            $status = 'already adopted'
            $detail = 'skipped'
        }
        else {
            $status = 'adopt'
            if ([string]$b.reason -ceq 'explicit-binding') {
                $detail = 'explicit binding'
                if ($null -ne $b.overrode_key -and -not [string]::IsNullOrEmpty([string]$b.overrode_key)) {
                    $detail = "explicit binding, overrides $($b.overrode_key)"
                }
            }
            else { $detail = 'label match' }
        }
        $out.Add((Format-AdoptPlanLine $display '→' ([string]$b.issue_key) $status $detail))
    }

    foreach ($r in @($ad.refusals)) {
        $ordText = $(if ($null -eq $r.story_ordinal) { '' } else { [string][int]$r.story_ordinal })
        $display = Get-JiraAdoptionDisplayName -Folder ([string]$r.spec_folder) -Level ([string]$r.level) -Ordinal $ordText
        $detail = ([string]$r.reason) -replace '-', ' '
        $keys = (@($r.issue_keys | ForEach-Object { [string]$_ })) -join ', '
        if (-not [string]::IsNullOrEmpty($keys)) { $detail = "${detail}: $keys" }
        $out.Add((Format-AdoptPlanLine $display '—' '' 'REFUSED' $detail))
        $out.Add("      remediation: $($r.remediation)")
    }

    if (@($ad.out_of_scope).Count -gt 0) {
        $out.Add('')
        $out.Add("  out of scope: $((@($ad.out_of_scope | ForEach-Object { [string]$_ })) -join ', ')")
    }
    $out.Add('')
    [Console]::Out.Write((($out -join "`n") + "`n"))
}

function Write-AdoptAction {
    # The action set the run performs, with the site host stripped to a
    # host-relative path (Constitution IV).
    param([string] $ActionsJson)
    $actions = @($ActionsJson | ConvertFrom-Json -Depth 100)
    if ($actions.Count -eq 0) {
        [Console]::Out.Write("Actions: none`n")
        return
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Actions:')
    foreach ($a in $actions) { $lines.Add("  $($a.method) $($a.url)") }
    [Console]::Out.Write((($lines -join "`n") + "`n"))
}

function Write-AdoptSummary {
    param([bool] $Json, [string] $SummaryJson)
    if ($Json) { [Console]::Out.Write($SummaryJson + "`n") }
    else { [Console]::Out.Write((ConvertTo-JiraSummaryProse -Json $SummaryJson)) }
}

function ConvertTo-AdoptWordArray {
    # A repeatable flag's values as a JSON array. Values carry no whitespace (a
    # folder name and a key never do), which is what makes the space-joined parse
    # state safe.
    param([AllowEmptyString()] [string] $Raw)
    if ([string]::IsNullOrEmpty($Raw)) { return '[]' }
    return (ConvertTo-JiraJsonValue ([string[]]@($Raw -split '\s+' | Where-Object { $_ -ne '' })))
}

function Get-AdoptMergedPinnedCandidate {
    # Read the context of every pinned key discovery did not already return, and
    # merge it into the candidate set, so a pin is validated through the
    # IDENTICAL path a discovered candidate is — same project check, same claim
    # check, same hierarchy checks (FR-020). Mirror of _adopt_merge_pinned.
    param([string] $CandidatesJson, [string] $PinsJson)

    $candidates = @($CandidatesJson | ConvertFrom-Json -Depth 100)
    $known = [string[]]@($candidates | ForEach-Object { [string]$_.key })
    $missing = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($p in @($PinsJson | ConvertFrom-Json -Depth 100)) {
        $k = [string]$p.issue_key
        if ($known -cnotcontains $k) { [void]$missing.Add($k) }
    }
    if ($missing.Count -eq 0) { return [pscustomobject]@{ ExitCode = 0; Json = $CandidatesJson } }

    $fetched = Get-JiraAdoptionPinnedContext -KeysJson (ConvertTo-JiraJsonValue ([string[]]@($missing)))
    if ([int]$fetched.ExitCode -ne 0) { return [pscustomobject]@{ ExitCode = [int]$fetched.ExitCode; Json = '' } }

    $all = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $candidates) { $all.Add($c) }
    foreach ($c in @($fetched.Json | ConvertFrom-Json -Depth 100)) { $all.Add($c) }
    $keys = [string[]]@($all | ForEach-Object { [string]$_.key })
    [System.Array]::Sort($keys, [System.StringComparer]::Ordinal)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $sorted = [System.Collections.Generic.List[object]]::new()
    foreach ($k in $keys) {
        if (-not $seen.Add($k)) { continue }
        foreach ($c in $all) { if ([string]$c.key -ceq $k) { $sorted.Add($c); break } }
    }
    return [pscustomobject]@{ ExitCode = 0; Json = (ConvertTo-JiraJsonValue $sorted.ToArray()) }
}

function Invoke-JiraAdopt {
    [CmdletBinding()]
    param([string[]] $Arguments = @())

    $parsed = Invoke-JiraCliParse -Arguments $Arguments
    $state = @{}
    foreach ($line in ($parsed -split "`n")) {
        if ($line -match '^([^=]+)=(.*)$') { $state[$Matches[1]] = $Matches[2] }
    }
    if ($state['exit'] -ne '0') {
        if ($state.ContainsKey('error') -and $state['error']) {
            [Console]::Error.WriteLine("adopt: $($state['error'])")
        }
        return [int]$state['exit']
    }

    $json = ($state['json'] -eq 'true')
    $dryRun = ($state['dry_run'] -eq 'true')
    $yes = ($state['yes'] -eq 'true')
    $bindsJson = ConvertTo-AdoptWordArray ($(if ($state.ContainsKey('binds')) { $state['binds'] } else { '' }))
    $specsFlagJson = ConvertTo-AdoptWordArray ($(if ($state.ContainsKey('specs')) { $state['specs'] } else { '' }))

    # ---- (1) Configuration ---------------------------------------------------
    $configDir = Get-AdoptConfigDir
    $cfgResult = Import-JiraConfig -ConfigDir $configDir
    if ([int]$cfgResult.ExitCode -ne 0) { return [int]$cfgResult.ExitCode }
    $cfgJson = [string]$cfgResult.Json
    $cfg = $cfgJson | ConvertFrom-Json -Depth 100

    $adoptionCfg = Get-AdoptCmdProp $cfg 'adoption'
    $enabledRaw = Get-AdoptCmdProp $adoptionCfg 'enabled'
    $enabled = ($enabledRaw -is [bool] -and $enabledRaw)
    $prefixRaw = Get-AdoptCmdProp $adoptionCfg 'label_prefix'
    $prefix = $(if ($null -eq $prefixRaw -or [string]::IsNullOrEmpty([string]$prefixRaw)) { 'speckit-adopt:' } else { [string]$prefixRaw })

    # ---- (2) Enablement gate — before ANY read against a candidate ticket -----
    if (-not $enabled) {
        [Console]::Error.WriteLine("adopt: adoption is disabled — set adoption.enabled to true in $configDir/config.yml to enable it; no ticket was read and nothing was written")
        $ad = New-AdoptAdoptionBlock $false $prefix $false '[]' '[]' '[]'
        Write-AdoptSummary $json (New-AdoptSummary $dryRun $ad '[]' 0 0 0 ([int](Get-JiraExitCode 'config')))
        return [int](Get-JiraExitCode 'config')
    }

    # ---- (3) Scope and pins (usage errors stop the run with zero writes) ------
    $allFoldersJson = ConvertTo-JiraJsonValue ([string[]]@(Get-AdoptSpecFolder))
    $scope = Get-JiraAdoptionScope -AllFoldersJson $allFoldersJson -ScopeJson $specsFlagJson
    if ([int]$scope.ExitCode -ne 0) {
        [Console]::Error.WriteLine("adopt: $($scope.Message)")
        return [int]$scope.ExitCode
    }
    $scopeObj = $scope.Json | ConvertFrom-Json -Depth 100
    $inScope = [string[]]@($scopeObj.in_scope | ForEach-Object { [string]$_ })
    $outOfScopeJson = ConvertTo-JiraJsonValue ([string[]]@($scopeObj.out_of_scope | ForEach-Object { [string]$_ }))

    $pinResult = Resolve-JiraAdoptionPin -PinsJson $bindsJson -AllFoldersJson $allFoldersJson
    if ([int]$pinResult.ExitCode -ne 0) {
        [Console]::Error.WriteLine("adopt: $($pinResult.Message)")
        return [int]$pinResult.ExitCode
    }
    $pinsJson = [string]$pinResult.Json

    # ---- (4) Targets ---------------------------------------------------------
    $specList = [System.Collections.Generic.List[object]]::new()
    foreach ($folder in $inScope) {
        $specList.Add([ordered]@{ folder = $folder; story_ordinals = [int[]]@(Get-AdoptStoryOrdinal -Folder $folder) })
    }
    $specsJson = ConvertTo-JiraJsonValue $specList.ToArray()

    $longest = Get-JiraAdoptionLongestSuffix -SpecsJson $specsJson
    $prefixCheck = Test-JiraAdoptionPrefix -Prefix $prefix -LongestSuffix $longest
    if ([int]$prefixCheck.ExitCode -ne 0) {
        [Console]::Error.WriteLine("adopt: config ($configDir/config.yml): $($prefixCheck.Message)")
        $ad = New-AdoptAdoptionBlock $true $prefix $false '[]' '[]' $outOfScopeJson
        Write-AdoptSummary $json (New-AdoptSummary $dryRun $ad '[]' 0 0 0 ([int](Get-JiraExitCode 'config')))
        return [int](Get-JiraExitCode 'config')
    }

    $targetResult = Get-JiraAdoptionTarget -SpecsJson $specsJson -Prefix $prefix -ConfigJson $cfgJson
    if ([int]$targetResult.ExitCode -ne 0) { return [int]$targetResult.ExitCode }
    $targetsJson = [string]$targetResult.Json

    # ---- (5) Discovery (read-only) -------------------------------------------
    $candResult = Get-JiraAdoptionCandidate -TargetsJson $targetsJson
    if ([int]$candResult.ExitCode -ne 0) { return [int]$candResult.ExitCode }
    $merged = Get-AdoptMergedPinnedCandidate -CandidatesJson ([string]$candResult.Json) -PinsJson $pinsJson
    if ([int]$merged.ExitCode -ne 0) { return [int]$merged.ExitCode }
    $identResult = Get-JiraAdoptionCandidateIdentity -CandidatesJson ([string]$merged.Json)
    if ([int]$identResult.ExitCode -ne 0) { return [int]$identResult.ExitCode }
    $candidatesJson = [string]$identResult.Json

    # ---- (6) Classification --------------------------------------------------
    $repo = $(if ($env:SPEC_KIT_JIRA_REPO) { $env:SPEC_KIT_JIRA_REPO } else { 'local/repo' })
    $planJson = Get-JiraAdoptionPlan -TargetsJson $targetsJson -CandidatesJson $candidatesJson -PinsJson $pinsJson -Repo $repo
    $plan = $planJson | ConvertFrom-Json -Depth 100
    $bindings = @($plan.bindings)
    $refusals = @($plan.refusals)
    $bindingsJson = ConvertTo-JiraJsonValue $bindings
    $refusalsJson = ConvertTo-JiraJsonValue $refusals

    # ---- (7) The action set IS the dry-run prediction (FR-023) ---------------
    $base = $(if ($env:SPEC_KIT_JIRA_BASE_URL) { $env:SPEC_KIT_JIRA_BASE_URL } else { '' })
    $actionsJson = Get-JiraAdoptionStampAction -BindingsJson $bindingsJson -Repo $repo
    $dispList = [System.Collections.Generic.List[object]]::new()
    foreach ($a in @($actionsJson | ConvertFrom-Json -Depth 100)) {
        $url = [string]$a.url
        if (-not [string]::IsNullOrEmpty($base) -and $url.StartsWith($base, [System.StringComparison]::Ordinal)) {
            $url = $url.Substring($base.Length)
        }
        $dispList.Add([ordered]@{ method = [string]$a.method; url = $url; body = $a.body })
    }
    $dispActionsJson = ConvertTo-JiraJsonValue $dispList.ToArray()

    # ---- (8) Confirmation ----------------------------------------------------
    $confirmed = $false
    $prompted = $false
    $declined = $false
    $noTerminal = $false
    if ($dryRun) {
        # a dry run never prompts and never writes
    }
    elseif ($yes) { $confirmed = $true }
    else {
        $answer = ''
        if ($env:SPEC_KIT_JIRA_ADOPT_ANSWER) {
            $prompted = $true
            $answer = $env:SPEC_KIT_JIRA_ADOPT_ANSWER
        }
        elseif (-not [Console]::IsInputRedirected) {
            $prompted = $true
            $line = [Console]::In.ReadLine()
            $answer = $(if ($null -eq $line) { '' } else { $line })
        }
        else { $noTerminal = $true }
        if ($prompted) {
            if (@('y', 'Y', 'yes', 'Yes', 'YES') -ccontains $answer) { $confirmed = $true } else { $declined = $true }
        }
    }

    # ---- (9) Report the plan BEFORE any write --------------------------------
    $ad = New-AdoptAdoptionBlock $true $prefix $confirmed $bindingsJson $refusalsJson $outOfScopeJson
    if (-not $json) {
        Write-AdoptPlan $ad
        if (-not $confirmed) { Write-AdoptAction $dispActionsJson }
        if ($prompted) {
            [Console]::Out.Write("Apply this plan? [y/N] $(if ($confirmed) { 'y' } else { 'n' })`n")
        }
        if ($declined) { [Console]::Out.Write("Adoption cancelled: nothing was written.`n") }
        if ($noTerminal) { [Console]::Out.Write("Adoption not applied: no terminal is attached. Re-run with --yes to apply this plan.`n") }
        if ($dryRun) { [Console]::Out.Write("Dry run: nothing was written.`n") }
    }

    # ---- (10) Apply ----------------------------------------------------------
    # Any per-binding refusal makes the run exit 4 whether confirmed or declined;
    # when classes co-occur the HIGHEST applicable code wins (FR-013).
    $rc = 0
    if ($refusals.Count -gt 0) { $rc = [int](Get-JiraExitCode 'config') }
    $actionCount = @($actionsJson | ConvertFrom-Json -Depth 100).Count
    if ($confirmed -and $actionCount -gt 0) {
        $applyRc = [int](Invoke-JiraApplyWriteSet -ActionsJson $actionsJson)
        if ($applyRc -gt $rc) { $rc = $applyRc }
    }

    $updated = @($bindings | Where-Object { [string]$_.status -ceq 'adopt' }).Count
    $skipped = @($bindings | Where-Object { [string]$_.status -ceq 'already-adopted' }).Count

    Write-AdoptSummary $json (New-AdoptSummary $dryRun $ad $dispActionsJson $updated $skipped $refusals.Count $rc)
    return $rc
}

Export-ModuleMember -Function Invoke-JiraAdopt
