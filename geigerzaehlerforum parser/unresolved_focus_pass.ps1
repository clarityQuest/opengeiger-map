Set-Content .\_unresolved_focus_started.txt -Value "started" -Encoding utf8
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
    'maps\.google[^"''\s]*[?&]q=(?<lat>-?\d{1,2}\.\d+),(?<lon>-?\d{1,3}\.\d+)',
    '#\d+(?:\.\d+)?/(?<lat>-?\d{1,2}\.\d+)/(?<lon>-?\d{1,3}\.\d+)',
    '#\d+(?:\.\d+)?-(?<lon>-?\d{1,3}\.\d+)-(?<lat>-?\d{1,2}\.\d+)'
  )
  foreach($p in $mapPats){
    $m=[regex]::Match($html,$p,[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if($m.Success){ $c=NormCoord $m.Groups['lat'].Value $m.Groups['lon'].Value; if($c){ return $c } }
  }

  $short=[regex]::Matches($html,'https?://(?:goo\.gl/maps|maps\.app\.goo\.gl|bit\.ly|t\.co)/[^"''\s<]+',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  foreach($s in $short){
    try{
      $resp=Invoke-WebRequest -UseBasicParsing -Uri $s.Value -MaximumRedirection 8 -Headers @{'User-Agent'='geiger-map/1.4'}
      $u=''
      if($resp.BaseResponse -and $resp.BaseResponse.ResponseUri){ $u=[string]$resp.BaseResponse.ResponseUri.AbsoluteUri }
      foreach($p in $mapPats){
        $m=[regex]::Match($u,$p,[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if($m.Success){ $c=NormCoord $m.Groups['lat'].Value $m.Groups['lon'].Value; if($c){ return $c } }
      }
    } catch {}
  }

  $t=[regex]::Replace([regex]::Replace([regex]::Replace($html,'<script[\s\S]*?</script>',' '),'<style[\s\S]*?</style>',' '),'<[^>]+>',' ')
  $t=[System.Net.WebUtility]::HtmlDecode($t)
  $t=[regex]::Replace($t,'\s+',' ')

  $textPats=@(
    '(?<lat>-?\d{1,2}[\.,]\d{3,})\s*[,;/]+\s*(?<lon>-?\d{1,3}[\.,]\d{3,})',
    '(?<lat>-?\d{1,2}[\.,]\d{3,})\s*°\s*[NnSs]?\s*[ ,;]+\s*(?:[EeWw]\s*)?(?<lon>-?\d{1,3}[\.,]\d{3,})\s*°',
    '(?<lat>-?\d{1,2}[\.,]\d{3,})\s*°?\s*[NnSs]?\s*[,;/ ]+\s*[EeWw]\s*(?<lon>-?\d{1,3}[\.,]\d{3,})\s*°?',
    '[Nn]\s*(?<lat>\d{1,2}[\.,]\d+)\s*°?\s*[ ,;]+\s*[Ee]\s*(?<lon>\d{1,3}[\.,]\d+)\s*°?'
  )
  foreach($p in $textPats){
    $m=[regex]::Match($t,$p,[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if($m.Success){ $c=NormCoord (($m.Groups['lat'].Value -replace ',','.')) (($m.Groups['lon'].Value -replace ',','.')); if($c){ return $c } }
  }

  return $null
}

function Geocode([string]$q){
  if([string]::IsNullOrWhiteSpace($q)){ return $null }
  $enc=[uri]::EscapeDataString($q)
  $url="https://nominatim.openstreetmap.org/search?format=jsonv2&limit=1&q=$enc"
  try{
    Start-Sleep -Milliseconds 1100
    $r=Invoke-RestMethod -Uri $url -Headers @{'User-Agent'='geiger-map/1.4'}
    if($r -and $r.Count -gt 0){ return (NormCoord $r[0].lat $r[0].lon) }
  } catch {}
  return $null
}

$filledSource=0
$filledGeo=0

foreach($r in $rows){
  if($r.gps_coordinates -and $r.gps_coordinates.Trim().Length -gt 0){ continue }

  $coord=$null
  if($r.source_url){
    try{ $html=(Invoke-WebRequest -UseBasicParsing -Uri $r.source_url -Headers @{'User-Agent'='geiger-map/1.4'}).Content } catch { $html=$null }
    $coord=ExtractFromHtml $html
  }

  if($coord){
    $r.gps_coordinates=$coord
    $filledSource++
    continue
  }

  $queries=@()
  if($r.name){ $queries += $r.name.Trim() }
  if($r.name -match '[:\-/,]\s*([^:\-/,]+)$'){ $queries += $matches[1].Trim() }
  if($r.location -and $r.location.Trim() -ne $r.name.Trim()){ $queries += $r.location.Trim() }
  if($r.name){ $queries += ($r.name.Trim() + ', Germany') }

  foreach($q in ($queries | Select-Object -Unique)){
    $coord=Geocode $q
    if($coord){ break }
  }

  if($coord){
    $r.gps_coordinates=$coord
    $filledGeo++
  }
}

$rows | Export-Csv .\geigerzaehlerforum_places_table.csv -NoTypeInformation -Encoding UTF8
$unresolved = $rows | Where-Object { -not $_.gps_coordinates -or $_.gps_coordinates.Trim().Length -eq 0 }
$unresolved | Export-Csv .\geigerzaehlerforum_places_unresolved.csv -NoTypeInformation -Encoding UTF8

Set-Content .\_unresolved_focus_summary.txt -Value @(
  "total=$($rows.Count)",
  "filled_from_source=$filledSource",
  "filled_from_geocode=$filledGeo",
  "with_coords=$(( $rows | Where-Object { $_.gps_coordinates -and $_.gps_coordinates.Trim().Length -gt 0 }).Count)",
  "missing=$($unresolved.Count)"
) -Encoding utf8
Set-Content .\_unresolved_focus_finished.txt -Value "finished" -Encoding utf8
