# T024/T025/T047/T048 [US1/US2] — the neutral mark -> ADF mark map (research
# §1, feature 016). Mirror of tests/bash/sink/test_adf_marks.bats.

BeforeAll {
    $Root = Join-Path $PSScriptRoot '../../..'
    $Sink = Join-Path $Root 'scripts/powershell/sink/jira'
    Import-Module (Join-Path $Sink 'Adf.psm1') -Force
    Import-Module (Join-Path $Sink '../../lib/Output.psm1') -Force -Global

    function Get-DescContent([string] $BlocksJson) {
        return (ConvertTo-JiraJsonValue ([ordered]@{ description = [ordered]@{ blocks = ($BlocksJson | ConvertFrom-Json -Depth 20) } }))
    }
}

Describe 'the neutral mark -> ADF mark map' {
    It 'bold maps to strong' {
        $c = Get-DescContent '[{"type":"paragraph","spans":[{"text":"x","marks":[{"kind":"bold"}]}]}]'
        $doc = ConvertTo-JiraAdfDocument -ContentJson $c | ConvertFrom-Json -Depth 20
        $doc.content[0].content[0].marks[0].type | Should -Be 'strong'
    }
    It 'italic maps to em' {
        $c = Get-DescContent '[{"type":"paragraph","spans":[{"text":"x","marks":[{"kind":"italic"}]}]}]'
        $doc = ConvertTo-JiraAdfDocument -ContentJson $c | ConvertFrom-Json -Depth 20
        $doc.content[0].content[0].marks[0].type | Should -Be 'em'
    }
    It 'monospace maps to code' {
        $c = Get-DescContent '[{"type":"paragraph","spans":[{"text":"x","marks":[{"kind":"monospace"}]}]}]'
        $doc = ConvertTo-JiraAdfDocument -ContentJson $c | ConvertFrom-Json -Depth 20
        $doc.content[0].content[0].marks[0].type | Should -Be 'code'
    }
    It 'strikethrough maps to strike' {
        $c = Get-DescContent '[{"type":"paragraph","spans":[{"text":"x","marks":[{"kind":"strikethrough"}]}]}]'
        $doc = ConvertTo-JiraAdfDocument -ContentJson $c | ConvertFrom-Json -Depth 20
        $doc.content[0].content[0].marks[0].type | Should -Be 'strike'
    }
    It 'link maps to link with href' {
        $c = Get-DescContent '[{"type":"paragraph","spans":[{"text":"docs","marks":[{"kind":"link","href":"https://example.com/x"}]}]}]'
        $doc = ConvertTo-JiraAdfDocument -ContentJson $c | ConvertFrom-Json -Depth 20
        $doc.content[0].content[0].marks[0].type | Should -Be 'link'
        $doc.content[0].content[0].marks[0].attrs.href | Should -Be 'https://example.com/x'
    }
    It 'a span with no marks carries no marks key at all' {
        $c = Get-DescContent '[{"type":"paragraph","spans":[{"text":"x","marks":[]}]}]'
        $doc = ConvertTo-JiraAdfDocument -ContentJson $c | ConvertFrom-Json -Depth 20
        ($doc.content[0].content[0].PSObject.Properties.Name -contains 'marks') | Should -BeFalse
    }
}

Describe 'ordered_list and verbatim code bodies (FR-007)' {
    It 'ordered_list renders as an ADF orderedList of listItem paragraphs' {
        $c = Get-DescContent '[{"type":"ordered_list","items":[[{"text":"first","marks":[]}],[{"text":"second","marks":[]}]]}]'
        $doc = ConvertTo-JiraAdfDocument -ContentJson $c | ConvertFrom-Json -Depth 20
        $doc.content[0].type | Should -Be 'orderedList'
        @($doc.content[0].content).Count | Should -Be 2
        $doc.content[0].content[0].type | Should -Be 'listItem'
        $doc.content[0].content[0].content[0].content[0].text | Should -Be 'first'
        $doc.content[0].content[1].content[0].content[0].text | Should -Be 'second'
    }
    It 'a code block body is verbatim — no inline mark interpretation' {
        $c = Get-DescContent '[{"type":"code","text":"**not bold** and [not](a-link)"}]'
        $doc = ConvertTo-JiraAdfDocument -ContentJson $c | ConvertFrom-Json -Depth 20
        $doc.content[0].type | Should -Be 'codeBlock'
        $doc.content[0].content[0].text | Should -Be '**not bold** and [not](a-link)'
        ($doc.content[0].content[0].PSObject.Properties.Name -contains 'marks') | Should -BeFalse
    }
    It 'an empty code body renders no content nodes' {
        $c = Get-DescContent '[{"type":"code","text":""}]'
        $doc = ConvertTo-JiraAdfDocument -ContentJson $c | ConvertFrom-Json -Depth 20
        $doc.content[0].type | Should -Be 'codeBlock'
        @($doc.content[0].content).Count | Should -Be 0
    }
}
