# T008/T011/T013/T015/T017 [027] — Pester twin of test_designator.bats.
# Designator grammar and reduction (contracts/designator-grammar.md).

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot '../../../scripts/powershell/sink/jira/Designator.psm1'
    Import-Module $ModulePath -Force
    $script:Base = 'https://acme.atlassian.net'
}

Describe 'Designator grammar (§2, D1)' {
    It 'PROJ-123 accepts' {
        Get-JiraDesignatorKey -Raw 'PROJ-123' | Should -Be 'PROJ-123'
    }
    It 'proj-123 normalises to upper case' {
        Get-JiraDesignatorKey -Raw 'proj-123' | Should -Be 'PROJ-123'
    }
    It 'P-1 refuses' {
        Get-JiraDesignatorKey -Raw 'P-1' | Should -BeNullOrEmpty
    }
    It 'PROJ- refuses' {
        Get-JiraDesignatorKey -Raw 'PROJ-' | Should -BeNullOrEmpty
    }
    It '1PROJ-1 refuses' {
        Get-JiraDesignatorKey -Raw '1PROJ-1' | Should -BeNullOrEmpty
    }
}

Describe 'URL reduction (§3, D2-D4)' {
    It 'D2: browse path reduces to the key' {
        $r = Resolve-JiraDesignator -Role story -Raw "$script:Base/browse/PROJ-123" -BaseUrl $script:Base | ConvertFrom-Json
        $r.form | Should -Be 'url'
        $r.key | Should -Be 'PROJ-123'
    }
    It 'D2: board-context URL with selectedIssue reduces to the key' {
        $r = Resolve-JiraDesignator -Role story -Raw "$script:Base/jira/software/projects/PROJ/boards/7?selectedIssue=PROJ-123" -BaseUrl $script:Base | ConvertFrom-Json
        $r.key | Should -Be 'PROJ-123'
    }
    It 'D2: trailing query or anchor still reduces' {
        $r = Resolve-JiraDesignator -Role story -Raw "$script:Base/browse/PROJ-123?filter=42#comment-9" -BaseUrl $script:Base | ConvertFrom-Json
        $r.key | Should -Be 'PROJ-123'
    }
    It 'D3: selectedIssue wins when the path segment disagrees' {
        $r = Resolve-JiraDesignator -Role story -Raw "$script:Base/browse/PROJ-999?selectedIssue=PROJ-123" -BaseUrl $script:Base | ConvertFrom-Json
        $r.key | Should -Be 'PROJ-123'
    }
    It 'D4: percent-encoded selectedIssue decodes before the grammar check' {
        $r = Resolve-JiraDesignator -Role story -Raw "$script:Base/jira/software/boards/7?selectedIssue=PROJ%2D123" -BaseUrl $script:Base | ConvertFrom-Json
        $r.key | Should -Be 'PROJ-123'
    }
}

Describe 'Host comparison (§4, D5-D6)' {
    It 'D5: host mismatch refuses with REF-HOST' {
        $r = Resolve-JiraDesignator -Role story -Raw 'https://evil.example.com/browse/PROJ-123' -BaseUrl $script:Base | ConvertFrom-Json
        $r.refuse | Should -Be 'REF-HOST'
    }
    It 'D5: an unrecognised URL shape is REF-DESIGNATOR, not REF-HOST' {
        $r = Resolve-JiraDesignator -Role story -Raw 'https://evil.example.com/not-an-issue-path' -BaseUrl $script:Base | ConvertFrom-Json
        $r.refuse | Should -Be 'REF-DESIGNATOR'
    }
    It 'D6: a base URL with a path prefix matches, and reduces' {
        $dc = 'https://jira.example.com/jira/'
        $r = Resolve-JiraDesignator -Role story -Raw 'https://jira.example.com/jira/browse/PROJ-1' -BaseUrl $dc | ConvertFrom-Json
        $r.key | Should -Be 'PROJ-1'
    }
}

Describe 'Order and de-duplication (§6, D7/D9)' {
    It 'D7: same issue as key and as URL is REF-DUPLICATE' {
        $a = Resolve-JiraDesignator -Role story -Raw 'PROJ-11' -BaseUrl $script:Base
        $b = Resolve-JiraDesignator -Role story -Raw "$script:Base/browse/PROJ-11" -BaseUrl $script:Base
        $result = Resolve-JiraDesignatorSet -Items "[$a,$b]" | ConvertFrom-Json
        $result.ok | Should -Be $false
        @($result.duplicates).Count | Should -Be 1
        $result.duplicates[0] | Should -Be 'PROJ-11'
    }
    It 'D9: ten designators, positions preserved in argv order' {
        $items = @()
        for ($i = 1; $i -le 10; $i++) { $items += (Resolve-JiraDesignator -Role story -Raw "PROJ-$i" -BaseUrl $script:Base) }
        $arr = '[' + ($items -join ',') + ']'
        $result = Resolve-JiraDesignatorSet -Items $arr | ConvertFrom-Json
        $result.ok | Should -Be $true
        @($result.designators).Count | Should -Be 10
        $result.designators[0].position | Should -Be 0
        $result.designators[9].position | Should -Be 9
        $result.designators[4].key | Should -Be 'PROJ-5'
    }
    It 'naming one issue as both roles is REF-DUPLICATE' {
        $parent = Resolve-JiraDesignator -Role specification -Raw 'PROJ-1' -BaseUrl $script:Base
        $story = Resolve-JiraDesignator -Role story -Raw 'PROJ-1' -BaseUrl $script:Base
        $result = Resolve-JiraDesignatorSet -Items "[$parent,$story]" | ConvertFrom-Json
        $result.ok | Should -Be $false
        $result.duplicates[0] | Should -Be 'PROJ-1'
    }
}

Describe 'Free text (§5, D8)' {
    It 'D8: blank free-text parent refuses with REF-DESIGNATOR' {
        $r = Resolve-JiraDesignator -Role specification -Raw '   ' -BaseUrl $script:Base | ConvertFrom-Json
        $r.refuse | Should -Be 'REF-DESIGNATOR'
    }
    It 'D8: non-blank free text is legal only for the specification role' {
        $r = Resolve-JiraDesignator -Role specification -Raw 'Payment webhooks rollout' -BaseUrl $script:Base | ConvertFrom-Json
        $r.form | Should -Be 'free_text'
        $r.text | Should -Be 'Payment webhooks rollout'
    }
    It 'D8: free text on the story role refuses with REF-DESIGNATOR' {
        $r = Resolve-JiraDesignator -Role story -Raw 'not a key or url' -BaseUrl $script:Base | ConvertFrom-Json
        $r.refuse | Should -Be 'REF-DESIGNATOR'
    }
}

Describe 'Windows (§7, D10)' {
    It 'D10: a designator with a trailing CR reduces identically' {
        $r = Resolve-JiraDesignator -Role story -Raw "PROJ-123`r" -BaseUrl $script:Base | ConvertFrom-Json
        $r.key | Should -Be 'PROJ-123'
    }
    It 'D10: a browse URL with a trailing CR reduces identically' {
        $r = Resolve-JiraDesignator -Role story -Raw "$script:Base/browse/PROJ-123`r" -BaseUrl $script:Base | ConvertFrom-Json
        $r.key | Should -Be 'PROJ-123'
    }
}

Describe 'a key-form designator with no configured base URL' {
    It 'classifies a key with an EMPTY -BaseUrl without throwing (027, Seed.psm1 resume, no SPEC_KIT_JIRA_BASE_URL)' {
        # Regression: Resolve-JiraDesignator's -BaseUrl param lacked
        # AllowEmptyString(), so a resume comparison with pure key-form
        # designators crashed whenever SPEC_KIT_JIRA_BASE_URL was unset —
        # bash's designator_classify has no such constraint on its base_url
        # string, so this was a PowerShell-only divergence.
        $r = Resolve-JiraDesignator -Role story -Raw 'PROJ-11' -BaseUrl '' | ConvertFrom-Json
        $r.key | Should -Be 'PROJ-11'
        $r.form | Should -Be 'key'
    }
}

Describe 'de-duplicating a set that includes a free-text (US2) specification designator' {
    It 'does not throw when the specification role is free-text (no -key at all)' {
        # Regression: Resolve-JiraDesignatorSet's key-collection ForEach-Object
        # accessed .key unconditionally, throwing PropertyNotFoundException
        # under Set-StrictMode for a free_text-form entry — bash's jq `.key`
        # is forgiving (undefined -> null), so this was a PowerShell-only
        # divergence, first hit by 027's free-text parent-creation path.
        $items = @(
            [ordered]@{ role = 'specification'; raw = 'Payment webhooks rollout'; form = 'free_text'; text = 'Payment webhooks rollout' },
            [ordered]@{ role = 'story'; raw = 'PROJ-11'; form = 'key'; key = 'PROJ-11' }
        ) | ConvertTo-Json -Depth 10 -Compress
        { Resolve-JiraDesignatorSet -Items $items } | Should -Not -Throw
        $result = Resolve-JiraDesignatorSet -Items $items | ConvertFrom-Json
        $result.ok | Should -Be $true
    }
}

Describe 'T064: FR-047, credentials never reach argv, logs, or traces' {
    It 'Designator.psm1 never references a credential variable or header' {
        $content = Get-Content -Raw -LiteralPath $ModulePath
        $content | Should -Not -Match 'JIRA_API_TOKEN'
        $content | Should -Not -Match 'Authorization'
    }
}
