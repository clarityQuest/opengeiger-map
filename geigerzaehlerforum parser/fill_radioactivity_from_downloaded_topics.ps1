param(
  [string]$InputCsv = ".\geigerzaehlerforum_places_table.csv",
  [string]$TopicsDir = ".\geigerzaehlerforum parser\downloaded_board6\topics",
  [string]$OutputCsv = ".\geigerzaehlerforum_places_table.csv",
  [string]$ReportOut = ".\geigerzaehlerforum parser\_radioactivity_fill_summary.txt"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $InputCsv)) { throw "CSV not found: $InputCsv" }
if (-not (Test-Path $TopicsDir)) { throw "Topics dir not found: $TopicsDir" }

function Get-TopicRootFromUrl {
  param([string]$Url)
  if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
  $m = [regex]::Match($Url, 'topic,(\d+)\.')
  if ($m.Success) {
    return ("topic,{0}" -f $m.Groups[1].Value)
  }
  return $null
}

function Convert-ToUSvPerHour {
  param(
    [string]$NumText,
    [string]$UnitText
  )

  if ([string]::IsNullOrWhiteSpace($NumText) -or [string]::IsNullOrWhiteSpace($UnitText)) { return $null }

  $num = 0.0
  $txt = $NumText.Trim().Replace(',', '.')
  if (-not [double]::TryParse($txt, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$num)) {
    return $null
  }

  $u = $UnitText.ToLowerInvariant().Replace('μ', 'µ')
  if ($u -eq 'msv') { return ($num * 1000.0) }
  if ($u -eq 'usv' -or $u -eq 'µsv') { return $num }
  return $null
}

function Get-MaxDoseFromText {
  param([string]$Text)

  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

  $pattern = '(?<a>\d{1,7}(?:[\.,]\d{1,6})?)\s*(?:-|–|bis)?\s*(?<b>\d{1,7}(?:[\.,]\d{1,6})?)?\s*(?<unit>uSv|µSv|μSv|mSv)\s*/\s*h'
  $matches = [regex]::Matches($Text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

  $best = $null
  foreach ($m in $matches) {
    $u = $m.Groups['unit'].Value
    $va = Convert-ToUSvPerHour -NumText $m.Groups['a'].Value -UnitText $u
    if ($null -ne $va) {
      if ($null -eq $best -or $va -gt $best) { $best = $va }
    }

    if ($m.Groups['b'].Success -and -not [string]::IsNullOrWhiteSpace($m.Groups['b'].Value)) {
      $vb = Convert-ToUSvPerHour -NumText $m.Groups['b'].Value -UnitText $u
      if ($null -ne $vb) {
        if ($null -eq $best -or $vb -gt $best) { $best = $vb }
      }
    }
  }

  return $best
}

# Build max dose per topic-root from downloaded topic html.
$topicMax = @{}
Get-ChildItem -Path $TopicsDir -Filter "*.html" -File | ForEach-Object {
  try {
    $raw = Get-Content -Path $_.FullName -Raw -Encoding UTF8
    $urlMatch = [regex]::Match($raw, 'property="og:url"\s+content="([^"]+)"', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $urlMatch.Success) { return }

    $topicUrl = $urlMatch.Groups[1].Value
    $topicRoot = Get-TopicRootFromUrl -Url $topicUrl
    if (-not $topicRoot) { return }

    $decoded = [System.Net.WebUtility]::HtmlDecode($raw)
    $plain = [regex]::Replace($decoded, '<[^>]+>', ' ')
    $plain = [regex]::Replace($plain, '\s+', ' ')

    $maxUSv = Get-MaxDoseFromText -Text $plain
    if ($null -eq $maxUSv) { return }

    if (-not $topicMax.ContainsKey($topicRoot) -or $maxUSv -gt $topicMax[$topicRoot]) {
      $topicMax[$topicRoot] = $maxUSv
    }
  } catch {
    # Keep processing other files.
  }
}

$rows = Import-Csv -Path $InputCsv
$filled = 0
$consideredEmpty = 0

foreach ($r in $rows) {
  $existing = [string]$r.max_radioactivity
  if (-not [string]::IsNullOrWhiteSpace($existing)) { continue }

  $consideredEmpty++
  $root = Get-TopicRootFromUrl -Url $r.source_url
  if (-not $root) { continue }
  if (-not $topicMax.ContainsKey($root)) { continue }

  $val = [double]$topicMax[$root]
  # Guard against clearly implausible parse artifacts.
  if ($val -le 0 -or $val -gt 100000000) { continue }

  $r.max_radioactivity = ("{0} uSv/h" -f $val.ToString("0.######", [System.Globalization.CultureInfo]::InvariantCulture))
  if ([string]::IsNullOrWhiteSpace([string]$r.reading_source)) {
    $r.reading_source = "text-auto"
  }
  $filled++
}

$rows | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8

@(
  "topic_roots_with_values=" + $topicMax.Count,
  "rows_empty_before=" + $consideredEmpty,
  "rows_filled=" + $filled,
  "output_csv=" + $OutputCsv
) | Set-Content -Path $ReportOut -Encoding utf8

Write-Host ("Done. Filled rows: {0}" -f $filled)
Write-Host ("Report: {0}" -f $ReportOut)
