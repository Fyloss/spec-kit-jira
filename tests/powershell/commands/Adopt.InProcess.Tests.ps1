# T177 [003] — In-process coverage of the adopt command (Constitution XIII).
#
# The other adopt suites drive the command through a CHILD PROCESS, because that
# is the only way to assert the real dispatcher's exit code and [Console] stream
# contract. Pester's coverage instrumentation cannot follow an execve'd child,
# though, so those runs measure nothing — the same blind spot the Bash port
# documents for kcov, and which it works around with an in-process seam.
#
# This suite is that seam for the PowerShell port: it calls Invoke-JiraAdopt
# DIRECTLY, redirecting the console streams, so every branch it exercises is
# both asserted and measured. The behaviour asserted here is deliberately the
# same behaviour the child-process suites assert, so the two cannot drift.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    Import-Module (Join-Path $script:Root 'scripts/powershell/commands/Adopt.psm1') -Force
    Import-Module (Join-Path $script:Root 'tests/conformance/mock-jira/Mock.psm1') -Force

    $script:Full = @'
{"projects":{"ADO":"company"},"issues":{
  "ADO-1":{"labels":["speckit-adopt:003-label-based-adoption"]},
  "ADO-2":{"labels":["speckit-adopt:003-label-based-adoption:us1"],"parent":"ADO-1"},
  "ADO-3":{"labels":["speckit-adopt:003-label-based-adoption:us2"],"parent":"ADO-1"},
  "ADO-4":{"labels":["speckit-adopt:004-billing-export"]},
  "ADO-5":{"labels":["speckit-adopt:004-billing-export:us1"],"parent":"ADO-4"},
  "ADO-6":{"labels":["speckit-adopt:005-audit-trail"]},
  "ADO-7":{"labels":["speckit-adopt:005-audit-trail:us1"],"parent":"ADO-6"}}}
'@
    $script:Mixed = @'
{"projects":{"ADO":"company"},"issues":{
  "ADO-1":{"labels":["speckit-adopt:003-label-based-adoption"]},
  "ADO-2":{"labels":["speckit-adopt:003-label-based-adoption:us1"],"parent":"ADO-1"},
  "ADO-8":{"labels":["speckit-adopt:004-billing-export"]},
  "ADO-9":{"labels":["speckit-adopt:004-billing-export"]}}}
'@

    function New-Workdir {
        param([string] $Fixture = 'repo-with-adoption')
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Copy-Item -Recurse -Force -Path (Join-Path $script:Root "tests/conformance/fixtures/$Fixture/*") -Destination $d
        return $d
    }

    function Invoke-InProcess {
        # Call the command directly, capturing what it writes to the console
        # streams, and return { ExitCode; StdOut; StdErr }.
        param([string[]] $AdoptArgs = @(), [string] $Workdir = $script:Work)
        $out = [System.IO.StringWriter]::new()
        $err = [System.IO.StringWriter]::new()
        $origOut = [Console]::Out
        $origErr = [Console]::Error
        [Console]::SetOut($out)
        [Console]::SetError($err)
        # Push-Location moves PowerShell's location but NOT the .NET process
        # working directory, which is what a relative path handed to
        # System.IO resolves against. A child process gets both for free; in
        # process they have to be moved together or a relative config path
        # resolves against the repository root instead of the workdir.
        $origCwd = [System.Environment]::CurrentDirectory
        Push-Location $Workdir
        [System.Environment]::CurrentDirectory = (Get-Location).ProviderPath
        try { $code = Invoke-JiraAdopt -Arguments $AdoptArgs }
        finally {
            Pop-Location
            [System.Environment]::CurrentDirectory = $origCwd
            [Console]::SetOut($origOut)
            [Console]::SetError($origErr)
        }
        return [pscustomobject]@{ ExitCode = [int]$code; StdOut = $out.ToString(); StdErr = $err.ToString() }
    }

    function Get-PutCount {
        return @((Get-JiraMockCallLog -Mock $script:Mock) | Where-Object { $_ -like 'PUT *' }).Count
    }

    # Defined HERE, not inside Describe: Pester 5 resolves helper functions from
    # the BeforeAll scope only.
    function Start-Corpus {
        param([string] $Json)
        $script:Mock = Start-JiraMock -ConfigJson $Json
        $env:SPEC_KIT_JIRA_BASE_URL = $script:Mock.BaseUrl
    }
}

Describe 'adopt, driven in process' {
    BeforeEach {
        $script:Work = New-Workdir
        $env:JIRA_EMAIL = 'user@example.com'
        $env:JIRA_API_TOKEN = 'RAWSECRETXYZ'
        $env:JIRA_NO_SLEEP = '1'
        $env:SPEC_KIT_JIRA_REPO = 'acme/app'
    }
    AfterEach {
        if ($script:Mock) { Stop-JiraMock -Mock $script:Mock; $script:Mock = $null }
        Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
        foreach ($v in @('SPEC_KIT_JIRA_BASE_URL', 'SPEC_KIT_JIRA_ADOPT_ANSWER', 'JIRA_CONFIG_DIR')) {
            Remove-Item "env:$v" -ErrorAction SilentlyContinue
        }
    }

    It 'reports a CLI usage error without touching Jira' {
        Start-Corpus $script:Full
        $r = Invoke-InProcess @('--nonsense')
        $r.ExitCode | Should -Be 1
        $r.StdErr | Should -BeLike '*adopt:*'
        @(Get-JiraMockCallLog -Mock $script:Mock).Count | Should -Be 0
    }

    It 'short-circuits at the enablement gate with zero reads' {
        Start-Corpus $script:Full
        $env:JIRA_CONFIG_DIR = '.specify/jira-disabled'
        $r = Invoke-InProcess @('--yes', '--json')
        $r.ExitCode | Should -Be 4
        $r.StdErr | Should -BeLike '*adoption.enabled*'
        @(Get-JiraMockCallLog -Mock $script:Mock).Count | Should -Be 0
        ($r.StdOut | ConvertFrom-Json).adoption.enabled | Should -BeFalse
    }

    It 'refuses an invalid label prefix before anything is searched' {
        Start-Corpus $script:Full
        $env:JIRA_CONFIG_DIR = '.specify/jira-invalid-prefix'
        $r = Invoke-InProcess @('--yes', '--json')
        $r.ExitCode | Should -Be 4
        $r.StdErr | Should -BeLike '*label_prefix*'
        @(Get-JiraMockCallLog -Mock $script:Mock).Count | Should -Be 0
    }

    It 'prints the prose plan and writes nothing on --dry-run' {
        Start-Corpus $script:Full
        $r = Invoke-InProcess @('--dry-run')
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -BeLike 'Adoption plan*'
        $r.StdOut | Should -BeLike '*Actions:*'
        $r.StdOut | Should -BeLike '*Dry run: nothing was written.*'
        Get-PutCount | Should -Be 0
    }

    It 'stamps every binding with --yes and emits the JSON summary' {
        Start-Corpus $script:Full
        $r = Invoke-InProcess @('--yes', '--json')
        $r.ExitCode | Should -Be 0
        Get-PutCount | Should -Be 7
        $j = $r.StdOut | ConvertFrom-Json
        $j.command | Should -Be 'adopt'
        @($j.actions).Count | Should -Be 7
    }

    It 'applies on an affirmative answer and prints the prompt' {
        Start-Corpus $script:Full
        $env:SPEC_KIT_JIRA_ADOPT_ANSWER = 'y'
        $r = Invoke-InProcess @()
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -BeLike '*Apply this plan?*'
        Get-PutCount | Should -Be 7
    }

    It 'cancels on a decline, with zero writes' {
        Start-Corpus $script:Full
        $env:SPEC_KIT_JIRA_ADOPT_ANSWER = 'n'
        $r = Invoke-InProcess @()
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -BeLike '*Adoption cancelled*'
        Get-PutCount | Should -Be 0
    }

    It 'names --yes when there is no terminal and no answer' {
        Start-Corpus $script:Full
        $r = Invoke-InProcess @()
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -BeLike '*no terminal is attached*'
        Get-PutCount | Should -Be 0
    }

    It 'renders refusals with their remediation and exits 4' {
        Start-Corpus $script:Mixed
        $r = Invoke-InProcess @('--yes')
        $r.ExitCode | Should -Be 4
        $r.StdOut | Should -BeLike '*REFUSED*'
        $r.StdOut | Should -BeLike '*remediation: *'
        # The mixed corpus labels 003's feature and its first story only, so two
        # bindings apply while every other target refuses.
        Get-PutCount | Should -Be 2
    }

    It 'renders an already-adopted binding as skipped' {
        Start-Corpus '{"projects":{"ADO":"company"},"identity":{"ADO-1":{"origin":"human","repo":"acme/app","spec_slug":"003-label-based-adoption"}},"issues":{"ADO-1":{"labels":["speckit-adopt:003-label-based-adoption"]}}}'
        $r = Invoke-InProcess @('--yes')
        $r.StdOut | Should -BeLike '*already adopted*'
    }

    It 'reports the out-of-scope folders and reads nothing for them' {
        Start-Corpus $script:Full
        $r = Invoke-InProcess @('--spec', '003-label-based-adoption', '--dry-run')
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -BeLike '*out of scope: 004-billing-export, 005-audit-trail*'
    }

    It 'stops on an unknown --spec folder before anything is read' {
        Start-Corpus $script:Full
        $r = Invoke-InProcess @('--spec', '009-never-on-disk', '--yes')
        $r.ExitCode | Should -Be 1
        $r.StdErr | Should -BeLike '*009-never-on-disk*'
        @(Get-JiraMockCallLog -Mock $script:Mock).Count | Should -Be 0
    }

    It 'stops on an unknown --bind folder before anything is read' {
        Start-Corpus $script:Full
        $r = Invoke-InProcess @('--bind', '009-never-on-disk=ADO-1', '--yes')
        $r.ExitCode | Should -Be 1
        @(Get-JiraMockCallLog -Mock $script:Mock).Count | Should -Be 0
    }

    It 'resolves a pin, reading the pinned key for its context' {
        Start-Corpus '{"projects":{"ADO":"company"},"issues":{
          "ADO-1":{"labels":["speckit-adopt:003-label-based-adoption"]},
          "ADO-2":{"labels":["speckit-adopt:003-label-based-adoption:us1"],"parent":"ADO-1"},
          "ADO-3":{"labels":["speckit-adopt:003-label-based-adoption:us2"],"parent":"ADO-1"},
          "ADO-4":{"labels":["speckit-adopt:004-billing-export"]},
          "ADO-5":{"labels":["speckit-adopt:004-billing-export:us1"],"parent":"ADO-4"},
          "ADO-6":{"labels":["speckit-adopt:005-audit-trail"]},
          "ADO-99":{"labels":[],"parent":"ADO-6"}}}'
        $r = Invoke-InProcess @('--bind', '005-audit-trail:us1=ADO-99', '--yes', '--json')
        $r.ExitCode | Should -Be 0
        $j = $r.StdOut | ConvertFrom-Json
        @($j.adoption.bindings | Where-Object { $_.issue_key -eq 'ADO-99' -and $_.reason -eq 'explicit-binding' }).Count |
            Should -Be 1
        ((Get-JiraMockCallLog -Mock $script:Mock) -join "`n") |
            Should -BeLike '*GET /rest/api/3/issue/ADO-99?fields=labels,parent,project*'
    }

    It 'propagates a fail-closed discovery read without writing' {
        Start-Corpus '{"projects":{"ADO":"company"},"fault":{"status":401},"issues":{"ADO-1":{"labels":["speckit-adopt:003-label-based-adoption"]}}}'
        $r = Invoke-InProcess @('--yes')
        $r.ExitCode | Should -Be 3
        Get-PutCount | Should -Be 0
    }

    It 'returns exit 9 with zero writes when the privacy guard blocks' {
        Start-Corpus $script:Full
        $env:SPEC_KIT_JIRA_REPO = 'acme/mirror-of-acme.atlassian.net'
        $r = Invoke-InProcess @('--yes')
        $r.ExitCode | Should -Be 9
        Get-PutCount | Should -Be 0
    }

    It 'fails closed when the site is unset' {
        $script:Mock = Start-JiraMock -ConfigJson $script:Full
        Remove-Item env:SPEC_KIT_JIRA_BASE_URL -ErrorAction SilentlyContinue
        $r = Invoke-InProcess @('--dry-run')
        $r.ExitCode | Should -Be 2
    }

    It 'refuses a missing configuration with exit 4' {
        Start-Corpus $script:Full
        $bare = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $bare -Force | Out-Null
        try {
            (Invoke-InProcess -AdoptArgs @('--dry-run') -Workdir $bare).ExitCode | Should -Be 4
        }
        finally { Remove-Item -Recurse -Force $bare -ErrorAction SilentlyContinue }
    }
}
