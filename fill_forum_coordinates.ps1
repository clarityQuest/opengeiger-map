param(
  [string]$CsvPath = ".\\geigerzaehlerforum_places_table.csv",
  [string]$UnresolvedOut = ".\\geigerzaehlerforum_places_unresolved.csv"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $CsvPath)) {
  throw "CSV file not found: $CsvPath"
}

$rows = Import-Csv $CsvPath
$script:LastNominatimCall = Get-Date '2000-01-01'
$script:LastPhotonCall = Get-Date '2000-01-01'

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

function Get-LocationTailCandidates {
  param([string]$Title)
  $candidates = New-Object System.Collections.Generic.List[string]
  if ([string]::IsNullOrWhiteSpace($Title)) { return @() }

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
    $segment = $inMatch.Groups[1].Value.Trim()
    if ($segment.Length -ge 3) { $candidates.Add($segment) }
  }

  $parenMatches = [regex]::Matches($clean, '\(([^\)]+)\)')
  foreach ($m in $parenMatches) {
    $segment = $m.Groups[1].Value.Trim()
    if ($segment.Length -ge 3) { $candidates.Add($segment) }
  }

  return ($candidates | Where-Object { $_ -and $_.Trim().Length -ge 3 } | Select-Object -Unique)
}

function Build-OrderedQueries {
  param(
    [string]$ForumTitle,
    [string]$CsvName,
    [string]$CsvLocation
  )

  $queries = New-Object System.Collections.Generic.List[string]

  $fullForumTitle = Normalize-QueryText $ForumTitle
  $fullCsvName = Normalize-QueryText $CsvName
  $fullCsvLocation = Normalize-QueryText $CsvLocation

  # Priority 1: full title text from the dedicated forum topic page.
  if ($fullForumTitle) { $queries.Add($fullForumTitle) }

  # Priority 2: full title text stored in the CSV.
  if ($fullCsvName) { $queries.Add($fullCsvName) }
  if ($fullCsvLocation -and $fullCsvLocation -ne $fullCsvName) { $queries.Add($fullCsvLocation) }

  # Priority 3: place tail at the end of title (often the exact location).
  foreach ($q in (Get-LocationTailCandidates -Title $fullForumTitle)) { $queries.Add($q) }
  foreach ($q in (Get-LocationTailCandidates -Title $fullCsvName)) { $queries.Add($q) }

  # Last fallback: add country context where most entries are expected.
  if ($fullForumTitle) { $queries.Add($fullForumTitle + ', Germany') }
  if ($fullCsvName) { $queries.Add($fullCsvName + ', Germany') }
  foreach ($q in (Get-LocationTailCandidates -Title $fullForumTitle)) { $queries.Add($q + ', Germany') }
  foreach ($q in (Get-LocationTailCandidates -Title $fullCsvName)) { $queries.Add($q + ', Germany') }

  return ($queries | Where-Object { $_ -and $_.Trim().Length -ge 2 } | Select-Object -Unique)
}

function Get-TopicTitleFromHtml {
  param([string]$Html)
  if ([string]::IsNullOrWhiteSpace($Html)) { return "" }

  $titleMatch = [regex]::Match($Html, '<title>([\s\S]*?)</title>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if (-not $titleMatch.Success) { return "" }

  $title = [System.Net.WebUtility]::HtmlDecode($titleMatch.Groups[1].Value)
  $title = $title -replace '\s*-\s*geigerzaehlerforum\.de\s*$', ''
  return (Normalize-QueryText $title)
}

function Get-ForumPageHtml {
  param([string]$Url)
  try {
    return (Invoke-WebRequest -UseBasicParsing -Uri $Url -Headers @{"User-Agent"="geiger-map/1.1"}).Content
  } catch {
    return $null
  }
}

function Normalize-CoordString {
  param([string]$Lat, [string]$Lon)
  if ([string]::IsNullOrWhiteSpace($Lat) -or [string]::IsNullOrWhiteSpace($Lon)) {
    return $null
  }
  $lat = $Lat.Trim().Replace(',', '.')
  $lon = $Lon.Trim().Replace(',', '.')

  $latValue = 0.0
  $lonValue = 0.0
  if (-not [double]::TryParse($lat, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$latValue)) { return $null }
  if (-not [double]::TryParse($lon, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$lonValue)) { return $null }

  if ($latValue -lt -90 -or $latValue -gt 90) { return $null }
  if ($lonValue -lt -180 -or $lonValue -gt 180) { return $null }

  return ("{0},{1}" -f $latValue.ToString("0.######", [System.Globalization.CultureInfo]::InvariantCulture), $lonValue.ToString("0.######", [System.Globalization.CultureInfo]::InvariantCulture))
}

function Try-ExtractCoordFromText {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

  $patterns = @(
    # Decimal pairs with explicit separators (comma/semicolon/slash), avoids plain-space false positives.
    '(?<lat>-?\d{1,2}[\.,]\d{3,})\s*[,;/]+\s*(?<lon>-?\d{1,3}[\.,]\d{3,})',
    # Decimal pair with degree symbols and optional cardinal letters, e.g. "52.743001° 13.222016°".
    '(?<lat>-?\d{1,2}[\.,]\d{3,})\s*°\s*[NnSs]?\s*[ ,;]+\s*(?:[EeWw]\s*)?(?<lon>-?\d{1,3}[\.,]\d{3,})\s*°',
    # Decimal pairs with cardinal marker between values, e.g. "50.77306° E 12.42910°"
    '(?<lat>-?\d{1,2}[\.,]\d{3,})\s*°?\s*[NnSs]?\s*[,;/ ]+\s*[EeWw]\s*(?<lon>-?\d{1,3}[\.,]\d{3,})\s*°?',
    # N/E prefixed decimal coordinates
    '[Nn]\s*(?<lat>\d{1,2}[\.,]\d+)\s*°?\s*[ ,;]+\s*[Ee]\s*(?<lon>\d{1,3}[\.,]\d+)\s*°?',
    # Decimal with labels
    '(?:lat|latitude)\s*[:=]\s*(?<lat>-?\d{1,2}[\.,]\d+)\s*[,;/ ]+\s*(?:lon|lng|long|longitude)\s*[:=]\s*(?<lon>-?\d{1,3}[\.,]\d+)'
  )

  foreach ($p in $patterns) {
    $m = [regex]::Match($Text, $p, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $latRaw = ($m.Groups['lat'].Value -replace ',', '.')
      $lonRaw = ($m.Groups['lon'].Value -replace ',', '.')
      $latNum = 0.0
      $lonNum = 0.0
      $okLat = [double]::TryParse($latRaw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$latNum)
      $okLon = [double]::TryParse($lonRaw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$lonNum)
      if (-not ($okLat -and $okLon)) { continue }

      # Reject implausible low-value pairs often coming from dose values like 0.205 / 0.2186.
      if ([math]::Abs($latNum) -lt 5 -and [math]::Abs($lonNum) -lt 5) { continue }

      $norm = Normalize-CoordString -Lat $latRaw -Lon $lonRaw
      if ($norm) { return $norm }
    }
  }

  # DMS patterns, e.g. N 52° 44' 34.8" E 13° 13' 19.3"
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
    $norm = Normalize-CoordString -Lat $lat.ToString([System.Globalization.CultureInfo]::InvariantCulture) -Lon $lon.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    if ($norm) { return $norm }
  }

  return $null
}

function Try-ExtractCoordFromForumPage {
  param([string]$Url, [string]$Html)

  if ([string]::IsNullOrWhiteSpace($Html) -and -not [string]::IsNullOrWhiteSpace($Url)) {
    $Html = Get-ForumPageHtml -Url $Url
  }
  if ([string]::IsNullOrWhiteSpace($Html)) {
    return $null
  }

  # Direct map query params
  $mapPatterns = @(
    '(?:[?&](?:q|query|ll|sll)=)(?<lat>-?\d{1,2}\.\d+),(?<lon>-?\d{1,3}\.\d+)',
    '@(?<lat>-?\d{1,2}\.\d+),(?<lon>-?\d{1,3}\.\d+),',
    'maps\.google[^"''\s]*[?&]q=(?<lat>-?\d{1,2}\.\d+),(?<lon>-?\d{1,3}\.\d+)',
    '#\d+(?:\.\d+)?/(?<lat>-?\d{1,2}\.\d+)/(?<lon>-?\d{1,3}\.\d+)'
  )

  foreach ($p in $mapPatterns) {
    $m = [regex]::Match($Html, $p, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $norm = Normalize-CoordString -Lat $m.Groups['lat'].Value -Lon $m.Groups['lon'].Value
      if ($norm) { return $norm }
    }
  }

  # Resolve shortened map links (e.g. goo.gl/maps) and parse final redirected URL.
  $shortMapLinks = [regex]::Matches(
    $Html,
    'https?://(?:goo\.gl/maps|maps\.app\.goo\.gl|bit\.ly|t\.co)/[^"''\s<]+',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
  foreach ($link in $shortMapLinks) {
    $shortUrl = $link.Value
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri $shortUrl -MaximumRedirection 8 -Headers @{"User-Agent"="geiger-map/1.2"}
      $finalUrl = ""
      if ($resp.BaseResponse -and $resp.BaseResponse.ResponseUri) {
        $finalUrl = [string]$resp.BaseResponse.ResponseUri.AbsoluteUri
      }
      if (-not [string]::IsNullOrWhiteSpace($finalUrl)) {
        foreach ($p in $mapPatterns) {
          $m = [regex]::Match($finalUrl, $p, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
          if ($m.Success) {
            $norm = Normalize-CoordString -Lat $m.Groups['lat'].Value -Lon $m.Groups['lon'].Value
            if ($norm) { return $norm }
          }
        }
      }
    } catch {}
  }

  # Fallback plain text parse
  $text = [regex]::Replace($Html, '<script[\s\S]*?</script>', ' ')
  $text = [regex]::Replace($text, '<style[\s\S]*?</style>', ' ')
  $text = [regex]::Replace($text, '<[^>]+>', ' ')
  $text = [System.Net.WebUtility]::HtmlDecode($text)
  $text = [regex]::Replace($text, '\s+', ' ')

  return (Try-ExtractCoordFromText -Text $text)
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
  $email = $env:NOMINATIM_CONTACT_EMAIL
  if ([string]::IsNullOrWhiteSpace($email)) {
    $url = "https://nominatim.openstreetmap.org/search?format=jsonv2&addressdetails=1&limit=5&q=$q"
  } else {
    $emailEscaped = [uri]::EscapeDataString($email)
    $url = "https://nominatim.openstreetmap.org/search?format=jsonv2&addressdetails=1&limit=5&email=$emailEscaped&q=$q"
  }

  for ($try = 0; $try -lt 3; $try++) {
    try {
      Wait-ApiThrottle -ApiName 'nominatim' -MinimumDelayMs 1100
      $resp = Invoke-RestMethod -Uri $url -Headers @{"User-Agent"="geiger-map/1.2"}
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
          $norm = Normalize-CoordString -Lat $best.lat -Lon $best.lon
          if ($norm) { return $norm }
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
    $resp = Invoke-RestMethod -Uri $url -Headers @{"User-Agent"="geiger-map/1.2"}
    if ($resp -and $resp.features -and $resp.features.Count -gt 0) {
      $best = $null
      $bestScore = -1
      foreach ($f in $resp.features) {
        $props = ""
        if ($f.properties.name) { $props += [string]$f.properties.name + " " }
        if ($f.properties.city) { $props += [string]$f.properties.city + " " }
        if ($f.properties.country) { $props += [string]$f.properties.country }
        $score = Get-TokenScore -Query $Query -DisplayName $props
        if ($score -gt $bestScore) {
          $bestScore = $score
          $best = $f
        }
      }
      if ($best -and $best.geometry -and $best.geometry.coordinates -and $best.geometry.coordinates.Count -ge 2) {
        $lon = [string]$best.geometry.coordinates[0]
        $lat = [string]$best.geometry.coordinates[1]
        $norm = Normalize-CoordString -Lat $lat -Lon $lon
        if ($norm) { return $norm }
      }
    }
  } catch {}

  return $null
}

function GeocodeWithGoogleApi {
  param([string]$Query)
  if ([string]::IsNullOrWhiteSpace($Query)) { return $null }

  $key = $env:GOOGLE_MAPS_API_KEY
  if ([string]::IsNullOrWhiteSpace($key)) { return $null }

  $q = [uri]::EscapeDataString($Query)
  $u = "https://maps.googleapis.com/maps/api/geocode/json?address=$q&key=$key"

  try {
    $resp = Invoke-RestMethod -Uri $u
    if ($resp.status -eq "OK" -and $resp.results.Count -gt 0) {
      $lat = $resp.results[0].geometry.location.lat
      $lon = $resp.results[0].geometry.location.lng
      return (Normalize-CoordString -Lat $lat -Lon $lon)
    }
  } catch {}

  return $null
}

$resolvedFromSource = 0
$resolvedFromGeo = 0
$already = 0

foreach ($r in $rows) {
  if (-not [string]::IsNullOrWhiteSpace($r.gps_coordinates)) {
    $already++
    continue
  }

  $coord = $null
  $topicTitle = ""
  $pageHtml = $null

  if (-not [string]::IsNullOrWhiteSpace($r.source_url)) {
    $pageHtml = Get-ForumPageHtml -Url $r.source_url
    $topicTitle = Get-TopicTitleFromHtml -Html $pageHtml

    # Step 1: first try to extract explicit coordinates from the dedicated forum page.
    $coord = Try-ExtractCoordFromForumPage -Url $r.source_url -Html $pageHtml
  }

  if (-not $coord) {
    # Step 2: geocode with ordered title strategy:
    # full title first, then title tail/place segment.
    $queries = Build-OrderedQueries -ForumTitle $topicTitle -CsvName $r.name -CsvLocation $r.location

    foreach ($q in $queries) {
      $coord = GeocodeWithGoogleApi -Query $q
      if (-not $coord) {
        $coord = GeocodeWithNominatim -Query $q
      }
      if (-not $coord) {
        $coord = GeocodeWithPhoton -Query $q
      }
      if ($coord) { break }
    }
  }

  if ($coord) {
    $r.gps_coordinates = $coord
    if ([string]::IsNullOrWhiteSpace($r.location)) {
      $r.location = $r.name
    }
    if ($r.source_url -and (Try-ExtractCoordFromForumPage -Url $r.source_url -Html $pageHtml)) {
      $resolvedFromSource++
    } else {
      $resolvedFromGeo++
    }
  }
}

$rows | Export-Csv $CsvPath -NoTypeInformation -Encoding UTF8

$unresolved = $rows | Where-Object { [string]::IsNullOrWhiteSpace($_.gps_coordinates) }
$unresolved | Export-Csv $UnresolvedOut -NoTypeInformation -Encoding UTF8

Write-Output ("Total rows: {0}" -f $rows.Count)
Write-Output ("Already had coordinates: {0}" -f $already)
Write-Output ("Resolved from source pages: {0}" -f $resolvedFromSource)
Write-Output ("Resolved via geocoding: {0}" -f $resolvedFromGeo)
Write-Output ("Still unresolved: {0}" -f $unresolved.Count)
Write-Output ("Updated CSV: {0}" -f (Resolve-Path $CsvPath))
Write-Output ("Unresolved CSV: {0}" -f (Resolve-Path $UnresolvedOut))
