# commands/Feature.psm1 — Ticket-first feature naming (002 US3, FR-013…FR-017).
# Mirror of commands/feature.sh.
#
# Invoke-JiraFeature is the deterministic step registered as the
# `before_specify` hook. It loads the committed `teams:` catalogue and the
# human-owned `.specify/jira/personal.yml` selection, resolves the effective
# team (honouring a cross-team `--use-team` confirmation), resolves the Jira
# ticket BEFORE naming (validate a mentioned key, else guarded-create one), and
# emits the branch name and flat folder short-name.
#
# Non-blocking by construction (FR-016/FR-017): no team selected ⇒
# {active:false}; Jira unreachable or a create refused ⇒ {active:false} plus one
# warning. The host specify flow then proceeds exactly as it does today.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../lib/Cli.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../lib/Output.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../lib/Config.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../engine/Naming.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../sink/jira/Ticket.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../sink/jira/Designator.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../sink/jira/Adoption.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../lib/SeedState.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../sink/jira/PrivacyGuard.psm1') -Force

function Get-FeatProp {
    # StrictMode-safe optional property read: $null when the property is absent.
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $p = $Object.PSObject.Properties[$Name]
        if ($p) { return $p.Value }
    }
    return $null
}

function Get-JiraFeatDesignatorNumberSource {
    <#
    .SYNOPSIS
      FR-059/research R9: which key supplies the naming engine's number.
      Mirror of _feat_designator_number_source. Naming.psm1 gains zero
      lines — this selects WHICH key is handed to the existing
      Get-JiraNamingTicketNumber. Returns $null for shape 5 (free-text
      parent, no stories) — not a refusal, the ordinary description-derived
      naming applies unchanged.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()] [string] $ParentJson = '', [string] $StoriesJson = '[]')

    if ($ParentJson) {
        $parent = $ParentJson | ConvertFrom-Json -Depth 20
        $form = Get-FeatProp $parent 'form'
        if ($form -eq 'key' -or $form -eq 'url') {
            return [string](Get-FeatProp $parent 'key')
        }
    }
    $stories = @($StoriesJson | ConvertFrom-Json -Depth 20)
    $storyOnly = @($stories | Where-Object { (Get-FeatProp $_ 'role') -eq 'story' } | Sort-Object { [int](Get-FeatProp $_ 'position') })
    if ($storyOnly.Count -gt 0) {
        return [string](Get-FeatProp $storyOnly[0] 'key')
    }
    return $null
}

function Get-JiraFeatResolvedSlug {
    <#
    .SYNOPSIS
      FR-059: the resolved slug. Mirror of _feat_resolved_slug. Shapes 1-4
      derive the slug from the resolved KEY via the existing
      Get-JiraFeatureSlug (ticket-first folder naming); shape 5 and the
      no-designator case fall through to the ordinary description-derived
      slug, unchanged (C-1).
    #>
    [CmdletBinding()]
    param([AllowEmptyString()] [string] $ParentJson = '', [string] $StoriesJson = '[]', [string] $Description)
    $key = Get-JiraFeatDesignatorNumberSource -ParentJson $ParentJson -StoriesJson $StoriesJson
    if ($key) { return (Get-JiraFeatureSlug -Description $key) }
    return (Get-JiraFeatureSlug -Description $Description)
}

function Get-JiraFeatDeclaredTypeFor {
    # The committed projects[].hierarchy.<Role> issue-type name, or empty.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Role, [Parameter(Mandatory)] [string] $ProjectKey, [Parameter(Mandatory)] $Merged)
    $projects = @((Get-FeatProp $Merged 'projects') | Where-Object { $null -ne $_ })
    $p = $projects | Where-Object { [string](Get-FeatProp $_ 'key') -ceq $ProjectKey } | Select-Object -First 1
    if (-not $p) { return '' }
    $h = Get-FeatProp $p 'hierarchy'
    if (-not $h) { return '' }
    $v = Get-FeatProp $h $Role
    if ($null -eq $v) { return '' }
    return [string]$v
}

function Get-JiraFeatHaltedCsvFor {
    # The committed projects[].halted_statuses as a comma-separated list.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ProjectKey, [Parameter(Mandatory)] $Merged)
    $projects = @((Get-FeatProp $Merged 'projects') | Where-Object { $null -ne $_ })
    $p = $projects | Where-Object { [string](Get-FeatProp $_ 'key') -ceq $ProjectKey } | Select-Object -First 1
    if (-not $p) { return '' }
    $hs = @(Get-FeatProp $p 'halted_statuses')
    return (($hs | Where-Object { $_ }) -join ',')
}

function Get-JiraFeatRefMessage {
    # Compose message + remediation for a moment-1 refusal class not already
    # carrying one. Text mirrors spec.md's FR-036 table verbatim.
    param([string] $Code, [string] $Detail)
    switch ($Code) {
        'REF-DESIGNATOR' { return "${Code}: ${Detail} — paste the issue key or the browser URL of the issue; or, for a parent to create, type its title" }
        'REF-HOST' { return "${Code}: ${Detail} — paste a URL from the configured site, or correct the site base URL in the configuration" }
        'REF-DUPLICATE' { return "${Code}: ${Detail} — remove the duplicate designator" }
        'REF-MULTIPROJECT' { return "${Code}: ${Detail} — name issues from one project per specification" }
        'REF-EXISTS' { return "${Code}: ${Detail} — retro-seeding is out of scope; create a new specification" }
        default { return "${Code}: ${Detail}" }
    }
}

function Invoke-JiraFeatSeedFromDesignator {
    <#
    .SYNOPSIS
      Moment 1's designator path (027, contract seed-cli-contract.md §3,
      research R1). Zero Jira mutations. Mirror of
      _feat_seed_from_designators. Writes via Write-FeatResult and returns
      the exit code.
    #>
    [CmdletBinding()]
    param(
        [bool] $Json, [bool] $DryRun, [string] $Description, [string] $EffId, [string] $EffProject,
        [string] $Prefix, [string] $Pattern, [bool] $OverrideUsed, [Parameter(Mandatory)] $Merged,
        [bool] $ParentSeen, [AllowEmptyString()] [string] $ParentRaw, [AllowEmptyString()] [string] $StoriesJoined
    )
    $baseUrl = if ($env:SPEC_KIT_JIRA_BASE_URL) { $env:SPEC_KIT_JIRA_BASE_URL } else { '' }

    # --- §3 steps 1-2: parse + classify, REF-DESIGNATOR / REF-HOST -----------
    $classified = [System.Collections.Generic.List[object]]::new()
    if ($ParentSeen) {
        $classified.Add((Resolve-JiraDesignator -Role 'specification' -Raw $ParentRaw -BaseUrl $baseUrl | ConvertFrom-Json -Depth 100))
    }
    $storyRaws = @()
    if ($StoriesJoined) {
        $us = [char]0x1F
        $storyRaws = @($StoriesJoined.Split($us))
    }
    foreach ($raw in $storyRaws) {
        $classified.Add((Resolve-JiraDesignator -Role 'story' -Raw $raw -BaseUrl $baseUrl | ConvertFrom-Json -Depth 100))
    }

    $refusing = @($classified | Where-Object { $_.PSObject.Properties.Name -contains 'refuse' })
    if ($refusing.Count -gt 0) {
        foreach ($r in $refusing) {
            $code = [string]$r.refuse
            $detail = "designator `"$($r.raw)`" did not resolve"
            [Console]::Error.WriteLine("feature: $(Get-JiraFeatRefMessage -Code $code -Detail $detail)")
        }
        return (Get-JiraExitCode 'config')
    }

    # --- §3 step 3: de-duplicate -----------------------------------------------
    $allJson = ConvertTo-JiraJsonValue $classified
    $dedupe = Resolve-JiraDesignatorSet -Items $allJson | ConvertFrom-Json -Depth 100
    if (-not [bool]$dedupe.ok) {
        $dups = ($dedupe.duplicates -join ', ')
        [Console]::Error.WriteLine("feature: $(Get-JiraFeatRefMessage -Code 'REF-DUPLICATE' -Detail "issue(s) named more than once: $dups")")
        return (Get-JiraExitCode 'config')
    }
    $designators = @($dedupe.designators)
    $designatorsJson = ConvertTo-JiraJsonValue $designators
    $parentObj = $designators | Where-Object { (Get-FeatProp $_ 'role') -eq 'specification' } | Select-Object -First 1
    $parentJson = if ($parentObj) { ConvertTo-JiraJsonValue $parentObj } else { '' }
    $storiesArr = @($designators | Where-Object { (Get-FeatProp $_ 'role') -eq 'story' } | Sort-Object { [int](Get-FeatProp $_ 'position') })
    $storiesJson = ConvertTo-JiraJsonValue $storiesArr

    # --- resolved slug / short-name (FR-059) ----------------------------------
    $bareSlug = Get-JiraFeatResolvedSlug -ParentJson $parentJson -StoriesJson $storiesJson -Description $Description
    $shortName = Get-JiraShortName -FolderPrefix $Prefix -Slug $bareSlug
    $synthSpecPath = "specs/$shortName/spec.md"

    # --- §3 step 4: folder exists? -> REF-EXISTS ------------------------------
    if (Test-Path -LiteralPath "specs/$shortName" -PathType Container) {
        [Console]::Error.WriteLine("feature: $(Get-JiraFeatRefMessage -Code 'REF-EXISTS' -Detail "the specification folder specs/$shortName already exists")")
        return (Get-JiraExitCode 'config')
    }

    # --- §3 step 5: one bulkfetch ----------------------------------------------
    $pkey = ''
    if ($parentObj) {
        $pform = Get-FeatProp $parentObj 'form'
        if ($pform -eq 'key' -or $pform -eq 'url') { $pkey = [string](Get-FeatProp $parentObj 'key') }
    }
    $keys = [System.Collections.Generic.List[string]]::new()
    if ($pkey) { $keys.Add($pkey) }
    foreach ($s in $storiesArr) { $keys.Add([string](Get-FeatProp $s 'key')) }

    if ($keys.Count -gt 0) {
        $loadRc = Invoke-JiraAdoptionLoad -Keys $keys.ToArray()
        if ([int]$loadRc -ne 0) {
            [Console]::Error.WriteLine('feature: an unreliable read occurred while resolving the named issues — designators were supplied, so the run refuses rather than proceeding without them (FR-038)')
            return (Get-JiraExitCode 'fail_closed')
        }
    }

    # --- §3 steps 6-12: per-key and set-wide refusal classes, aggregated -----
    # spec_ref.spec_slug prefers SPEC_KIT_JIRA_SPEC_SLUG (the host's own
    # numbered feature id) — never the resolved short_name, which is this
    # extension's OWN ticket-based folder name and a different identifier
    # entirely (matches the existing ticket-create path further below).
    $repo = if ($env:SPEC_KIT_JIRA_REPO) { $env:SPEC_KIT_JIRA_REPO } else { 'local/repo' }
    $specSlug = if ($env:SPEC_KIT_JIRA_SPEC_SLUG) { $env:SPEC_KIT_JIRA_SPEC_SLUG } else { 'spec' }
    $specRef = ConvertTo-JiraJsonValue ([ordered]@{ repo = $repo; spec_slug = $specSlug })
    $evalResults = [System.Collections.Generic.List[object]]::new()
    if ($pkey) {
        $ptype = Get-JiraFeatDeclaredTypeFor -Role 'specification' -ProjectKey $EffProject -Merged $Merged
        $pterm = Get-JiraFeatHaltedCsvFor -ProjectKey $EffProject -Merged $Merged
        $evalResults.Add((Test-JiraAdoptionEvaluate -RoutedProject $EffProject -Role 'specification' -Key $pkey -DeclaredType $ptype -TerminalStatusesCsv $pterm -SpecRefJson $specRef | ConvertFrom-Json -Depth 100))
    }
    $stype = Get-JiraFeatDeclaredTypeFor -Role 'story' -ProjectKey $EffProject -Merged $Merged
    $sterm = Get-JiraFeatHaltedCsvFor -ProjectKey $EffProject -Merged $Merged
    foreach ($s in $storiesArr) {
        $skey = [string](Get-FeatProp $s 'key')
        $evalResults.Add((Test-JiraAdoptionEvaluate -RoutedProject $EffProject -Role 'story' -Key $skey -DeclaredType $stype -TerminalStatusesCsv $sterm -SpecRefJson $specRef | ConvertFrom-Json -Depth 100))
    }

    $storyKeysJson = ConvertTo-JiraJsonValue (@($storiesArr | ForEach-Object { [string](Get-FeatProp $_ 'key') }))
    $mp = Get-JiraAdoptionMultiprojectViolation -StoryKeysJson $storyKeysJson | ConvertFrom-Json -Depth 100
    if (@($mp).Count -gt 0) {
        $msg = Get-JiraFeatRefMessage -Code 'REF-MULTIPROJECT' -Detail "named story-role issues span more than one project: $(@($mp) -join ', ')"
        $evalResults.Add(([pscustomobject][ordered]@{ code = 'REF-MULTIPROJECT'; key = ''; message = $msg }))
    }

    $evalJson = ConvertTo-JiraJsonValue $evalResults
    $refusals = @(Get-JiraAdoptionAggregateRefusal -Items $evalJson | ConvertFrom-Json -Depth 100)
    if ($refusals.Count -gt 0) {
        foreach ($r in $refusals) {
            [Console]::Error.WriteLine("feature: $($r.code): $($r.message)")
        }
        return (Get-JiraExitCode 'config')
    }

    # --- naming (FR-059/R9): the SAME key feeds Get-JiraTicketNumber ---------
    $desigKey = Get-JiraFeatDesignatorNumberSource -ParentJson $parentJson -StoriesJson $storiesJson
    $number = ''
    $branchName = ''
    if ($desigKey) {
        $number = Get-JiraTicketNumber -Key $desigKey
        $branchName = Expand-JiraBranchPattern -Pattern $Pattern -Id $number -FeatureName $bareSlug
    }

    # --- §3 step 15 (material) precedes 13-14 (record): FR-065 requires the
    # scan to run "before it is handed to the drafting agent", and a BLOCK is
    # zero writes of any kind, so the seed record must not be written before
    # the scan clears.
    function Get-FeatMaterialParent {
        param($EntryFields)
        $p = Get-FeatProp $EntryFields 'parent'
        if (-not $p) { return $null }
        $pf = Get-FeatProp $p 'fields'
        return [ordered]@{
            key     = [string](Get-FeatProp $p 'key')
            summary = [string](Get-FeatProp $pf 'summary')
            status  = [string](Get-FeatProp (Get-FeatProp $pf 'status') 'name')
        }
    }

    $material = [System.Collections.Generic.List[object]]::new()
    if ($pkey) {
        $pentry = Get-JiraAdoption -Key $pkey | ConvertFrom-Json -Depth 100
        $pfields = Get-FeatProp $pentry 'fields'
        $material.Add([ordered]@{
            role        = 'specification'; key = $pkey
            summary     = [string](Get-FeatProp $pfields 'summary')
            description = Get-JiraAdoptionDescriptionText (Get-FeatProp $pfields 'description')
            status      = [string](Get-FeatProp (Get-FeatProp $pfields 'status') 'name')
            parent      = (Get-FeatMaterialParent $pfields)
        })
    }
    foreach ($s in $storiesArr) {
        $skey2 = [string](Get-FeatProp $s 'key')
        $sentry = Get-JiraAdoption -Key $skey2 | ConvertFrom-Json -Depth 100
        $sfields = Get-FeatProp $sentry 'fields'
        $material.Add([ordered]@{
            role        = 'story'; key = $skey2
            summary     = [string](Get-FeatProp $sfields 'summary')
            description = Get-JiraAdoptionDescriptionText (Get-FeatProp $sfields 'description')
            status      = [string](Get-FeatProp (Get-FeatProp $sfields 'status') 'name')
            parent      = (Get-FeatMaterialParent $sfields)
        })
    }
    $materialContent = ConvertTo-JiraJsonValue $material

    # --- FR-065: the two-tier pre-write privacy guard, over the seed
    # material, before it is handed to the drafting agent.
    $allowlist = if ($env:SPEC_KIT_JIRA_ALLOWLIST) { $env:SPEC_KIT_JIRA_ALLOWLIST } else { '[]' }
    $blockRc = Test-JiraPrivacyBlock -Payload $materialContent -KnownCoordinatesJson '[]' -AllowlistJson $allowlist
    if ([int]$blockRc -ne 0) { return [int]$blockRc }

    # --- §3 steps 13-14: slug + seed record -----------------------------------
    # The material path is DETERMINISTIC (a sibling of the seed record,
    # under the same state directory) rather than a fresh temp path: a
    # random OS temp path in the emitted JSON would never be byte-identical
    # across a conformance run's two ports (NFR-1/Constitution VI).
    $seedMaterialPath = ''
    if (-not $DryRun) {
        # routing: the routed project, the declared types/terminal statuses
        # moment 1 already resolved from config.yml, and the RESOLVED
        # numeric type ids from config.local.yml (parent_type.id/
        # child_type.id) — recorded so a resume (FR-062) can re-evaluate
        # every refusal class from Jira alone, and so a free-text parent
        # create (FR-023) has the type id it needs, without moment 2 ever
        # opening config.yml/personal.yml/config.local.yml itself.
        $localCfg = Get-CfgLocalObject
        $resolvedIds = if ($localCfg.Contains('resolved_ids')) { $localCfg['resolved_ids'] } else { $null }
        $localBinding = if ($resolvedIds -and $resolvedIds.Contains($EffProject)) { $resolvedIds[$EffProject] } else { $null }
        $parentTypeId = if ($localBinding -and $localBinding.Contains('parent_type') -and $localBinding['parent_type'].Contains('id')) { [string]$localBinding['parent_type']['id'] } else { '' }
        $childTypeId = if ($localBinding -and $localBinding.Contains('child_type') -and $localBinding['child_type'].Contains('id')) { [string]$localBinding['child_type']['id'] } else { '' }
        $routingJson = ConvertTo-JiraJsonValue ([ordered]@{
                project                     = $EffProject
                declared_type_specification = (Get-JiraFeatDeclaredTypeFor -Role 'specification' -ProjectKey $EffProject -Merged $Merged)
                declared_type_story         = (Get-JiraFeatDeclaredTypeFor -Role 'story' -ProjectKey $EffProject -Merged $Merged)
                terminal_statuses_csv       = (Get-JiraFeatHaltedCsvFor -ProjectKey $EffProject -Merged $Merged)
                parent_type_id              = $parentTypeId
                child_type_id               = $childTypeId
            })
        $doc = New-JiraSeedStateDocument -Slug $shortName -DesignatorsJson $designatorsJson -PlanDigest '' -RoutingJson $routingJson -PlanSnapshotJson '[]'
        Save-JiraSeedState -SpecPath $synthSpecPath -DocumentJson $doc
        $configDir = if ($env:JIRA_CONFIG_DIR) { $env:JIRA_CONFIG_DIR } else { '.specify/jira' }
        $seedMaterialPath = Join-Path $configDir "state/$shortName.seed-material.json"
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($seedMaterialPath, $materialContent, $utf8NoBom)
    }

    $ticketKeyOut = if ($desigKey) { $desigKey } else { $null }
    $numOut = if ($desigKey) { $number } else { $null }
    $branchOut = if ($desigKey) { $branchName } else { $null }
    $action = if ($desigKey) { 'adopted' } else { 'none' }
    $materialOut = if ($seedMaterialPath) { $seedMaterialPath } else { $null }

    $payload = ConvertTo-JiraJsonValue ([ordered]@{
        active = $true; team = $EffId
        ticket = [ordered]@{ key = $ticketKeyOut; number = $numOut; action = $action }
        branch_name = $branchOut; short_name = $shortName; override_used = $OverrideUsed; warnings = @()
        seed_material = $materialOut
    })
    Write-FeatResult -Payload $payload -Json $Json
    return 0
}

function Write-FeatResult {
    # Print the canonical result (JSON or prose). Mirror of _feat_emit.
    param([string] $Payload, [bool] $Json)
    if ($Json) {
        [Console]::Out.Write($Payload + "`n")
    }
    else {
        [Console]::Out.Write((ConvertTo-JiraFeatureProse -Json $Payload))
    }
}

function ConvertTo-JiraFeatureProse {
    # Render the feature result as human prose (the default output). The
    # payload is feature-shaped (contracts/feature-cli-contract.md) — never a
    # run summary, so the run-summary renderer does not apply. Byte-identical
    # to the bash twin's _feat_render_prose (NFR-1).
    param([Parameter(Mandatory)] [string] $Json)
    $p = $Json | ConvertFrom-Json -Depth 100
    $lines = [System.Collections.Generic.List[string]]::new()
    $confirmation = Get-FeatProp $p 'confirmation_required'
    if (-not [bool](Get-FeatProp $p 'active')) {
        $lines.Add('Feature: inactive')
    }
    elseif ($null -ne $confirmation) {
        $lines.Add('Feature: confirmation required')
        $tt = [string](Get-FeatProp $confirmation 'ticket_team')
        if ([string]::IsNullOrEmpty($tt)) { $tt = '—' }
        $lines.Add("Ticket: $([string](Get-FeatProp $confirmation 'ticket')) (team: $tt)")
        $lines.Add("Selected team: $([string](Get-FeatProp $confirmation 'selected_team'))")
    }
    else {
        $lines.Add("Feature: active (team: $([string](Get-FeatProp $p 'team')))")
        $ticket = Get-FeatProp $p 'ticket'
        $key = [string](Get-FeatProp $ticket 'key')
        if ([string]::IsNullOrEmpty($key)) { $key = '—' }
        $lines.Add("Ticket: $key ($([string](Get-FeatProp $ticket 'action')))")
        $branch = [string](Get-FeatProp $p 'branch_name')
        if ([string]::IsNullOrEmpty($branch)) { $branch = '—' }
        $lines.Add("Branch: $branch")
        $lines.Add("Folder: $([string](Get-FeatProp $p 'short_name'))")
        $ou = if ([bool](Get-FeatProp $p 'override_used')) { 'true' } else { 'false' }
        $lines.Add("Override used: $ou")
    }
    foreach ($w in @(Get-FeatProp $p 'warnings')) {
        if (-not [string]::IsNullOrEmpty([string]$w)) { $lines.Add("Warning: $w") }
    }
    return (($lines -join "`n") + "`n")
}

function Write-FeatFallback {
    # The FR-016 non-blocking fallback: {active:false} plus exactly one warning;
    # one WARNING: line on stderr; exit 0. Mirror of _feat_fallback.
    param([bool] $Json)
    $msg = 'could not resolve a ticket in Jira — proceeding without one (reconciliation will attach it later)'
    [Console]::Error.WriteLine("WARNING: $msg")
    $payload = ConvertTo-JiraJsonValue ([ordered]@{ active = $false; warnings = @($msg) })
    Write-FeatResult -Payload $payload -Json $Json
}

function Invoke-JiraFeature {
    <#
    .SYNOPSIS
      The feature-naming ceremony (contracts/feature-cli-contract.md). Writes
      the result via the [Console] streams and returns ONLY its numeric exit
      code (mirroring the Bash port's echo -> fd1, return -> status convention).
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments = @())

    $parsed = Invoke-JiraCliParse -Arguments $Arguments
    $state = @{}
    foreach ($line in ($parsed -split "`n")) {
        if ($line -match '^([^=]+)=(.*)$') { $state[$Matches[1]] = $Matches[2] }
    }
    if ($state['exit'] -ne '0') {
        if ($state.ContainsKey('error') -and $state['error']) { [Console]::Error.WriteLine("feature: $($state['error'])") }
        return [int] $state['exit']
    }
    $json = $state['json'] -eq 'true'
    $dryRun = $state['dry_run'] -eq 'true'
    $useTeam = if ($state.ContainsKey('use_team')) { $state['use_team'] } else { '' }
    $argsLine = if ($state.ContainsKey('args')) { $state['args'] } else { '' }
    $parentSeen = $state['parent_seen'] -eq 'true'
    $parentRaw = if ($state.ContainsKey('parent')) { $state['parent'] } else { '' }
    $storiesJoined = if ($state.ContainsKey('stories')) { $state['stories'] } else { '' }

    $dir = if ($env:JIRA_CONFIG_DIR) { $env:JIRA_CONFIG_DIR } else { '.specify/jira' }

    # (1) No committed catalogue at all ⇒ pass-through (FR-017).
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'config.yml'))) {
        Write-FeatResult -Payload '{"active":false}' -Json $json
        return 0
    }
    # The Bash twin silences this load's stderr (2>/dev/null): a failed read is
    # a silent pass-through, never a block.
    $errSink = [System.IO.StringWriter]::new()
    $origErr = [Console]::Error
    [Console]::SetError($errSink)
    try { $cfg = Import-JiraConfig -ConfigDir $dir }
    finally { [Console]::SetError($origErr) }
    if ($cfg.ExitCode -ne 0) {
        Write-FeatResult -Payload '{"active":false}' -Json $json
        return 0
    }
    $merged = $cfg.Json | ConvertFrom-Json -Depth 100
    $teams = @((Get-FeatProp $merged 'teams') | Where-Object { $null -ne $_ })
    if ($teams.Count -eq 0) {
        Write-FeatResult -Payload '{"active":false}' -Json $json
        return 0
    }

    # (2) Personal selection (human-owned; validated; never written). An invalid
    #     file fails closed with a located error (exit 4).
    $personal = Import-JiraPersonalConfig -ConfigDir $dir -MergedJson $cfg.Json
    if ($personal.ExitCode -ne 0) { return [int] $personal.ExitCode }
    $pObj = $personal.Json | ConvertFrom-Json -Depth 100
    $pActive = [bool](Get-FeatProp $pObj 'active')
    $pTeam = [string](Get-FeatProp $pObj 'team')
    $pOverride = Get-FeatProp $pObj 'override'

    # No selection and no cross-team answer ⇒ pass-through (FR-017).
    if (-not $pActive -and [string]::IsNullOrEmpty($useTeam)) {
        Write-FeatResult -Payload '{"active":false}' -Json $json
        return 0
    }

    # (3) Effective team resolution.
    $ids = @($teams | ForEach-Object { [string](Get-FeatProp $_ 'id') })
    $overrideUsed = $false
    $override = $null
    if (-not [string]::IsNullOrEmpty($useTeam)) {
        if ($ids -cnotcontains $useTeam) {
            [Console]::Error.WriteLine("feature: unknown team `"$useTeam`" — valid teams: $($ids -join ', ')")
            return (Get-JiraExitCode 'config')
        }
        $effId = $useTeam
    }
    else {
        $effId = $pTeam
        $override = $pOverride
        if ($null -ne $override) { $overrideUsed = $true }
    }

    # (4) Description is required once a team is in play (FR-013 precedes naming).
    #     The optional leading positional is a mentioned issue key.
    $words = @($argsLine -split ' ' | Where-Object { $_ -ne '' })
    $ticketKey = ''
    $desc = ''
    if ($words.Count -gt 0 -and $words[0] -cmatch '^[A-Z][A-Z0-9_]+-[0-9]+$') {
        $ticketKey = $words[0]
        $desc = ($words | Select-Object -Skip 1) -join ' '
    }
    else {
        $desc = $words -join ' '
    }
    if ([string]::IsNullOrEmpty($desc)) {
        [Console]::Error.WriteLine('feature: a feature description is required')
        return (Get-JiraExitCode 'usage')
    }

    # Resolve the effective team entry and its naming rule.
    $teamEntry = $teams | Where-Object { [string](Get-FeatProp $_ 'id') -ceq $effId } | Select-Object -First 1
    $effProject = [string](Get-FeatProp $teamEntry 'project')
    if ($null -ne $override) {
        $prefix = [string](Get-FeatProp $override 'folder_prefix')
        if ([string]::IsNullOrEmpty($prefix)) { $prefix = [string](Get-FeatProp $teamEntry 'folder_prefix') }
        $pattern = [string](Get-FeatProp $override 'branch_pattern')
        if ([string]::IsNullOrEmpty($pattern)) { $pattern = [string](Get-FeatProp $teamEntry 'branch_pattern') }
    }
    else {
        $prefix = [string](Get-FeatProp $teamEntry 'folder_prefix')
        $pattern = [string](Get-FeatProp $teamEntry 'branch_pattern')
    }

    $slug = Get-JiraFeatureSlug -Description $desc

    # (027, US1/US3): designators supplied ⇒ moment 1's seed-from-Jira path
    # takes over ticket resolution and naming entirely. Byte-identical to
    # the release below when neither flag is supplied (C-1, US5).
    if ($parentSeen -or $storiesJoined) {
        return (Invoke-JiraFeatSeedFromDesignator -Json $json -DryRun $dryRun -Description $desc -EffId $effId `
                -EffProject $effProject -Prefix $prefix -Pattern $pattern -OverrideUsed $overrideUsed -Merged $merged `
                -ParentSeen $parentSeen -ParentRaw $parentRaw -StoriesJoined $storiesJoined)
    }

    # (5) Ticket resolution BEFORE naming.
    if (-not [string]::IsNullOrEmpty($ticketKey)) {
        # Mentioned key: validate (read). A fail-closed read never falls back.
        $validated = Confirm-JiraTicket -Key $ticketKey
        if ($validated.ExitCode -ne 0) { return [int] $validated.ExitCode }
        $vObj = $validated.Json | ConvertFrom-Json -Depth 100
        $ticketProject = [string](Get-FeatProp $vObj 'project')
        $ticketTeam = ''
        foreach ($t in $teams) {
            if ([string](Get-FeatProp $t 'project') -ceq $ticketProject) { $ticketTeam = [string](Get-FeatProp $t 'id'); break }
        }

        # Cross-team confirmation (only when the operator did not answer it).
        if ([string]::IsNullOrEmpty($useTeam)) {
            if ([string]::IsNullOrEmpty($ticketTeam) -or $ticketTeam -cne $pTeam) {
                $tt = if ([string]::IsNullOrEmpty($ticketTeam)) { $null } else { $ticketTeam }
                $payload = ConvertTo-JiraJsonValue ([ordered]@{
                    active = $true
                    confirmation_required = [ordered]@{ ticket = $ticketKey; ticket_team = $tt; selected_team = $pTeam }
                })
                Write-FeatResult -Payload $payload -Json $json
                return 0
            }
        }

        $number = Get-JiraTicketNumber -Key $ticketKey
        $ticketKeyOut = $ticketKey
        $action = if ($dryRun) { 'would-attach' } else { 'attached' }
    }
    else {
        # No mentioned key: guarded create in the effective team's project.
        if ($dryRun) {
            # Predict only — zero Jira calls, no branch (no number yet).
            $shortDry = Get-JiraShortName -FolderPrefix $prefix -Slug $slug
            $payload = ConvertTo-JiraJsonValue ([ordered]@{
                active = $true; team = $effId
                ticket = [ordered]@{ key = $null; number = $null; action = 'would-create' }
                branch_name = $null; short_name = $shortDry; override_used = $overrideUsed; warnings = @()
            })
            Write-FeatResult -Payload $payload -Json $json
            return 0
        }

        $typeId = ''
        if ($env:SPEC_KIT_JIRA_PLAN_CONTEXT) {
            try { $typeId = [string](Get-FeatProp ($env:SPEC_KIT_JIRA_PLAN_CONTEXT | ConvertFrom-Json -Depth 100) 'story_type_id') }
            catch { $typeId = '' }
        }
        $repo = if ($env:SPEC_KIT_JIRA_REPO) { $env:SPEC_KIT_JIRA_REPO } else { 'local/repo' }
        $slugRef = if ($env:SPEC_KIT_JIRA_SPEC_SLUG) { $env:SPEC_KIT_JIRA_SPEC_SLUG } else { 'spec' }
        $specRef = '{"repo":' + (ConvertTo-JiraJsonString $repo) + ',"spec_slug":' + (ConvertTo-JiraJsonString $slugRef) + '}'

        if ([string]::IsNullOrEmpty($typeId) -or [string]::IsNullOrEmpty($env:SPEC_KIT_JIRA_BASE_URL)) {
            Write-FeatFallback -Json $json
            return 0
        }

        $created = New-JiraTicket -ProjectKey $effProject -Summary $desc -StoryTypeId $typeId -SpecRefJson $specRef
        if ($created.ExitCode -eq 9) { return 9 }
        if ($created.ExitCode -ne 0) {
            Write-FeatFallback -Json $json
            return 0
        }
        $createdKey = [string]((($created.Json) | ConvertFrom-Json -Depth 100).key)
        $number = Get-JiraTicketNumber -Key $createdKey
        $ticketKeyOut = $createdKey
        $action = 'created'
    }

    # (6) Naming (pure engine).
    $branchName = Expand-JiraBranchPattern -Pattern $pattern -Id $number -FeatureName $slug
    $shortName = Get-JiraShortName -FolderPrefix $prefix -Slug $slug

    $payload = ConvertTo-JiraJsonValue ([ordered]@{
        active = $true; team = $effId
        ticket = [ordered]@{ key = $ticketKeyOut; number = $number; action = $action }
        branch_name = $branchName; short_name = $shortName; override_used = $overrideUsed; warnings = @()
    })
    Write-FeatResult -Payload $payload -Json $json
    return 0
}

Export-ModuleMember -Function Invoke-JiraFeature, Get-JiraFeatDesignatorNumberSource, Get-JiraFeatResolvedSlug, `
    Invoke-JiraFeatSeedFromDesignator
