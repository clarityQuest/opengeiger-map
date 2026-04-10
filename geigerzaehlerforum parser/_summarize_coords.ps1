$rows = Import-Csv .\geigerzaehlerforum_places_table.csv
$total = $rows.Count
$withCoords = ($rows | Where-Object { $_.gps_coordinates -and $_.gps_coordinates.Trim().Length -gt 0 }).Count
$missing = $total - $withCoords
$out = @()
$out += "total=$total"
$out += "with_coords=$withCoords"
$out += "missing=$missing"
if (Test-Path .\geigerzaehlerforum_places_unresolved.csv) {
  $u = Import-Csv .\geigerzaehlerforum_places_unresolved.csv
  $out += "unresolved_file_rows=$($u.Count)"
}
Set-Content .\_coord_summary.txt -Value $out -Encoding utf8
