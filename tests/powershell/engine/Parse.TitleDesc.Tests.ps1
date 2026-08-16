# T050 [US3] — Engine parser, PowerShell side. Mirror of
# tests/bash/engine/test_parse_title_desc.bats. Cross-port byte-parity is proven
# in the bats test; here we assert the port's own behaviour (FR-013–FR-018).

BeforeAll {
    $EngineDir = Join-Path $PSScriptRoot '../../../scripts/powershell/engine'
    Import-Module (Join-Path $EngineDir 'Parse.psm1') -Force
}

Describe 'Get-JiraParsedTitle' {
    It 'prefers an explicit Title: line' {
        Get-JiraParsedTitle -Text "Title: The Chosen Title`n# An H1" -FolderSlug '001-x' | Should -Be 'The Chosen Title'
    }
    It 'falls back to the first H1' {
        Get-JiraParsedTitle -Text "# Feature Specification: Rich Tickets`n## Summary`nignore" -FolderSlug '001-x' | Should -Be 'Rich Tickets'
    }
    It 'falls back to a user-story section title' {
        Get-JiraParsedTitle -Text "### User Story 3 - Rich, reliable content (Priority: P1)`nbody" -FolderSlug '001-x' | Should -Be 'Rich, reliable content'
    }
    It 'falls back to the first non-empty paragraph' {
        Get-JiraParsedTitle -Text "`nA plain sentence of need.`nmore" -FolderSlug '001-x' | Should -Be 'A plain sentence of need.'
    }
    It 'falls back to the humanised folder slug last' {
        Get-JiraParsedTitle -Text '' -FolderSlug '001-jira-reconcile-engine' | Should -Be 'jira reconcile engine'
    }
    It 'never derives the title from a ## Summary' {
        $t = Get-JiraParsedTitle -Text "# Real Title`n## Summary`nSummary derived title" -FolderSlug '001-x'
        $t | Should -Be 'Real Title'
        $t | Should -Not -BeLike '*Summary*'
    }
}

Describe 'Get-JiraParsedDescription' {
    It 'is a non-empty structured block tree' {
        $d = Get-JiraParsedDescription -Text "# T`n`nWe need a reconcile bridge for specs." | ConvertFrom-Json
        @($d.blocks).Count | Should -BeGreaterOrEqual 1
    }
    It 'is never empty even with no prose and no ## Summary' {
        $d = Get-JiraParsedDescription -Text "# Only A Title" | ConvertFrom-Json
        @($d.blocks).Count | Should -BeGreaterOrEqual 1
        # A first non-empty paragraph field is always present (feature 016:
        # text lives on span[0].text within the paragraph's spans array).
        ($d.blocks | Where-Object { $_.type -eq 'paragraph' -and @($_.spans).Count -gt 0 -and $_.spans[0].text.Length -gt 0 }).Count | Should -BeGreaterOrEqual 1
    }
}

Describe 'Get-JiraParsedAcceptance' {
    It 'extracts a one-clause-per-line scenario' {
        $a = Get-JiraParsedAcceptance -Text "- **Given** a signed-in user`n- **When** they open the board`n- **Then** widgets load" | ConvertFrom-Json
        @($a).Count | Should -Be 1
        $a[0].given[0][0].text | Should -Be 'a signed-in user'
        $a[0].then[0][0].text | Should -Be 'widgets load'
    }
    It 'extracts an inline scenario' {
        $a = Get-JiraParsedAcceptance -Text 'Given a user When they click Then it opens' | ConvertFrom-Json
        @($a).Count | Should -Be 1
        $a[0].then[0][0].text | Should -Be 'it opens'
    }
    It "keeps a Given clause containing the word 'when' intact in an inline triple" {
        $a = Get-JiraParsedAcceptance -Text 'Given the user logs in when prompted, When they click, Then it opens' | ConvertFrom-Json
        $a[0].given[0][0].text | Should -Be 'the user logs in when prompted'
        $a[0].when[0][0].text | Should -Be 'they click'
        $a[0].then[0][0].text | Should -Be 'it opens'
    }
    It 'yields an empty array when no Gherkin' {
        Get-JiraParsedAcceptance -Text 'just prose' | Should -Be '[]'
    }

    # --- 028: the template's own single-line emphasised triple (contract §4) ---
    # rows 1, 2, 5, 6, 9 plus rule T3. Every row asserts clause DISJOINTNESS
    # (§6 invariant 1) and, for FR-011, that concatenating the three clause
    # texts reproduces the source line minus its keywords, wrappers and
    # clause delimiters.

    It 'contract §4 row 1: emphasised delimited triple yields three disjoint clauses' {
        $a = Get-JiraParsedAcceptance -Text '**Given** a user arrives on the Homepage, **When** they click Login, **Then** the login form appears.' | ConvertFrom-Json
        @($a).Count | Should -Be 1
        $g = $a[0].given[0][0].text
        $w = $a[0].when[0][0].text
        $t = $a[0].then[0][0].text
        $g | Should -Be 'a user arrives on the Homepage'
        $w | Should -Be 'they click Login'
        $t | Should -Be 'the login form appears.'
        $g | Should -Not -Match '(Given|When|Then)'
        $w | Should -Not -Match '(Given|When|Then)'
        $t | Should -Not -Match '(Given|When)'
        "$g, $w, $t" | Should -Be 'a user arrives on the Homepage, they click Login, the login form appears.'
    }

    It 'contract §4 row 2: plain delimited triple yields three disjoint clauses' {
        $a = Get-JiraParsedAcceptance -Text 'Given a user arrives on the Homepage, When they click Login, Then the login form appears.' | ConvertFrom-Json
        $g = $a[0].given[0][0].text
        $w = $a[0].when[0][0].text
        $t = $a[0].then[0][0].text
        $g | Should -Be 'a user arrives on the Homepage'
        $w | Should -Be 'they click Login'
        $t | Should -Be 'the login form appears.'
        "$g, $w, $t" | Should -Be 'a user arrives on the Homepage, they click Login, the login form appears.'
    }

    It 'contract §4 row 5: emphasised delimiter-free triple yields three disjoint clauses' {
        $a = Get-JiraParsedAcceptance -Text '**Given** a user **When** they click **Then** it opens' | ConvertFrom-Json
        $g = $a[0].given[0][0].text
        $w = $a[0].when[0][0].text
        $t = $a[0].then[0][0].text
        $g | Should -Be 'a user'
        $w | Should -Be 'they click'
        $t | Should -Be 'it opens'
        "$g $w $t" | Should -Be 'a user they click it opens'
    }

    It 'contract §4 row 6: emphasis inside a clause body survives as marks, wrapper around the keyword does not' {
        $a = Get-JiraParsedAcceptance -Text '__Given__ a **bold** thing, __When__ x, __Then__ y' | ConvertFrom-Json
        $givenText = ($a[0].given[0] | ForEach-Object { $_.text }) -join ''
        $givenText | Should -Be 'a bold thing'
        ($a[0].given[0] | Where-Object { $_.text -eq 'bold' }).marks[0].kind | Should -Be 'bold'
        $a[0].when[0][0].text | Should -Be 'x'
        $a[0].then[0][0].text | Should -Be 'y'
        $givenText | Should -Not -Match '__'
    }

    It 'contract §4 row 9: the greedy delimiter-free split pins the last When' {
        $a = Get-JiraParsedAcceptance -Text 'Given a When b When c Then d' | ConvertFrom-Json
        $g = $a[0].given[0][0].text
        $w = $a[0].when[0][0].text
        $t = $a[0].then[0][0].text
        $g | Should -Be 'a When b'
        $w | Should -Be 'c'
        $t | Should -Be 'd'
        "$g $w $t" | Should -Be 'a When b c d'
    }

    It 'contract §2 rule T3: keywords present but out of grammar order emit nothing (fail closed)' {
        Get-JiraParsedAcceptance -Text 'Then it opens, When they click, Given a user' | Should -Be '[]'
    }

    # --- 028 US2: no clause body ever repeats its own keyword (contract §6 invariant 2) ---

    It 'US2: no clause body opens with a keyword, on the per-line, delimited and delimiter-free forms' {
        $a1 = Get-JiraParsedAcceptance -Text "- **Given** a signed-in user`n- **When** they open the board`n- **Then** widgets load" | ConvertFrom-Json
        $a1[0].given[0][0].text | Should -Not -BeLike 'Given*'
        $a1[0].when[0][0].text | Should -Not -BeLike 'When*'
        $a1[0].then[0][0].text | Should -Not -BeLike 'Then*'

        $a2 = Get-JiraParsedAcceptance -Text '**Given** a user arrives on the Homepage, **When** they click Login, **Then** the login form appears.' | ConvertFrom-Json
        $a2[0].given[0][0].text | Should -Not -BeLike 'Given*'
        $a2[0].when[0][0].text | Should -Not -BeLike 'When*'
        $a2[0].then[0][0].text | Should -Not -BeLike 'Then*'

        $a3 = Get-JiraParsedAcceptance -Text '**Given** a user **When** they click **Then** it opens' | ConvertFrom-Json
        $a3[0].given[0][0].text | Should -Not -BeLike 'Given*'
        $a3[0].when[0][0].text | Should -Not -BeLike 'When*'
        $a3[0].then[0][0].text | Should -Not -BeLike 'Then*'
    }

    It 'US2: an emphasised And/But continuation joins the correct bucket without repeating a keyword' {
        $a = Get-JiraParsedAcceptance -Text "- **Given** a signed-in user`n- **And** an active session`n- **When** they open the board`n- **But** the network is slow`n- **Then** widgets load" | ConvertFrom-Json
        @($a[0].given).Count | Should -Be 2
        $a[0].given[1][0].text | Should -Be 'an active session'
        @($a[0].when).Count | Should -Be 2
        $a[0].when[1][0].text | Should -Be 'the network is slow'
        $a[0].given[1][0].text | Should -Not -BeLike 'And*'
        $a[0].when[1][0].text | Should -Not -BeLike 'But*'
    }

    It "US2: a clause body containing the word 'then' survives unsplit (FR-007)" {
        $a = Get-JiraParsedAcceptance -Text 'Given the report only loads then only if cached, When they refresh, Then it reloads' | ConvertFrom-Json
        $a[0].given[0][0].text | Should -Be 'the report only loads then only if cached'
        $a[0].when[0][0].text | Should -Be 'they refresh'
        $a[0].then[0][0].text | Should -Be 'it reloads'
    }

    It 'US2: a one-sided emphasis wrapper never reaches the clause body' {
        $a1 = Get-JiraParsedAcceptance -Text '**Given a user, When they click, Then it opens' | ConvertFrom-Json
        $a1[0].given[0][0].text | Should -Be 'a user'

        $a2 = Get-JiraParsedAcceptance -Text 'Given** a user, When they click, Then it opens' | ConvertFrom-Json
        $a2[0].given[0][0].text | Should -Be 'a user'
    }

    It 'US2: a mixed emphasis form on one line yields one scenario with all three clauses correct (contract §5)' {
        $a = Get-JiraParsedAcceptance -Text '**Given** a user, When they click, **Then** it opens' | ConvertFrom-Json
        @($a).Count | Should -Be 1
        $a[0].given[0][0].text | Should -Be 'a user'
        $a[0].when[0][0].text | Should -Be 'they click'
        $a[0].then[0][0].text | Should -Be 'it opens'
    }

    # --- 028 US4: a scenario wrapped across several lines is read whole (contract §3) ---

    It 'US4: a scenario wrapped inside a clause, followed by a second scenario, is read whole' {
        $text = "1. **Given** a user who has been sitting on the homepage for a`n" +
        "   very long while without any interaction at all, **When** they`n" +
        "   finally click the Login button, **Then** the login form appears`n" +
        "   on the screen right away.`n" +
        "2. **Given** another scenario, **When** something else happens, **Then** it also works."
        $a = Get-JiraParsedAcceptance -Text $text | ConvertFrom-Json
        @($a).Count | Should -Be 2
        $a[0].given[0][0].text | Should -Be 'a user who has been sitting on the homepage for a very long while without any interaction at all'
        $a[0].when[0][0].text | Should -Be 'they finally click the Login button'
        $a[0].then[0][0].text | Should -Be 'the login form appears on the screen right away.'
        $a[1].given[0][0].text | Should -Be 'another scenario'
        $a[1].when[0][0].text | Should -Be 'something else happens'
        $a[1].then[0][0].text | Should -Be 'it also works.'
    }

    It 'US4: the existing per-line form passes through the join pre-pass unchanged (§3 identity invariant)' {
        $a = Get-JiraParsedAcceptance -Text "- **Given** a signed-in user`n- **When** they open the board`n- **Then** widgets load" | ConvertFrom-Json
        @($a).Count | Should -Be 1
        $a[0].given[0][0].text | Should -Be 'a signed-in user'
        $a[0].when[0][0].text | Should -Be 'they open the board'
        $a[0].then[0][0].text | Should -Be 'widgets load'
    }

    It 'US4: an unindented prose line immediately after a scenario is not joined' {
        $a = Get-JiraParsedAcceptance -Text "Given a user, When they click, Then it opens`nThis is unrelated prose that happens to follow immediately." | ConvertFrom-Json
        @($a).Count | Should -Be 1
        $a[0].then[0][0].text | Should -Be 'it opens'
        ($a | ConvertTo-Json -Depth 20) | Should -Not -Match 'unrelated prose'
    }

    It 'US4, FR-022: a scenario wrapped at a clause boundary emits nothing (pinned, not fixed - real shape from 019 spec.md:93-95)' {
        $text = "1. **Given** a parent whose recorded origin is the mirror's own and whose description carries no boundary,`n" +
        "   **When** ``plan.md``'s summary changes and reconcile is run, **Then** the parent's description carries the`n" +
        "   new summary exactly once and no part of the previous one."
        Get-JiraParsedAcceptance -Text $text | Should -Be '[]'
    }

    # --- 028 US5: text that is not a scenario is still not turned into one ---

    It 'US5, FR-012: prose containing given/when/then mid-sentence yields no clause' {
        Get-JiraParsedAcceptance -Text 'The system checks whether login was given, when it happened, and then updates the log.' | Should -Be '[]'
    }

    It 'US5, FR-014: an absent or empty acceptance-scenario section yields [] with no warning' {
        Get-JiraParsedAcceptance -Text "**Acceptance Scenarios**:`n`nNothing here yet." | Should -Be '[]'
    }

    It 'US5, FR-013: a scenario that never reaches a Then is not emitted' {
        Get-JiraParsedAcceptance -Text "- **Given** a user`n- **When** they act" | Should -Be '[]'
    }

    It 'US5/US4: a story section mixing prose (Why this priority / Independent Test) with scenarios joins no prose into a clause' {
        $text = "### User Story 1 - Homepage login (Priority: P1)`n`n" +
        "As a visitor, I want to sign in from the homepage.`n`n" +
        "**Why this priority**: This is the primary entry point for every returning user.`n`n" +
        "**Independent Test**: Can be fully tested by visiting the homepage and signing in.`n`n" +
        "**Acceptance Scenarios**:`n`n" +
        "1. **Given** a user arrives on the Homepage, **When** they click Login, **Then** the login form appears."
        $a = Get-JiraParsedAcceptance -Text $text | ConvertFrom-Json
        @($a).Count | Should -Be 1
        $a[0].given[0][0].text | Should -Be 'a user arrives on the Homepage'
        ($a | ConvertTo-Json -Depth 20) | Should -Not -Match 'Why this priority'
        ($a | ConvertTo-Json -Depth 20) | Should -Not -Match 'Independent Test'
    }
}

Describe 'Get-JiraParsedDesign' {
    It 'extracts a Figma link and UX guidance' {
        $d = Get-JiraParsedDesign -Text "## Design`nUse the blue accent.`nSee https://www.figma.com/file/abc/Board" | ConvertFrom-Json
        @($d | Where-Object { $_.kind -eq 'figma_link' }).Count | Should -BeGreaterOrEqual 1
        @($d | Where-Object { $_.kind -eq 'guidance' }).Count | Should -BeGreaterOrEqual 1
    }
}

Describe 'Get-JiraParsedPriority / Estimation' {
    It 'extracts P1' { Get-JiraParsedPriority -Text '### US (Priority: P1)' | Should -Be 'P1' }
    It 'defaults to P2' { Get-JiraParsedPriority -Text 'no priority' | Should -Be 'P2' }
    It 'extracts an estimation number' { Get-JiraParsedEstimation -Text 'Estimation: 5' | Should -Be '5' }
    It 'is null when undeclared' { Get-JiraParsedEstimation -Text 'no estimate' | Should -Be 'null' }
}
