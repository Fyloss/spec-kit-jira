# tests/powershell/helpers/ArtifactFixture.psm1 — Pester twin of
# tests/bash/helpers/artifact_fixture.bash.
#
# Same rationale as the Bash original, and the same two load-bearing choices:
#
#   1. The fixture builds its OWN git repository. `git ls-files --cached
#      --others --exclude-standard` is the enumeration under test (research
#      R5); it answers relative to a repository, so the fixture must be in one
#      whose ignore rules it controls.
#   2. The exclusion goes in `.git/info/exclude`, never a `.gitignore` inside
#      the feature directory — that file would itself be an untracked,
#      non-ignored file, i.e. an artifact, and every expected-set assertion
#      would have to carry it.
#
# The directory this writes MUST be byte-identical to the Bash helper's, or
# the cross-port equivalence assertions compare two different corpora and
# prove nothing (Principle VI).

Set-StrictMode -Version Latest

# The artifact paths written below, relative to the feature directory, in the
# byte-wise sorted order the artifact set must produce (data-model §1
# "Ordering").
$script:ArtifactPaths = @(
    'assets/diagram.png'
    'checklists/requirements.md'
    'contracts/api.md'
    'data-model.md'
    'plan.md'
    'research.md'
    'spec.md'
    'tasks.md'
)

# The flattened attachment name for each path above, same order (research R7).
$script:ArtifactNames = @(
    'assets__diagram.png'
    'checklists__requirements.md'
    'contracts__api.md'
    'data-model.md'
    'plan.md'
    'research.md'
    'spec.md'
    'tasks.md'
)

# Write text as LF-terminated UTF-8 with no BOM and no trailing CR.
#
# Not a convenience: `Set-Content` writes the host's line ending, so on Windows
# every fixture file would differ from the Bash port's by one byte per line and
# every content hash would diverge. The bytes are written directly.
function Write-FixtureText {
    param(
        [Parameter(Mandatory)][string] $Path,
        # [AllowEmptyString()] is load-bearing: a Mandatory [string[]] gets an
        # implicit per-element non-empty check, so a blank line in the middle of
        # a document — which every one of these fixtures has — is rejected at
        # bind time. Without it the PowerShell fixture writes a different corpus
        # from the Bash one and every cross-port assertion compares two
        # different things.
        [Parameter(Mandatory)][AllowEmptyString()][string[]] $Lines
    )
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $text = ($Lines -join "`n") + "`n"
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($text)
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function New-ArtifactRepo {
    <#
    .SYNOPSIS
      A git repository at <Root> with the ignore rule already in place.
    #>
    param([Parameter(Mandatory)][string] $Root)

    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    & git -C $Root init --quiet
    & git -C $Root config user.email 'fixture@example.invalid'
    & git -C $Root config user.name 'fixture'
    Write-FixtureText -Path (Join-Path $Root '.git/info/exclude') -Lines @('*.log', 'scratch/')
}

function Write-BinaryArtifact {
    <#
    .SYNOPSIS
      64 deterministic non-text bytes: a PNG signature — which carries a CRLF
      pair — then a run across the byte range.
    .DESCRIPTION
      The CRLF is deliberate. A port that normalises line endings anywhere on
      the upload path corrupts this file, and FR-002 requires the bytes to
      arrive unmodified.
    #>
    param([Parameter(Mandatory)][string] $Path)

    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $bytes = [System.Collections.Generic.List[byte]]::new()
    foreach ($b in 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) { $bytes.Add([byte] $b) }
    for ($i = 0; $i -lt 56; $i++) { $bytes.Add([byte] (($i * 4) % 256)) }
    [System.IO.File]::WriteAllBytes($Path, $bytes.ToArray())
}

function New-ArtifactFixture {
    <#
    .SYNOPSIS
      Write the feature directory under an initialised repository; returns its
      absolute path.
    #>
    param(
        [Parameter(Mandatory)][string] $Root,
        [string] $Name = '036-artifact-fixture'
    )

    if (-not (Test-Path -LiteralPath (Join-Path $Root '.git'))) { New-ArtifactRepo -Root $Root }

    $dir = Join-Path $Root "specs/$Name"
    foreach ($sub in 'contracts', 'checklists', 'assets', 'scratch') {
        New-Item -ItemType Directory -Path (Join-Path $dir $sub) -Force | Out-Null
    }

    Write-FixtureText -Path (Join-Path $dir 'spec.md') -Lines @(
        '# Feature Specification: Widget Management'
        ''
        'We need to let users manage widgets end to end.'
        ''
        '### User Story 1 - Manage widgets (Priority: P1)'
        ''
        'As a user, I want to manage widgets.'
        ''
        '- **Given** a precondition'
        '- **When** I act'
        '- **Then** it happens'
    )
    Write-FixtureText -Path (Join-Path $dir 'plan.md') -Lines @(
        '# Implementation Plan: Widget Management', '', 'Two ports, one contract.'
    )
    Write-FixtureText -Path (Join-Path $dir 'tasks.md') -Lines @(
        '# Tasks: Widget Management', '', '- [ ] T001 [US1] Do the thing in src/thing.sh'
    )
    Write-FixtureText -Path (Join-Path $dir 'research.md') -Lines @(
        '# Phase 0 — Research', '', 'The decision, the rationale, and what was rejected.'
    )
    Write-FixtureText -Path (Join-Path $dir 'data-model.md') -Lines @(
        '# Phase 1 — Data model', '', 'One entity, three fields.'
    )
    Write-FixtureText -Path (Join-Path $dir 'contracts/api.md') -Lines @(
        '# Contract: the widget interface', '', 'C1. A widget answers to its own name.'
    )
    Write-FixtureText -Path (Join-Path $dir 'checklists/requirements.md') -Lines @(
        '# Checklist: requirements', '', '- [x] Scope is bounded'
    )
    Write-BinaryArtifact -Path (Join-Path $dir 'assets/diagram.png')

    # Excluded by .git/info/exclude: neither may appear in the artifact set
    # (FR-007). Two shapes, because a rule can match a suffix or a directory.
    Write-FixtureText -Path (Join-Path $dir 'editor.log') -Lines @('editor noise, not an artifact')
    Write-FixtureText -Path (Join-Path $dir 'scratch/notes.md') -Lines @('local scratch, not an artifact')

    return $dir
}

function Get-ArtifactFixtureExpectedPath {
    <#
    .SYNOPSIS
      The sorted relative paths the artifact set must contain.
    #>
    return $script:ArtifactPaths
}

function Get-ArtifactFixtureExpectedName {
    <#
    .SYNOPSIS
      The flattened attachment names, in the same order.
    #>
    return $script:ArtifactNames
}

function New-WideArtifactFixture {
    <#
    .SYNOPSIS
      A feature directory holding <Count> artifacts, for the process-budget and
      argv-size assertions.
    #>
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][int] $Count
    )

    if (-not (Test-Path -LiteralPath (Join-Path $Root '.git'))) { New-ArtifactRepo -Root $Root }
    $dir = Join-Path $Root "specs/$Name"
    New-Item -ItemType Directory -Path (Join-Path $dir 'contracts') -Force | Out-Null
    Write-FixtureText -Path (Join-Path $dir 'spec.md') -Lines @('# Feature Specification: Wide')
    for ($i = 0; $i -lt $Count; $i++) {
        $n = '{0:d3}' -f $i
        Write-FixtureText -Path (Join-Path $dir "contracts/c$n.md") -Lines @("contract $n")
    }
    return $dir
}

Export-ModuleMember -Function New-ArtifactRepo, Write-BinaryArtifact, New-ArtifactFixture,
Get-ArtifactFixtureExpectedPath, Get-ArtifactFixtureExpectedName, New-WideArtifactFixture,
Write-FixtureText
