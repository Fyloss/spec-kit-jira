# T021 [Phase 2, 036] — Pester twin of tests/bash/sink/test_client_multipart.bats.
#
# The transport's multipart capability (036 C2.2; FR-023; Constitution IV).
#
# The two ports compose the body by different mechanisms — curl builds it from
# a config file, PowerShell from a MultipartFormDataContent — so what they must
# agree on is the REQUEST: the same part name, the same explicit filenames in
# the same order, the same XSRF header, and no Content-Type of our own.
#
# Asserted against the composed content rather than the wire, which is exactly
# what the Bash twin does when it reads back the curl config it built. A real
# listener was tried first and was the wrong instrument: `Invoke-WebRequest`
# does not always send a Content-Length, so a hand-rolled TCP reader waits out
# its own deadline and the suite looks hung. The wire itself is covered by the
# conformance corpus against the mock, where a real HTTP server does the
# parsing.

BeforeAll {
    $Root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    Import-Module (Join-Path $Root 'scripts/powershell/sink/jira/Client.psm1') -Force

    # Render a composed MultipartFormDataContent to text, headers included, so
    # the assertions below read like the Bash port's config assertions.
    function Get-ComposedText {
        param([Parameter(Mandatory)] $Content)
        # The BODY only, read as BYTES and decoded Latin-1.
        #
        # Two traps avoided here. The Content-Type lives on a typed header
        # object that does not interpolate to a string, and reaching for it in
        # this helper made the whole BeforeEach throw under StrictMode — taking
        # every test in the block with it; the media type gets its own
        # assertion against the typed property instead. And ReadAsStringAsync
        # came back EMPTY on this content, where ReadAsByteArrayAsync does not
        # — which is also the read the binary case needs, so one read serves
        # both.
        $bytes = $Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        return [System.Text.Encoding]::Latin1.GetString($bytes)
    }
}

Describe 'New-JiraMultipartContent (036 T021, C2.2)' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path (Join-Path $script:Dir 'contracts') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:Dir 'spec.md'), "spec body`n")
        [System.IO.File]::WriteAllText((Join-Path $script:Dir 'contracts/api.md'), "api body`n")
        $script:Parts = @(
            @{ Name = 'spec.md'; File = (Join-Path $script:Dir 'spec.md') }
            @{ Name = 'contracts__api.md'; File = (Join-Path $script:Dir 'contracts/api.md') }
        )
        $script:Text = Get-ComposedText -Content (New-JiraMultipartContent -FormParts $script:Parts)
    }

    It 'C2.2 composes multipart/form-data with a boundary of its own' {
        $ct = (New-JiraMultipartContent -FormParts $script:Parts).Headers.ContentType
        $ct.MediaType | Should -Be 'multipart/form-data'
        # The boundary is PowerShell's, which is what proves it built the body
        # rather than us handing it a pre-composed one.
        @($ct.Parameters | Where-Object { $_.Name -eq 'boundary' }).Count | Should -Be 1
    }

    It 'C2.2 emits one part per artifact, and no more' {
        ([regex]::Matches($script:Text, 'name="file"')).Count | Should -Be 2
    }

    It 'C2.2 every part is named "file"' {
        # Jira reads the parts by this name; a differently-named part is ignored.
        ([regex]::Matches($script:Text, 'Content-Disposition:\s*form-data')).Count | Should -Be 2
        ([regex]::Matches($script:Text, 'name="file"')).Count | Should -Be 2
    }

    It 'C2.2 each part carries the FLATTENED filename, not the basename' {
        # Without the explicit filename, `contracts/api.md` arrives as `api.md`
        # — exactly the collision the flattening exists to prevent.
        $script:Text | Should -Match 'filename="spec\.md"'
        $script:Text | Should -Match 'filename="contracts__api\.md"'
        $script:Text | Should -Not -Match 'filename="api\.md"'
    }

    It 'Constitution VI part order is the caller order, so both ports send the same sequence' {
        $script:Text.IndexOf('filename="spec.md"') |
            Should -BeLessThan $script:Text.IndexOf('filename="contracts__api.md"')
    }

    It 'FR-002 the artifact bytes travel verbatim' {
        $script:Text | Should -Match 'spec body'
        $script:Text | Should -Match 'api body'
    }

    It 'C2.2 a binary artifact survives composition byte for byte' {
        $png = Join-Path $script:Dir 'diagram.png'
        $bytes = [byte[]] (0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF, 0x7F)
        [System.IO.File]::WriteAllBytes($png, $bytes)
        $c = New-JiraMultipartContent -FormParts @(@{ Name = 'assets__diagram.png'; File = $png })
        $raw = $c.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        # The PNG signature must appear intact in the composed body — a port
        # that decoded and re-encoded the file would corrupt it.
        $needle = [System.Text.Encoding]::Latin1.GetString($bytes)
        [System.Text.Encoding]::Latin1.GetString($raw) | Should -Match ([regex]::Escape($needle))
    }

    It 'C2.2 a single artifact still produces one part, not an unwrapped scalar' {
        # PowerShell unwraps a one-element collection on return; [object[]] on
        # the parameter is what keeps a single part an array here.
        $c = New-JiraMultipartContent -FormParts @(@{ Name = 'spec.md'; File = (Join-Path $script:Dir 'spec.md') })
        ([regex]::Matches((Get-ComposedText -Content $c), 'name="file"')).Count | Should -Be 1
    }
}

Describe 'Invoke-JiraRequest -FormParts wiring (036 T021)' {
    It 'C2.2 accepts -FormParts without demanding a Body' {
        # The parameter exists, is optional, and does not collide with -Body.
        $cmd = Get-Command Invoke-JiraRequest
        $cmd.Parameters.ContainsKey('FormParts') | Should -BeTrue
        $cmd.Parameters['FormParts'].Attributes.Mandatory | Should -Not -Contain $true
    }

    It 'C2.2 the JSON path is untouched when no FormParts are supplied' {
        # Guards the regression that would matter most: 036 must not change how
        # every pre-036 caller sends its body.
        $src = Get-Content -Raw (Join-Path $Root 'scripts/powershell/sink/jira/Client.psm1')
        $src | Should -Match "\`$params\.ContentType = 'application/json'"
        $src | Should -Match "\`$header\['X-Atlassian-Token'\] = 'no-check'"
    }
}
