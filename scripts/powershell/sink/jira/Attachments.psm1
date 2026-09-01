# sink/jira/Attachments.psm1 — publishing the feature's artifacts onto its
# specification ticket. Mirror of sink/jira/attachments.sh.
# (036; contracts/artifact-publication.md; contracts/comment-body.md.)
#
# SINK layer: everything here knows about Jira. The engine hands over the
# artifact set and this module turns it into attachments, one announcing
# comment, and a manifest.
#
# Three rules shape all of it and none of them bend:
#
#   * ONE REQUEST FOR THE WHOLE SET — never a call per artifact (FR-023).
#   * ZERO WRITES WHEN NOTHING CHANGED — zero of every kind, attachments,
#     comment and manifest alike (Principle II, C4.5).
#   * NOTHING IS EVER REMOVED — a superseded attachment stays (Principle I,
#     FR-014).

Set-StrictMode -Version Latest

# WITHOUT -Force on Client: PlanApply and others already load it, and a forced
# nested import here would tear its exports out of their scope and rebind them
# to this one — the defect that once had every timing phase reporting 0
# requests against 123 real ones.
Import-Module (Join-Path $PSScriptRoot 'Client.psm1')
Import-Module (Join-Path $PSScriptRoot '../../lib/Cli.psm1')
Import-Module (Join-Path $PSScriptRoot '../../lib/Output.psm1')

# The entity-property key holding the publication manifest. A constant of ours,
# never an Atlassian default — the sibling of `spec-kit-jira` in Identity.psm1.
$script:ArtifactsPropertyKey = if ($env:SPEC_KIT_JIRA_ARTIFACTS_KEY) { $env:SPEC_KIT_JIRA_ARTIFACTS_KEY } else { 'spec-kit-jira-artifacts' }

# The manifest's shape version. A reader that does not recognise the value
# treats the manifest as ABSENT and republishes — never as an error.
$script:ManifestSchema = 1

# An ASSUMED cap on an entity-property value, pending research §R15 item 4.
# Declared as an assumption rather than a measured constant, because that is
# what it is: nothing in this repository has observed the real limit.
$script:PropertyCap = if ($env:SPEC_KIT_JIRA_PROPERTY_CAP) { [int] $env:SPEC_KIT_JIRA_PROPERTY_CAP } else { 32768 }

$script:LimitCache = $null

function Get-JiraAttachmentLimit {
    <#
    .SYNOPSIS
      The site's attachment settings as { Enabled; UploadLimit } (C1.1). Read
      ONCE per run and memoised.
    .DESCRIPTION
      Principle VII forbids compiling in 10 MB as though it were universal:
      sites raise and lower it, and FR-017 requires the warning to state the
      real number. Returns $null when the call fails, which the caller treats
      as "withhold the whole publication" rather than "assume a default".
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $BaseUrl)

    if ($null -ne $script:LimitCache) { return $script:LimitCache }
    $r = Invoke-JiraRequest -Method 'GET' -Url "$BaseUrl/rest/api/3/attachment/meta"
    if ($r.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($r.Body)) { return $null }
    $parsed = $null
    try { $parsed = $r.Body | ConvertFrom-Json } catch { return $null }
    $enabled = $true
    $limit = 0
    if ($parsed.PSObject.Properties.Name -contains 'enabled') { $enabled = [bool] $parsed.enabled }
    if ($parsed.PSObject.Properties.Name -contains 'uploadLimit') { $limit = [int64] $parsed.uploadLimit }
    $script:LimitCache = [pscustomobject]@{ Enabled = $enabled; UploadLimit = $limit }
    return $script:LimitCache
}

function Get-JiraArtifactManifest {
    <#
    .SYNOPSIS
      The manifest stored on the ticket, as canonical JSON; '{}' when absent (C1.2).
    .DESCRIPTION
      A 404 is NOT fail-closed here: it means "nothing published yet", the
      ordinary state of a first run. Treating it as an error would make every
      first publication a failure.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $BaseUrl, [Parameter(Mandatory)] [string] $TicketKey)

    $r = Invoke-JiraRequest -Method 'GET' -Url "$BaseUrl/rest/api/3/issue/$TicketKey/properties/$($script:ArtifactsPropertyKey)"
    if ($r.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($r.Body)) { return '{}' }
    $parsed = $null
    try { $parsed = $r.Body | ConvertFrom-Json } catch { return '{}' }
    if ($parsed.PSObject.Properties.Name -notcontains 'value') { return '{}' }
    $v = $parsed.value
    if ($v.PSObject.Properties.Name -notcontains 'schema' -or [int] $v.schema -ne $script:ManifestSchema) { return '{}' }
    if ($v.PSObject.Properties.Name -notcontains 'artifacts') { return '{}' }
    return (ConvertTo-JiraCanonicalJson -Json ($v.artifacts | ConvertTo-Json -Depth 20 -Compress))
}

function Get-JiraArtifactDecision {
    <#
    .SYNOPSIS
      The decision for every artifact, as canonical JSON (C4.1, C4.2).
    .DESCRIPTION
      `action` is one of published · revised · unchanged · withheld.

      A decision that WILL be published carries the artifact's `hash`, because
      the manifest is composed from the decision set and has nothing else to
      record it from. Without it the manifest stores an empty hash, every later
      run reads "the hash differs", and zero-churn never holds — a defect that
      would look like the feature working and re-uploading everything forever.

      WITHHOLDING PRECEDENCE is fixed — name-collision, then oversized — so a
      run's warnings are deterministic across ports.

      The trust rule (C4.3): an artifact whose hash matches is `unchanged` ONLY
      if the attachment id the manifest claims is still on the ticket.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $SetJson,
        [string] $ManifestJson = '{}',
        [int64] $Limit = 0,
        [string] $TicketAttachmentIdsJson = $null
    )

    $set = @($SetJson | ConvertFrom-Json)
    if ($set.Count -eq 0) { return '[]' }
    $manifest = @{}
    if (-not [string]::IsNullOrWhiteSpace($ManifestJson)) {
        $m = $ManifestJson | ConvertFrom-Json -AsHashtable
        if ($m) { $manifest = $m }
    }
    $ids = $null
    if (-not [string]::IsNullOrWhiteSpace($TicketAttachmentIdsJson)) {
        $ids = @($TicketAttachmentIdsJson | ConvertFrom-Json)
    }

    $byName = @{}
    foreach ($a in $set) {
        if (-not $byName.ContainsKey($a.attachment_name)) { $byName[$a.attachment_name] = @() }
        $byName[$a.attachment_name] += $a.path
    }

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($a in $set) {
        $rec = if ($manifest.ContainsKey($a.path)) { $manifest[$a.path] } else { $null }
        $siblings = @($byName[$a.attachment_name] | Where-Object { $_ -ne $a.path })
        if ($siblings.Count -gt 0) {
            $out.Add([ordered]@{
                    path = $a.path; attachment_name = $a.attachment_name; action = 'withheld'
                    reason = 'name-collision'; collides_with = ($siblings -join ', ')
                })
        }
        elseif ($Limit -gt 0 -and [int64] $a.size -gt $Limit) {
            $out.Add([ordered]@{
                    path = $a.path; attachment_name = $a.attachment_name; action = 'withheld'
                    reason = 'oversized'; size = [int64] $a.size; limit = $Limit
                })
        }
        elseif ($null -eq $rec) {
            $out.Add([ordered]@{ path = $a.path; attachment_name = $a.attachment_name; hash = $a.hash; action = 'published' })
        }
        elseif ([string] $rec['hash'] -ne [string] $a.hash) {
            $out.Add([ordered]@{ path = $a.path; attachment_name = $a.attachment_name; hash = $a.hash; action = 'revised' })
        }
        elseif ($null -ne $ids -and -not ($ids -contains [string] $rec['attachment_id'])) {
            # The manifest is ahead of the ticket: republish (C4.3).
            $out.Add([ordered]@{ path = $a.path; attachment_name = $a.attachment_name; hash = $a.hash; action = 'published' })
        }
        else {
            $out.Add([ordered]@{ path = $a.path; attachment_name = $a.attachment_name; action = 'unchanged' })
        }
    }
    return (ConvertTo-JiraCanonicalJson -Json (ConvertTo-Json -InputObject @($out) -Depth 10 -Compress))
}

function New-JiraArtifactComment {
    <#
    .SYNOPSIS
      The ADF document announcing this run's publication (comment-body.md B1-B4).
    .DESCRIPTION
      The literals are PINNED, copied from the contract rather than composed,
      because the Bash twin must produce the same bytes and a shared generator
      across two languages is exactly where they drift apart.

      Withheld artifacts are ABSENT (B4): the comment announces what a reader
      can now download, and naming a file that is not there is worse than
      silence. They are reported in the run summary instead.
    #>
    # [AllowEmptyString()] on the event: a reconcile invoked directly rather
    # than from a lifecycle hook has no event, and the Bash port renders that as
    # an empty `code` span without complaint. A Mandatory [string] rejects it at
    # bind time, so the whole publication died on a run that had nothing wrong
    # with it.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $LifecycleEvent, [Parameter(Mandatory)] [AllowEmptyString()] [string] $DecisionsJson)

    $decisions = @($DecisionsJson | ConvertFrom-Json)
    $published = @($decisions | Where-Object { $_.action -eq 'published' -or $_.action -eq 'revised' })
    $anyRevised = @($published | Where-Object { $_.action -eq 'revised' }).Count -gt 0

    # One literal for the lead, as in the Bash port — exactly one place the two
    # have to match.
    $lead = 'Spec Kit published these feature artifacts after '
    $tail = if ($anyRevised) { '. Revised files are attached again; earlier versions are kept.' }
    else { '. They are attached to this ticket.' }

    $items = @()
    foreach ($p in $published) {
        $suffix = if ($p.action -eq 'revised') { ' — revised' } else { ' — new' }
        $items += [ordered]@{
            type    = 'listItem'
            content = @([ordered]@{
                    type    = 'paragraph'
                    content = @(
                        [ordered]@{ type = 'text'; text = $p.path; marks = @([ordered]@{ type = 'code' }) },
                        [ordered]@{ type = 'text'; text = $suffix }
                    )
                })
        }
    }

    $doc = [ordered]@{
        type    = 'doc'
        version = 1
        content = @(
            [ordered]@{
                type    = 'paragraph'
                content = @(
                    [ordered]@{ type = 'text'; text = $lead },
                    [ordered]@{ type = 'text'; text = $LifecycleEvent; marks = @([ordered]@{ type = 'code' }) },
                    [ordered]@{ type = 'text'; text = $tail }
                )
            },
            [ordered]@{ type = 'bulletList'; content = @($items) }
        )
    }
    return (ConvertTo-JiraCanonicalJson -Json (ConvertTo-Json -InputObject $doc -Depth 20 -Compress))
}

function New-JiraArtifactManifest {
    <#
    .SYNOPSIS
      The manifest to store after this run, as canonical JSON (data-model §2).
    .DESCRIPTION
      Only entries that ACTUALLY LANDED are folded in: `Created` is the sink's
      own response, so an upload that failed contributes nothing and the next
      run retries it. Entries for artifacts no longer in the set are LEFT IN
      PLACE — their attachments still exist on the ticket (FR-015).

      `Created` is paired with the published decisions BY INDEX, which is only
      sound because the upload preserves part order (C2.3).
    #>
    [CmdletBinding()]
    param(
        [string] $ManifestJson = '{}',
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $DecisionsJson,
        [string] $CreatedJson = '[]',
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $LifecycleEvent
    )

    $manifest = @{}
    if (-not [string]::IsNullOrWhiteSpace($ManifestJson)) {
        $m = $ManifestJson | ConvertFrom-Json -AsHashtable
        if ($m) { $manifest = $m }
    }
    $published = @(@($DecisionsJson | ConvertFrom-Json) | Where-Object { $_.action -eq 'published' -or $_.action -eq 'revised' })
    $created = @($CreatedJson | ConvertFrom-Json)

    for ($i = 0; $i -lt $published.Count; $i++) {
        if ($i -ge $created.Count) { break }
        $p = $published[$i]
        $hash = ''
        if ($p.PSObject.Properties.Name -contains 'hash') { $hash = [string] $p.hash }
        $manifest[[string] $p.path] = [ordered]@{
            hash = $hash; attachment_id = [string] $created[$i].id; run = $LifecycleEvent
        }
    }
    return (ConvertTo-JiraCanonicalJson -Json (ConvertTo-Json -InputObject $manifest -Depth 20 -Compress))
}

function Test-JiraManifestOversized {
    <#
    .SYNOPSIS
      True when the composed manifest would exceed the property cap (C4.4.1).
    .DESCRIPTION
      Fails closed rather than publishing what fits: a partial manifest would
      make the next run republish exactly the artifacts this one dropped,
      forever, which is worse than not starting.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $ArtifactsJson)

    $doc = "{`"schema`":$($script:ManifestSchema),`"artifacts`":$ArtifactsJson}"
    return ([System.Text.Encoding]::UTF8.GetByteCount($doc) -gt $script:PropertyCap)
}

function Publish-JiraArtifactSet {
    <#
    .SYNOPSIS
      Upload every artifact this run decided to publish, in ONE request (C1.4).
      Returns the sink's response JSON; '[]' when there is nothing to send.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $BaseUrl,
        [Parameter(Mandatory)] [string] $TicketKey,
        [Parameter(Mandatory)] [string] $FeatureDirectory,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $DecisionsJson
    )

    $published = @(@($DecisionsJson | ConvertFrom-Json) | Where-Object { $_.action -eq 'published' -or $_.action -eq 'revised' })
    if ($published.Count -eq 0) { return '[]' }
    $parts = @()
    foreach ($p in $published) {
        $parts += @{ Name = [string] $p.attachment_name; File = (Join-Path $FeatureDirectory ([string] $p.path)) }
    }
    $r = Invoke-JiraRequest -Method 'POST' -Url "$BaseUrl/rest/api/3/issue/$TicketKey/attachments" -FormParts $parts
    if ($r.ExitCode -ne 0) { return '' }
    return $r.Body
}

function Send-JiraArtifactComment {
    <#
    .SYNOPSIS
      Post the announcing comment (C1.5). One per publishing run; the caller
      decides whether there is anything to announce.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $BaseUrl,
        [Parameter(Mandatory)] [string] $TicketKey,
        [Parameter(Mandatory)] [string] $AdfJson
    )
    $body = "{`"body`":$AdfJson}"
    $r = Invoke-JiraRequest -Method 'POST' -Url "$BaseUrl/rest/api/3/issue/$TicketKey/comment" -Body $body
    return ($r.ExitCode -eq 0)
}

function Save-JiraArtifactManifest {
    <#
    .SYNOPSIS
      Store the manifest (C1.6). Issued ONLY by a caller that has something to
      record, so the zero-write floor lives at the call site.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $BaseUrl,
        [Parameter(Mandatory)] [string] $TicketKey,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $ArtifactsJson
    )
    $body = "{`"schema`":$($script:ManifestSchema),`"artifacts`":$ArtifactsJson}"
    $r = Invoke-JiraRequest -Method 'PUT' `
        -Url "$BaseUrl/rest/api/3/issue/$TicketKey/properties/$($script:ArtifactsPropertyKey)" -Body $body
    return ($r.ExitCode -eq 0)
}

function Get-JiraTicketAttachmentId {
    <#
    .SYNOPSIS
      The attachment ids currently on the ticket, as JSON (C1.3). Used only by
      the trust rule, and only when the manifest claims an id a run is about to
      call `unchanged`.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $BaseUrl, [Parameter(Mandatory)] [string] $TicketKey)

    $r = Invoke-JiraRequest -Method 'GET' -Url "$BaseUrl/rest/api/3/issue/$TicketKey`?fields=attachment"
    if ($r.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($r.Body)) { return $null }
    $parsed = $null
    try { $parsed = $r.Body | ConvertFrom-Json } catch { return $null }
    if ($parsed.PSObject.Properties.Name -notcontains 'fields') { return '[]' }
    if ($parsed.fields.PSObject.Properties.Name -notcontains 'attachment') { return '[]' }
    $ids = @(@($parsed.fields.attachment) | ForEach-Object { [string] $_.id })
    return (ConvertTo-Json -InputObject @($ids) -Depth 5 -Compress)
}

Export-ModuleMember -Function Get-JiraAttachmentLimit, Get-JiraArtifactManifest,
Get-JiraArtifactDecision, New-JiraArtifactComment, New-JiraArtifactManifest,
Test-JiraManifestOversized, Publish-JiraArtifactSet, Send-JiraArtifactComment,
Save-JiraArtifactManifest, Get-JiraTicketAttachmentId
