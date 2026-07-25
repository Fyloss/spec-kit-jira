# hooks/ReadmeBlock.psm1 — Version-marked managed README-block writer. Mirror of
# hooks/readme_block.sh (US5, T064).
#
# Renders the self-documenting README block from the template, stamping the marker
# lines with the single source-of-truth version (FR-024), and splices it into the
# consuming repository's README via the neutral engine byte-splice (FR-025).
# Idempotent (FR-028); hand-edited blocks are regenerated (FR-029); malformed
# markers are refused with zero writes and exit 4 (FR-027).

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../engine/ManagedSection.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../lib/Config.psm1') -Force # Get-JiraExtensionVersion — the single version source

$script:ReadmeBeginToken = '<!-- spec-kit-jira:begin'
$script:ReadmeEndToken = '<!-- spec-kit-jira:end'
$script:ExitConfig = 4

function Get-JiraReadmeTemplatePath {
    if ($env:SPEC_KIT_JIRA_README_TEMPLATE) { return $env:SPEC_KIT_JIRA_README_TEMPLATE }
    return (Join-Path $PSScriptRoot '../../../templates/readme-block.template')
}

function Get-JiraReadmeBlock {
    <#
    .SYNOPSIS
      Render the version-marked block (markers included), LF-joined and without a
      trailing newline. Returns $null (with an error on stderr) if the template is
      missing. Byte-identical to readme_block_render.
    #>
    [CmdletBinding()]
    param()
    $version = Get-JiraExtensionVersion
    $tmpl = Get-JiraReadmeTemplatePath
    if (-not (Test-Path -LiteralPath $tmpl)) {
        [Console]::Error.WriteLine("readme: block template not found: $tmpl")
        return $null
    }
    $body = [System.IO.File]::ReadAllText($tmpl)
    $body = $body -replace "`r`n", "`n"   # normalise the template to LF
    $body = $body.TrimEnd("`n")
    return $body.Replace('{{VERSION}}', [string]$version)
}

function Set-JiraReadmeBlock {
    <#
    .SYNOPSIS
      Render the block and splice it into the host README (creating it if absent).
      Returns { ExitCode; Status } where Status is created | written | unchanged |
      refused. ExitCode 4 on malformed markers (zero writes). In dry-run the status
      is computed but the file is never touched.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [bool] $DryRun = $false
    )

    $block = Get-JiraReadmeBlock
    if ($null -eq $block) { return [pscustomobject]@{ ExitCode = $script:ExitConfig; Status = 'refused' } }

    $existed = Test-Path -LiteralPath $Path
    $current = if ($existed) { [System.IO.File]::ReadAllText($Path) } else { '' }

    $r = Invoke-JiraManagedSectionSplice -Text $current -BeginToken $script:ReadmeBeginToken `
        -EndToken $script:ReadmeEndToken -NewBlock $block
    if ($r.ExitCode -ne 0) {
        return [pscustomobject]@{ ExitCode = $script:ExitConfig; Status = 'refused' }
    }
    $new = $r.Content

    $status = if ($existed -and [System.String]::Equals($current, $new, [System.StringComparison]::Ordinal)) {
        'unchanged'
    }
    elseif (-not $existed) { 'created' }
    else { 'written' }

    if (-not $DryRun -and $status -ne 'unchanged') {
        if ($PSCmdlet.ShouldProcess($Path, 'write managed README block')) {
            [System.IO.File]::WriteAllText($Path, $new, (New-Object System.Text.UTF8Encoding($false)))
        }
    }
    return [pscustomobject]@{ ExitCode = 0; Status = $status }
}

Export-ModuleMember -Function Get-JiraReadmeBlock, Set-JiraReadmeBlock
