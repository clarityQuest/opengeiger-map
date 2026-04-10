param(
  [int]$Start = 0,
  [int]$BatchSize = 20
)

$rows = Import-Csv .\geigerzaehlerforum_places_table.csv

function NormCoord([string]$lat,[string]$lon){
  if([string]::IsNullOrWhiteSpace($lat) -or [string]::IsNullOrWhiteSpace($lon)){ return $null }
  $latv=0.0; $lonv=0.0
  $la=$lat.Trim().Replace(',','.')
  $lo=$lon.Trim().Replace(',','.')
  if(-not [double]::TryParse($la,[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$latv)){ return $null }
  if(-not [double]::TryParse($lo,[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$lonv)){ return $null }
  if($latv -lt -90 -or $latv -gt 90){ return $null }
  if($lonv -lt -180 -or $lonv -gt 180){ return $null }
  if([math]::Abs($latv) -lt 5 -and [math]::Abs($lonv) -lt 5){ return $null }
  return ("{0},{1}" -f $latv.ToString('0.######',[System.Globalization.CultureInfo]::InvariantCulture),$lonv.ToString('0.######',[System.Globalization.CultureInfo]::InvariantCulture))
}

function ExtractFromHtml([string]$html){
  if([string]::IsNullOrWhiteSpace($html)){ return $null }
  $mapPats=@(
    '(?:[?&](?:q|query|ll|sll)=)(?<lat>-?\d{1,2}\.\d+),(?<lon>-?\d{1,3}\.\d+)',
    '@(?<lat>-?\d{1,2}\.\d+),(?<lon>-?\d{1,3}\.\d+),',
    '#\d+(?:\.\d+)?/(?<lat>-?\d{1,2}\.\d+)/(?<lon>-?\d{1,3}\.\d+)',
    '#\d+(?:\.\d+)?-(?<lon>-?\d{1,3}\.\d+)-(?<lat>-?\d{1,2}\.\d+)'
  )
  foreach($p in $mapPats){
    $m=[regex]::Match($html,$p,[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if($m.Success){ $c=NormCoord $m.Groups['lat'].Value $m.Groups['lon'].Value; if($c){ return $c } }
  }

  $t=[regex]::Replace([regex]::Replace([regex]::Replace($html,'<script[\s\S]*?</script>',' '),'<style[\s\S]*?</style>',' '),'<[^>]+>',' ')
  $t=[System.Net.WebUtility]::HtmlDecode($t)
  $t=[regex]::Replace($t,'\s+',' ')
  $textPats=@(
    '(?<lat>-?\d{1,2}[\.,]\d{3,})\s*°\s*[NnSs]?\s*[ ,;]+\s*(?:[EeWw]\s*)?(?<lon>-?\d{1,3}[\.,]\d{3,})\s*°',
    '(?<lat>-?\d{1,2}[\.,]\d{3,})\s*°?\s*[NnSs]?\s*[,;/ ]+\s*[EeWw]\s*(?<lon>-?\d{1,3}[\.,]\d{3,})\s*°?',
    '(?<lat>-?\d{1,2}[\.,]\d{3,})\s*[,;/]+\s*(?<lon>-?\d{1,3}[\.,]\d{3,})'
  )
  foreach($p in $textPats){
    $m=[regex]::Match($t,$p,[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if($m.Success){ $c=NormCoord ($m.Groups['lat'].Value -replace ',','.') ($m.Groups['lon'].Value -replace ',','.'); if($c){ return $c } }
  }
  return $null
}

function Geocode([string]$q){
  if([string]::IsNullOrWhiteSpace($q)){ return $null }
  $enc=[uri]::EscapeDataString($q)
  $url="https://nominatim.openstreetmap.org/search?format=jsonv2&limit=1&q=$enc"
  try{
    Start-Sleep -Milliseconds 1100
    $r=Invoke-RestMethod -Uri $url -Headers @{'User-Agent'='geiger-map/1.5'}
    if($r -and $r.Count -gt 0){ return (NormCoord $r[0].lat $r[0].lon) }
  } catch {}
  return $null
}

$missingIdx = @()
for($i=0; $i -lt $rows.Count; $i++){
  if(-not $rows[$i].gps_coordinates -or $rows[$i].gps_coordinates.Trim().Length -eq 0){ $missingIdx += $i }
}

$end = [Math]::Min($Start + $BatchSize, $missingIdx.Count)
$filled = 0
for($k=$Start; $k -lt $end; $k++){
  $i = $missingIdx[$k]
  $r = $rows[$i]
  $coord = $null

  if($r.source_url){
    try { $html=(Invoke-WebRequest -UseBasicParsing -Uri $r.source_url -Headers @{'User-Agent'='geiger-map/1.5'}).Content } catch { $html=$null }
    $coord = ExtractFromHtml $html
  }

  if(-not $coord){
    $queries=@()
    if($r.name){ $queries += $r.name.Trim() }
    if($r.name -match '[:\-/,]\s*([^:\-/,]+)$'){ $queries += $matches[1].Trim() }
    if($r.location -and $r.location.Trim() -ne $r.name.Trim()){ $queries += $r.location.Trim() }
    if($r.name){ $queries += ($r.name.Trim() + ', Germany') }
    foreach($q in ($queries | Select-Object -Unique)){
      $coord = Geocode $q
      if($coord){ break }
    }
  }

  if($coord){
    $rows[$i].gps_coordinates = $coord
    $filled++
  }
}

$rows | Export-Csv .\geigerzaehlerforum_places_table.csv -NoTypeInformation -Encoding UTF8
$unresolved = $rows | Where-Object { -not $_.gps_coordinates -or $_.gps_coordinates.Trim().Length -eq 0 }
$unresolved | Export-Csv .\geigerzaehlerforum_places_unresolved.csv -NoTypeInformation -Encoding UTF8

Set-Content .\_chunk_summary.txt -Value @(
  "start=$Start",
  "batch_size=$BatchSize",
  "processed=$($end-$Start)",
  "filled=$filled",
  "remaining=$($unresolved.Count)"
) -Encoding utf8
