# engine/Markdown.psm1 — Markdown subset -> neutral blocks + marked spans (016).
# Mirror of engine/markdown.sh.
#
# Implements specs/016-jira-markdown-rendering/contracts/markdown-subset.md:
# Part B (block segmentation), Part C (inline tokenization), Part D (emission).
# NEUTRAL layer: zero Jira identifiers, never imports sink/ (Constitution VIII).
# The mark vocabulary is bold/italic/monospace/strikethrough/link — deliberately
# not ADF's strong/em/code/strike (research §1); the sink owns that map.
#
# Pure function from bytes to a neutral tree: this module never opens a file for
# writing (FR-000). Output is byte-identical to the Bash port (NFR-1) via the
# same hand-built JSON string form the Bash port uses (not ConvertTo-Json).

Set-StrictMode -Version Latest

function ConvertTo-JiraMarkdownJsonString {
    <#
    .SYNOPSIS
      JSON-string-escape TEXT exactly as lib/Output.psm1's ConvertTo-JiraJsonString
      does: " \ and the named control escapes, \u00XX for other C0 controls, raw
      UTF-8 otherwise.
    #>
    param([string] $Text)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int][char]$ch
        switch ($ch) {
            '"' { [void]$sb.Append('\"'); continue }
            '\' { [void]$sb.Append('\\'); continue }
            "`b" { [void]$sb.Append('\b'); continue }
            "`f" { [void]$sb.Append('\f'); continue }
            "`n" { [void]$sb.Append('\n'); continue }
            "`r" { [void]$sb.Append('\r'); continue }
            "`t" { [void]$sb.Append('\t'); continue }
            default {
                if ($code -lt 0x20) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
                else { [void]$sb.Append($ch) }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

$script:MdPunct = [System.Collections.Generic.HashSet[char]]::new(
    [char[]]('!"#$%&''()*+,-./:;<=>?@[\]^_`{|}~'.ToCharArray())
)

function Test-JiraMarkdownSpaceChar {
    param([Nullable[char]] $Ch)
    if ($null -eq $Ch) { return $false }
    return ($Ch -eq ' ' -or $Ch -eq "`t")
}

function Test-JiraMarkdownPunctChar {
    param([Nullable[char]] $Ch)
    if ($null -eq $Ch) { return $false }
    return $script:MdPunct.Contains([char]$Ch)
}

$script:MdMarkOrder = @('bold', 'italic', 'link', 'monospace', 'strikethrough')

function Add-JiraMarkdownMark {
    <#
    .SYNOPSIS
      Insert Kind into a comma-joined marks list, keeping canonical alphabetical
      order (D2) and idempotent on a kind already present. Mirror of _md_marks_add.
    #>
    param([string] $Csv, [string] $Kind)
    $present = @()
    if ($Csv -ne '') { $present = $Csv -split ',' }
    if ($present -contains $Kind) { return $Csv }
    $set = [System.Collections.Generic.HashSet[string]]::new([string[]]$present)
    [void]$set.Add($Kind)
    $ordered = $script:MdMarkOrder | Where-Object { $set.Contains($_) }
    return ($ordered -join ',')
}

function ConvertTo-JiraMarkdownMarksJson {
    <#
    .SYNOPSIS
      Render a marks-csv (plus the one href active, iff "link" is present) to a
      JSON array of mark objects. Mirror of _md_marks_csv_to_json.
    #>
    param([string] $Csv, [string] $Href)
    if ($Csv -eq '') { return '[]' }
    $parts = foreach ($k in ($Csv -split ',')) {
        if ($k -eq '') { continue }
        if ($k -eq 'link') {
            '{"href":' + (ConvertTo-JiraMarkdownJsonString $Href) + ',"kind":"link"}'
        }
        else {
            '{"kind":"' + $k + '"}'
        }
    }
    return '[' + ($parts -join ',') + ']'
}

# --- The scanner --------------------------------------------------------------
#
# Spans accumulate into module-scoped lists during a scan (mirrors the Bash
# port's globals) — no per-span allocation of a heavier structure, and no
# subprocess of any kind (research §3's "zero additional subprocess spawns").
$script:MdOutText = [System.Collections.Generic.List[string]]::new()
$script:MdOutMarks = [System.Collections.Generic.List[string]]::new()
$script:MdOutHref = [System.Collections.Generic.List[string]]::new()

function Add-JiraMarkdownSpan {
    param([string] $Text, [string] $Marks, [string] $Href)
    [void]$script:MdOutText.Add($Text)
    [void]$script:MdOutMarks.Add($Marks)
    [void]$script:MdOutHref.Add($Href)
}

function Find-JiraMarkdownUnescaped {
    <#
    .SYNOPSIS
      Index of the first Char at or after Start not preceded by a backslash
      escape, or -1 on failure. Mirror of _md_find_unescaped.
    #>
    param([string] $Text, [int] $Start, [int] $N, [char] $Char)
    $k = $Start
    while ($k -lt $N) {
        if ($Text[$k] -eq '\' -and ($k + 1) -lt $N) { $k += 2; continue }
        if ($Text[$k] -eq $Char) { return $k }
        $k++
    }
    return -1
}

function Find-JiraMarkdownDelimiter {
    <#
    .SYNOPSIS
      C6/C7/C8, governed by C9. Pure match (no emission — the caller must flush
      its pending literal run before scanning the matched content, or emission
      order would invert). Returns $null on failure, else a pscustomobject
      { Content; NewMarks; NextIndex }. Mirror of _md_try_delim.
    #>
    param([string] $Text, [int] $I, [int] $N, [string] $Delim, [string] $Kind, [string] $Marks, [int] $Depth)
    $dlen = $Delim.Length
    if ($Depth -ge 8) { return $null } # C9.6
    if ($I + $dlen -gt $N -or $Text.Substring($I, $dlen) -ne $Delim) { return $null }
    $openEnd = $I + $dlen
    if ($openEnd -ge $N) { return $null } # C9.1
    if (Test-JiraMarkdownSpaceChar $Text[$openEnd]) { return $null } # C9.1

    $underscore = ($Delim -eq '_' -or $Delim -eq '__')
    if ($underscore -and $I -gt 0) {
        $before = $Text[$I - 1]
        if (-not (Test-JiraMarkdownSpaceChar $before) -and -not (Test-JiraMarkdownPunctChar $before)) {
            return $null
        }
    }

    $search = $openEnd
    $closeStart = -1
    $closeEnd = -1
    while ($search -le ($N - $dlen)) {
        if ($Text.Substring($search, $dlen) -eq $Delim) {
            $pc = $Text[$search - 1]
            if (-not (Test-JiraMarkdownSpaceChar $pc)) {
                $ok = $true
                if ($underscore) {
                    $after = $search + $dlen
                    if ($after -lt $N) {
                        $ac = $Text[$after]
                        if (-not (Test-JiraMarkdownSpaceChar $ac) -and -not (Test-JiraMarkdownPunctChar $ac)) {
                            $ok = $false
                        }
                    }
                }
                if ($ok) { $closeStart = $search; $closeEnd = $search + $dlen; break }
            }
        }
        $search++
    }
    if ($closeStart -lt 0) { return $null } # C9.4

    $content = $Text.Substring($openEnd, $closeStart - $openEnd)
    $newMarks = Add-JiraMarkdownMark -Csv $Marks -Kind $Kind
    return [pscustomobject]@{ Content = $content; NewMarks = $newMarks; NextIndex = $closeEnd }
}

function Invoke-JiraMarkdownScan {
    <#
    .SYNOPSIS
      Part C, tried in order C1..C10, C11 fallthrough. Appends spans via
      Add-JiraMarkdownSpan. Mirror of _md_scan.
    #>
    param([string] $Text, [string] $Marks, [string] $Href, [int] $Depth, [bool] $NoLink)
    $n = $Text.Length
    $i = 0
    $run = [System.Text.StringBuilder]::new()

    while ($i -lt $n) {
        $c = $Text[$i]

        # C1 — backslash escape.
        if ($c -eq '\') {
            if ($i + 1 -lt $n) {
                $nc = $Text[$i + 1]
                if (Test-JiraMarkdownPunctChar $nc) { [void]$run.Append($nc) }
                else { [void]$run.Append('\').Append($nc) }
                $i += 2
                continue
            }
            else {
                [void]$run.Append('\')
                $i += 1
                continue
            }
        }

        # C2 — code span: a run of N backticks, closed by exactly N.
        if ($c -eq '`') {
            $j = $i
            $runLen = 0
            while ($j -lt $n -and $Text[$j] -eq '`') { $runLen++; $j++ }
            $search = $j
            $closeStart = -1
            $closeEnd = -1
            while ($search -lt $n) {
                if ($Text[$search] -eq '`') {
                    $k = $search
                    $klen = 0
                    while ($k -lt $n -and $Text[$k] -eq '`') { $klen++; $k++ }
                    if ($klen -eq $runLen) { $closeStart = $search; $closeEnd = $k; break }
                    $search = $k
                }
                else { $search++ }
            }
            if ($closeStart -ge 0) {
                if ($run.Length -gt 0) { Add-JiraMarkdownSpan -Text $run.ToString() -Marks $Marks -Href $Href; [void]$run.Clear() }
                $content = $Text.Substring($j, $closeStart - $j)
                $codeMarks = Add-JiraMarkdownMark -Csv $Marks -Kind 'monospace'
                Add-JiraMarkdownSpan -Text $content -Marks $codeMarks -Href $Href
                $i = $closeEnd
                continue
            }
            else {
                [void]$run.Append($Text.Substring($i, $runLen))
                $i += $runLen
                continue
            }
        }

        # C3 — autolink: <http(s)://...>.
        if ($c -eq '<') {
            $m = [regex]::Match($Text.Substring($i), '^<(https?://[^>\s]+)>')
            if ($m.Success) {
                $url = $m.Groups[1].Value
                if ($run.Length -gt 0) { Add-JiraMarkdownSpan -Text $run.ToString() -Marks $Marks -Href $Href; [void]$run.Clear() }
                $linkMarks = Add-JiraMarkdownMark -Csv $Marks -Kind 'link'
                Add-JiraMarkdownSpan -Text $url -Marks $linkMarks -Href $url
                $i += 2 + $url.Length
                continue
            }
        }

        # C4 — image: ![alt](target).
        if ($c -eq '!' -and ($i + 1) -lt $n -and $Text[$i + 1] -eq '[') {
            $altClose = Find-JiraMarkdownUnescaped -Text $Text -Start ($i + 2) -N $n -Char ']'
            if ($altClose -ge 0 -and ($altClose + 1) -lt $n -and $Text[$altClose + 1] -eq '(') {
                $tgtClose = Find-JiraMarkdownUnescaped -Text $Text -Start ($altClose + 2) -N $n -Char ')'
                if ($tgtClose -ge 0) {
                    $alt = $Text.Substring($i + 2, $altClose - ($i + 2))
                    $tgt = $Text.Substring($altClose + 2, $tgtClose - ($altClose + 2))
                    if ($run.Length -gt 0) { Add-JiraMarkdownSpan -Text $run.ToString() -Marks $Marks -Href $Href; [void]$run.Clear() }
                    $show = if ($alt -ne '') { $alt } else { $tgt }
                    Add-JiraMarkdownSpan -Text $show -Marks $Marks -Href $Href
                    $i = $tgtClose + 1
                    continue
                }
            }
        }

        # C5 — link: [label](target).
        if ($c -eq '[' -and -not $NoLink) {
            $lblClose = Find-JiraMarkdownUnescaped -Text $Text -Start ($i + 1) -N $n -Char ']'
            if ($lblClose -ge 0 -and ($lblClose + 1) -lt $n -and $Text[$lblClose + 1] -eq '(') {
                $tgtClose = Find-JiraMarkdownUnescaped -Text $Text -Start ($lblClose + 2) -N $n -Char ')'
                if ($tgtClose -ge 0) {
                    $label = $Text.Substring($i + 1, $lblClose - ($i + 1))
                    $target = $Text.Substring($lblClose + 2, $tgtClose - ($lblClose + 2))
                    $trimmed = $target.Trim()
                    if ($run.Length -gt 0) { Add-JiraMarkdownSpan -Text $run.ToString() -Marks $Marks -Href $Href; [void]$run.Clear() }
                    if ($trimmed -match '^https?://\S+$') {
                        $saveText = [System.Collections.Generic.List[string]]::new($script:MdOutText)
                        $saveMarks = [System.Collections.Generic.List[string]]::new($script:MdOutMarks)
                        $saveHref = [System.Collections.Generic.List[string]]::new($script:MdOutHref)
                        $script:MdOutText = [System.Collections.Generic.List[string]]::new()
                        $script:MdOutMarks = [System.Collections.Generic.List[string]]::new()
                        $script:MdOutHref = [System.Collections.Generic.List[string]]::new()
                        Invoke-JiraMarkdownScan -Text $label -Marks $Marks -Href $Href -Depth $Depth -NoLink $true
                        $lblText = $script:MdOutText
                        $lblMarks = $script:MdOutMarks
                        $script:MdOutText = $saveText
                        $script:MdOutMarks = $saveMarks
                        $script:MdOutHref = $saveHref
                        for ($li = 0; $li -lt $lblText.Count; $li++) {
                            $lm = Add-JiraMarkdownMark -Csv $lblMarks[$li] -Kind 'link'
                            Add-JiraMarkdownSpan -Text $lblText[$li] -Marks $lm -Href $trimmed
                        }
                    }
                    else {
                        $degraded = "$label ($target)"
                        Invoke-JiraMarkdownScan -Text $degraded -Marks $Marks -Href $Href -Depth $Depth -NoLink $NoLink
                    }
                    $i = $tgtClose + 1
                    continue
                }
            }
        }

        # C6 — strikethrough (~~), C7 — strong (** / __), C8 — emphasis (* / _).
        # A position beginning a run of 2 of the same char only ever tries the
        # 2-char delimiter there — see the Bash port's comment on the same
        # branch for why single-char emphasis must not retry the same run.
        if ($c -eq '~' -and ($i + 2) -le $n -and $Text.Substring($i, 2) -eq '~~') {
            $m = Find-JiraMarkdownDelimiter -Text $Text -I $i -N $n -Delim '~~' -Kind 'strikethrough' -Marks $Marks -Depth $Depth
            if ($null -ne $m) {
                if ($run.Length -gt 0) { Add-JiraMarkdownSpan -Text $run.ToString() -Marks $Marks -Href $Href; [void]$run.Clear() }
                Invoke-JiraMarkdownScan -Text $m.Content -Marks $m.NewMarks -Href $Href -Depth ($Depth + 1) -NoLink $NoLink
                $i = $m.NextIndex
                continue
            }
        }
        if ($c -eq '*' -or $c -eq '_') {
            $d2 = if (($i + 2) -le $n) { $Text.Substring($i, 2) } else { '' }
            if ($d2 -eq '**' -or $d2 -eq '__') {
                $m = Find-JiraMarkdownDelimiter -Text $Text -I $i -N $n -Delim $d2 -Kind 'bold' -Marks $Marks -Depth $Depth
                if ($null -ne $m) {
                    if ($run.Length -gt 0) { Add-JiraMarkdownSpan -Text $run.ToString() -Marks $Marks -Href $Href; [void]$run.Clear() }
                    Invoke-JiraMarkdownScan -Text $m.Content -Marks $m.NewMarks -Href $Href -Depth ($Depth + 1) -NoLink $NoLink
                    $i = $m.NextIndex
                    continue
                }
            }
            else {
                $m = Find-JiraMarkdownDelimiter -Text $Text -I $i -N $n -Delim ([string]$c) -Kind 'italic' -Marks $Marks -Depth $Depth
                if ($null -ne $m) {
                    if ($run.Length -gt 0) { Add-JiraMarkdownSpan -Text $run.ToString() -Marks $Marks -Href $Href; [void]$run.Clear() }
                    Invoke-JiraMarkdownScan -Text $m.Content -Marks $m.NewMarks -Href $Href -Depth ($Depth + 1) -NoLink $NoLink
                    $i = $m.NextIndex
                    continue
                }
            }
        }

        # C10 — raw HTML tag: discarded; inner text scans normally.
        if ($c -eq '<') {
            $nx = if (($i + 1) -lt $n) { $Text[$i + 1] } else { $null }
            if ($null -ne $nx -and ($nx -eq '/' -or [char]::IsLetter($nx))) {
                $gtClose = Find-JiraMarkdownUnescaped -Text $Text -Start ($i + 1) -N $n -Char '>'
                if ($gtClose -ge 0) {
                    $i = $gtClose + 1
                    continue
                }
            }
        }

        # C11 — literal fallthrough.
        [void]$run.Append($c)
        $i++
    }
    if ($run.Length -gt 0) { Add-JiraMarkdownSpan -Text $run.ToString() -Marks $Marks -Href $Href }
}

function ConvertTo-JiraMarkdownInlineSpanList {
    <#
    .SYNOPSIS
      Part C + Part D. Returns a JSON array of spans ({text, marks}), D1-merged
      and D3-trimmed. Mirror of markdown_tokenize_inline.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $script:MdOutText = [System.Collections.Generic.List[string]]::new()
    $script:MdOutMarks = [System.Collections.Generic.List[string]]::new()
    $script:MdOutHref = [System.Collections.Generic.List[string]]::new()
    Invoke-JiraMarkdownScan -Text $Text -Marks '' -Href '' -Depth 0 -NoLink $false

    $ft = [System.Collections.Generic.List[string]]::new()
    $fcsv = [System.Collections.Generic.List[string]]::new()
    $fhref = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $script:MdOutText.Count; $i++) {
        $t = $script:MdOutText[$i]
        $m = $script:MdOutMarks[$i]
        $h = $script:MdOutHref[$i]
        $last = $ft.Count - 1
        if ($last -ge 0 -and $fcsv[$last] -eq $m -and $fhref[$last] -eq $h) {
            $ft[$last] = $ft[$last] + $t
        }
        else {
            [void]$ft.Add($t); [void]$fcsv.Add($m); [void]$fhref.Add($h)
        }
    }

    $parts = for ($i = 0; $i -lt $ft.Count; $i++) {
        if ($ft[$i] -eq '') { continue }
        $marksJson = ConvertTo-JiraMarkdownMarksJson -Csv $fcsv[$i] -Href $fhref[$i]
        '{"text":' + (ConvertTo-JiraMarkdownJsonString $ft[$i]) + ',"marks":' + $marksJson + '}'
    }
    return '[' + (($parts -join ',')) + ']'
}

function Get-JiraMarkdownInlinePlain {
    <#
    .SYNOPSIS
      A single unmarked span wrapping the whole of Text verbatim (no
      tokenization). D3 still applies: empty text -> []. Mirror of
      markdown_inline_plain.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    if ($Text -eq '') { return '[]' }
    return '[{"text":' + (ConvertTo-JiraMarkdownJsonString $Text) + ',"marks":[]}]'
}

# --- Part B — block segmentation ----------------------------------------------

function Split-JiraMarkdownLine {
    param([string] $Text)
    if ($null -eq $Text) { $Text = '' }
    return (($Text -replace "`r`n", "`n") -replace "`r", "`n") -split "`n"
}

function ConvertTo-JiraMarkdownBlockList {
    <#
    .SYNOPSIS
      Part B, B1-B8 (the B9 cap is the caller's — data-model.md §4). Returns a
      JSON array of block objects. Mirror of markdown_parse_blocks.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $lines = Split-JiraMarkdownLine $Text
    $blocksOut = [System.Collections.Generic.List[string]]::new()

    $mode = ''
    $para = ''
    $liLines = [System.Collections.Generic.List[string]]::new()
    $codeLines = [System.Collections.Generic.List[string]]::new()
    $inFence = $false

    $closeOpen = {
        if ($mode -eq 'paragraph' -and $para -ne '') {
            $blocksOut.Add('{"type":"paragraph","spans":' + (ConvertTo-JiraMarkdownInlineSpanList -Text $para) + '}')
        }
        elseif (($mode -eq 'bullet_list' -or $mode -eq 'ordered_list') -and $liLines.Count -gt 0) {
            $items = ($liLines | ForEach-Object { ConvertTo-JiraMarkdownInlineSpanList -Text $_ }) -join ','
            $typeName = if ($mode -eq 'bullet_list') { 'bullet_list' } else { 'ordered_list' }
            $blocksOut.Add('{"type":"' + $typeName + '","items":[' + $items + ']}')
        }
        $mode = ''
        $para = ''
        $liLines.Clear()
    }

    foreach ($rawLine in $lines) {
        $line = $rawLine

        # B5 — blockquote: strip prefix, re-enter segmentation on the remainder.
        $bq = [regex]::Match($line, '^\s*>\s?(.*)$')
        if ($bq.Success) { $line = $bq.Groups[1].Value }

        # B1 — fenced code.
        if (-not $inFence -and $line -match '^\s*(`{3,})') {
            . $closeOpen
            $inFence = $true
            $mode = 'code'
            $codeLines = [System.Collections.Generic.List[string]]::new()
            continue
        }
        if ($inFence) {
            if ($line -match '^\s*(`{3,})') {
                $body = ($codeLines -join "`n")
                $blocksOut.Add('{"type":"code","text":' + (ConvertTo-JiraMarkdownJsonString $body) + '}')
                $mode = ''
                $inFence = $false
                continue
            }
            [void]$codeLines.Add($line)
            continue
        }

        $t = $line.Trim()

        # B7 — blank line.
        if ($t -eq '') {
            . $closeOpen
            continue
        }

        # B2 — ATX heading.
        $hm = [regex]::Match($t, '^(#{1,6})\s+(.*)$')
        if ($hm.Success) {
            . $closeOpen
            $level = $hm.Groups[1].Value.Length
            $htext = $hm.Groups[2].Value -replace '\s*#+\s*$', ''
            $htext = $htext.Trim()
            $blocksOut.Add('{"type":"heading","level":' + $level + ',"spans":' + (ConvertTo-JiraMarkdownInlineSpanList -Text $htext) + '}')
            continue
        }

        # B3 — bullet item.
        $bm = [regex]::Match($t, '^[-*+]\s+(.*)$')
        if ($bm.Success) {
            if ($mode -ne 'bullet_list') { . $closeOpen; $mode = 'bullet_list' }
            [void]$liLines.Add($bm.Groups[1].Value)
            continue
        }

        # B4 — ordered item.
        $om = [regex]::Match($t, '^[0-9]{1,9}[.)]\s+(.*)$')
        if ($om.Success) {
            if ($mode -ne 'ordered_list') { . $closeOpen; $mode = 'ordered_list' }
            [void]$liLines.Add($om.Groups[1].Value)
            continue
        }

        # B6 — table row.
        if ($t.StartsWith('|') -and $t.EndsWith('|') -and $t.Length -ge 2) {
            . $closeOpen
            $cells = [System.Collections.Generic.List[string]]::new()
            $cur = [System.Text.StringBuilder]::new()
            $k = 0
            $tn = $t.Length
            while ($k -lt $tn) {
                $ch = $t[$k]
                if ($ch -eq '\' -and ($k + 1) -lt $tn) {
                    [void]$cur.Append($t.Substring($k, 2))
                    $k += 2
                    continue
                }
                if ($ch -eq '|') {
                    [void]$cells.Add($cur.ToString())
                    [void]$cur.Clear()
                    $k++
                    continue
                }
                [void]$cur.Append($ch)
                $k++
            }
            [void]$cells.Add($cur.ToString())
            $n = $cells.Count
            $trimmedCells = [System.Collections.Generic.List[string]]::new()
            for ($ci = 0; $ci -lt $n; $ci++) {
                if (($ci -eq 0 -or $ci -eq ($n - 1)) -and $cells[$ci].Trim() -eq '') { continue }
                [void]$trimmedCells.Add($cells[$ci].Trim())
            }
            $isDelim = $trimmedCells.Count -gt 0
            $hasDash = $false
            foreach ($tc in $trimmedCells) {
                if ($tc -notmatch '^[-:\s]+$') { $isDelim = $false }
                if ($tc.Contains('-')) { $hasDash = $true }
            }
            if ($isDelim -and $hasDash) { continue }
            $joined = ($trimmedCells -join ' — ')
            $blocksOut.Add('{"type":"paragraph","spans":' + (ConvertTo-JiraMarkdownInlineSpanList -Text $joined) + '}')
            continue
        }

        # B8 — paragraph (fallthrough). A list closes at a non-matching line.
        if ($mode -eq 'bullet_list' -or $mode -eq 'ordered_list') { . $closeOpen }
        $mode = 'paragraph'
        if ($para -ne '') { $para = "$para $t" } else { $para = $t }
    }

    if ($inFence) {
        $body = ($codeLines -join "`n")
        $blocksOut.Add('{"type":"code","text":' + (ConvertTo-JiraMarkdownJsonString $body) + '}')
    }
    else {
        . $closeOpen
    }

    return '[' + ($blocksOut -join ',') + ']'
}

Export-ModuleMember -Function ConvertTo-JiraMarkdownInlineSpanList, Get-JiraMarkdownInlinePlain, ConvertTo-JiraMarkdownBlockList
