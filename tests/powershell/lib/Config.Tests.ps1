# T028 [US4] — Config storage layer, PowerShell side. Mirror of
# tests/bash/lib/test_config.bats. Cross-port byte-parity of the YAML->JSON
# output and the version reader is proven in the bats suite.

BeforeAll {
    $LibDir = Join-Path $PSScriptRoot '../../../scripts/powershell/lib'
    Import-Module (Join-Path $LibDir 'Config.psm1') -Force
    $script:ExtYml = Join-Path $PSScriptRoot '../../../extension.yml'

    function New-TempConfigDir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        return $d
    }

    function Get-CanonicalJson {
        # Key-order-independent canonicalisation for equality checks — mirror
        # of the bats tests' `jq -cS .`. ConvertTo-Json preserves the parsed
        # property order, which the writer legitimately reorders (ordinal sort).
        param([string] $Json)
        return ($Json | & jq -cS .)
    }

    $script:ValidTeam = @'
# Team config (committable, credential-free).
projects:
  - key: PROJ
    style: company_managed
    issue_types:
      Epic: "10001"
      Story: "10002"
    priority_map:
      P1: Highest
      P2: Medium
      P3: Low
routing:
  - match:
      folder_prefix: "billing-"
    project: PROJ
routing_default: PROJ
privacy:
  allowlist:
    - support.example.atlassian.net
'@
}

Describe 'Get-JiraExtensionVersion' {
    It 'reads the version field from extension.yml (single source)' {
        $expected = (Select-String -Path $script:ExtYml -Pattern '^\s+version:\s*(.+)$').Matches[0].Groups[1].Value.Trim()
        Get-JiraExtensionVersion | Should -Be $expected
    }
}

Describe 'Assert-JiraSingleVersionSource' {
    It 'rejects a stray version marker (exit 4)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'VERSION') -Value '0.9.9'
        $env:JIRA_CONFIG_DIR = $d
        try { Assert-JiraSingleVersionSource | Should -Be 4 }
        finally { Remove-Item env:JIRA_CONFIG_DIR; Remove-Item -Recurse -Force $d }
    }
    It 'passes when no stray marker exists' {
        $d = New-TempConfigDir
        $env:JIRA_CONFIG_DIR = $d
        try { Assert-JiraSingleVersionSource | Should -Be 0 }
        finally { Remove-Item env:JIRA_CONFIG_DIR; Remove-Item -Recurse -Force $d }
    }
}

Describe 'ConvertFrom-JiraConfigYaml' {
    It 'parses mappings, sequences, and quoted scalars into canonical JSON' {
        $d = New-TempConfigDir
        $f = Join-Path $d 'config.yml'
        Set-Content -Path $f -Value $script:ValidTeam -NoNewline
        $json = ConvertFrom-JiraConfigYaml -Path $f
        $o = $json | ConvertFrom-Json
        $o.routing_default | Should -Be 'PROJ'
        $o.projects[0].style | Should -Be 'company_managed'
        $o.projects[0].issue_types.Epic | Should -Be '10001'
        $o.privacy.allowlist[0] | Should -Be 'support.example.atlassian.net'
        Remove-Item -Recurse -Force $d
    }

    It 'coerces true/false to JSON booleans' {
        $d = New-TempConfigDir
        $f = Join-Path $d 'c.yml'
        Set-Content -Path $f -Value "generation:`n  design_section: false`n" -NoNewline
        $json = ConvertFrom-JiraConfigYaml -Path $f
        $json | Should -Be '{"generation":{"design_section":false}}'
        Remove-Item -Recurse -Force $d
    }

    It "keeps a map key with an apostrophe (a Won't Do status) in the round-trip" {
        # Regression (002 US1): keys sorted after an apostrophe key (style,
        # style_source) were dropped by the reader. Twin of the bats test.
        $d = New-TempConfigDir
        $f = Join-Path $d 'local.yml'
        $yaml = ConvertTo-JiraConfigYaml -Json '{"resolved_ids":{"TEAM":{"statuses":{"Done":"13","Won''t Do":"14"},"style":"team_managed","style_source":"api"}}}'
        [System.IO.File]::WriteAllText($f, $yaml + "`n")
        $obj = (ConvertFrom-JiraConfigYaml -Path $f) | ConvertFrom-Json
        $obj.resolved_ids.TEAM.statuses."Won't Do" | Should -Be '14'
        $obj.resolved_ids.TEAM.style | Should -Be 'team_managed'
        $obj.resolved_ids.TEAM.style_source | Should -Be 'api'
        Remove-Item -Recurse -Force $d
    }

    # --- Unicode and punctuated mapping keys (007, contracts/yaml-key-grammar.md) -

    It "the bug report's own document round-trips whole (007 FR-002, FR-004)" {
        $d = New-TempConfigDir
        $f = Join-Path $d 'rt.yml'
        $input = '{"resolved_ids":{"JET":{"issue_types":{"R' + [char]0xE9 + 'cit":"10004","Story":"10005"},"priorities":{"Faible":"4","' + [char]0xC9 + 'lev' + [char]0xE9 + 'e' + '":"1"},"statuses":{"Termin' + [char]0xE9 + '":"10002","Won''t Do":"10004","' + [char]0xC0 + ' faire":"10001","' + [char]0x5B8C + [char]0x4E86 + '":"10003"},"style":"company_managed"}}}'
        $yaml = ConvertTo-JiraConfigYaml -Json $input
        [System.IO.File]::WriteAllText($f, $yaml + "`n")
        $back = ConvertFrom-JiraConfigYaml -Path $f
        (Get-CanonicalJson $input) | Should -Be (Get-CanonicalJson $back)
        Remove-Item -Recurse -Force $d
    }

    It 'keys in four different scripts read back bare (007 FR-002)' {
        $d = New-TempConfigDir
        $f = Join-Path $d 'scripts.yml'
        $content = "Gr" + [char]0xF6 + "e: `"3`"`n" +
        [char]0x41F + [char]0x440 + [char]0x438 + [char]0x43E + [char]0x440 + [char]0x438 + [char]0x442 + [char]0x435 + [char]0x442 + ': "2"' + "`n" +
        [char]0x5B8C + [char]0x4E86 + ': "10003"' + "`n" +
        'Done (QA): "10005"' + "`n" +
        'high/low: "6"' + "`n"
        [System.IO.File]::WriteAllText($f, $content, (New-Object System.Text.UTF8Encoding($false)))
        $obj = (ConvertFrom-JiraConfigYaml -Path $f) | ConvertFrom-Json
        $obj.('Gr' + [char]0xF6 + 'e') | Should -Be '3'
        $obj.([char]0x41F + [char]0x440 + [char]0x438 + [char]0x43E + [char]0x440 + [char]0x438 + [char]0x442 + [char]0x435 + [char]0x442) | Should -Be '2'
        $obj.([char]0x5B8C + [char]0x4E86) | Should -Be '10003'
        $obj.'Done (QA)' | Should -Be '10005'
        $obj.'high/low' | Should -Be '6'
        Remove-Item -Recurse -Force $d
    }

    It 'a bare apostrophe key still parses (guards the non-quote-aware bare scan, 007 R1)' {
        $d = New-TempConfigDir
        $f = Join-Path $d 'apos.yml'
        Set-Content -Path $f -Value "Won't Do: `"7`"" -NoNewline
        $obj = (ConvertFrom-JiraConfigYaml -Path $f) | ConvertFrom-Json
        $obj.'Won''t Do' | Should -Be '7'
        Remove-Item -Recurse -Force $d
    }

    It 'a bare URL value is still a scalar, not a key (007 FR-003)' {
        $d = New-TempConfigDir
        $f = Join-Path $d 'url.yml'
        Set-Content -Path $f -Value 'site: https://example.atlassian.net' -NoNewline
        $obj = (ConvertFrom-JiraConfigYaml -Path $f) | ConvertFrom-Json
        $obj.site | Should -Be 'https://example.atlassian.net'
        Remove-Item -Recurse -Force $d
    }

    It 'keys requiring writer quoting survive the write-read round trip (007 FR-004, FR-005)' {
        $d = New-TempConfigDir
        $f = Join-Path $d 'quoted.yml'
        $input = '{"a":{"Blocked: waiting on QA":"5","Sprint # 2":"6","- pending":"7","  padded  ":"8"}}'
        $yaml = ConvertTo-JiraConfigYaml -Json $input
        [System.IO.File]::WriteAllText($f, $yaml + "`n")
        $back = ConvertFrom-JiraConfigYaml -Path $f
        (Get-CanonicalJson $input) | Should -Be (Get-CanonicalJson $back)
        Remove-Item -Recurse -Force $d
    }

    It 'every emitted key is double-quoted (007 contract yaml-key-grammar.md section 2.1)' {
        $yaml = ConvertTo-JiraConfigYaml -Json ('{"a":{"' + [char]0xC9 + 'lev' + [char]0xE9 + 'e":"1"}}')
        $yaml | Should -Match ('"' + [char]0xC9 + 'lev' + [char]0xE9 + 'e": "1"')
    }

    # --- Escape decoding (013, contracts/yaml-string-escaping.md §2) --------

    It 'a quoted-legacy escaped sequence item decodes to the label with an embedded quote (013 contract §2.4)' {
        $d = New-TempConfigDir
        $f = Join-Path $d 'a.yml'
        Set-Content -Path $f -Value "allowed:`n  - `"Platform \`"legacy\`"`"" -NoNewline
        $obj = (ConvertFrom-JiraConfigYaml -Path $f) | ConvertFrom-Json
        $obj.allowed[0] | Should -Be 'Platform "legacy"'
        Remove-Item -Recurse -Force $d
    }

    It 'a double backslash in a quoted scalar decodes to one backslash (013 contract §2.4)' {
        $d = New-TempConfigDir
        $f = Join-Path $d 'b.yml'
        Set-Content -Path $f -Value 'k: "Delivery\\Platform"' -NoNewline
        $obj = (ConvertFrom-JiraConfigYaml -Path $f) | ConvertFrom-Json
        $obj.k | Should -Be 'Delivery\Platform'
        Remove-Item -Recurse -Force $d
    }

    It 'a trailing escaped backslash does not swallow the closing delimiter (013 contract §2.1 rule 2)' {
        $d = New-TempConfigDir
        $f = Join-Path $d 'c.yml'
        Set-Content -Path $f -Value "allowed:`n  - `"trailing\\`"`n  - `"second`"" -NoNewline
        $obj = (ConvertFrom-JiraConfigYaml -Path $f) | ConvertFrom-Json
        $obj.allowed[0] | Should -Be 'trailing\'
        $obj.allowed[1] | Should -Be 'second'
        Remove-Item -Recurse -Force $d
    }

    It 'an escaped backslash followed by an escaped quote decodes to backslash-quote, two characters (013 contract §2.4)' {
        $d = New-TempConfigDir
        $f = Join-Path $d 'd.yml'
        Set-Content -Path $f -Value 'k: "\\\""' -NoNewline
        $obj = (ConvertFrom-JiraConfigYaml -Path $f) | ConvertFrom-Json
        $obj.k | Should -Be '\"'
        Remove-Item -Recurse -Force $d
    }

    It 'the escaped form decodes identically as a sequence item and as a mapping value (013 contract §2.4)' {
        $d = New-TempConfigDir
        $f = Join-Path $d 'e.yml'
        Set-Content -Path $f -Value "seq:`n  - `"Platform \`"legacy\`"`"`nval: `"Platform \`"legacy\`"`"" -NoNewline
        $obj = (ConvertFrom-JiraConfigYaml -Path $f) | ConvertFrom-Json
        $obj.seq[0] | Should -Be $obj.val
        $obj.val | Should -Be 'Platform "legacy"'
        Remove-Item -Recurse -Force $d
    }

    It 'an escaped quote inside a double-quoted scalar does not end the string at a following # (013 FR-011)' {
        $d = New-TempConfigDir
        $f = Join-Path $d 'tricky.yml'
        Set-Content -Path $f -Value 'tricky: "a \" # b"' -NoNewline
        $obj = (ConvertFrom-JiraConfigYaml -Path $f) | ConvertFrom-Json
        $obj.tricky | Should -Be 'a " # b'
        Remove-Item -Recurse -Force $d
    }

    It 'an escaped quote inside a quoted key is decoded, not treated as the closing delimiter (013 FR-010, contract §2.3)' {
        $d = New-TempConfigDir
        $f = Join-Path $d 'key.yml'
        Set-Content -Path $f -Value '"say \"x\"": v' -NoNewline
        $obj = (ConvertFrom-JiraConfigYaml -Path $f) | ConvertFrom-Json
        $obj.'say "x"' | Should -Be 'v'
        Remove-Item -Recurse -Force $d
    }

    # --- Escape encoding (013, contracts/yaml-string-escaping.md §1) -----------

    It 'a value with an embedded double quote is emitted with the exact escaped bytes (013 contract §1.3)' {
        $yaml = ConvertTo-JiraConfigYaml -Json '{"k":"Platform \"legacy\""}'
        $yaml | Should -Match ([regex]::Escape('"k": "Platform \"legacy\""'))
    }

    It 'a value with a single backslash is emitted doubled (013 contract §1.3)' {
        $yaml = ConvertTo-JiraConfigYaml -Json '{"k":"Delivery\\Platform"}'
        $yaml | Should -Match ([regex]::Escape('"k": "Delivery\\Platform"'))
    }

    It 'a value with both a quote and a backslash is emitted backslash-first (013 contract §1.1, §1.3)' {
        $yaml = ConvertTo-JiraConfigYaml -Json '{"k":"Group \"A\\B\""}'
        $yaml | Should -Match ([regex]::Escape('"k": "Group \"A\\B\""'))
    }

    It 'a value that is exactly backslash-quote round-trips without double-escaping (013 contract §1.3)' {
        $yaml = ConvertTo-JiraConfigYaml -Json '{"k":"\\\""}'
        $yaml | Should -Match ([regex]::Escape('"k": "\\\""'))
    }

    It 'a value with neither character is emitted byte-identically to before this feature (013 contract §1.3)' {
        $yaml = ConvertTo-JiraConfigYaml -Json '{"k":"clean"}'
        $yaml | Should -Match ([regex]::Escape('"k": "clean"'))
    }

    It 'a mapping key containing a double quote is emitted escaped and reads back identical (013 FR-010, FR-014)' {
        $yaml = ConvertTo-JiraConfigYaml -Json '{"say \"hi\"":"1"}'
        $yaml | Should -Match ([regex]::Escape('"say \"hi\""'))
        $d = New-TempConfigDir
        $f = Join-Path $d 'qkey.yml'
        [System.IO.File]::WriteAllText($f, $yaml)
        $obj = (ConvertFrom-JiraConfigYaml -Path $f) | ConvertFrom-Json
        $obj.PSObject.Properties.Name | Should -Be 'say "hi"'
        Remove-Item -Recurse -Force $d
    }

    # --- Round-trip corpus (013, User Story 2, T031) --------------------------

It 'a run of consecutive backslashes is preserved in count after a round trip (013 FR-006, edge case)' {
    $raw = 'a\\\b'
    $json = (@{k=$raw} | ConvertTo-Json -Compress)
    $yaml = ConvertTo-JiraConfigYaml -Json $json
    $tmpf = Join-Path $TestDrive 'backslashes.yml'
    Set-Content -LiteralPath $tmpf -Value $yaml -NoNewline
    $obj = (ConvertFrom-JiraConfigYaml -Path $tmpf) | ConvertFrom-Json
    $obj.k | Should -Be $raw
}

It 'a quote adjacent to the delimiter round-trips as literal content (013 edge case)' {
    $raw = '"quoted"'
    $json = (@{k=$raw} | ConvertTo-Json -Compress)
    $yaml = ConvertTo-JiraConfigYaml -Json $json
    $tmpf = Join-Path $TestDrive 'adjacent.yml'
    Set-Content -LiteralPath $tmpf -Value $yaml -NoNewline
    $obj = (ConvertFrom-JiraConfigYaml -Path $tmpf) | ConvertFrom-Json
    $obj.k | Should -Be $raw
}

It 'a quoted and an unquoted variant of a label stay distinct values after a round trip (013 FR-006 invariant I5)' {
    $rawA = 'Platform "legacy"'
    $rawB = 'Platform legacy'
    $json = (@{a=$rawA; b=$rawB} | ConvertTo-Json -Compress)
    $yaml = ConvertTo-JiraConfigYaml -Json $json
    $tmpf = Join-Path $TestDrive 'distinct.yml'
    Set-Content -LiteralPath $tmpf -Value $yaml -NoNewline
    $obj = (ConvertFrom-JiraConfigYaml -Path $tmpf) | ConvertFrom-Json
    $obj.a | Should -Be $rawA
    $obj.b | Should -Be $rawB
    $obj.a | Should -Not -Be $obj.b
}

# --- Wedged-configuration recovery (013 US3, quickstart Scenario 1, T037) --

It 'a pre-seeded file already holding the escaped form loads and rewrites byte-identically (013 US3, quickstart Scenario 1)' {
    $tmpf = Join-Path $TestDrive 'wedged.yml'
    $wedged = "`"allowed`":`n  - `"Platform \`"legacy\`"`""
    Set-Content -LiteralPath $tmpf -Value $wedged -NoNewline
    $json = (ConvertFrom-JiraConfigYaml -Path $tmpf) | ConvertFrom-Json
    $json.allowed[0] | Should -Be 'Platform "legacy"'
    $rewritten = ConvertTo-JiraConfigYaml -Json (ConvertFrom-JiraConfigYaml -Path $tmpf)
    $rewritten | Should -Be $wedged
}

# --- Line-break refusal (013 FR-020, contract §1.4, §4) ---------------------

    It 'a string value containing a line break (LF) is refused, value never printed (013 FR-020)' {
        { ConvertTo-JiraConfigYaml -Json '{"k":"before\nafter"}' } | Should -Throw
        try { ConvertTo-JiraConfigYaml -Json '{"k":"before\nafter"}' }
        catch {
            $_.Exception.Message | Should -Match 'k'
            $_.Exception.Message | Should -Not -Match 'before'
            $_.Exception.Message | Should -Not -Match 'after'
        }
    }

    It 'a string value containing a bare CR is refused (013 FR-020, contract §4)' {
        { ConvertTo-JiraConfigYaml -Json '{"k":"before\rafter"}' } | Should -Throw
        try { ConvertTo-JiraConfigYaml -Json '{"k":"before\rafter"}' }
        catch {
            $_.Exception.Message | Should -Match 'k'
            $_.Exception.Message | Should -Not -Match 'before'
            $_.Exception.Message | Should -Not -Match 'after'
        }
    }

    It 'a document with two unrepresentable paths reports both, deduplicated and in the same order (013 US4, research R5)' {
        { ConvertTo-JiraConfigYaml -Json '{"a":"before\nafter","b":"before\nafter"}' } | Should -Throw
        try { ConvertTo-JiraConfigYaml -Json '{"a":"before\nafter","b":"before\nafter"}' }
        catch {
            $_.Exception.Message | Should -Be "config: a: a string value here contains a line break, which this writer cannot represent`nconfig: b: a string value here contains a line break, which this writer cannot represent"
        }
    }

    # --- Compatibility guards: must stay green throughout (013 FR-012/013, 007 R1, research R2) -

    It 'an unrecognised backslash escape stays literal, both backslashes kept (013 FR-012)' {
        $d = New-TempConfigDir
        $f = Join-Path $d 'path.yml'
        Set-Content -Path $f -Value 'path: "C:\Users\shared"' -NoNewline
        $obj = (ConvertFrom-JiraConfigYaml -Path $f) | ConvertFrom-Json
        $obj.path | Should -Be 'C:\Users\shared'
        Remove-Item -Recurse -Force $d
    }

    It 'a single-quoted scalar is never decoded (013 FR-013, contract §2.2)' {
        $d = New-TempConfigDir
        $f = Join-Path $d 'single.yml'
        Set-Content -Path $f -Value 'single: ''a\"b''' -NoNewline
        $obj = (ConvertFrom-JiraConfigYaml -Path $f) | ConvertFrom-Json
        $obj.single | Should -Be 'a\"b'
        Remove-Item -Recurse -Force $d
    }

    It 'a literal TAB inside a quoted scalar round-trips unchanged (013 research R2)' {
        $d = New-TempConfigDir
        $f = Join-Path $d 'tab.yml'
        [System.IO.File]::WriteAllText($f, "k: `"a`tb`"")
        $obj = (ConvertFrom-JiraConfigYaml -Path $f) | ConvertFrom-Json
        $obj.k | Should -Be "a`tb"
        Remove-Item -Recurse -Force $d
    }

    # --- Privacy guard: must stay green throughout (013 FR-024, Constitution IX) -

    It 'a malformed line with an escaped quote before a credential-shaped token is still redacted (013 FR-024)' {
        $d = New-TempConfigDir
        $f = Join-Path $d 'leak2.yml'
        Set-Content -Path $f -Value "resolved_ids:`n  JET:`n    bad `"a \`" # ATATT3xFfGF0secrettoken" -NoNewline
        $errMsg = $null
        try { ConvertFrom-JiraConfigYaml -Path $f | Out-Null } catch { $errMsg = $_.Exception.Message }
        $firstLine = ($errMsg -split "`n")[0]
        $firstLine | Should -Not -Match 'ATATT3xFfGF0secrettoken'
        $firstLine | Should -Match ([regex]::Escape('[redacted]'))
        Remove-Item -Recurse -Force $d
    }

    It 'a key containing a double quote is written and round-trips (013 contract §1, was: refused on write, 007 research R3)' {
        $yaml = ConvertTo-JiraConfigYaml -Json '{"a":{"say \"hi\"":"1"}}'
        $yaml | Should -Match ([regex]::Escape('"say \"hi\""'))
        $d = New-TempConfigDir
        $f = Join-Path $d 'key.yml'
        [System.IO.File]::WriteAllText($f, $yaml)
        $obj = (ConvertFrom-JiraConfigYaml -Path $f) | ConvertFrom-Json
        $obj.a.PSObject.Properties.Name | Should -Be 'say "hi"'
        Remove-Item -Recurse -Force $d
    }

    It 'a string value containing a double quote is written and round-trips (013 contract §1, was: refused on write, 007 research R3)' {
        $yaml = ConvertTo-JiraConfigYaml -Json '{"a":{"k":"say \"hi\""}}'
        $yaml | Should -Match ([regex]::Escape('"say \"hi\""'))
        $d = New-TempConfigDir
        $f = Join-Path $d 'val.yml'
        [System.IO.File]::WriteAllText($f, $yaml)
        $obj = (ConvertFrom-JiraConfigYaml -Path $f) | ConvertFrom-Json
        $obj.a.k | Should -Be 'say "hi"'
        Remove-Item -Recurse -Force $d
    }

    # --- Fail-closed on a line that cannot be interpreted (007, contracts/parse-failure.md) -

    It 'a malformed line fails closed with the exact three-line message (007 FR-007 to FR-009)' {
        $d = New-TempConfigDir
        $f = Join-Path $d 'bad.yml'
        Set-Content -Path $f -Value "resolved_ids:`n  JET:`n    this line has no delimiter" -NoNewline
        $errMsg = $null
        try { ConvertFrom-JiraConfigYaml -Path $f | Out-Null; $threw = $false }
        catch { $threw = $true; $errMsg = $_.Exception.Message }
        $threw | Should -BeTrue
        $lines = $errMsg -split "`n"
        $lines[0] | Should -Be "config: ${f}:3: cannot parse this line as a mapping entry: this line has no delimiter"
        $lines[1] | Should -Be 'config: a key must be followed by ": " — quote the key if it contains a colon, e.g. "Blocked: waiting": "10001"'
        $lines[2] | Should -Be "config: re-run /speckit.jira.config to regenerate ${f} from the Jira instance."
        Remove-Item -Recurse -Force $d
    }

    It 'the reported line number counts blank and comment lines (007 FR-009)' {
        $d = New-TempConfigDir
        $f = Join-Path $d 'bad2.yml'
        Set-Content -Path $f -Value "# a comment`n`nresolved_ids:`n  JET:`n    broken" -NoNewline
        $errMsg = $null
        try { ConvertFrom-JiraConfigYaml -Path $f | Out-Null } catch { $errMsg = $_.Exception.Message }
        $errMsg | Should -Match ':5:'
        Remove-Item -Recurse -Force $d
    }

    It "a '- jira' sequence item is not a parse failure (007 contract yaml-key-grammar.md section 1.4)" {
        $d = New-TempConfigDir
        $f = Join-Path $d 'seq.yml'
        Set-Content -Path $f -Value "installed:`n- jira" -NoNewline
        $obj = (ConvertFrom-JiraConfigYaml -Path $f) | ConvertFrom-Json
        $obj.installed[0] | Should -Be 'jira'
        Remove-Item -Recurse -Force $d
    }

    It 'a malformed line carrying credential-shaped content is redacted (007 FR-009, Constitution IV)' {
        $d = New-TempConfigDir
        $f = Join-Path $d 'leak.yml'
        Set-Content -Path $f -Value "resolved_ids:`n  JET:`n    ATATT3xFfGF0 someone@example.com https://acme.atlassian.net" -NoNewline
        $errMsg = $null
        try { ConvertFrom-JiraConfigYaml -Path $f | Out-Null } catch { $errMsg = $_.Exception.Message }
        $firstLine = ($errMsg -split "`n")[0]
        $firstLine | Should -Match ([regex]::Escape("${f}:3:"))
        $firstLine | Should -Not -Match 'ATATT3xFfGF0'
        $firstLine | Should -Not -Match 'someone@example.com'
        $firstLine | Should -Not -Match 'acme.atlassian.net'
        $firstLine | Should -Match ([regex]::Escape('[redacted]'))
        Remove-Item -Recurse -Force $d
    }

    It 'a key repeated at the same mapping level fails, naming both lines (007 FR-016)' {
        $d = New-TempConfigDir
        $f = Join-Path $d 'dup.yml'
        Set-Content -Path $f -Value "statuses:`n  `"Termin$([char]0xE9)`": `"1`"`n  `"Termin$([char]0xE9)`": `"2`"" -NoNewline
        $errMsg = $null
        try { ConvertFrom-JiraConfigYaml -Path $f | Out-Null } catch { $errMsg = $_.Exception.Message }
        $firstLine = ($errMsg -split "`n")[0]
        $firstLine | Should -Match ([regex]::Escape("${f}:3:"))
        $firstLine | Should -Match 'duplicate key'
        $firstLine | Should -Match 'line 2'
        Remove-Item -Recurse -Force $d
    }

    It 'the same key at two different mapping levels stays legal (007 yaml-key-grammar.md section 1.5)' {
        $d = New-TempConfigDir
        $f = Join-Path $d 'nodup.yml'
        Set-Content -Path $f -Value "resolved_ids:`n  COMP:`n    statuses:`n      `"To Do`": `"1`"`n  TEAM:`n    statuses:`n      `"To Do`": `"2`"" -NoNewline
        $obj = (ConvertFrom-JiraConfigYaml -Path $f) | ConvertFrom-Json
        $obj.resolved_ids.COMP.statuses.'To Do' | Should -Be '1'
        $obj.resolved_ids.TEAM.statuses.'To Do' | Should -Be '2'
        Remove-Item -Recurse -Force $d
    }
}

Describe 'Import-JiraConfig' {
    It 'accepts a valid team config (exit 0)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value $script:ValidTeam -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 0
        ($r.Json | ConvertFrom-Json).routing_default | Should -Be 'PROJ'
        Remove-Item -Recurse -Force $d
    }

    It 'merges config.local overrides over the team config' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value $script:ValidTeam -NoNewline
        Set-Content -Path (Join-Path $d 'config.local.yml') -Value "site_alias: prod`noverrides:`n  routing_default: OTHER`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 0
        ($r.Json | ConvertFrom-Json).routing_default | Should -Be 'OTHER'
        Remove-Item -Recurse -Force $d
    }

    It 'fails when config.yml is absent (exit 4)' {
        $d = New-TempConfigDir
        (Import-JiraConfig -ConfigDir $d).ExitCode | Should -Be 4
        Remove-Item -Recurse -Force $d
    }

    It 'rejects an ATATT token shape and never echoes the secret (exit 4)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value ($script:ValidTeam + "`nsite_url: ATATT3xFfGF0secrettoken`n") -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'credential|Atlassian'
        ($r.Errors -join "`n") | Should -Not -Match 'ATATT3xFfGF0secrettoken'
        Remove-Item -Recurse -Force $d
    }

    It 'rejects a real *.atlassian.net host in the local layer (exit 4)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value $script:ValidTeam -NoNewline
        Set-Content -Path (Join-Path $d 'config.local.yml') -Value "overrides:`n  site: acme.atlassian.net`n" -NoNewline
        (Import-JiraConfig -ConfigDir $d).ExitCode | Should -Be 4
        Remove-Item -Recurse -Force $d
    }

    It 'does NOT scan privacy.allowlist for atlassian hosts (FR-053)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value $script:ValidTeam -NoNewline
        (Import-JiraConfig -ConfigDir $d).ExitCode | Should -Be 0
        Remove-Item -Recurse -Force $d
    }

    It 'rejects a missing routing_default (exit 4)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    style: company_managed`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'routing_default'
        Remove-Item -Recurse -Force $d
    }

    It 'rejects a case-variant project style like the Bash port — "Company_Managed" is invalid (NFR-1)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    style: Company_Managed`nrouting_default: PROJ`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'style'
        Remove-Item -Recurse -Force $d
    }

    It 'keeps sibling projects when a local override touches only one of them' {
        $d = New-TempConfigDir
        $team = "projects:`n  - key: PROJ`n    style: company_managed`n  - key: OPS`n    style: team_managed`nrouting_default: PROJ`n"
        Set-Content -Path (Join-Path $d 'config.yml') -Value $team -NoNewline
        Set-Content -Path (Join-Path $d 'config.local.yml') -Value "overrides:`n  projects:`n    - key: PROJ`n      style: team_managed`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 0
        $merged = $r.Json | ConvertFrom-Json
        @($merged.projects).Count | Should -Be 2
        @($merged.projects)[0].key | Should -Be 'PROJ'
        @($merged.projects)[0].style | Should -Be 'team_managed'
        @($merged.projects)[1].key | Should -Be 'OPS'
        Remove-Item -Recurse -Force $d
    }

    It 'rejects an unknown top-level key (exit 4)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value ($script:ValidTeam + "`nmystery: value`n") -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'unknown'
        Remove-Item -Recurse -Force $d
    }

    It 'rejects a phase_status_map that is not a mapping to status names (exit 4, T074)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    style: company_managed`n    phase_status_map: `"not-a-mapping`"`nrouting_default: PROJ`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'phase_status_map'
        Remove-Item -Recurse -Force $d
    }

    It 'accepts a valid phase_status_map and halted_statuses (T074)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    style: company_managed`n    phase_status_map:`n      after_specify: `"To Do`"`n      after_plan: `"In Progress`"`n    halted_statuses:`n      - `"Blocked`"`nrouting_default: PROJ`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 0
        Remove-Item -Recurse -Force $d
    }

    It 'rejects a halted_statuses that is neither a list nor a string (exit 4, T074)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    style: company_managed`n    halted_statuses:`n      count: 3`nrouting_default: PROJ`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'halted_statuses'
        Remove-Item -Recurse -Force $d
    }

    # --- T075/T088 [Phase 9] — the `hierarchy` schema (010, contracts/role-mapping.md §6.1, §2) ---

    It 'T075 — rejects a projects[].hierarchy that is not an object (exit 4)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    hierarchy: `"Epic`"`nrouting_default: PROJ`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'projects\[0\]\.hierarchy must be a mapping of role to issue type name'
        Remove-Item -Recurse -Force $d
    }

    It 'T075 — rejects an unknown role in projects[].hierarchy, naming the closed role set' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    hierarchy:`n      epic: Epic`nrouting_default: PROJ`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'projects\[0\]\.hierarchy declares unknown role `epic`; the roles are specification, story, task'
        Remove-Item -Recurse -Force $d
    }

    It 'T075 — rejects an empty projects[].hierarchy.<role> value' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    hierarchy:`n      specification: `"`"`nrouting_default: PROJ`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'projects\[0\]\.hierarchy\.specification must be a non-empty issue type name'
        Remove-Item -Recurse -Force $d
    }

    It 'T075 — accepts a valid projects[].hierarchy declaration' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value "projects:`n  - key: PROJ`n    hierarchy:`n      specification: Epic`n      story: Story`n      task: `"Sous-tâche`"`nrouting_default: PROJ`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 0
        Remove-Item -Recurse -Force $d
    }

    It 'T075 — rejects a non-object resolved_ids.<KEY>.roles (exit 4)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value $script:ValidTeam -NoNewline
        Set-Content -Path (Join-Path $d 'config.local.yml') -Value "resolved_ids:`n  PROJ:`n    roles: `"Epic`"`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'resolved_ids\.PROJ\.roles must be a mapping'
        Remove-Item -Recurse -Force $d
    }

    It 'T075 — rejects an unknown role in resolved_ids.<KEY>.roles (exit 4)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value $script:ValidTeam -NoNewline
        $local = "resolved_ids:`n  PROJ:`n    roles:`n      epic:`n        logical_name: `"Epic`"`n        id: `"10001`"`n        hierarchy_level: `"1`"`n        subtask: false`n        source: declared`n"
        Set-Content -Path (Join-Path $d 'config.local.yml') -Value $local -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'resolved_ids\.PROJ\.roles declares unknown role `epic`'
        Remove-Item -Recurse -Force $d
    }

    It 'T075 — rejects resolved_ids.<KEY>.roles.<role>.source outside declared|operator|derived (exit 4)' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value $script:ValidTeam -NoNewline
        $local = "resolved_ids:`n  PROJ:`n    roles:`n      specification:`n        logical_name: `"Epic`"`n        id: `"10001`"`n        hierarchy_level: `"1`"`n        subtask: false`n        source: guessed`n"
        Set-Content -Path (Join-Path $d 'config.local.yml') -Value $local -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 4
        ($r.Errors -join "`n") | Should -Match 'resolved_ids\.PROJ\.roles\.specification\.source is invalid'
        Remove-Item -Recurse -Force $d
    }

    It 'T075 — accepts a valid resolved_ids.<KEY>.roles block' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value $script:ValidTeam -NoNewline
        $local = "resolved_ids:`n  PROJ:`n    roles:`n      specification:`n        logical_name: `"Epic`"`n        id: `"10001`"`n        hierarchy_level: `"1`"`n        subtask: false`n        source: declared`n"
        Set-Content -Path (Join-Path $d 'config.local.yml') -Value $local -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 0
        Remove-Item -Recurse -Force $d
    }
}

Describe 'The operator disable record (T009, FR-007, FR-029)' {
    # Twin of the T008 cases in tests/bash/lib/test_config.bats. The registry
    # cannot carry the operator's decision across a reinstall (research R5), so
    # it is recorded in the gitignored local binding instead.
    BeforeEach {
        $script:Dir = New-TempConfigDir
    }
    AfterEach {
        Remove-Item -Recurse -Force $script:Dir -ErrorAction SilentlyContinue
    }

    It 'reads an absent record as the empty set' {
        Get-JiraHooksDisabled -ConfigDir $script:Dir | Should -BeExactly '[]'
    }

    It 'reads a local binding with no hooks key as the empty set' {
        Set-Content -Path (Join-Path $script:Dir 'config.local.yml') -Value "site_alias: `"prod`"`n" -NoNewline
        Get-JiraHooksDisabled -ConfigDir $script:Dir | Should -BeExactly '[]'
    }

    It 'round-trips a written record' {
        (Add-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $script:Dir) | Should -BeExactly 'recorded'
        Get-JiraHooksDisabled -ConfigDir $script:Dir | Should -BeExactly '["after_implement"]'
    }

    It 'reports an already-recorded event unchanged and never duplicates it' {
        $null = Add-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $script:Dir
        (Add-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $script:Dir) | Should -BeExactly 'unchanged'
        @((Get-JiraHooksDisabled -ConfigDir $script:Dir) | ConvertFrom-Json).Count | Should -Be 1
    }

    It 'orders the record so two runs write byte-identical bytes (FR-003)' {
        $null = Add-JiraHooksDisabled -LifecycleEvent 'after_tasks' -ConfigDir $script:Dir
        $null = Add-JiraHooksDisabled -LifecycleEvent 'after_clarify' -ConfigDir $script:Dir
        Get-JiraHooksDisabled -ConfigDir $script:Dir | Should -BeExactly '["after_clarify","after_tasks"]'
    }

    It 'reports an unknown event name and IGNORES it rather than failing the run' {
        Set-Content -Path (Join-Path $script:Dir 'config.local.yml') `
            -Value "hooks:`n  disabled:`n    - after_implement`n    - after_typo`n" -NoNewline
        Get-JiraHooksDisabled -ConfigDir $script:Dir | Should -BeExactly '["after_implement"]'
    }

    It 'reports an unknown event name on record and does not fail the run' {
        $null = Add-JiraHooksDisabled -LifecycleEvent 'not_an_event' -ConfigDir $script:Dir
        Get-JiraHooksDisabled -ConfigDir $script:Dir | Should -BeExactly '[]'
    }

    It 'predicts the record write under -DryRun without performing it (Constitution XI)' {
        (Add-JiraHooksDisabled -LifecycleEvent 'after_plan' -ConfigDir $script:Dir -DryRun $true) | Should -BeExactly 'recorded'
        Test-Path -LiteralPath (Join-Path $script:Dir 'config.local.yml') | Should -BeFalse
        Get-JiraHooksDisabled -ConfigDir $script:Dir | Should -BeExactly '[]'
    }

    It 'clears an event from the record on release (FR-007, FR-029)' {
        $null = Add-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $script:Dir
        $null = Add-JiraHooksDisabled -LifecycleEvent 'after_plan' -ConfigDir $script:Dir
        (Remove-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $script:Dir) | Should -BeExactly 'released'
        Get-JiraHooksDisabled -ConfigDir $script:Dir | Should -BeExactly '["after_plan"]'
    }

    It 'reports releasing an unrecorded event as a no-op' {
        (Remove-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $script:Dir) | Should -BeExactly 'unrecorded'
    }

    It 'predicts the release under -DryRun without performing it (Constitution XI)' {
        $null = Add-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $script:Dir
        (Remove-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $script:Dir -DryRun $true) | Should -BeExactly 'released'
        Get-JiraHooksDisabled -ConfigDir $script:Dir | Should -BeExactly '["after_implement"]'
    }

    It "preserves the operator's site_alias and overrides" {
        Set-Content -Path (Join-Path $script:Dir 'config.local.yml') `
            -Value "overrides:`n  routing_default: OPS`nsite_alias: `"prod`"`n" -NoNewline
        $null = Add-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $script:Dir
        $json = ConvertFrom-JiraConfigYaml -Path (Join-Path $script:Dir 'config.local.yml') | ConvertFrom-Json
        $json.site_alias | Should -BeExactly 'prod'
        $json.overrides.routing_default | Should -BeExactly 'OPS'
        $json.hooks.disabled[0] | Should -BeExactly 'after_implement'
    }

    It 'accepts the hooks key in local-binding schema validation (T013)' {
        Set-Content -Path (Join-Path $script:Dir 'config.yml') -Value $script:ValidTeam -NoNewline
        Set-Content -Path (Join-Path $script:Dir 'config.local.yml') `
            -Value "hooks:`n  disabled:`n    - after_implement`n" -NoNewline
        (Import-JiraConfig -ConfigDir $script:Dir).ExitCode | Should -Be 0
    }
}

Describe 'Empty collections round-trip (003 T010 regression)' {
    # Twin of the bats case: the writer emits `key: []` / `key: {}` and the
    # reader must return a collection, not the string "[]" / "{}". The hook
    # registry reader depends on it — `after_plan: []` is what our own
    # serialiser writes for an event with no entries.
    It 'reads a written empty collection back as a collection' {
        $d = New-TempConfigDir
        $yaml = ConvertTo-JiraConfigYaml -Json '{"a":[],"b":{},"c":"x"}'
        Set-Content -Path (Join-Path $d 'rt.yml') -Value $yaml -NoNewline
        $json = ConvertFrom-JiraConfigYaml -Path (Join-Path $d 'rt.yml')
        $json | Should -BeExactly '{"a":[],"b":{},"c":"x"}'
        Remove-Item -Recurse -Force $d
    }

    It 'keeps a QUOTED [] a string — only the bare flow form is a collection' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'q.yml') -Value "a: `"[]`"`nb: `"{}`"`n" -NoNewline
        $json = ConvertFrom-JiraConfigYaml -Path (Join-Path $d 'q.yml')
        $json | Should -BeExactly '{"a":"[]","b":"{}"}'
        Remove-Item -Recurse -Force $d
    }
}

Describe 'Block sequences at the parent key indentation (003 T011 regression)' {
    # Twin of the bats cases. PyYAML — which is what `specify extension add`
    # serialises the hook registry with — emits block sequences at the SAME
    # indentation as their parent key. This reader required a greater indent, so
    # the hook registry of every real installation parsed as `{"installed":null}`
    # and hook health reported a healthy repository unreadable.
    It "reads a sequence at its parent key's indentation" {
        $d = New-TempConfigDir
        $yaml = @(
            'installed:'
            '- jira'
            'settings:'
            '  auto_execute_hooks: true'
            'hooks:'
            '  before_specify:'
            '  - extension: jira'
            '    command: speckit.jira.feature'
            '    enabled: true'
        ) -join "`n"
        Set-Content -Path (Join-Path $d 'pyyaml.yml') -Value ($yaml + "`n") -NoNewline
        $json = ConvertFrom-JiraConfigYaml -Path (Join-Path $d 'pyyaml.yml') | ConvertFrom-Json
        $json.installed[0] | Should -BeExactly 'jira'
        $json.settings.auto_execute_hooks | Should -BeTrue
        @($json.hooks.before_specify).Count | Should -Be 1
        @($json.hooks.before_specify)[0].command | Should -BeExactly 'speckit.jira.feature'
        @($json.hooks.before_specify)[0].enabled | Should -BeTrue
        Remove-Item -Recurse -Force $d
    }

    It 'produces the SAME parse for both sequence indentations' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'flat.yml') -Value "hooks:`n  after_plan:`n  - command: a`n  - command: b`n" -NoNewline
        Set-Content -Path (Join-Path $d 'deep.yml') -Value "hooks:`n  after_plan:`n    - command: a`n    - command: b`n" -NoNewline
        (ConvertFrom-JiraConfigYaml -Path (Join-Path $d 'flat.yml')) |
            Should -BeExactly (ConvertFrom-JiraConfigYaml -Path (Join-Path $d 'deep.yml'))
        Remove-Item -Recurse -Force $d
    }
}

Describe 'An empty local binding is tolerated (003 T013)' {
    # Releasing the last held event leaves the local binding with nothing in it,
    # so the writer emits an empty document. Reading that back must be a no-op,
    # not a refusal — otherwise clearing the last disabled hook would break every
    # subsequent run of the ceremony. The Bash port tolerates it; this is the
    # twin that keeps the two in agreement (Constitution VI).
    It 'loads a config whose local binding is empty' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value $script:ValidTeam -NoNewline
        Set-Content -Path (Join-Path $d 'config.local.yml') -Value "`n" -NoNewline
        $r = Import-JiraConfig -ConfigDir $d
        $r.ExitCode | Should -Be 0
        ($r.Json | ConvertFrom-Json).routing_default | Should -BeExactly 'PROJ'
        Remove-Item -Recurse -Force $d
    }

    It 'leaves a loadable local binding after releasing the last held event' {
        $d = New-TempConfigDir
        Set-Content -Path (Join-Path $d 'config.yml') -Value $script:ValidTeam -NoNewline
        $null = Add-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $d
        $null = Remove-JiraHooksDisabled -LifecycleEvent 'after_implement' -ConfigDir $d
        (Import-JiraConfig -ConfigDir $d).ExitCode | Should -Be 0
        (Get-JiraHooksDisabled -ConfigDir $d) | Should -BeExactly '[]'
        Remove-Item -Recurse -Force $d
    }
}
