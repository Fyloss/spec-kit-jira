# engine/Interchange.psm1 — Neutral interchange document validation.
# Mirror of engine/interchange.sh.
#
# Validates the neutral document (contracts/neutral-interchange.schema.json)
# BEFORE any write (Constitution VIII). A failure means ZERO writes.
#
# NEUTRAL layer: zero Jira identifiers, never imports sink/.

Set-StrictMode -Version Latest

function Test-JiraInterchangeProp {
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $false }
    return ($Object.PSObject.Properties.Name -contains $Name)
}

function Get-JiraInterchangeProp {
    param($Object, [string] $Name)
    if (Test-JiraInterchangeProp $Object $Name) { return $Object.$Name }
    return $null
}

function Get-JiraArrayCount {
    # Count an array-valued property WITHOUT triggering PowerShell's single- and
    # empty-collection unwrapping (which a plain `return` would). -1 = absent.
    param($Object, [string] $Name)
    if (-not (Test-JiraInterchangeProp $Object $Name)) { return -1 }
    $value = $Object.$Name
    if ($null -eq $value) { return 0 }
    return @($value).Count
}

function Test-JiraInterchange {
    <#
    .SYNOPSIS
      Validate a neutral interchange document. Returns $true when valid; writes
      each error to stderr and returns $false otherwise.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Json)

    try { $d = $Json | ConvertFrom-Json -Depth 100 }
    catch { [Console]::Error.WriteLine('interchange: input is not valid JSON'); return $false }

    $errors = [System.Collections.Generic.List[string]]::new()

    if ((Get-JiraInterchangeProp $d 'schema_version') -ne '1.0') {
        $errors.Add('schema_version must be "1.0"')
    }

    $specRef = Get-JiraInterchangeProp $d 'spec_ref'
    if ($null -eq $specRef) {
        $errors.Add('spec_ref is required')
    }
    else {
        if ([string]::IsNullOrEmpty([string](Get-JiraInterchangeProp $specRef 'repo'))) { $errors.Add('spec_ref.repo is required') }
        if ([string]::IsNullOrEmpty([string](Get-JiraInterchangeProp $specRef 'folder'))) { $errors.Add('spec_ref.folder is required') }
        $slug = [string](Get-JiraInterchangeProp $specRef 'spec_slug')
        if ($slug -notmatch '^[0-9]{3}-[a-z0-9-]+$') { $errors.Add('spec_ref.spec_slug is malformed') }
    }

    $routing = Get-JiraInterchangeProp $d 'routing'
    $projectKey = [string](Get-JiraInterchangeProp $routing 'project_key')
    if ($projectKey -notmatch '^[A-Z][A-Z0-9_]+$') { $errors.Add('routing.project_key is invalid') }

    $epic = Get-JiraInterchangeProp $d 'epic'
    if ($null -eq $epic) {
        $errors.Add('epic is required')
    }
    else {
        if ([string]::IsNullOrEmpty([string](Get-JiraInterchangeProp $epic 'title'))) { $errors.Add('epic.title is required') }
        if (@('per_repo', 'per_feature') -notcontains (Get-JiraInterchangeProp $epic 'strategy')) { $errors.Add('epic.strategy is invalid') }
        if ((Get-JiraArrayCount (Get-JiraInterchangeProp $epic 'description') 'blocks') -lt 1) { $errors.Add('epic.description.blocks must be non-empty') }
    }

    if ((Get-JiraArrayCount $d 'stories') -lt 1) {
        $errors.Add('stories must be a non-empty array')
    }
    else {
        foreach ($s in @($d.stories)) {
            if ([string]::IsNullOrEmpty([string](Get-JiraInterchangeProp $s 'local_id'))) { $errors.Add('story.local_id is required') }
            if ([string]::IsNullOrEmpty([string](Get-JiraInterchangeProp $s 'title'))) { $errors.Add('story.title is required') }
            if (@('P1', 'P2', 'P3') -notcontains (Get-JiraInterchangeProp $s 'priority_logical')) { $errors.Add('story.priority_logical is invalid') }
            if ((Get-JiraArrayCount (Get-JiraInterchangeProp $s 'description') 'blocks') -lt 1) { $errors.Add('story.description.blocks must be non-empty') }
        }
    }

    if ($errors.Count -eq 0) { return $true }
    foreach ($e in $errors) { [Console]::Error.WriteLine("interchange: $e") }
    return $false
}

Export-ModuleMember -Function Test-JiraInterchange
