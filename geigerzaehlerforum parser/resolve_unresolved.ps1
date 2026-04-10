param(
  [string]$CsvPath = ".\\geigerzaehlerforum_places_table.csv",
  [string]$UnresolvedOut = ".\\geigerzaehlerforum_places_unresolved.csv",
  [string]$SummaryOut = ".\\_unresolved_pass_summary.txt"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $CsvPath)) {
  throw "CSV file not found: $CsvPath"
}

Set-Content -Path .\_unresolved_pass_started.txt -Value "started" -Encoding utf8

$rows = Import-Csv $CsvPath
$script:LastNominatimCall = Get-Date '2000-01-01'
$script:LastPhotonCall = Get-Date '2000-01-01'
$script:HtmlCache = @{}

function Wait-ApiThrottle {
  param(
    [string]$ApiName,
    [int]$MinimumDelayMs
  )

  $now = Get-Date
  if ($ApiName -eq 'nominatim') {
    $elapsed = ($now - $script:LastNominatimCall).TotalMilliseconds
    if ($elapsed -lt $MinimumDelayMs) {
      Start-Sleep -Milliseconds ([int]($MinimumDelayMs - $elapsed))
    }
    $script:LastNominatimCall = Get-Date
    return
  }

  if ($ApiName -eq 'photon') {
    $elapsed = ($now - $script:LastPhotonCall).TotalMilliseconds
    if ($elapsed -lt $MinimumDelayMs) {
      Start-Sleep -Milliseconds ([int]($MinimumDelayMs - $elapsed))
    }
    $script:LastPhotonCall = Get-Date
    return
  }
}

function Normalize-QueryText {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
  $t = [System.Net.WebUtility]::HtmlDecode($Text)
  $t = $t -replace '^\s*(Re:|Aw:|FW:|Fwd:)\s*', ''
  $t = $t -replace '[_"''`]', ' '
  $t = $t -replace '\s+', ' '
  return $t.Trim()
}

function Normalize-CoordString {
  param([string]$Lat, [string]$Lon)

  if ([string]::IsNullOrWhiteSpace($Lat) -or [string]::IsNullOrWhiteSpace($Lon)) {
    return $null
  }

  $latRaw = $Lat.Trim().Replace(',', '.')
  $lonRaw = $Lon.Trim().Replace(',', '.')

  $lat = 0.0
  $lon = 0.0
  $okLat = [double]::TryParse($latRaw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$lat)
  $okLon = [double]::TryParse($lonRaw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$lon)
  if (-not ($okLat -and $okLon)) { return $null }

  if ($lat -lt -90 -or $lat -gt 90) { return $null }
  if ($lon -lt -180 -or $lon -gt 180) { return $null }

  # Reject low-value non-coordinate pairs that often come from dose values.
  if ([math]::Abs($lat) -lt 5 -and [math]::Abs($lon) -lt 5) { return $null }

  return ("{0},{1}" -f $lat.ToString("0.######", [System.Globalization.CultureInfo]::InvariantCulture), $lon.ToString("0.######", [System.Globalization.CultureInfo]::InvariantCulture))
}

function Get-ForumPageHtml {
  param([string]$Url)

  if ($script:HtmlCache.ContainsKey($Url)) {
    return $script:HtmlCache[$Url]
  }

  try {
    $html = (Invoke-WebRequest -UseBasicParsing -Uri $Url -Headers @{"User-Agent"="geiger-map/1.3"}).Content
    $script:HtmlCache[$Url] = $html
    return $html
  } catch {
    return $null
  }
}

function Get-TokenScore {
  param([string]$Query, [string]$DisplayName)

  $q = (Normalize-QueryText $Query).ToLowerInvariant()
  $d = (Normalize-QueryText $DisplayName).ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($q) -or [string]::IsNullOrWhiteSpace($d)) { return 0 }

  $tokens = $q -split '\s+' | Where-Object { $_.Length -ge 3 }
  if ($tokens.Count -eq 0) { return 0 }

  $score = 0
  foreach ($t in $tokens) {
    if ($d.Contains($t)) { $score++ }
  }
  return $score
}

function GeocodeWithNominatim {
  param([string]$Query)

  if ([string]::IsNullOrWhiteSpace($Query)) { return $null }
  $q = [uri]::EscapeDataString($Query)
  $url = "https://nominatim.openstreetmap.org/search?format=jsonv2&addressdetails=1&limit=5&q=$q"

  for ($try = 0; $try -lt 3; $try++) {
    try {
      Wait-ApiThrottle -ApiName 'nominatim' -MinimumDelayMs 1100
      $resp = Invoke-RestMethod -Uri $url -Headers @{"User-Agent"="geiger-map/1.3"}
      if ($resp -and $resp.Count -gt 0) {
        $best = $null
        $bestScore = -1
        foreach ($item in $resp) {
          $display = ""
          if ($item.display_name) { $display = [string]$item.display_name }
          $score = Get-TokenScore -Query $Query -DisplayName $display
          if ($score -gt $bestScore) {
            $bestScore = $score
            $best = $item
          }
        }
        if ($best) {
          $coord = Normalize-CoordString -Lat $best.lat -Lon $best.lon
          if ($coord) { return $coord }
        }
      }
    } catch {}
    Start-Sleep -Milliseconds (600 + (400 * $try))
  }

  return $null
}

function GeocodeWithPhoton {
  param([string]$Query)

  if ([string]::IsNullOrWhiteSpace($Query)) { return $null }
  $q = [uri]::EscapeDataString($Query)
  $url = "https://photon.komoot.io/api/?q=$q&limit=5"

  try {
    Wait-ApiThrottle -ApiName 'photon' -MinimumDelayMs 350
    $resp = Invoke-RestMethod -Uri $url -Headers @{"User-Agent"="geiger-map/1.3"}
    if ($resp -and $resp.features -and $resp.features.Count -gt 0) {
      $best = $null
      $bestScore = -1
      foreach ($f in $resp.features) {
        $desc = ""
        if ($f.properties.name) { $desc += [string]$f.properties.name + " " }
        if ($f.properties.city) { $desc += [string]$f.properties.city + " " }
        if ($f.properties.country) { $desc += [string]$f.properties.country }
        $score = Get-TokenScore -Query $Query -DisplayName $desc
        if ($score -gt $bestScore) {
          $bestScore = $score
          $best = $f
        }
      }
      if ($best -and $best.geometry -and $best.geometry.coordinates -and $best.geometry.coordinates.Count -ge 2) {
        $lon = [string]$best.geometry.coordinates[0]
        $lat = [string]$best.geometry.coordinates[1]
        $coord = Normalize-CoordString -Lat $lat -Lon $lon
        if ($coord) { return $coord }
      }
    }
  } catch {}

  return $null
}

function Get-LocationTailCandidates {
  param([string]$Title)

  $candidates = New-Object System.Collections.Generic.List[string]
  $clean = Normalize-QueryText $Title
  if (-not [string]::IsNullOrWhiteSpace($clean)) {
    $candidates.Add($clean)
  }

  $parts = $clean -split '\s+-\s+|\s+/\s+|:\s*|,\s*'
  if ($parts.Count -gt 1) {
    $tail = $parts[$parts.Count - 1].Trim()
    if ($tail.Length -ge 3) { $candidates.Add($tail) }
  }

  $inMatch = [regex]::Match($clean, '\bin\s+([\p{L}0-9 .\-]+)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($inMatch.Success) {
    $seg = $inMatch.Groups[1].Value.Trim()
    if ($seg.Length -ge 3) { $candidates.Add($seg) }
  }

  return ($candidates | Where-Object { $_ -and $_.Trim().Length -ge 3 } | Select-Object -Unique)
}

function Get-TopicTitleFromHtml {
  param([string]$Html)

  if ([string]::IsNullOrWhiteSpace($Html)) { return "" }
  $m = [regex]::Match($Html, '<title>([\s\S]*?)</title>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if (-not $m.Success) { return "" }

  $title = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
  $title = $title -replace '\s*-\s*geigerzaehlerforum\.de\s*$', ''
  return (Normalize-QueryText $title)
}

function Get-TopicPageUrls {
  param([string]$SourceUrl)

  if ([string]::IsNullOrWhiteSpace($SourceUrl)) { return @() }

  $urls = New-Object System.Collections.Generic.List[string]
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'
  $queue = New-Object System.Collections.Generic.Queue[string]

  $queue.Enqueue($SourceUrl)
  [void]$seen.Add($SourceUrl)

  while ($queue.Count -gt 0 -and $urls.Count -lt 20) {
    $url = $queue.Dequeue()
    $urls.Add($url)

    $html = Get-ForumPageHtml -Url $url
    if ([string]::IsNullOrWhiteSpace($html)) { continue }

    # Capture pagination links within the same topic.
    $topicId = ""
    $tm = [regex]::Match($SourceUrl, 'topic,(?<id>\d+)\.\d+\.html', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($tm.Success) { $topicId = $tm.Groups['id'].Value }

    if (-not [string]::IsNullOrWhiteSpace($topicId)) {
      $matches = [regex]::Matches($html, ('https?://www\.geigerzaehlerforum\.de/index\.php/topic,' + $topicId + '\.\d+\.html'), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
      foreach ($m in $matches) {
        $u = $m.Value
        if (-not $seen.Contains($u)) {
          [void]$seen.Add($u)
          $queue.Enqueue($u)
        }
      }
    }
  }

  return $urls
}

function ExtractCoordFromAnyText {
  param([string]$Text)

  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

  $patterns = @(
    '(?<lat>-?\d{1,2}[\.,]\d{3,})\s*[,;/]+\s*(?<lon>-?\d{1,3}[\.,]\d{3,})',
    '(?<lat>-?\d{1,2}[\.,]\d{3,})\s*°\s*[NnSs]?\s*[ ,;]+\s*(?:[EeWw]\s*)?(?<lon>-?\d{1,3}[\.,]\d{3,})\s*°',
    '(?<lat>-?\d{1,2}[\.,]\d{3,})\s*°?\s*[NnSs]?\s*[,;/ ]+\s*[EeWw]\s*(?<lon>-?\d{1,3}[\.,]\d{3,})\s*°?',
    '[Nn]\s*(?<lat>\d{1,2}[\.,]\d+)\s*°?\s*[ ,;]+\s*[Ee]\s*(?<lon>\d{1,3}[\.,]\d+)\s*°?'
  )

  foreach ($p in $patterns) {
    $m = [regex]::Match($Text, $p, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $coord = Normalize-CoordString -Lat $m.Groups['lat'].Value -Lon $m.Groups['lon'].Value
      if ($coord) { return $coord }
    }
  }

  # DMS format
  $dms = [regex]::Match(
    $Text,
    '[Nn]\s*(?<latDeg>\d{1,2})\s*°\s*(?<latMin>\d{1,2})\s*[\'']\s*(?<latSec>\d{1,2}(?:[\.,]\d+)?)\s*["]?\s*[ ,;]+\s*[Ee]\s*(?<lonDeg>\d{1,3})\s*°\s*(?<lonMin>\d{1,2})\s*[\'']\s*(?<lonSec>\d{1,2}(?:[\.,]\d+)?)\s*["]?',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
  if ($dms.Success) {
    $latDeg = [double](($dms.Groups['latDeg'].Value) -replace ',', '.')
    $latMin = [double](($dms.Groups['latMin'].Value) -replace ',', '.')
    $latSec = [double](($dms.Groups['latSec'].Value) -replace ',', '.')
    $lonDeg = [double](($dms.Groups['lonDeg'].Value) -replace ',', '.')
    $lonMin = [double](($dms.Groups['lonMin'].Value) -replace ',', '.')
    $lonSec = [double](($dms.Groups['lonSec'].Value) -replace ',', '.')

    $lat = $latDeg + ($latMin / 60.0) + ($latSec / 3600.0)
    $lon = $lonDeg + ($lonMin / 60.0) + ($lonSec / 3600.0)
    $coord = Normalize-CoordString -Lat $lat.ToString([System.Globalization.CultureInfo]::InvariantCulture) -Lon $lon.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    if ($coord) { return $coord }
  }

  return $null
}

function ExtractCoordFromHtml {
  param([string]$Html)

  if ([string]::IsNullOrWhiteSpace($Html)) { return $null }

  $mapPatterns = @(
    '(?:[?&](?:q|query|ll|sll)=)(?<lat>-?\d{1,2}\.\d+),(?<lon>-?\d{1,3}\.\d+)',
    '@(?<lat>-?\d{1,2}\.\d+),(?<lon>-?\d{1,3}\.\d+),',
    'maps\.google[^"''\s]*[?&]q=(?<lat>-?\d{1,2}\.\d+),(?<lon>-?\d{1,3}\.\d+)',
    '#\d+(?:\.\d+)?/(?<lat>-?\d{1,2}\.\d+)/(?<lon>-?\d{1,3}\.\d+)',
    '#\d+(?:\.\d+)?-(?<lon>-?\d{1,3}\.\d+)-(?<lat>-?\d{1,2}\.\d+)'
  )

  foreach ($p in $mapPatterns) {
    $m = [regex]::Match($Html, $p, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $coord = Normalize-CoordString -Lat $m.Groups['lat'].Value -Lon $m.Groups['lon'].Value
      if ($coord) { return $coord }
    }
  }

  # Resolve shortened map links and parse final URL.
  $shortMapLinks = [regex]::Matches(
    $Html,
    'https?://(?:goo\.gl/maps|maps\.app\.goo\.gl|bit\.ly|t\.co)/[^"''\s<]+',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
  foreach ($link in $shortMapLinks) {
    $shortUrl = $link.Value
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri $shortUrl -MaximumRedirection 8 -Headers @{"User-Agent"="geiger-map/1.3"}
      $finalUrl = ""
      if ($resp.BaseResponse -and $resp.BaseResponse.ResponseUri) {
        $finalUrl = [string]$resp.BaseResponse.ResponseUri.AbsoluteUri
      }
      if (-not [string]::IsNullOrWhiteSpace($finalUrl)) {
        foreach ($p in $mapPatterns) {
          $m = [regex]::Match($finalUrl, $p, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
          if ($m.Success) {
            $coord = Normalize-CoordString -Lat $m.Groups['lat'].Value -Lon $m.Groups['lon'].Value
            if ($coord) { return $coord }
          }
        }
      }
    } catch {}
  }

  $text = [regex]::Replace($Html, '<script[\s\S]*?</script>', ' ')
  $text = [regex]::Replace($text, '<style[\s\S]*?</style>', ' ')
  $text = [regex]::Replace($text, '<[^>]+>', ' ')
  $text = [System.Net.WebUtility]::HtmlDecode($text)
  $text = [regex]::Replace($text, '\s+', ' ')

  return (ExtractCoordFromAnyText -Text $text)
}

function BuildOrderedQueries {
  param(
    [string]$ForumTitle,
    [string]$CsvName,
    [string]$CsvLocation
  )

  $queries = New-Object System.Collections.Generic.List[string]

  $fullForumTitle = Normalize-QueryText $ForumTitle
  $fullCsvName = Normalize-QueryText $CsvName
  $fullCsvLocation = Normalize-QueryText $CsvLocation

  if ($fullForumTitle) { $queries.Add($fullForumTitle) }
  if ($fullCsvName) { $queries.Add($fullCsvName) }
  if ($fullCsvLocation -and $fullCsvLocation -ne $fullCsvName) { $queries.Add($fullCsvLocation) }

  foreach ($q in (Get-LocationTailCandidates -Title $fullForumTitle)) { $queries.Add($q) }
  foreach ($q in (Get-LocationTailCandidates -Title $fullCsvName)) { $queries.Add($q) }

  if ($fullForumTitle) { $queries.Add($fullForumTitle + ', Germany') }
  if ($fullCsvName) { $queries.Add($fullCsvName + ', Germany') }
  foreach ($q in (Get-LocationTailCandidates -Title $fullForumTitle)) { $queries.Add($q + ', Germany') }
  foreach ($q in (Get-LocationTailCandidates -Title $fullCsvName)) { $queries.Add($q + ', Germany') }

  return ($queries | Where-Object { $_ -and $_.Trim().Length -ge 2 } | Select-Object -Unique)
}

$resolvedFromPages = 0
$resolvedFromGeocode = 0
$missingBefore = ($rows | Where-Object { [string]::IsNullOrWhiteSpace($_.gps_coordinates) }).Count

foreach ($r in $rows) {
  if (-not [string]::IsNullOrWhiteSpace($r.gps_coordinates)) { continue }

  $coord = $null
  $topicTitle = ""

  $topicUrls = Get-TopicPageUrls -SourceUrl $r.source_url
  foreach ($u in $topicUrls) {
    $html = Get-ForumPageHtml -Url $u
    if ([string]::IsNullOrWhiteSpace($html)) { continue }

    if ([string]::IsNullOrWhiteSpace($topicTitle)) {
      $topicTitle = Get-TopicTitleFromHtml -Html $html
    }

    $coord = ExtractCoordFromHtml -Html $html
    if ($coord) { break }
  }

  if ($coord) {
    $r.gps_coordinates = $coord
    $resolvedFromPages++
    continue
  }

  $queries = BuildOrderedQueries -ForumTitle $topicTitle -CsvName $r.name -CsvLocation $r.location
  foreach ($q in $queries) {
    $coord = GeocodeWithNominatim -Query $q
    if (-not $coord) { $coord = GeocodeWithPhoton -Query $q }
    if ($coord) { break }
  }

  if ($coord) {
    $r.gps_coordinates = $coord
    $resolvedFromGeocode++
  }
}

$rows | Export-Csv $CsvPath -NoTypeInformation -Encoding UTF8

$unresolved = $rows | Where-Object { [string]::IsNullOrWhiteSpace($_.gps_coordinates) }
$unresolved | Export-Csv $UnresolvedOut -NoTypeInformation -Encoding UTF8

$missingAfter = $unresolved.Count

$out = @()
$out += "total=$($rows.Count)"
$out += "missing_before=$missingBefore"
$out += "resolved_from_pages=$resolvedFromPages"
$out += "resolved_from_geocode=$resolvedFromGeocode"
$out += "missing_after=$missingAfter"
$out += "updated_csv=$((Resolve-Path $CsvPath).Path)"
$out += "unresolved_csv=$((Resolve-Path $UnresolvedOut).Path)"

Set-Content -Path $SummaryOut -Value $out -Encoding utf8
Set-Content -Path .\_unresolved_pass_finished.txt -Value "finished" -Encoding utf8
