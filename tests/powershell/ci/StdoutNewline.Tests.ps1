# #46 D3 — stdout is written with an explicit LF, never with WriteLine.
#
# `[Console]::Out` is a TextWriter whose NewLine is `[Environment]::NewLine`:
# CRLF on Windows, LF everywhere else. So `WriteLine` emits two bytes on one
# host and one byte on another, while the Bash twin's `printf` emits LF on
# every host. That is a byte divergence on stdout — the first artifact
# ci-conformance.sh compares — and it produces no error on either side, so it
# is invisible in stderr and renders IDENTICALLY in a `diff`. Only `cmp` sees
# it. Measured on Windows 2026-08-22, us2-field-defaults-question:
#
#     stdout: sizes bash=414 pwsh=415 — differ at byte 414
#       bash tail: … 70 65 6e 64 69 6e 67 22 7d 0a
#       pwsh tail: … 70 65 6e 64 69 6e 67 22 7d 0d 0a
#
# The port's own idiom everywhere else is an explicit LF:
#
#     [Console]::Out.Write($Payload + "`n")     — Feature.psm1, Config.psm1, …
#
# WHY LEXICAL, AND WHY IT IS SOUND
#
# This one cannot be reproduced off Windows: Environment.NewLine IS LF on
# macOS and Linux, so the defective call and the correct one emit the same
# bytes there. A behavioural twin would be green on the maintainer's machine
# whether or not the defect is present — the failure mode §13 of the handoff
# names. So the rule is pinned lexically instead, which is sound here because
# the forbidden spelling has no legitimate use in this port: stdout owes byte
# parity, and only an explicit `\n` can promise it on every host.
#
# When this guard was written there were exactly THREE `[Console]::Out.WriteLine`
# calls in the whole port and all three were the defect — 2086 on the `--json`
# branch (the one two conformance scenarios caught) and 2090-2091 on the prose
# branch, which no scenario covers and which would otherwise have shipped
# uncaught. Red before the fix by construction, silent after.
#
# stderr is deliberately NOT covered: ci-conformance.sh never compares it —
# "the two ports owe each other byte-identical stdout, exit code, call
# sequence and written tree, never identically phrased diagnostics" — and the
# port has 110 `[Console]::Error.WriteLine` calls that are perfectly correct.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:PortFiles = @(
        Get-ChildItem -LiteralPath (Join-Path $script:Root 'scripts/powershell') `
            -Recurse -File -Include '*.psm1', '*.ps1'
    )
}

Describe 'the PowerShell port never lets the host choose stdout''s line terminator (#46 D3)' {

    It 'has port files to inspect' {
        # A guard whose subject list came back empty passes vacuously. Pin the
        # subject before pinning the rule.
        $script:PortFiles.Count | Should -BeGreaterThan 20
    }

    It 'calls [Console]::Out.WriteLine nowhere' {
        $bad = $script:PortFiles | ForEach-Object {
            Select-String -LiteralPath $_.FullName -Pattern '\[Console\]::Out\.WriteLine'
        } | Where-Object { $_ }

        if ($bad) {
            $detail = ($bad | ForEach-Object {
                    '{0}:{1}: {2}' -f (Resolve-Path -Relative $_.Path), $_.LineNumber, $_.Line.Trim()
                }) -join "`n"
            throw ("stdout is written with WriteLine, whose terminator is the HOST's " +
                "(CRLF on Windows) — the Bash twin writes LF on every host:`n$detail`n" +
                'Use [Console]::Out.Write($x + "`n").')
        }
    }

    It 'writes stdout through the explicit-LF idiom instead' {
        # The positive half: forbidding a spelling passes just as well when the
        # call site is deleted altogether.
        $writes = $script:PortFiles | ForEach-Object {
            Select-String -LiteralPath $_.FullName -Pattern '\[Console\]::Out\.Write\('
        } | Where-Object { $_ }
        $writes.Count | Should -BeGreaterThan 5
    }
}
