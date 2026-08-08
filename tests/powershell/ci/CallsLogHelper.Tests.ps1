# T004 — Pester twin of tests/bash/ci/test_calls_log_helper.bats.
# Guard for tests/powershell/helpers/CallsLog.psm1.
#
# Every request-count claim in feature 021 is read through this helper. If it
# miscounts, those tests pass while the product regresses, so the helper needs
# its own failing test before anything depends on it. The three cases that
# would actually bite: an absent log (a short-circuited run, must read as
# zero, not as an error), a Windows-authored log carrying CR line endings, and
# a trailing line with no final newline.

BeforeAll {
    $ModuleDir = Join-Path $PSScriptRoot '../helpers'
    Import-Module (Join-Path $ModuleDir 'CallsLog.psm1') -Force
}

Describe 'CallsLog helper' {
    BeforeEach {
        $script:TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:TmpDir | Out-Null
        $script:Log = Join-Path $script:TmpDir 'calls.log'
    }

    AfterEach {
        if (Test-Path $script:TmpDir) { Remove-Item -Recurse -Force $script:TmpDir }
    }

    It 'an absent calls.log counts as zero requests, not as an error' {
        Get-CallsLogTotal -Path (Join-Path $script:TmpDir 'nope.log') | Should -Be 0
    }

    It 'an empty calls.log counts as zero requests' {
        Set-Content -LiteralPath $script:Log -Value $null -NoNewline
        Get-CallsLogTotal -Path $script:Log | Should -Be 0
    }

    It 'each request line counts once' {
        [System.IO.File]::WriteAllText($script:Log, "GET /rest/api/3/issue/PROJ-1`nGET /rest/api/3/issue/PROJ-2`nPOST /rest/api/3/issue`n")
        Get-CallsLogTotal -Path $script:Log | Should -Be 3
    }

    It 'a final line without a trailing newline still counts' {
        [System.IO.File]::WriteAllText($script:Log, "GET /a`nGET /b")
        Get-CallsLogTotal -Path $script:Log | Should -Be 2
    }

    It 'blank lines are not requests' {
        [System.IO.File]::WriteAllText($script:Log, "GET /a`n`n`nGET /b`n")
        Get-CallsLogTotal -Path $script:Log | Should -Be 2
    }

    It 'a CRLF-authored log counts the same as an LF one' {
        [System.IO.File]::WriteAllText($script:Log, "GET /a`r`nGET /b`r`n")
        Get-CallsLogTotal -Path $script:Log | Should -Be 2
    }

    It 'the carriage return is stripped from the target, so a match is not defeated by it' {
        [System.IO.File]::WriteAllText($script:Log, "POST /rest/api/3/issue/bulkfetch`r`n")
        Get-CallsLogMatchCount -Path $script:Log -Substring '/rest/api/3/issue/bulkfetch' | Should -Be 1
    }

    It 'Get-CallsLogMatchCount counts only the lines carrying the substring' {
        [System.IO.File]::WriteAllText($script:Log, "GET /rest/api/3/issue/PROJ-1`nPOST /rest/api/3/issue/bulkfetch`nGET /rest/api/3/issue/PROJ-2`n")
        Get-CallsLogMatchCount -Path $script:Log -Substring 'bulkfetch' | Should -Be 1
        Get-CallsLogMatchCount -Path $script:Log -Substring 'GET /rest/api/3/issue/' | Should -Be 2
    }

    It 'Get-CallsLogMatchCount returns zero for a target never requested' {
        [System.IO.File]::WriteAllText($script:Log, "GET /a`n")
        Get-CallsLogMatchCount -Path $script:Log -Substring 'bulkfetch' | Should -Be 0
    }

    It 'Get-CallsLogByPath tabulates each distinct request once, with its count' {
        [System.IO.File]::WriteAllText($script:Log, "GET /b`nGET /a`nGET /b`n")
        $result = @(Get-CallsLogByPath -Path $script:Log)
        $result[0] | Should -Be "1`tGET /a"
        $result[1] | Should -Be "2`tGET /b"
    }

    It 'Get-CallsLogByPath is deterministic: request order does not change its output' {
        [System.IO.File]::WriteAllText($script:Log, "GET /b`nGET /a`nGET /b`n")
        $first = @(Get-CallsLogByPath -Path $script:Log)
        [System.IO.File]::WriteAllText($script:Log, "GET /b`nGET /b`nGET /a`n")
        $second = @(Get-CallsLogByPath -Path $script:Log)
        ($second -join "`n") | Should -Be ($first -join "`n")
    }
}
