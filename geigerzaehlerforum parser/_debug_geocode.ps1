$q = 'cold war museum berlin'
$enc = [uri]::EscapeDataString($q)
$out = @()
$out += "query=$q"

try {
  $n = Invoke-RestMethod -Uri ("https://nominatim.openstreetmap.org/search?format=jsonv2&limit=3&q=" + $enc) -Headers @{"User-Agent"="geiger-map/1.1"}
  $out += "nominatim_count=$($n.Count)"
  if ($n -and $n.Count -gt 0) {
    $out += "nominatim_1=$($n[0].lat),$($n[0].lon) | $($n[0].display_name)"
  }
} catch {
  $out += "nominatim_error=$($_.Exception.Message)"
}

try {
  $p = Invoke-RestMethod -Uri ("https://photon.komoot.io/api/?q=" + $enc + "&limit=3") -Headers @{"User-Agent"="geiger-map/1.1"}
  $out += "photon_count=$($p.features.Count)"
  if ($p.features -and $p.features.Count -gt 0) {
    $coords = $p.features[0].geometry.coordinates
    $out += "photon_1=$($coords[1]),$($coords[0]) | $($p.features[0].properties.name)"
  }
} catch {
  $out += "photon_error=$($_.Exception.Message)"
}

Set-Content -Path .\_debug_geocode.txt -Value $out -Encoding utf8
