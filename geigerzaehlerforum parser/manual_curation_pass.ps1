# manual_curation_pass.ps1
# Curated geocoding pass using manually identified place names from titles

$ErrorActionPreference = "Continue"
$csvPath = ".\geigerzaehlerforum_places_table.csv"

# Ordered list: [ partial-name-substring, geocoding-query ]
# First match wins. Entries without a match are skipped.
$mappings = @(
    @('Cherbourg',                       'Cherbourg-en-Cotentin France'),
    @('Karlsbad',                        'Karlovy Vary Czech Republic'),
    @('Aschaffenbrug',                   'Aschaffenburg Germany'),
    @('Schneeberg',                      'Schneeberg Erzgebirge Germany'),
    @('Ottofelsen',                      'Ottofelsen Harz Germany'),
    @('Thumkuhlental',                   'Ottofelsen Harz Germany'),
    @('Seelingstädt',                    'Seelingstädt Thuringia Germany'),
    @('Krümmel',                         'Kernkraftwerk Krümmel Geesthacht Germany'),
    @('Wernigerode',                     'Wernigerode Germany'),
    @('Merkers',                         'Merkers Thuringia Germany'),
    @('nahe Prag',                       'Prague Czech Republic'),
    @('Osjorsk',                         'Ozersk Chelyabinsk Russia'),
    @('Pripjat',                         'Pripyat Ukraine'),
    @('Freital',                         'Freital Saxony Germany'),
    @('Antonsthal',                      'Antonsthal Erzgebirge Germany'),
    @('Zehdenick',                       'Zehdenick Brandenburg Germany'),
    @('Vogelsang',                       'Vogelsang Zehdenick Brandenburg Germany'),
    @('Gosel',                           'Bad Frankenhausen Thuringia Germany'),
    @('Frankenhausen',                   'Bad Frankenhausen Thuringia Germany'),
    @('Tännichtgrund',                   'Meißen Saxony Germany'),
    @('Magdeburg',                       'Magdeburg Germany'),
    @('Tschernobyl',                     'Chernobyl Ukraine'),
    @('Chernobyl',                       'Chernobyl Ukraine'),
    @('Pripyat',                         'Pripyat Ukraine'),
    @('atommuzeum',                      'Temelín Czech Republic'),
    @('HAZMAT radioactive',              'Chernobyl Ukraine')
)

function Geocode-Place {
    param([string]$query)
    # Try Photon (komoot) first
    try {
        $encoded = [uri]::EscapeDataString($query)
        $url = "https://photon.komoot.io/api/?q=$encoded&limit=1"
        $r = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = 'geiger-map/1.5' } -TimeoutSec 15
        if ($r -and $r.features -and $r.features.Count -gt 0) {
            $coords = $r.features[0].geometry.coordinates
            $lon = [double]$coords[0]; $lat = [double]$coords[1]
            if ([Math]::Abs($lat) -lt 5 -and [Math]::Abs($lon) -lt 5) { return $null }
            return "$lat,$lon"
        }
    } catch { }
    # Fallback: Nominatim
    try {
        $encoded = [uri]::EscapeDataString($query)
        $url = "https://nominatim.openstreetmap.org/search?format=jsonv2&limit=1&q=$encoded"
        $r = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = 'geiger-map/1.5' } -TimeoutSec 15
        if ($r -and $r.Count -gt 0) {
            $lat = [double]$r[0].lat; $lon = [double]$r[0].lon
            if ([Math]::Abs($lat) -lt 5 -and [Math]::Abs($lon) -lt 5) { return $null }
            return "$lat,$lon"
        }
    } catch { }
    return $null
}

$rows = Import-Csv $csvPath
$filled = 0
$skipped = 0

foreach ($row in $rows) {
    if ($row.gps_coordinates -and $row.gps_coordinates.Trim() -ne '') { continue }

    $name = $row.name
    $query = $null

    foreach ($m in $mappings) {
        if ($name -like "*$($m[0])*") {
            $query = $m[1]
            break
        }
    }

    if ($query) {
        Write-Host "Geocoding [$name]"
        Write-Host "  query: $query"
        $coord = Geocode-Place -query $query
        if ($coord) {
            $row.gps_coordinates = $coord
            $filled++
            Write-Host "  -> $coord"
        } else {
            Write-Host "  -> NOT FOUND"
        }
        Start-Sleep -Milliseconds 1200
    } else {
        $skipped++
        Write-Host "SKIP: $name"
    }
}

$rows | Export-Csv $csvPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "=== Done. Filled: $filled | Skipped: $skipped ==="
