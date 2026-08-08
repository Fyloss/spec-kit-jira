# T086 — guard: the prefetch field union (contracts/recognition-prefetch.md
# §5) must stay a superset of every field either reader ever requests. A
# field added to a reader and forgotten here silently drops from the result
# on a prefetch HIT only — the fall-through GET still supplies it, and the
# mock's GET-vs-bulkfetch field-filtering asymmetry hides the divergence.
# This is how Flagged was lost until T057 (US4 checkpoint). Parses the
# readers' own literal field lists out of Recognition.psm1's source rather
# than hardcoding a second copy, so a future field addition there fails this
# test instead of silently narrowing prefetch's coverage.

BeforeAll {
    $SinkDir = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira'
    Import-Module (Join-Path $SinkDir 'Prefetch.psm1') -Force
    $RecognitionSource = Get-Content -Raw (Join-Path $SinkDir 'Recognition.psm1')
}

Describe 'the prefetch field union (T086)' {
    It 'is a superset of every field either reader requests' {
        $baseMatch = [regex]::Match($RecognitionSource, "\`$fieldsParam = '([^']+)'")
        $baseMatch.Success | Should -BeTrue
        $baseFields = $baseMatch.Groups[1].Value

        $extraMatch = [regex]::Match($RecognitionSource, "\`$readExtra = if \(\`$Kind -eq 'story'\) \{ '([^']+)' \}")
        $extraMatch.Success | Should -BeTrue
        $storyExtra = $extraMatch.Groups[1].Value

        $parentMatch = [regex]::Match($RecognitionSource, "Get-JiraPrefetch -Key \`$Key -FieldsCsv '([^']+)'")
        $parentMatch.Success | Should -BeTrue
        $parentFields = $parentMatch.Groups[1].Value

        $union = InModuleScope Prefetch { $script:JiraPrefetchFields } | ForEach-Object { $_ -split ',' }
        $required = @($baseFields -split ',') + @($storyExtra) + @($parentFields -split ',')

        $missing = $required | Where-Object { $union -notcontains $_ } | Select-Object -Unique
        $missing | Should -BeNullOrEmpty
    }
}
