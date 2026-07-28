# engine/Adoption.psm1 — Pure label-based adoption engine. Mirror of
# engine/adoption.sh (003 US1/US2/US4/US6).
#
# NEUTRAL layer (Constitution VIII): prefix validation, label derivation, scope
# and pin resolution, and the eight-class ambiguity classification. Candidates
# arrive as opaque JSON; this module never learns what a tracker key looks like.
#
# Every message and every emitted document is byte-identical to the Bash port for
# identical inputs (NFR 1) — the strings below are the contract, not prose.
#
# ⚠️ BOUNDARY CONSTRAINT (research §8). The CI boundary gate greps every file
# under engine/ for the tracker's key shape, its vendor name, and its metadata
# endpoints, and it FAILS ON A MATCH INSIDE A COMMENT TOO. So this file carries
# no example key, not even illustratively, and requirement references are written
# with a space ("FR 009") rather than a hyphen.

Set-StrictMode -Version Latest

$ModuleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $ModuleRoot 'lib/Output.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Interchange.psm1') -Force

# The label length limit a prefix plus the longest implied suffix must respect.
$script:AdoptionLabelMax = 255
# The origin recorded on a ticket the bridge created itself. The wire value is
# hyphenated; the spec's prose spelling names the concept, not the literal
# (research §4).
$script:AdoptionOriginBridge = 'bridge-created'

$script:ExitUsage = 1
$script:ExitConfig = 4

function Get-AdoptProp {
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

function Get-AdoptOrdinalSorted {
    # Codepoint (ordinal) ordering — the Bash twin's jq `sort` semantics. A
    # culture-aware sort would reorder mixed-case folders and break byte parity.
    #
    # The result is emitted UNWRAPPED and every caller re-collects it with
    # `[string[]]@(...)`. The `, $a` idiom is wrong here: for an EMPTY array it
    # emits one object (the empty array itself), which `@()` then collects as a
    # single element and the cast turns into an array holding one empty string —
    # an empty `issue_keys` would serialise as [""] instead of [].
    param([string[]] $Values)
    $a = [string[]]@($Values)
    [System.Array]::Sort($a, [System.StringComparer]::Ordinal)
    return $a
}

# =============================================================================
# Label grammar (research §3, data-model §3)
# =============================================================================

function Get-JiraAdoptionNumberComponent {
    <#
    .SYNOPSIS
      The folder's leading numbering component (the digits before its first
      hyphen), or the empty string. Mirror of adoption_number_component.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Folder)
    if ($Folder -cmatch '^([0-9]+)-') { return $Matches[1] }
    return ''
}

function Get-JiraAdoptionDisplayName {
    <#
    .SYNOPSIS
      How a target is named in every plan line, message and remediation. Mirror
      of adoption_display_name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Folder,
        [Parameter(Mandatory)] [string] $Level,
        [AllowEmptyString()] [string] $Ordinal = ''
    )
    if ($Level -ceq 'story') { return "${Folder}:us${Ordinal}" }
    return $Folder
}

function Get-JiraAdoptionLabel {
    <#
    .SYNOPSIS
      The exact label values a target implies — the ONLY values ever searched for
      (NFR 6). Mirror of adoption_labels_for.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Prefix,
        [Parameter(Mandatory)] [string] $Folder,
        [Parameter(Mandatory)] [string] $Level,
        [AllowEmptyString()] [string] $Ordinal = '',
        [AllowEmptyString()] [string] $ShortNumber = ''
    )
    $out = [System.Collections.Generic.List[string]]::new()
    if ($Level -ceq 'story') {
        $out.Add("$Prefix$Folder`:us$Ordinal")
    }
    else {
        $out.Add("$Prefix$Folder")
        if (-not [string]::IsNullOrEmpty($ShortNumber)) { $out.Add("$Prefix$ShortNumber") }
    }
    return (ConvertTo-JiraJsonValue $out.ToArray())
}

function Get-JiraAdoptionLongestSuffix {
    <#
    .SYNOPSIS
      The longest suffix any folder in scope appends to the prefix, so the prefix
      check is made against the real worst case. Mirror of
      adoption_longest_suffix.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SpecsJson)
    $longest = 0
    foreach ($s in @($SpecsJson | ConvertFrom-Json -Depth 100)) {
        $folder = [string](Get-AdoptProp $s 'folder')
        if ($folder.Length -gt $longest) { $longest = $folder.Length }
        foreach ($o in @(Get-AdoptProp $s 'story_ordinals')) {
            if ($null -eq $o) { continue }
            $len = $folder.Length + 3 + ([string]$o).Length
            if ($len -gt $longest) { $longest = $len }
        }
    }
    return $longest
}

function Test-JiraAdoptionPrefix {
    <#
    .SYNOPSIS
      The FR 002 rules: non-empty, no whitespace of any kind, and within the
      length limit once the longest implied suffix is appended. Mirror of
      adoption_validate_prefix; returns { ExitCode; Message }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Prefix,
        [int] $LongestSuffix = 0
    )
    if ([string]::IsNullOrEmpty($Prefix)) {
        return [pscustomobject]@{ ExitCode = $script:ExitConfig; Message = 'adoption.label_prefix must not be empty' }
    }
    if ($Prefix -cmatch '\s') {
        return [pscustomobject]@{ ExitCode = $script:ExitConfig; Message = 'adoption.label_prefix must not contain whitespace' }
    }
    $total = $Prefix.Length + $LongestSuffix
    if ($total -gt $script:AdoptionLabelMax) {
        return [pscustomobject]@{
            ExitCode = $script:ExitConfig
            Message  = "adoption.label_prefix is too long: the prefix plus the longest suffix it implies is $total characters, over the $($script:AdoptionLabelMax)-character limit"
        }
    }
    return [pscustomobject]@{ ExitCode = 0; Message = '' }
}

# =============================================================================
# Scope (data-model §6, FR 026)
# =============================================================================

function Get-JiraAdoptionScope {
    <#
    .SYNOPSIS
      The subset of spec folders the run considers. A scope naming a folder
      absent from disk stops the run as a usage error with zero writes. Mirror of
      adoption_scope; returns { ExitCode; Message; Json }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $AllFoldersJson,
        [string] $ScopeJson = '[]'
    )
    $all = [string[]]@($AllFoldersJson | ConvertFrom-Json -Depth 100 | ForEach-Object { [string]$_ })
    $scope = [string[]]@($ScopeJson | ConvertFrom-Json -Depth 100 | ForEach-Object { [string]$_ })

    $unknown = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $scope) { if ($all -cnotcontains $s) { $unknown.Add($s) } }
    if ($unknown.Count -gt 0) {
        return [pscustomobject]@{ ExitCode = $script:ExitUsage; Message = "no such spec folder: $($unknown -join ', ')"; Json = '' }
    }

    $sorted = [string[]]@(Get-AdoptOrdinalSorted $all)
    $inScope = [System.Collections.Generic.List[string]]::new()
    $outScope = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $sorted) {
        if ($scope.Count -eq 0 -or $scope -ccontains $f) { $inScope.Add($f) } else { $outScope.Add($f) }
    }
    $obj = [ordered]@{ in_scope = $inScope.ToArray(); out_of_scope = $outScope.ToArray() }
    return [pscustomobject]@{ ExitCode = 0; Message = ''; Json = (ConvertTo-JiraJsonValue $obj) }
}

# =============================================================================
# Target derivation (data-model §2)
# =============================================================================

function Get-JiraAdoptionTarget {
    <#
    .SYNOPSIS
      One `feature` target per spec folder in scope plus one `story` target per
      user story, ordered folder ascending, feature before story, ordinal
      ascending. A numbering component shared by two folders in scope suppresses
      the short label form for BOTH; the suppressed value is still emitted as a
      probe label so a ticket carrying it stays DISCOVERABLE and can be refused by
      name. Mirror of adoption_targets; returns { ExitCode; Json }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SpecsJson,
        [Parameter(Mandatory)] [string] $Prefix,
        [string] $ConfigJson = '{}'
    )
    $specs = @($SpecsJson | ConvertFrom-Json -Depth 100)

    $ordinalsOf = @{}
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $specs) {
        $f = [string](Get-AdoptProp $s 'folder')
        $names.Add($f)
        $ords = [System.Collections.Generic.List[int]]::new()
        foreach ($o in @(Get-AdoptProp $s 'story_ordinals')) {
            if ($null -eq $o) { continue }
            $ords.Add([int]$o)
        }
        $arr = $ords.ToArray()
        [System.Array]::Sort($arr)
        $ordinalsOf[$f] = $arr
    }
    $folders = [string[]]@(Get-AdoptOrdinalSorted $names.ToArray())

    # Numbering components and the folders that share them, accumulated in the
    # same sorted order the Bash twin's reduce walks.
    $byNum = @{}
    foreach ($f in $folders) {
        $n = Get-JiraAdoptionNumberComponent -Folder $f
        if ($n -eq '') { continue }
        if (-not $byNum.ContainsKey($n)) { $byNum[$n] = [System.Collections.Generic.List[string]]::new() }
        $byNum[$n].Add($f)
    }

    $targets = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $folders) {
        $r = Resolve-JiraRouting -FolderName $f -LabelsJson '[]' -RoutingConfigJson $ConfigJson
        if ([int]$r.ExitCode -ne 0) { return [pscustomobject]@{ ExitCode = [int]$r.ExitCode; Json = '' } }
        $project = [string]$r.ProjectKey

        $num = Get-JiraAdoptionNumberComponent -Folder $f
        # `[string[]]@(...)` guards the same single-element unrolling trap.
        $sharers = [string[]]@(if ($num -ne '' -and $byNum.ContainsKey($num)) { $byNum[$num].ToArray() } else { @() })
        $short = "$Prefix$num"
        $unique = ($num -ne '' -and $sharers.Count -eq 1)
        $shared = ($num -ne '' -and $sharers.Count -gt 1)

        $labels = [System.Collections.Generic.List[string]]::new()
        $labels.Add("$Prefix$f")
        if ($unique) { $labels.Add($short) }
        $probe = [System.Collections.Generic.List[string]]::new()
        if ($shared) { $probe.Add($short) }

        $targets.Add([ordered]@{
                spec_folder    = $f
                level          = 'feature'
                story_ordinal  = $null
                project_key    = $project
                labels         = $labels.ToArray()
                probe_labels   = $probe.ToArray()
                short_conflict = $(if ($shared) { [ordered]@{ label = $short; folders = $sharers } } else { $null })
            })

        foreach ($o in $ordinalsOf[$f]) {
            $targets.Add([ordered]@{
                    spec_folder    = $f
                    level          = 'story'
                    story_ordinal  = [int]$o
                    project_key    = $project
                    labels         = @("$Prefix$f`:us$o")
                    probe_labels   = @()
                    short_conflict = $null
                })
        }
    }
    return [pscustomobject]@{ ExitCode = 0; Json = (ConvertTo-JiraJsonValue $targets.ToArray()) }
}

# =============================================================================
# Explicit bindings (data-model §5, FR 020…FR 022)
# =============================================================================

function Resolve-JiraAdoptionPin {
    <#
    .SYNOPSIS
      Parse the operator's repeatable overrides — "<folder>[:us<N>]=<KEY>" — into
      structured pins. An unknown folder stops the whole run as a usage error
      with zero writes (FR 021). The key's SHAPE is deliberately NOT checked here
      (research §9). Mirror of adoption_pins_resolve; returns
      { ExitCode; Message; Json }.
    #>
    [CmdletBinding()]
    param(
        [string] $PinsJson = '[]',
        [string] $AllFoldersJson = '[]'
    )
    $all = [string[]]@($AllFoldersJson | ConvertFrom-Json -Depth 100 | ForEach-Object { [string]$_ })
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($raw in @($PinsJson | ConvertFrom-Json -Depth 100)) {
        $rawStr = [string]$raw
        $eq = $rawStr.IndexOf('=')
        $target = if ($eq -ge 0) { $rawStr.Substring(0, $eq) } else { '' }
        $key = if ($eq -ge 0) { $rawStr.Substring($eq + 1) } else { '' }
        if ($eq -lt 0 -or [string]::IsNullOrEmpty($target) -or [string]::IsNullOrEmpty($key)) {
            return [pscustomobject]@{ ExitCode = $script:ExitUsage; Message = "malformed --bind value: $rawStr (expected <folder>[:us<N>]=<KEY>)"; Json = '' }
        }
        $folder = $target
        $level = 'feature'
        $ordinal = $null
        if ($target -cmatch '^(.+):us([0-9]+)$') {
            $folder = $Matches[1]
            $level = 'story'
            $ordinal = [int]$Matches[2]
        }
        if ($all -cnotcontains $folder) {
            return [pscustomobject]@{ ExitCode = $script:ExitUsage; Message = "no such spec folder: $folder"; Json = '' }
        }
        $out.Add([ordered]@{ spec_folder = $folder; level = $level; story_ordinal = $ordinal; issue_key = $key })
    }
    return [pscustomobject]@{ ExitCode = 0; Message = ''; Json = (ConvertTo-JiraJsonValue $out.ToArray()) }
}

# =============================================================================
# Classification (data-model §7, §8)
# =============================================================================

function New-AdoptBinding {
    param([string] $Folder, [string] $Level, $Ordinal, [string] $Key, [string] $Reason, [string] $Overrode, [string] $Status)
    return [ordered]@{
        spec_folder   = $Folder
        level         = $Level
        story_ordinal = $Ordinal
        issue_key     = $Key
        reason        = $Reason
        overrode_key  = $(if ([string]::IsNullOrEmpty($Overrode)) { $null } else { $Overrode })
        status        = $Status
    }
}

function New-AdoptRefusal {
    param([string] $Folder, [string] $Level, $Ordinal, [string] $Reason, [string[]] $Keys, [string] $Message, [string] $Remediation)
    return [ordered]@{
        spec_folder   = $Folder
        level         = $Level
        story_ordinal = $Ordinal
        reason        = $Reason
        issue_keys    = [string[]]@(Get-AdoptOrdinalSorted $Keys)
        message       = $Message
        remediation   = $Remediation
    }
}

function Get-AdoptBindHint {
    param([string] $Display)
    return "spec-kit-jira adopt --bind $Display=<ISSUE-KEY>"
}

function Get-JiraAdoptionPlan {
    <#
    .SYNOPSIS
      Turn every target into a binding or one of the eight named refusal classes.
      Candidates are consumed as OPAQUE JSON. Nothing here depends on the order
      the tracker returned results, on titles, on recency, or on issue type —
      FR 012 forbids any such path from existing at all, not merely from being
      reached. Mirror of adoption_classify; returns the canonical
      {bindings, refusals}.
    #>
    [CmdletBinding()]
    param(
        [string] $TargetsJson = '[]',
        [string] $CandidatesJson = '[]',
        [string] $PinsJson = '[]',
        [AllowEmptyString()] [string] $Repo = ''
    )
    $targets = @($TargetsJson | ConvertFrom-Json -Depth 100)
    $candidates = @($CandidatesJson | ConvertFrom-Json -Depth 100)
    $pins = @($PinsJson | ConvertFrom-Json -Depth 100)

    $bindings = [System.Collections.Generic.List[object]]::new()
    $refusals = [System.Collections.Generic.List[object]]::new()
    $featureKeys = @{}

    foreach ($t in $targets) {
        $folder = [string](Get-AdoptProp $t 'spec_folder')
        $level = [string](Get-AdoptProp $t 'level')
        $ordinalRaw = Get-AdoptProp $t 'story_ordinal'
        $ordinal = $(if ($null -eq $ordinalRaw) { $null } else { [int]$ordinalRaw })
        $ordinalText = $(if ($null -eq $ordinalRaw) { '' } else { [string][int]$ordinalRaw })
        $project = [string](Get-AdoptProp $t 'project_key')
        $labels = [string[]]@(Get-AdoptProp $t 'labels' | ForEach-Object { [string]$_ })
        $display = Get-JiraAdoptionDisplayName -Folder $folder -Level $level -Ordinal $ordinalText

        # --- Which ticket does this target resolve to? ----------------------
        $pinKey = ''
        foreach ($p in $pins) {
            $po = Get-AdoptProp $p 'story_ordinal'
            $poText = $(if ($null -eq $po) { '' } else { [string][int]$po })
            if ([string](Get-AdoptProp $p 'spec_folder') -ceq $folder -and
                [string](Get-AdoptProp $p 'level') -ceq $level -and $poText -ceq $ordinalText) {
                $pinKey = [string](Get-AdoptProp $p 'issue_key'); break
            }
        }

        $matched = [System.Collections.Generic.List[object]]::new()
        foreach ($c in $candidates) {
            if ([string](Get-AdoptProp $c 'project_key') -cne $project) { continue }
            $hit = $false
            foreach ($l in @(Get-AdoptProp $c 'labels')) { if ($labels -ccontains [string]$l) { $hit = $true; break } }
            if ($hit) { $matched.Add($c) }
        }
        $matchedKeys = [string[]]@(Get-AdoptOrdinalSorted ([string[]]@($matched | ForEach-Object { [string](Get-AdoptProp $_ 'key') })))
        $matchedSorted = [System.Collections.Generic.List[object]]::new()
        foreach ($k in $matchedKeys) {
            foreach ($m in $matched) { if ([string](Get-AdoptProp $m 'key') -ceq $k) { $matchedSorted.Add($m); break } }
        }

        $reason = 'label-match'
        $overrode = ''
        $chosen = ''
        $cand = $null

        if (-not [string]::IsNullOrEmpty($pinKey)) {
            $reason = 'explicit-binding'
            $chosen = $pinKey
            if ($matchedSorted.Count -eq 1) {
                $disc = [string](Get-AdoptProp $matchedSorted[0] 'key')
                if ($disc -cne $pinKey) { $overrode = $disc }
            }
            foreach ($c in $candidates) { if ([string](Get-AdoptProp $c 'key') -ceq $pinKey) { $cand = $c; break } }
        }
        else {
            # A suppressed short number is an ambiguity the moment a ticket
            # carries it: the label names a number two folders in scope share,
            # so it names no spec.
            $conflict = Get-AdoptProp $t 'short_conflict'
            if ($null -ne $conflict) {
                $clabel = [string](Get-AdoptProp $conflict 'label')
                $hits = [System.Collections.Generic.List[string]]::new()
                foreach ($c in $candidates) {
                    foreach ($l in @(Get-AdoptProp $c 'labels')) {
                        if ([string]$l -ceq $clabel) { $hits.Add([string](Get-AdoptProp $c 'key')); break }
                    }
                }
                if ($hits.Count -gt 0) {
                    $sharers = @(Get-AdoptProp $conflict 'folders') -join ', '
                    $refusals.Add((New-AdoptRefusal $folder $level $ordinal 'ambiguous-short-number' $hits.ToArray() `
                                "the short adoption label `"$clabel`" names a numbering component shared by the spec folders $sharers, so it names no single spec" `
                                "use the full-folder label form, or $(Get-AdoptBindHint $display)"))
                    continue
                }
            }

            if ($matchedSorted.Count -eq 0) {
                $searched = $labels -join ', '
                $rem = "apply the label in the tracker, or $(Get-AdoptBindHint $display)"
                # FR 014: an unlabelled child under a labelled parent is a
                # blessed outcome, not a dead end — the ordinary reconcile
                # creates it. Only a story target has a parent to be created
                # under, so the feature-level remediation is left as it was.
                if ($level -ceq 'story') {
                    $rem = "$rem, or leave it unlabelled and let the ordinary reconcile create it as a bridge-created ticket under the adopted parent"
                }
                $refusals.Add((New-AdoptRefusal $folder $level $ordinal 'no-candidate' @() `
                            "no accessible ticket carries an adoption label for `"$display`" (searched: $searched)" `
                            $rem))
                continue
            }
            if ($matchedSorted.Count -gt 1) {
                $refusals.Add((New-AdoptRefusal $folder $level $ordinal 'several-candidates' $matchedKeys `
                            "`"$display`" is carried by more than one ticket ($($matchedKeys -join ', ')); adoption never guesses which one a spec means" `
                            "spec-kit-jira adopt --bind $display=$($matchedKeys[0])"))
                continue
            }
            $cand = $matchedSorted[0]
            $chosen = [string](Get-AdoptProp $cand 'key')
        }

        # --- The routed project owns the binding (FR 005) -------------------
        $candProject = $(if ($null -eq $cand) { '' } else { [string](Get-AdoptProp $cand 'project_key') })
        if (-not [string]::IsNullOrEmpty($candProject) -and $candProject -cne $project) {
            $refusals.Add((New-AdoptRefusal $folder $level $ordinal 'wrong-project' @($chosen) `
                        "`"$display`" routes to project $project, but $chosen belongs to project $candProject; adoption never migrates a ticket" `
                        "$(Get-AdoptBindHint $display) naming a ticket in $project"))
            continue
        }

        # --- Claim checks (FR 011, FR 027) ----------------------------------
        $identity = $(if ($null -eq $cand) { $null } else { Get-AdoptProp $cand 'identity' })
        if ($null -ne $identity) {
            $idRepo = [string](Get-AdoptProp $identity 'repo')
            $idSlug = [string](Get-AdoptProp $identity 'spec_slug')
            $idOrigin = [string](Get-AdoptProp $identity 'origin')
            if ($idRepo -ceq $Repo -and $idSlug -ceq $folder) {
                if ($idOrigin -ceq $script:AdoptionOriginBridge) {
                    $refusals.Add((New-AdoptRefusal $folder $level $ordinal 'spec-owns-bridge-ticket' @($chosen) `
                                "`"$display`" resolves to $chosen, which this spec already owns as a ticket the bridge created itself" `
                                "resolve the collision in the tracker, then re-run: spec-kit-jira adopt --spec $folder"))
                    continue
                }
                # Already adopted by THIS spec: skipped, counted as skipped,
                # never re-stamped (FR 027).
                $bindings.Add((New-AdoptBinding $folder $level $ordinal $chosen $reason $overrode 'already-adopted'))
                if ($level -ceq 'feature') { $featureKeys[$folder] = $chosen }
                continue
            }
            $otherRepo = $(if ([string]::IsNullOrEmpty($idRepo)) { '?' } else { $idRepo })
            $otherSlug = $(if ([string]::IsNullOrEmpty($idSlug)) { '?' } else { $idSlug })
            $refusals.Add((New-AdoptRefusal $folder $level $ordinal 'already-claimed' @($chosen) `
                        "`"$display`" resolves to $chosen, which is already claimed by another spec ($otherRepo/$otherSlug)" `
                        "resolve the claim in the tracker, or $(Get-AdoptBindHint $display)"))
            continue
        }

        # --- Hierarchy (FR 014, FR 015) -------------------------------------
        if ($level -ceq 'story') {
            if (-not $featureKeys.ContainsKey($folder)) {
                $refusals.Add((New-AdoptRefusal $folder $level $ordinal 'unbound-parent' @($chosen) `
                            "`"$display`" resolves to $chosen, but the feature-level ticket of spec `"$folder`" is not bound in this run" `
                            "bind the spec's feature-level ticket in the same run: $(Get-AdoptBindHint $folder)"))
                continue
            }
            $expected = [string]$featureKeys[$folder]
            $parentRaw = $(if ($null -eq $cand) { $null } else { Get-AdoptProp $cand 'parent_key' })
            $parent = $(if ($null -eq $parentRaw) { '' } else { [string]$parentRaw })
            if ($parent -cne $expected) {
                $shown = $(if ([string]::IsNullOrEmpty($parent)) { '(none)' } else { $parent })
                $keys = [System.Collections.Generic.List[string]]::new()
                foreach ($k in @($chosen, $parent, $expected)) { if (-not [string]::IsNullOrEmpty($k) -and -not $keys.Contains($k)) { $keys.Add($k) } }
                $refusals.Add((New-AdoptRefusal $folder $level $ordinal 'wrong-parent' $keys.ToArray() `
                            "`"$display`" resolves to $chosen, whose parent is $shown, but the spec is bound to $expected" `
                            "re-parent $chosen under $expected in the tracker, then re-run: spec-kit-jira adopt --spec $folder"))
                continue
            }
        }

        # --- Bind ------------------------------------------------------------
        $bindings.Add((New-AdoptBinding $folder $level $ordinal $chosen $reason $overrode 'adopt'))
        if ($level -ceq 'feature') { $featureKeys[$folder] = $chosen }
    }

    return (ConvertTo-JiraJsonValue ([ordered]@{ bindings = $bindings.ToArray(); refusals = $refusals.ToArray() }))
}

Export-ModuleMember -Function Get-JiraAdoptionNumberComponent, Get-JiraAdoptionDisplayName, `
    Get-JiraAdoptionLabel, Get-JiraAdoptionLongestSuffix, Test-JiraAdoptionPrefix, `
    Get-JiraAdoptionScope, Get-JiraAdoptionTarget, Resolve-JiraAdoptionPin, Get-JiraAdoptionPlan
