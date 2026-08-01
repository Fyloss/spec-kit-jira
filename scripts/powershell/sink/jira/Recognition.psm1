# sink/jira/Recognition.psm1 — Recognise the tickets reconcile already
# created. Mirror of sink/jira/recognition.sh (Phase 3, US1;
# contracts/recognition-contract.md).
#
# Reads each story's recorded ticket BY KEY (research R2 — never search: Jira's
# index is eventually consistent, and this is the reported defect's exact
# window), folds the identity marker returned by the SAME request into a
# verification decision, and returns {bound, new, blocked} for the command
# layer to split into the plan and lifecycle contexts. A read failure is NEVER
# downgraded to "no ticket exists" (FR-004) — an inconclusive read fails the
# WHOLE specification closed; a marker mismatch/duplicate/malformed marker
# blocks only the story it names (FR-011, FR-016, FR-021).

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../../lib/Cli.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../../lib/Output.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Client.psm1') -Force

function Get-JiraRecognitionIdentityKey {
    if ($env:SPEC_KIT_JIRA_IDENTITY_KEY) { return $env:SPEC_KIT_JIRA_IDENTITY_KEY }
    return 'spec-kit-jira'
}

function Get-JiraRecognitionRead {
    <#
    .SYNOPSIS
      One GET folding the identity property into the issue fetch (research
      R3). Returns a pscustomobject { ExitCode; Gone; Marker; Fields }.
      ExitCode 0 with Gone=$true on a 404 (not a failure). Any other
      transport failure returns its mapped exit code (fail-closed).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Key, [string] $Extra = '')
    $base = if ($env:SPEC_KIT_JIRA_BASE_URL) { $env:SPEC_KIT_JIRA_BASE_URL } else { '' }
    $fieldsParam = 'summary,description,priority,status,issuelinks'
    if (-not [string]::IsNullOrEmpty($Extra)) { $fieldsParam = "$fieldsParam,$Extra" }
    $idKey = Get-JiraRecognitionIdentityKey
    $url = "$base/rest/api/3/issue/$Key`?properties=$idKey&fields=$fieldsParam"
    $r = Invoke-JiraRequest -Method GET -Url $url
    if ([int]$r.ExitCode -eq 0) {
        $body = $r.Body | ConvertFrom-Json -Depth 100
        $marker = $null
        if ($body.PSObject.Properties.Name -contains 'properties') {
            $props = $body.properties
            if ($props -and ($props.PSObject.Properties.Name -contains $idKey)) { $marker = $props.$idKey }
        }
        $fields = if ($body.PSObject.Properties.Name -contains 'fields') { $body.fields } else { [pscustomobject]@{} }
        return [pscustomobject]@{ ExitCode = 0; Gone = $false; Marker = $marker; Fields = $fields }
    }
    if ([string]$r.Status -eq '404') {
        return [pscustomobject]@{ ExitCode = 0; Gone = $true; Marker = $null; Fields = $null }
    }
    return [pscustomobject]@{ ExitCode = [int]$r.ExitCode; Gone = $false; Marker = $null; Fields = $null }
}

function Get-JiraRecognitionProjectOf {
    param([string] $IssueKey)
    $idx = $IssueKey.IndexOf('-')
    if ($idx -lt 0) { return $IssueKey }
    return $IssueKey.Substring(0, $idx)
}

function Get-JiraRecognitionSafe {
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $m = $Object.PSObject.Properties[$Name]
    if ($null -eq $m) { return $null }
    return $m.Value
}

function Get-JiraRecognitionReadParent {
    <#
    .SYNOPSIS
      One GET folding the identity property into the issue fetch, fields
      limited to summary,description (contract hierarchy-resolution.md §7).
      Mirror of _recognition_read_parent. Returns a pscustomobject
      { ExitCode; Gone; Marker; Fields }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Key)
    $base = if ($env:SPEC_KIT_JIRA_BASE_URL) { $env:SPEC_KIT_JIRA_BASE_URL } else { '' }
    $idKey = Get-JiraRecognitionIdentityKey
    $url = "$base/rest/api/3/issue/$Key`?properties=$idKey&fields=summary,description"
    $r = Invoke-JiraRequest -Method GET -Url $url
    if ([int]$r.ExitCode -eq 0) {
        $body = $r.Body | ConvertFrom-Json -Depth 100
        $marker = $null
        if ($body.PSObject.Properties.Name -contains 'properties') {
            $props = $body.properties
            if ($props -and ($props.PSObject.Properties.Name -contains $idKey)) { $marker = $props.$idKey }
        }
        $fields = if ($body.PSObject.Properties.Name -contains 'fields') { $body.fields } else { [pscustomobject]@{} }
        return [pscustomobject]@{ ExitCode = 0; Gone = $false; Marker = $marker; Fields = $fields }
    }
    if ([string]$r.Status -eq '404') {
        return [pscustomobject]@{ ExitCode = 0; Gone = $true; Marker = $null; Fields = $null }
    }
    return [pscustomobject]@{ ExitCode = [int]$r.ExitCode; Gone = $false; Marker = $null; Fields = $null }
}

function Invoke-JiraRecognitionParentRun {
    <#
    .SYNOPSIS
      Mirror of recognition_parent_run (contract hierarchy-resolution.md §7,
      data-model.md §1 "epic.marker"). Returns { ExitCode; Json }: ExitCode 0
      with the parent recognition result JSON on success, or the transport's
      mapped exit code (>= 2) with Json = '' when the bound read is
      inconclusive — never downgraded to "no parent exists".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $MarkerInfoJson,
        [Parameter(Mandatory)] [string] $SpecRefJson,
        [Parameter(Mandatory)] [string] $ProjectKey,
        [Parameter(Mandatory)] [string] $SpecPath
    )
    $minfo = $MarkerInfoJson | ConvertFrom-Json -Depth 100
    $state = [string](Get-JiraRecognitionSafe $minfo 'state')

    switch ($state) {
        { $_ -in @('absent', 'assigned') } {
            return [pscustomobject]@{ ExitCode = 0; Json = (ConvertTo-JiraJsonValue ([ordered]@{ state = 'new' })) }
        }
        'creating' {
            $id = [string](Get-JiraRecognitionSafe $minfo 'id')
            $detail = "$SpecPath marks its parent ``creating``: a previous run was interrupted after creating the parent and before recording its key, so whether it exists cannot be determined. Find the issue carrying identifier $id in project $ProjectKey and record it as ``<!-- speckit-jira spec=$id ticket=<KEY> -->``, or delete ``creating`` to mirror a new parent."
            return [pscustomobject]@{ ExitCode = 0; Json = (ConvertTo-JiraJsonValue ([ordered]@{ state = 'blocked'; reason = 'parent-key-unrecorded'; detail = $detail })) }
        }
        'malformed' {
            $lines = @(Get-JiraRecognitionSafe $minfo 'lines')
            $line = if ($lines.Count -gt 0) { $lines[0] } else { 0 }
            $detail = "$SpecPath line ${line}: malformed speckit-jira parent marker; nothing was written for this specification. Expected ``<!-- speckit-jira spec=<16 hex> ticket=<KEY> -->``."
            return [pscustomobject]@{ ExitCode = 0; Json = (ConvertTo-JiraJsonValue ([ordered]@{ state = 'blocked'; reason = 'parent-marker-malformed'; detail = $detail })) }
        }
        'duplicate' {
            $lines = @(Get-JiraRecognitionSafe $minfo 'lines')
            $linesCsv = ($lines -join ', ')
            $detail = "$SpecPath carries $($lines.Count) speckit-jira parent markers (lines $linesCsv); a specification has exactly one parent. Keep the line naming the parent that exists in Jira and delete the others."
            return [pscustomobject]@{ ExitCode = 0; Json = (ConvertTo-JiraJsonValue ([ordered]@{ state = 'blocked'; reason = 'parent-marker-duplicate'; detail = $detail })) }
        }
        'bound' {
            $key = [string](Get-JiraRecognitionSafe $minfo 'ticket')
            $result = Get-JiraRecognitionReadParent -Key $key
            if ([int]$result.ExitCode -ne 0) {
                return [pscustomobject]@{ ExitCode = [int]$result.ExitCode; Json = '' }
            }
            if ($result.Gone) {
                return [pscustomobject]@{ ExitCode = 0; Json = (ConvertTo-JiraJsonValue ([ordered]@{ state = 'new'; recreated_from = [ordered]@{ key = $key } })) }
            }

            $marker = $result.Marker
            $unverifiableDetail = "$key is recorded as the parent of $SpecPath but carries no spec-kit-jira parent identity; nothing was written. The bridge never adopts a ticket it did not create — clear the ticket= value to create a new parent, or restore the identity by hand."
            if ($null -eq $marker) {
                return [pscustomobject]@{ ExitCode = 0; Json = (ConvertTo-JiraJsonValue ([ordered]@{ state = 'blocked'; reason = 'parent-identity-unverifiable'; detail = $unverifiableDetail })) }
            }

            $role = [string](Get-JiraRecognitionSafe $marker 'role')
            if ($role -ne 'parent') {
                return [pscustomobject]@{ ExitCode = 0; Json = (ConvertTo-JiraJsonValue ([ordered]@{ state = 'blocked'; reason = 'parent-identity-unverifiable'; detail = $unverifiableDetail })) }
            }

            $specRef = $SpecRefJson | ConvertFrom-Json -Depth 100
            $repo = [string](Get-JiraRecognitionSafe $specRef 'repo')
            $slug = [string](Get-JiraRecognitionSafe $specRef 'spec_slug')
            $mRepo = [string](Get-JiraRecognitionSafe $marker 'repo')
            $mSlug = [string](Get-JiraRecognitionSafe $marker 'spec_slug')
            if ($mRepo -ne $repo -or $mSlug -ne $slug) {
                $detail = "$key is recorded as the parent of $SpecPath but its identity names specification $mSlug; nothing was written. Correct the ticket= value, or clear it to create a new parent."
                return [pscustomobject]@{ ExitCode = 0; Json = (ConvertTo-JiraJsonValue ([ordered]@{ state = 'blocked'; reason = 'parent-claimed-by-other'; detail = $detail })) }
            }

            $fields = $result.Fields
            $descVal = Get-JiraRecognitionSafe $fields 'description'
            $current = [ordered]@{
                summary     = [string](Get-JiraRecognitionSafe $fields 'summary')
                description = if ($null -eq $descVal) { [ordered]@{} } else { $descVal }
            }
            $origin = [string](Get-JiraRecognitionSafe $marker 'origin')
            if ([string]::IsNullOrEmpty($origin)) { $origin = 'bridge' }
            return [pscustomobject]@{ ExitCode = 0; Json = (ConvertTo-JiraJsonValue ([ordered]@{ state = 'bound'; key = $key; current = $current; origin = $origin })) }
        }
    }
}

function Invoke-JiraRecognitionRun {
    <#
    .SYNOPSIS
      Mirror of recognition_run. Returns { ExitCode; Json }: ExitCode 0 with
      the recognition result JSON on success —
      {"bound":{...},"new":[...],"blocked":[...]} — or the transport's
      mapped exit code (>= 2) with Json = '' when the WHOLE specification
      fails closed on an inconclusive read.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StoriesJson,
        [Parameter(Mandatory)] [string] $SpecRefJson,
        [Parameter(Mandatory)] [string] $ProjectKey,
        [Parameter(Mandatory)] [string] $SpecPath
    )
    $stories = @($StoriesJson | ConvertFrom-Json -Depth 100)
    $specRef = $SpecRefJson | ConvertFrom-Json -Depth 100
    $repo = [string](Get-JiraRecognitionSafe $specRef 'repo')
    $specSlug = [string](Get-JiraRecognitionSafe $specRef 'spec_slug')

    $bound = [ordered]@{}
    $new = [System.Collections.Generic.List[string]]::new()
    $blocked = [System.Collections.Generic.List[object]]::new()
    $rerouted = [ordered]@{}
    $allIds = @($stories | ForEach-Object { [string]$_.local_id })

    foreach ($st in $stories) {
        $id = [string]$st.local_id
        $marker = Get-JiraRecognitionSafe $st 'marker'
        $state = if ($marker) { [string](Get-JiraRecognitionSafe $marker 'state') } else { 'absent' }
        if ($state -eq 'malformed') {
            $lines = @(Get-JiraRecognitionSafe $marker 'lines')
            $ln = if ($lines.Count -gt 0) { $lines[0] } else { 0 }
            $detail = "$SpecPath line ${ln}: malformed speckit-jira marker; nothing was written for that story. Expected ``<!-- speckit-jira story=<16 hex> ticket=<KEY> -->``."
            $blocked.Add([ordered]@{ story = $id; reason = 'marker-malformed'; detail = $detail })
        }
        elseif ($state -eq 'duplicate') {
            $lines = @(Get-JiraRecognitionSafe $marker 'lines')
            $linesCsv = ($lines -join ', ')
            $detail = "Story identifier $id appears on 2 user stories in $SpecPath (lines $linesCsv); nothing was written for any of them. Give each story its own marker line, or delete the duplicates to have them mirrored as new tickets."
            $blocked.Add([ordered]@{ story = $id; reason = 'duplicate-claim'; detail = $detail })
        }
    }

    foreach ($st in $stories) {
        $id = [string]$st.local_id
        $marker = Get-JiraRecognitionSafe $st 'marker'
        $state = if ($marker) { [string](Get-JiraRecognitionSafe $marker 'state') } else { 'absent' }
        if ($state -eq 'assigned') {
            $new.Add($id)
        }
        elseif ($state -eq 'creating') {
            $detail = "Story $id in $SpecPath is marked ``creating``: a previous run was interrupted after creating its ticket and before recording the key, so whether a ticket exists cannot be determined. Check the project for a ticket carrying that identifier and record it as ``<!-- speckit-jira story=$id ticket=<KEY> -->``, or replace ``creating`` with nothing to mirror the story as a new ticket."
            $blocked.Add([ordered]@{ story = $id; reason = 'key-unrecorded'; detail = $detail })
        }
    }

    $boundStories = @($stories | Where-Object { $m = Get-JiraRecognitionSafe $_ 'marker'; $m -and ([string](Get-JiraRecognitionSafe $m 'state')) -eq 'bound' })
    $dupKeys = @($boundStories | ForEach-Object { [string](Get-JiraRecognitionSafe (Get-JiraRecognitionSafe $_ 'marker') 'ticket') } | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })

    foreach ($st in $boundStories) {
        $id = [string]$st.local_id
        $marker = Get-JiraRecognitionSafe $st 'marker'
        $key = [string](Get-JiraRecognitionSafe $marker 'ticket')

        if ($dupKeys -contains $key) {
            $detail = "Ticket $key is recorded for more than one story in $SpecPath; nothing was written for any of them. Give each story its own ticket, or correct the ticket= value."
            $blocked.Add([ordered]@{ story = $id; reason = 'duplicate-claim'; detail = $detail })
            continue
        }

        if (-not [string]::IsNullOrEmpty($ProjectKey) -and (Get-JiraRecognitionProjectOf -IssueKey $key) -ne $ProjectKey) {
            $new.Add($id)
            $rerouted[$id] = [ordered]@{ former_key = $key; former_project = (Get-JiraRecognitionProjectOf -IssueKey $key) }
            continue
        }

        $result = Get-JiraRecognitionRead -Key $key
        if ([int]$result.ExitCode -ne 0) {
            return [pscustomobject]@{ ExitCode = [int]$result.ExitCode; Json = '' }
        }
        if ($result.Gone) {
            $new.Add($id)
            continue
        }

        $rmarker = $result.Marker
        if ($null -eq $rmarker) {
            $detail = "Ticket $key recorded for story $id in $SpecPath does not carry that story's identity marker; nothing was written to it. Correct the ticket= value in $SpecPath, or delete the marker line to mirror the story as a new ticket."
            $blocked.Add([ordered]@{ story = $id; reason = 'marker-mismatch'; detail = $detail })
            continue
        }

        $mStory = [string](Get-JiraRecognitionSafe $rmarker 'story')
        $mRepo = [string](Get-JiraRecognitionSafe $rmarker 'repo')
        $mSlug = [string](Get-JiraRecognitionSafe $rmarker 'spec_slug')

        if ([string]::IsNullOrEmpty($mStory)) {
            $detail = "Ticket $key recorded for story $id in $SpecPath does not carry that story's identity marker; nothing was written to it. Correct the ticket= value in $SpecPath, or delete the marker line to mirror the story as a new ticket."
            $blocked.Add([ordered]@{ story = $id; reason = 'marker-mismatch'; detail = $detail })
            continue
        }

        # Decision order (first match wins): a marker with no `story` field is
        # always marker-mismatch (handled above); THEN repo/spec_slug —
        # claimed-by-other applies even when `story` happens to equal this
        # id, since it is the more fundamental "is this ticket even for this
        # specification" question; only once repo/spec_slug agree does a
        # non-matching `story` resolve to orphan or marker-mismatch.
        # spec_slug is deliberately NOT part of this check (US3,
        # FR-017/FR-018): it is derived from the specification FOLDER's
        # name, which a rename changes — the durable `story` identifier,
        # unique per specification by construction, is what protects
        # against cross-specification collision without breaking on rename.
        if ($mRepo -ne $repo) {
            $detail = "Ticket $key recorded for story $id in $SpecPath is claimed by specification $mSlug; nothing was written to it. Correct the ticket= value in $SpecPath, or reconcile that specification instead."
            $blocked.Add([ordered]@{ story = $id; reason = 'claimed-by-other'; detail = $detail })
            continue
        }
        if ($mStory -ne $id) {
            if ($allIds -notcontains $mStory) {
                $detail = "Ticket $key recorded in $SpecPath carries story identifier $mStory, which no user story in $SpecPath claims; nothing was written to it. Restore $mStory as that story's identifier with ``<!-- speckit-jira story=$mStory ticket=$key -->``, or delete the marker line to mirror the story as a new ticket and close $key in Jira."
                $blocked.Add([ordered]@{ story = $id; reason = 'orphan'; detail = $detail })
            }
            else {
                $detail = "Ticket $key recorded for story $id in $SpecPath does not carry that story's identity marker; nothing was written to it. Correct the ticket= value in $SpecPath, or delete the marker line to mirror the story as a new ticket."
                $blocked.Add([ordered]@{ story = $id; reason = 'marker-mismatch'; detail = $detail })
            }
            continue
        }

        $fields = $result.Fields
        $origin = [string](Get-JiraRecognitionSafe $rmarker 'origin')
        if ([string]::IsNullOrEmpty($origin)) { $origin = 'bridge' }
        $descVal = Get-JiraRecognitionSafe $fields 'description'
        $current = [ordered]@{
            summary     = [string](Get-JiraRecognitionSafe $fields 'summary')
            description = if ($null -eq $descVal) { [ordered]@{} } else { $descVal }
            priority    = (Get-JiraRecognitionSafe $fields 'priority')
        }
        $statusObj = Get-JiraRecognitionSafe $fields 'status'
        $status = if ($statusObj) { [string](Get-JiraRecognitionSafe $statusObj 'name') } else { '' }
        $statusCategoryObj = if ($statusObj) { Get-JiraRecognitionSafe $statusObj 'statusCategory' } else { $null }
        $statusCategory = if ($statusCategoryObj) { [string](Get-JiraRecognitionSafe $statusCategoryObj 'key') } else { '' }
        $flaggedVal = Get-JiraRecognitionSafe $fields 'Flagged'
        $flagged = ($null -ne $flaggedVal) -and (@($flaggedVal).Count -gt 0)
        $links = @(Get-JiraRecognitionSafe $fields 'issuelinks')
        $blockers = [System.Collections.Generic.List[string]]::new()
        foreach ($link in $links) {
            $type = Get-JiraRecognitionSafe $link 'type'
            $inwardIssue = Get-JiraRecognitionSafe $link 'inwardIssue'
            if ($type -and (Get-JiraRecognitionSafe $type 'inward') -and $inwardIssue) {
                $blockers.Add([string](Get-JiraRecognitionSafe $inwardIssue 'key'))
            }
        }

        $bound[$id] = [ordered]@{
            key             = $key
            origin          = $origin
            current         = $current
            status          = $status
            status_category = $statusCategory
            flagged         = $flagged
            blockers        = $blockers
        }
    }

    $json = ConvertTo-JiraJsonValue ([ordered]@{ bound = $bound; new = $new; blocked = $blocked; rerouted = $rerouted })
    return [pscustomobject]@{ ExitCode = 0; Json = $json }
}

Export-ModuleMember -Function Invoke-JiraRecognitionRun, Get-JiraRecognitionRead, Get-JiraRecognitionProjectOf, `
    Invoke-JiraRecognitionParentRun, Get-JiraRecognitionReadParent
