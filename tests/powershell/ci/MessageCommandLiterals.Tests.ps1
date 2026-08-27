# T045 [US5] — Every command literal in every message is runnable as spelled,
# PowerShell port. Twin of tests/bash/ci/test_message_command_literals.bats,
# over `scripts/powershell/**` and `commands/*.md` (FR-018, SC-009).
#
# The reported defect told the developer to run `/speckit-jira-conifg`. That
# command resolves to nothing. It was never in this repository — the assistant
# composed it — but the same class of error is committed too, and nothing checked
# for it: a command name is just a string in a `WriteLine`, and a wrong one only
# fails in front of a user.
#
# FR-018 names three classes of literal and all three are checked here:
#   (a) an assistant command of this extension — must match a declared name;
#   (b) an invocation of the bridge — must be the repository-relative per-port
#       form, never a bare executable name (the install puts nothing on PATH);
#   (c) a host command — must be given in the form the operator actually runs.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:ManifestLines = (Get-Content -Raw -LiteralPath (Join-Path $script:Root 'extension.yml')) -split "`r?`n"

    # Files in scope: every PowerShell port module, every command document, and
    # the documentation the install SHIPS — the managed README block template
    # lands in every consuming repository, and README.md / INSTALL.md are where an
    # operator copies a command from before any of our code has run. A wrong
    # literal there fails in front of exactly the user who has no way to know
    # better.
    $script:Scope = @()
    $script:Scope += Get-ChildItem -LiteralPath (Join-Path $script:Root 'scripts/powershell') -Recurse -Include '*.psm1', '*.ps1' -File
    $script:Scope += Get-ChildItem -LiteralPath (Join-Path $script:Root 'commands') -Filter '*.md' -File
    $script:Scope += Get-ChildItem -LiteralPath (Join-Path $script:Root 'templates') -Filter '*.template' -File
    $script:Scope += Get-Item -LiteralPath (Join-Path $script:Root 'README.md'), (Join-Path $script:Root 'INSTALL.md')

    function Get-DeclaredCommands {
        $out = [System.Collections.Generic.List[string]]::new()
        $inProvides = $false
        foreach ($line in $script:ManifestLines) {
            if ($line -match '^provides:') { $inProvides = $true; continue }
            if ($inProvides -and $line -match '^[^\s#]') { $inProvides = $false }
            if ($inProvides -and $line -match '^\s+- name:\s*(\S+)\s*$') { $out.Add($Matches[1]) }
        }
        return $out.ToArray()
    }

    function Select-ScopeLine {
        # Every line of every in-scope file, with its origin, optionally excluding
        # comment lines.
        param([switch] $ExcludeComments)
        foreach ($f in $script:Scope) {
            $n = 0
            foreach ($line in ((Get-Content -Raw -LiteralPath $f.FullName) -split "`r?`n")) {
                $n++
                if ($ExcludeComments -and $line -match '^\s*#') { continue }
                [pscustomobject]@{ File = $f.FullName; Line = $n; Text = $line }
            }
        }
    }
}

Describe '(a) Assistant commands' {
    It 'matches every /speckit.jira-mirror.* literal to a declared command name' {
        $declared = Get-DeclaredCommands
        $declared.Count | Should -BeGreaterThan 0
        foreach ($row in (Select-ScopeLine)) {
            foreach ($m in [regex]::Matches($row.Text, '/?speckit\.jira-mirror\.[a-z0-9_-]+')) {
                $name = $m.Value.TrimStart('/')
                if ($declared -notcontains $name) {
                    throw "message names an undeclared command '$name' at $($row.File):$($row.Line)"
                }
            }
        }
    }

    It 'never uses the hyphenated /speckit-jira-* form — it resolves to nothing' {
        # This is the exact shape of the reported `/speckit-jira-conifg`: the agent
        # substitutes hyphens for dots when recalling a name from memory, and the
        # result is not a command. Only the dotted form is ever registered.
        foreach ($row in (Select-ScopeLine)) {
            $row.Text | Should -Not -Match '/speckit-jira-[a-z0-9-]+'
        }
    }
}

Describe '(b) Bridge invocations' {
    It 'gives every bridge invocation in the repository-relative per-port form (FR-014)' {
        # An invocation is the bridge name followed by one of its subcommands. The
        # allowed forms are the two entry-point paths and nothing else; a bare name
        # is exactly the assumption that produced the reported defect.
        foreach ($row in (Select-ScopeLine)) {
            if ($row.Text -match '(^|[^/])spec-kit-jira(\.sh|\.ps1)?\s+(config|reconcile|mention|feature)\b') {
                throw "bridge invoked by a bare name at $($row.File):$($row.Line): $($row.Text.Trim())"
            }
        }
    }

    It 'finds both named entry points at the paths the messages spell' {
        Test-Path -LiteralPath (Join-Path $script:Root 'scripts/bash/spec-kit-jira.sh') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Root 'scripts/powershell/spec-kit-jira.ps1') | Should -BeTrue
    }

    It 'names no --repair-hooks flag outside a comment — it no longer exists (T073)' {
        # It was removed because it existed only to write the hook registry, which
        # FR-022 forbids. A message naming a flag that is now a usage error would
        # be the worst of both worlds. Comments explaining WHY it is gone are
        # exempt: they are what stops it being reintroduced.
        foreach ($row in (Select-ScopeLine -ExcludeComments)) {
            $row.Text | Should -Not -Match 'repair-hooks'
        }
    }
}

Describe '(c) Host commands' {
    It "spells every 'specify extension add' instruction as the operator runs it" {
        # An INSTRUCTION carries arguments; a bare mention inside prose that
        # explains what the host does is a reference, not something to copy and
        # run, so only the argument-carrying occurrences are checked. Two runnable
        # forms exist and both are accepted: the archive install an operator of a
        # consuming repository runs, and the dev install with --force, which is
        # what someone working on the extension itself runs. Anything else is a
        # third spelling nobody can execute.
        $runnable = @(
            'specify extension add --dev <path-to-spec-kit-jira> --force'
            'specify extension add jira-mirror --from https://github.com/Fyloss/spec-kit-jira-mirror/releases/latest/download/spec-kit-jira-mirror.zip --force'
            'specify extension add jira-mirror --from https://github.com/Fyloss/spec-kit-jira-mirror/releases/latest/download/spec-kit-jira-mirror.zip'
            'specify extension add jira-mirror --from https://github.com/Fyloss/spec-kit-jira-mirror/releases/download/v<X.Y.Z>/spec-kit-jira-mirror-<X.Y.Z>.zip'
        )
        foreach ($row in (Select-ScopeLine)) {
            if ($row.Text -match 'specify extension add\s+[^`]') {
                $ok = $false
                foreach ($form in $runnable) { if ($row.Text.Contains($form)) { $ok = $true; break } }
                if (-not $ok) {
                    throw "host install command not in a runnable form at $($row.File):$($row.Line): $($row.Text.Trim())"
                }
            }
        }
    }
}

Describe 'The literals the reader emits at runtime' {
    BeforeAll {
        Import-Module (Join-Path $script:Root 'scripts/powershell/hooks/RegisterHooks.psm1') -Force
    }

    It 'passes all three classes for every repair hint (FR-018)' {
        # The hint strings are assembled at runtime from constants, so checking the
        # source is not quite checking the message. Build each one and check it.
        $work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        try {
            # missing -> the official install command, in its runnable form.
            $h = Get-JiraHookHealth -Path (Join-Path $work 'absent.yml') | ConvertFrom-Json
            $h.repair_hint | Should -Match ([regex]::Escape('specify extension add jira-mirror --from https://github.com/Fyloss/spec-kit-jira-mirror/releases/latest/download/spec-kit-jira-mirror.zip --force'))

            # held disabled -> the release flag on a declared command.
            $empty = Join-Path $work 'e.yml'
            [System.IO.File]::WriteAllText($empty, "hooks: {}`n", (New-Object System.Text.UTF8Encoding($false)))
            $h = Get-JiraHookHealth -Path $empty -DisabledJson '["after_plan"]' | ConvertFrom-Json
            $h.repair_hint | Should -Match ([regex]::Escape('/speckit.jira-mirror.config --enable-hook after_plan'))
            (Get-DeclaredCommands) | Should -Contain 'speckit.jira-mirror.config'

            # No hint may contain a bare bridge invocation.
            $h.repair_hint | Should -Not -Match '(^|[^/])spec-kit-jira(\.sh|\.ps1)?\s+(config|reconcile)'
        }
        finally { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
    }
}
