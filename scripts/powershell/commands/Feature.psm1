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

function Get-JiraFeatReduceMention {
    <#
    .SYNOPSIS
      029, contract mention-grammar.md §1-§3: does -Raw reduce to a Jira
      issue key, either directly or via a browser URL (reusing
      Get-JiraDesignatorUrlCandidate — never a second reduction
      implementation). Mirror of _feat_reduce_mention. Returns the reduced
      key, or $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Raw)
    if ($Raw -cmatch '^[A-Z][A-Z0-9_]+-[0-9]+$') { return $Raw }
    if ($Raw.Contains('://')) {
        $candidate = Get-JiraDesignatorUrlCandidate -Raw $Raw
        if ($candidate -and $candidate -cmatch '^[A-Z][A-Z0-9_]+-[0-9]+$') { return $candidate }
    }
    return $null
}

function Get-JiraFeatDetectMention {
    <#
    .SYNOPSIS
      029, contract mention-grammar.md §1-§3: the gate + scan. Mirror of
      _feat_detect_mentions. Returns an array of {raw; key} pscustomobjects
      in argv order. The gate (§1 rule 1): if the LEADING word does not
      itself reduce to a key, returns an empty array — no further word is
      examined. Once open, every remaining word that reduces to a key is
      detected too (§1 rule 2); the leading word's own detection is always
      first (§1 rule 3).
    #>
    [CmdletBinding()]
    param([string[]] $Words = @())
    $out = [System.Collections.Generic.List[object]]::new()
    if ($Words.Count -eq 0) { return $out.ToArray() }
    if (-not (Get-JiraFeatReduceMention -Raw $Words[0])) { return $out.ToArray() }
    foreach ($w in $Words) {
        $key = Get-JiraFeatReduceMention -Raw $w
        if ($key) { $out.Add([pscustomobject]@{ raw = $w; key = $key }) }
    }
    return $out.ToArray()
}

function Invoke-JiraFeatComposeReuseQuestion {
    <#
    .SYNOPSIS
      029, contract feature-question-contract.md §3/§3.1: compose the
      reuse_required payload (FR-001-FR-005, FR-025, FR-031, FR-033-FR-036,
      FR-040). Mirror of _feat_compose_reuse_question. -MentionsJson is
      Get-JiraFeatDetectMention' output (>=1 entries, gate already open);
      -PrimaryWideJson is Confirm-JiraTicket -Wide's result for the first
      mention — already read by the caller, no request here. Every issue
      beyond the first is resolved via Invoke-JiraAdoptionLoad/Get-JiraAdoption
      — the SAME bulk-read the designator path already uses — at most one
      further request regardless of count (FR-017, FR-034). Returns
      { ExitCode; Json }; Json is '' when ExitCode is non-zero (a fail-closed
      bulk read).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Mentions, [Parameter(Mandatory)] [string] $PrimaryWideJson,
        [Parameter(Mandatory)] [string] $EffProject, [Parameter(Mandatory)] $Merged
    )
    $n = @($Mentions).Count
    $extraKeys = [System.Collections.Generic.List[string]]::new()
    for ($i = 1; $i -lt $n; $i++) { $extraKeys.Add([string]$Mentions[$i].key) }
    if ($extraKeys.Count -gt 0) {
        $loadRc = Invoke-JiraAdoptionLoad -Keys $extraKeys.ToArray()
        if ([int]$loadRc -ne 0) { return [pscustomobject]@{ ExitCode = (Get-JiraExitCode 'fail_closed'); Json = '' } }
    }

    $specType = Get-JiraFeatDeclaredTypeFor -Role 'specification' -ProjectKey $EffProject -Merged $Merged
    $storyType = Get-JiraFeatDeclaredTypeFor -Role 'story' -ProjectKey $EffProject -Merged $Merged
    $haltedCsv = Get-JiraFeatHaltedCsvFor -ProjectKey $EffProject -Merged $Merged
    $noHierarchy = [string]::IsNullOrEmpty($specType) -and [string]::IsNullOrEmpty($storyType)
    $haltedList = @()
    if ($haltedCsv) { $haltedList = @($haltedCsv -split ',') }

    $primary = $PrimaryWideJson | ConvertFrom-Json -Depth 100
    $entries = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $n; $i++) {
        if ($i -eq 0) {
            $key = [string](Get-FeatProp $primary 'key')
            $summary = [string](Get-FeatProp $primary 'summary')
            $type = [string](Get-FeatProp $primary 'type')
            $status = [string](Get-FeatProp $primary 'status')
        }
        else {
            $key = [string]$Mentions[$i].key
            $entryJson = Get-JiraAdoption -Key $key
            if (-not $entryJson) { return [pscustomobject]@{ ExitCode = (Get-JiraExitCode 'fail_closed'); Json = '' } }
            $entry = $entryJson | ConvertFrom-Json -Depth 100
            $fields = Get-FeatProp $entry 'fields'
            $summary = [string](Get-FeatProp $fields 'summary')
            $type = [string](Get-FeatProp (Get-FeatProp $fields 'issuetype') 'name')
            $status = [string](Get-FeatProp (Get-FeatProp $fields 'status') 'name')
        }

        $role = $null
        $unmapped = $false
        if (-not $noHierarchy) {
            if ($specType -and $type -ceq $specType) { $role = 'specification' }
            elseif ($storyType -and $type -ceq $storyType) { $role = 'story' }
            else { $role = 'story'; $unmapped = $true }
        }
        $halted = $false
        if ($status -and ($haltedList -ccontains $status)) { $halted = $true }

        $entries.Add([ordered]@{
                key = $key; summary = $summary; type = $type; status = $status
                role = $role; unmapped = $unmapped; halted = $halted
            })
    }

    $declines = [ordered]@{
        specification = if ($noHierarchy) { $null } else { if ($specType) { $specType } else { $null } }
        story         = if ($noHierarchy) { $null } else { if ($storyType) { $storyType } else { $null } }
    }
    $payload = ConvertTo-JiraJsonValue ([ordered]@{
            active        = $true
            reuse_required = [ordered]@{ issues = $entries; declines_to = $declines }
        })
    return [pscustomobject]@{ ExitCode = 0; Json = $payload }
}

function ConvertTo-JiraFeatureReuseProse {
    <#
    .SYNOPSIS
      029: the prose form of a reuse_required (or reuse_issues_required)
      payload. Mirror of _feat_render_reuse_prose. Every line is its own
      string addition, never a multi-line jq/ConvertTo-Json render — keeps
      Windows' CRLF-emitting jq build out of the bash twin's path and keeps
      this port's own line endings under [Console]::Out's control (T022).
    #>
    param([Parameter(Mandatory)] [string] $Json)
    $p = $Json | ConvertFrom-Json -Depth 100
    $key = 'reuse_required'
    if (-not (Get-FeatProp $p 'reuse_required')) { $key = 'reuse_issues_required' }
    $q = Get-FeatProp $p $key
    $issues = @(Get-FeatProp $q 'issues')

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Feature: reuse decision required')
    foreach ($iss in $issues) {
        $type = [string](Get-FeatProp $iss 'type')
        $status = [string](Get-FeatProp $iss 'status')
        $summary = [string](Get-FeatProp $iss 'summary')
        $lines.Add("Detected: $([string](Get-FeatProp $iss 'key')) ($type, $status) $summary")
    }

    $declines = Get-FeatProp $q 'declines_to'
    $specType = [string](Get-FeatProp $declines 'specification')
    $storyType = [string](Get-FeatProp $declines 'story')

    if ([string]::IsNullOrEmpty($specType) -and [string]::IsNullOrEmpty($storyType)) {
        if ([string](Get-FeatProp $q 'reason') -eq 'designators required') {
            $lines.Add('Missing: which issues to reuse — this run cannot derive it without designators')
        }
        else {
            $lines.Add('Missing: this project declares no hierarchy, so no placement can be proposed')
        }
        $lines.Add('Answers: re-invoke with --parent <key|title> and one --story <key> per issue to reuse')
    }
    else {
        $specKeys = @($issues | Where-Object { (Get-FeatProp $_ 'role') -eq 'specification' } | ForEach-Object { [string](Get-FeatProp $_ 'key') })
        $storyKeys = @($issues | Where-Object { (Get-FeatProp $_ 'role') -eq 'story' } | ForEach-Object { [string](Get-FeatProp $_ 'key') })
        $clause = ''
        if ($specKeys.Count -gt 0) { $clause = "$($specKeys -join ', ') as the $specType of this specification" }
        if ($storyKeys.Count -gt 0) {
            if ($clause) { $clause += ', and ' }
            $clause += "$($storyKeys -join ', ') as a $storyType beneath it"
        }
        $lines.Add("Attach ${clause}?")
        $lines.Add("Source: the detected issues' content is what spec.md will be written from")
        $specWord = if ($specType) { $specType } else { 'Epic' }
        $storyWord = if ($storyType) { $storyType } else { 'Story' }
        $lines.Add("Answers: --reuse yes attaches them as proposed · --reuse no creates a new $specWord, plus one $storyWord per drafted user story")
    }

    $unmappedStoryWord = if ($storyType) { $storyType } else { 'Story' }
    $unmappedSpecWord = if ($specType) { $specType } else { 'Epic' }
    foreach ($iss in $issues) {
        if ([bool](Get-FeatProp $iss 'unmapped')) {
            $lines.Add("Unmapped: $([string](Get-FeatProp $iss 'key')) is a $([string](Get-FeatProp $iss 'type')), a type this project declares for no role — proposed as a $unmappedStoryWord; it needs no $unmappedSpecWord, and --reuse yes --parent <key|title> gives it one")
        }
    }
    foreach ($iss in $issues) {
        if ([bool](Get-FeatProp $iss 'halted')) {
            $lines.Add("Halted: $([string](Get-FeatProp $iss 'key')) is in $([string](Get-FeatProp $iss 'status')), halted — --reuse yes would be refused (REF-TERMINAL); answer --reuse no, reopen it, or name another")
        }
    }
    if (@($issues | Where-Object { (Get-FeatProp $_ 'role') -eq 'story' }).Count -gt 0) {
        $lines.Add("Drafted: user stories drafted beyond these become new $unmappedStoryWord issues beneath the same $unmappedSpecWord — named issues are reused, never duplicated")
    }

    return (($lines -join "`n") + "`n")
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

function Test-JiraFeatDesignatorRoleEvaluate {
    <#
    .SYNOPSIS
      029, T118 (FR-022/FR-036/FR-039, research R11): mirror of bash's
      _feat_designator_role_evaluate. Test-JiraAdoptionEvaluate collapses
      "type matches neither declared role" and "type matches the OTHER
      role's declared type" into one REF-ROLE; R11 requires the two to
      diverge on the designator path exactly as they do on the
      auto-detected question. A key whose type equals its own role's
      declared type, or for which no type is declared, is unchanged. A
      genuinely misplaced key — type equals the OTHER role's declared type
      — still refuses via Test-JiraAdoptionEvaluate's own REF-ROLE message,
      unchanged. Only a type matching NEITHER declared type is new: it
      refuses with FR-039's container wording for the specification/parent
      role, and is accepted with no type refusal for story (R11 — unmapped
      content needs no parent).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Role,
        [Parameter(Mandatory)] [string] $Key,
        [AllowEmptyString()] [string] $OwnType = '',
        [AllowEmptyString()] [string] $OtherType = '',
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $RoutedProject,
        [AllowEmptyString()] [string] $TerminalStatusesCsv = '',
        [AllowEmptyString()] [string] $SpecRefJson = ''
    )
    if (-not $OwnType) {
        return (Test-JiraAdoptionEvaluate -RoutedProject $RoutedProject -Role $Role -Key $Key -DeclaredType '' -TerminalStatusesCsv $TerminalStatusesCsv -SpecRefJson $SpecRefJson)
    }
    $entry = Get-JiraAdoption -Key $Key
    $actual = ''
    if ($entry) {
        $e = $entry | ConvertFrom-Json -Depth 100
        $itype = $e.fields.issuetype.name
        if ($itype) { $actual = [string]$itype }
    }
    if (-not $actual -or $actual -eq $OwnType) {
        return (Test-JiraAdoptionEvaluate -RoutedProject $RoutedProject -Role $Role -Key $Key -DeclaredType $OwnType -TerminalStatusesCsv $TerminalStatusesCsv -SpecRefJson $SpecRefJson)
    }
    if ($OtherType -and $actual -eq $OtherType) {
        return (Test-JiraAdoptionEvaluate -RoutedProject $RoutedProject -Role $Role -Key $Key -DeclaredType $OwnType -TerminalStatusesCsv $TerminalStatusesCsv -SpecRefJson $SpecRefJson)
    }
    if ($Role -eq 'specification') {
        $msg = "issue $Key has type $actual, declared for no role — the specification role is the container, and this feature never changes an existing issue type; supply a title instead of a key: --reuse yes --parent `"<title>`" --story $Key"
        return (ConvertTo-JiraJsonValue ([ordered]@{ code = 'REF-ROLE'; key = $Key; message = $msg }))
    }
    return (Test-JiraAdoptionEvaluate -RoutedProject $RoutedProject -Role $Role -Key $Key -DeclaredType '' -TerminalStatusesCsv $TerminalStatusesCsv -SpecRefJson $SpecRefJson)
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
    $ptype = Get-JiraFeatDeclaredTypeFor -Role 'specification' -ProjectKey $EffProject -Merged $Merged
    $stype = Get-JiraFeatDeclaredTypeFor -Role 'story' -ProjectKey $EffProject -Merged $Merged
    $pterm = Get-JiraFeatHaltedCsvFor -ProjectKey $EffProject -Merged $Merged
    $sterm = Get-JiraFeatHaltedCsvFor -ProjectKey $EffProject -Merged $Merged
    $evalResults = [System.Collections.Generic.List[object]]::new()
    if ($pkey) {
        $evalResults.Add((Test-JiraFeatDesignatorRoleEvaluate -Role 'specification' -Key $pkey -OwnType $ptype -OtherType $stype -RoutedProject $EffProject -TerminalStatusesCsv $pterm -SpecRefJson $specRef | ConvertFrom-Json -Depth 100))
    }
    foreach ($s in $storiesArr) {
        $skey = [string](Get-FeatProp $s 'key')
        $evalResults.Add((Test-JiraFeatDesignatorRoleEvaluate -Role 'story' -Key $skey -OwnType $stype -OtherType $ptype -RoutedProject $EffProject -TerminalStatusesCsv $sterm -SpecRefJson $specRef | ConvertFrom-Json -Depth 100))
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
        # 029/T119 (FR-037): the escape every refusal reachable here
        # carries, composed once by the aggregator and appended once —
        # never duplicated into each refusal class.
        $escSpec = if ($ptype) { $ptype } else { 'specification-role issue' }
        $escStory = if ($stype) { $stype } else { 'story-role issue' }
        [Console]::Error.WriteLine("feature: decline, and the extension creates a new $escSpec plus one $escStory per drafted user story")
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
        # Spelled, not joined. This value is printed to stdout as
        # `seed_material` a few lines below, so it owes the Bash twin byte
        # parity (NFR-1) and the twin is a plain interpolation —
        # "${JIRA_CONFIG_DIR:-.specify/jira}/state/${short_name}.seed-material.json"
        # (commands/feature.sh:622). Join-Path renormalises to the host's
        # separator in BOTH directions — it rewrote even the `/` inside the
        # literal argument here — which diverged five conformance scenarios on
        # Windows at exit 0, silently (#46 D2). Quirk 8,
        # docs/10-windows-portability.md; the rule is in AGENTS.md.
        #
        # WriteAllText below takes this same string: .NET resolves either
        # separator on Windows, so one value still serves both jobs, exactly as
        # it does in the Bash twin.
        $seedMaterialPath = "$configDir/state/$shortName.seed-material.json"
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

function Write-FeatVerboseDiag {
    # The on-request diagnostic (031, US3, contract C4.1): which resolution
    # state produced this pass-through, the absolute path it consulted, and
    # what would change it. Mirror of _feat_verbose_diag. Written to stderr,
    # and ONLY when $Verbose is $true — the default and --json payloads never
    # gain a line or a key for this (C4.2).
    param([bool] $Verbose, [string] $State, [string] $Path, [string] $Hint)
    if (-not $Verbose) { return }
    [Console]::Error.WriteLine("feature: resolution state: $State")
    [Console]::Error.WriteLine("feature: path consulted: $Path")
    [Console]::Error.WriteLine("feature: $Hint")
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
    elseif ((Get-FeatProp $p 'reuse_required') -or (Get-FeatProp $p 'reuse_issues_required')) {
        return (ConvertTo-JiraFeatureReuseProse -Json $Json)
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
    # The FR-016 non-blocking fallback: {active:false} plus exactly one
    # warning; one WARNING: line on stderr; exit 0. Mirror of _feat_fallback.
    # 029/T132 (FR-041): the shipped text claimed reconciliation "will
    # attach it later" — false, since a create that never happened has
    # nothing to attach; the following reconcile creates a fresh issue
    # instead. $Cause is composed by the caller from the exit code the
    # failed call already returned, never invented here.
    param([bool] $Json, [string] $Cause)
    $msg = "$Cause — proceeding without a ticket; the next reconcile creates a new issue for this specification"
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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'The empty-config.yml probe (031, FR-006/C2.5) deliberately ignores a parse failure here: a malformed file is expected to throw, and the exception is not the outcome being sought — $rawTeamParsed stays false, so the caller falls through to Import-JiraConfig, which reports the SAME failure with its own located reason a few lines below.')]
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
    $reuse = if ($state.ContainsKey('reuse')) { $state['reuse'] } else { '' }
    $verbose = $state['verbose'] -eq 'true'

    # 029, contract mention-grammar.md §1-§3: the mention evaluation is a pure
    # string operation on argv alone, needing no configuration — it moves to
    # the top of Invoke-JiraFeature (before the four early pass-through
    # exits, R4) so both the usage-error gate below and the
    # missing-configuration report (US6) can consult it without a second
    # detection pass.
    $words = @($argsLine -split ' ' | Where-Object { $_ -ne '' })
    $mentions = @(Get-JiraFeatDetectMention -Words $words)
    $hasMention = $mentions.Count -gt 0
    $ticketKey = ''
    $desc = ''
    if ($hasMention) {
        $ticketKey = [string] $mentions[0].key
        $desc = ($words | Select-Object -Skip 1) -join ' '
    }
    else {
        $desc = $words -join ' '
    }

    # 029, contract feature-question-contract.md §2 rows 2-3 (FR-015): decided
    # from argv alone, before any configuration read or Jira request — an
    # unconfigured repository or an unreadable key must never mask a
    # mis-scripted invocation. Row 1 (an invalid --reuse value) already
    # exited inside Invoke-JiraCliParse, above.
    $hasDesignator = $parentSeen -or (-not [string]::IsNullOrEmpty($storiesJoined))
    if (-not [string]::IsNullOrEmpty($reuse) -and -not $hasMention -and -not $hasDesignator) {
        [Console]::Error.WriteLine("feature: --reuse $reuse answers a question that was never posed — no ticket is mentioned and no designator is supplied")
        return (Get-JiraExitCode 'usage')
    }
    if ($reuse -eq 'no' -and $hasDesignator) {
        [Console]::Error.WriteLine('feature: --reuse no contradicts the designators supplied with it — designators name issues to reuse')
        return (Get-JiraExitCode 'usage')
    }

    # (0) Configuration directory (031, FR-007/FR-014, contract C1.1): an
    # explicit JIRA_CONFIG_DIR, then SPECIFY_INIT_DIR, then the nearest
    # ancestor of the working directory carrying .specify/ — REPLACING the
    # relative ".specify/jira" fallback, never supplementing it. When neither
    # override is set and no ancestor qualifies, this is reported
    # unconditionally (not gated on $hasMention — C1.4) rather than passed
    # through in silence.
    $startDir = (Get-Location).Path
    $dir = Resolve-JiraConfigDir
    if (-not $dir) {
        [Console]::Error.WriteLine("feature: no project found — no ancestor of $startDir contains .specify/; naming falls back to the host default")
        Write-FeatVerboseDiag -Verbose $verbose -State 'no-repository' -Path $startDir `
            -Hint 'create .specify/ above the working directory, or set JIRA_CONFIG_DIR, to change this'
        Write-FeatResult -Payload '{"active":false}' -Json $json
        return 0
    }
    # FR-016: the resolved directory governs run-state and seed-state as well
    # — a SINGLE assignment here, before anything downstream reads it, is
    # what keeps `state/` under the same directory as the two configuration
    # files.
    $env:JIRA_CONFIG_DIR = $dir

    # 029, contract feature-question-contract.md §5 (FR-026-FR-028, research
    # R5): a mentioned ticket met with silence is the same defect class one
    # layer earlier. Gated on $hasMention so a run naming nothing stays
    # byte-identical to the current release (FR-028); never issues a Jira
    # request (FR-027).
    $noConfigMsg = 'no team configuration found — .specify/jira/config.yml is missing, unreadable, or declares no teams; run /speckit.jira-mirror.config to create one'
    $noSelectionMsg = 'no team selected in .specify/jira/personal.yml — that selection is your own and no script writes it for you; run /speckit.jira-mirror.config to select one'

    # $dir/config.yml and $dir/personal.yml below: '/'-concatenation, never
    # Path.Combine or Join-Path (code review, PR #55 — measured on
    # windows-latest). $dir (Resolve-JiraConfigDir) is not uniformly
    # separator-spelled: the explicit-JIRA_CONFIG_DIR branch returns a plain
    # GetFullPath (native, backslash), but the ancestor-walk/SPECIFY_INIT_DIR
    # branches append a DELIBERATE forward-slash '.specify/jira' suffix (to
    # match the bash port's own spelling there, Config.psm1's own docstring).
    # Path.Combine's native separator is only right for the first branch; for
    # the second it plants a stray backslash exactly at the .../jira boundary
    # — the one thing conformance's workdir-masking cannot paper over, since
    # masking only replaces the ROOT, never this suffix.
    #
    # (1) No committed catalogue at all ⇒ pass-through (FR-017).
    if (-not (Test-Path -LiteralPath "$dir/config.yml")) {
        if ($hasMention) {
            Write-FeatResult -Payload (ConvertTo-JiraJsonValue ([ordered]@{ active = $false; warnings = @($noConfigMsg) })) -Json $json
        }
        else {
            Write-FeatResult -Payload '{"active":false}' -Json $json
        }
        Write-FeatVerboseDiag -Verbose $verbose -State 'no-config-file' -Path $dir `
            -Hint "create $dir/config.yml with a teams: catalogue to change this"
        return 0
    }
    # 031, research D2: the loader's stderr is no longer discarded here — a
    # present-but-unloadable config.yml is REPORTED (FR-001/FR-002, C2.1),
    # whether or not a ticket was mentioned; the JSON payload below is
    # unaffected either way (C4.2). Called ONCE: the common (successful)
    # path pays exactly this one parse, never two (code review).
    # Import-JiraConfig writes its located error to [Console]::Error as a
    # SIDE EFFECT of parsing — unconditionally, before this function ever
    # gets to decide whether the cause was "genuinely empty" (silent, below)
    # or "genuinely broken" (reported) — so it is captured here, not
    # streamed live, and only replayed on the branch that actually needs it.
    $errSink = [System.IO.StringWriter]::new()
    $origErr = [Console]::Error
    [Console]::SetError($errSink)
    try { $cfg = Import-JiraConfig -ConfigDir $dir }
    finally { [Console]::SetError($origErr) }
    if ($cfg.ExitCode -ne 0) {
        # An empty config.yml — 0 bytes, or comments-only, parsing to $null —
        # carries no statement from its author (FR-006, C2.5): treated
        # exactly like a valid catalogue declaring zero teams, never as a
        # load failure. Import-JiraConfig's OWN empty-document coercion
        # happens too late to help here — a coerced {} still fails
        # config.yml's schema (`projects must be a non-empty array`),
        # correct for a NON-empty file missing that key but wrong for no
        # content at all. A cheap raw re-parse, on this (rare) failure path
        # only, is what research D2 already accepted; it is never the
        # doubled FULL Import-JiraConfig D2 rejected.
        $rawTeam = $null
        $rawTeamParsed = $false
        try { $rawTeam = Read-JiraConfigYamlObject -Path "$dir/config.yml"; $rawTeamParsed = $true } catch { }
        if ($rawTeamParsed -and $null -eq $rawTeam) {
            $merged = (ConvertTo-JiraJsonValue ([ordered]@{})) | ConvertFrom-Json -Depth 100
        }
        else {
            if ($hasMention) {
                Write-FeatResult -Payload (ConvertTo-JiraJsonValue ([ordered]@{ active = $false; warnings = @($noConfigMsg) })) -Json $json
            }
            else {
                Write-FeatResult -Payload '{"active":false}' -Json $json
            }
            [Console]::Error.Write($errSink.ToString())
            # Import-JiraConfig validates config.yml AND config.local.yml —
            # the located error above already names whichever layer actually
            # failed, so the hint names the directory, never a filename that
            # may not be the one that broke (code review).
            Write-FeatVerboseDiag -Verbose $verbose -State 'config-unloadable' -Path $dir `
                -Hint "fix the configuration error reported above in $dir to change this"
            return 0
        }
    }
    else {
        $merged = $cfg.Json | ConvertFrom-Json -Depth 100
    }

    # (2) Personal selection (human-owned; validated; never written), checked
    # NOW — before team_count, not after. A personal.yml that structurally
    # fails to load is reported and passed through (FR-013, C3.3), but a
    # WELL-FORMED file selecting a team absent from the catalogue still
    # fails closed (FR-017: "that behaviour is unchanged") EVEN WHEN the
    # catalogue is empty — exactly the scenario this ordering exists to
    # reach. Checking this after team_count would let the zero-teams
    # silence below swallow that located error (code review).
    $mergedJsonForPersonal = if ($cfg.ExitCode -eq 0) { $cfg.Json } else { ConvertTo-JiraJsonValue ([ordered]@{}) }
    $personal = Import-JiraPersonalConfig -ConfigDir $dir -MergedJson $mergedJsonForPersonal -SoftLoad $true
    if ($personal.ExitCode -ne 0) { return [int] $personal.ExitCode }
    $pObj = $personal.Json | ConvertFrom-Json -Depth 100
    $pActive = [bool](Get-FeatProp $pObj 'active')
    $pTeam = [string](Get-FeatProp $pObj 'team')
    $pOverride = Get-FeatProp $pObj 'override'
    $pState = [string](Get-FeatProp $pObj 'state')

    # The resolution chokepoint (030, plan.md §Key design decision): seed
    # SPEC_KIT_JIRA_BASE_URL / JIRA_EMAIL from config.yml and the `$personal`
    # result JUST computed above — no second Import-JiraConfig, no second
    # Import-JiraPersonalConfig, and no second base_url/personal validation
    # to silently contradict the pass-through treatment a malformed file
    # already received a few lines up.
    $chokepointRc = Resolve-JiraConnection -ConfigDir $dir -MergedJson $mergedJsonForPersonal -PersonalJson $personal.Json
    if ($chokepointRc -ne 0) { return [int] $chokepointRc }

    $teams = @((Get-FeatProp $merged 'teams') | Where-Object { $null -ne $_ })
    if ($teams.Count -eq 0) {
        if ($hasMention) {
            Write-FeatResult -Payload (ConvertTo-JiraJsonValue ([ordered]@{ active = $false; warnings = @($noConfigMsg) })) -Json $json
        }
        else {
            Write-FeatResult -Payload '{"active":false}' -Json $json
        }
        Write-FeatVerboseDiag -Verbose $verbose -State 'no-teams' -Path $dir `
            -Hint "add an entry to teams: in $dir/config.yml to change this"
        return 0
    }

    if ($pState -eq 'personal-unloadable') {
        if ($hasMention) {
            Write-FeatResult -Payload (ConvertTo-JiraJsonValue ([ordered]@{ active = $false; warnings = @($noSelectionMsg) })) -Json $json
        }
        else {
            Write-FeatResult -Payload '{"active":false}' -Json $json
        }
        Write-FeatVerboseDiag -Verbose $verbose -State 'personal-unloadable' -Path $dir `
            -Hint "fix the error reported above in $dir/personal.yml to change this"
        return 0
    }

    # No selection and no cross-team answer ⇒ pass-through (FR-017).
    if (-not $pActive -and [string]::IsNullOrEmpty($useTeam)) {
        if ($hasMention) {
            Write-FeatResult -Payload (ConvertTo-JiraJsonValue ([ordered]@{ active = $false; warnings = @($noSelectionMsg) })) -Json $json
        }
        else {
            Write-FeatResult -Payload '{"active":false}' -Json $json
        }
        Write-FeatVerboseDiag -Verbose $verbose -State $pState -Path $dir `
            -Hint "select a team in $dir/personal.yml to change this"
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

    # (4) Description is required once a team is in play (FR-013 precedes
    # naming). $words/$mentions/$ticketKey/$desc are already computed above.
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

    # 029: declared here (not only inside the mentioned-key branch) so the
    # no-mention guarded-create path — which never sets it — reads an empty
    # string under Set-StrictMode rather than throwing.
    $suppressedWarning = ''

    # (5) Ticket resolution BEFORE naming.
    if (-not [string]::IsNullOrEmpty($ticketKey)) {
        # 029: known from argv and the loaded configuration alone, before the
        # read (contract §7) — mention present (guaranteed here), no
        # designator (guaranteed: the designator branch above already
        # returned), no answer, not unattended.
        $reuseState = if ($state.ContainsKey('reuse')) { $state['reuse'] } else { '' }
        $acceptDefaultsState = $state['accept_defaults'] -eq 'true'
        $aboutToAsk = [string]::IsNullOrEmpty($reuseState) -and (-not $acceptDefaultsState)
        # 029/FR-029: "reuse" also needs the wide field set to derive each
        # detected issue's role — it is a second invocation, not the
        # question path FR-017 bounds.
        $wantsWide = $aboutToAsk -or ($reuseState -eq 'yes')

        # Mentioned key: validate (read). A fail-closed read never falls back.
        $validated = Confirm-JiraTicket -Key $ticketKey -Wide $wantsWide
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

        # (029, FR-025/R6) — the reuse question, immediately after the
        # cross-team question and before naming. Zero writes either way, so
        # --dry-run predicts it by definition (FR-020): the question never
        # performs anything to begin with.
        if ($aboutToAsk) {
            $qResult = Invoke-JiraFeatComposeReuseQuestion -Mentions $mentions -PrimaryWideJson $validated.Json -EffProject $effProject -Merged $merged
            if ([int]$qResult.ExitCode -ne 0) { return [int] $qResult.ExitCode }
            Write-FeatResult -Payload $qResult.Json -Json $json
            return 0
        }

        # (029, FR-013/FR-014) — an unattended run is never asked; it
        # proceeds exactly as "create new" would, and states that the
        # question was suppressed and which answer was assumed.
        $suppressedWarning = ''
        if ([string]::IsNullOrEmpty($reuseState) -and $acceptDefaultsState) {
            $suppressedWarning = 'the reuse question was suppressed by --accept-defaults; assumed answer: do not reuse — the mentioned ticket names this feature but is not bound to it, and the next reconcile creates a new parent beside it'
        }

        # (029, FR-029/FR-030/FR-038) — "reuse" with no designator is the
        # operator accepting the question's own proposal: every detected
        # issue, in the role already derived. Auto-routes into 027's
        # designator path with synthesized --parent/--story equivalents, so
        # the result is byte-identical to typing them (US3 AC1). Falls back
        # to the which-issues follow-up in exactly one case — no role could
        # be derived at all, because the routed project declares no
        # hierarchy (FR-035): a proposal holding story-role issues and no
        # specification-role one is NOT that case (FR-038) and still
        # routes, with no parent.
        if ($reuseState -eq 'yes') {
            $qResult2 = Invoke-JiraFeatComposeReuseQuestion -Mentions $mentions -PrimaryWideJson $validated.Json -EffProject $effProject -Merged $merged
            if ([int]$qResult2.ExitCode -ne 0) { return [int] $qResult2.ExitCode }
            $qObj = $qResult2.Json | ConvertFrom-Json -Depth 100

            $noHierarchy = ($null -eq $qObj.reuse_required.declines_to.specification) -and ($null -eq $qObj.reuse_required.declines_to.story)

            if ($noHierarchy) {
                # Contract §3.1: "reuse_issues_required carries the identical
                # object" — so it is composed FROM the question rather than
                # rebuilt. Rebuilding it from $ticketKey alone dropped every
                # issue past the leading one (FR-034) and stripped the survivor
                # of summary/type/status, which the prose then rendered as
                # `Detected: IJT-40 (, )`. Mirror of the Bash port's jq merge.
                $rr = $qObj.reuse_required
                $payload = ConvertTo-JiraJsonValue ([ordered]@{
                        active = $true
                        reuse_issues_required = [ordered]@{
                            issues      = @($rr.issues)
                            declines_to = $rr.declines_to
                            reason      = 'designators required'
                        }
                    })
                Write-FeatResult -Payload $payload -Json $json
                return 0
            }

            # First specification-role issue wins the parent slot; every
            # other detected issue (including any further
            # specification-role match) becomes a story-role designator —
            # never silently dropped.
            $autoParent = ''
            $autoStoriesList = [System.Collections.Generic.List[string]]::new()
            foreach ($qi in @($qObj.reuse_required.issues)) {
                if ($qi.role -eq 'specification' -and [string]::IsNullOrEmpty($autoParent)) {
                    $autoParent = [string]$qi.key
                }
                else {
                    $autoStoriesList.Add([string]$qi.key)
                }
            }
            $us = [char]0x1F
            $autoStories = ($autoStoriesList -join $us)
            $autoParentSeen = -not [string]::IsNullOrEmpty($autoParent)

            return (Invoke-JiraFeatSeedFromDesignator -Json $json -DryRun $dryRun -Description $desc -EffId $effId `
                    -EffProject $effProject -Prefix $prefix -Pattern $pattern -OverrideUsed $overrideUsed -Merged $merged `
                    -ParentSeen $autoParentSeen -ParentRaw $autoParent -StoriesJoined $autoStories)
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
            Write-FeatFallback -Json $json -Cause 'Jira is not configured for creating a ticket yet'
            return 0
        }

        $created = New-JiraTicket -ProjectKey $effProject -Summary $desc -StoryTypeId $typeId -SpecRefJson $specRef
        if ($created.ExitCode -eq 9) { return 9 }
        if ($created.ExitCode -ne 0) {
            $cause = ''
            if ($created.ExitCode -eq (Get-JiraExitCode 'auth')) {
                $cause = 'Jira rejected the credentials'
            }
            elseif ($created.Status -eq 0 -or $null -eq $created.Status) {
                $cause = 'Jira is unreachable'
            }
            elseif ($created.Status -eq 404) {
                $cause = 'the target project could not be found or is not visible'
            }
            else {
                $cause = "Jira returned an error (status $($created.Status))"
            }
            Write-FeatFallback -Json $json -Cause $cause
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

    # 029, FR-014: an unattended run's suppressed question is stated here,
    # not silently applied — the only warning this path can carry beyond the
    # existing empty array. The leading comma is load-bearing: an `if/else`
    # whose taken branch is `@()` otherwise unwraps to $null on assignment,
    # which ConvertTo-JiraJsonValue would then render as `null`, not `[]`.
    $warningsOut = if ($suppressedWarning) { , @($suppressedWarning) } else { , @() }

    $payload = ConvertTo-JiraJsonValue ([ordered]@{
        active = $true; team = $effId
        ticket = [ordered]@{ key = $ticketKeyOut; number = $number; action = $action }
        branch_name = $branchName; short_name = $shortName; override_used = $overrideUsed; warnings = $warningsOut
    })
    Write-FeatResult -Payload $payload -Json $json
    return 0
}

Export-ModuleMember -Function Invoke-JiraFeature, Get-JiraFeatDesignatorNumberSource, Get-JiraFeatResolvedSlug, `
    Invoke-JiraFeatSeedFromDesignator, Get-JiraFeatReduceMention, Get-JiraFeatDetectMention, `
    Invoke-JiraFeatComposeReuseQuestion, ConvertTo-JiraFeatureReuseProse
