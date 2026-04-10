param(
  [string]$BoardUrl = "https://www.geigerzaehlerforum.de/index.php/board,6.0.html",
  [string]$OutRoot = ".\\geigerzaehlerforum parser\\downloaded_board6",
  [string]$TopicLinksFile = ".\\geigerzaehlerforum parser\\_topic_links.txt",
  [string]$CookieHeader = "",
  [string]$UserAgent = "geiger-map/board6-downloader-1.0"
)

$ErrorActionPreference = "Stop"

function New-DirIfMissing {
  param([string]$Path)
  if (-not (Test-Path $Path)) {
    New-Item -ItemType Directory -Path $Path | Out-Null
  }
}

function Get-Headers {
  param(
    [string]$Cookie,
    [string]$UA
  )

  $h = @{ "User-Agent" = $UA }
  if (-not [string]::IsNullOrWhiteSpace($Cookie)) {
    $h["Cookie"] = $Cookie
  }
  return $h
}

function Get-AbsoluteUrl {
  param(
    [string]$BaseUrl,
    [string]$RawUrl
  )

  if ([string]::IsNullOrWhiteSpace($RawUrl)) { return $null }
  $trimmed = $RawUrl.Trim()
  try {
    $baseUri = [Uri]$BaseUrl
    $abs = [Uri]::new($baseUri, $trimmed)
    return $abs.AbsoluteUri
  } catch {
    return $null
  }
}

function Save-Html {
  param(
    [string]$Url,
    [string]$OutputFile,
    [hashtable]$Headers
  )

  $resp = Invoke-WebRequest -UseBasicParsing -Uri $Url -Headers $Headers
  [System.IO.File]::WriteAllText($OutputFile, $resp.Content, [System.Text.UTF8Encoding]::new($false))
  return $resp.Content
}

function Get-SafeNameFromUrl {
  param(
    [string]$Url,
    [string]$FallbackPrefix,
    [int]$Index
  )

  $u = [Uri]$Url
  $leaf = [System.IO.Path]::GetFileName($u.AbsolutePath)
  if ([string]::IsNullOrWhiteSpace($leaf)) {
    $leaf = "{0}_{1}.bin" -f $FallbackPrefix, $Index
  }

  $leaf = $leaf -replace "[^A-Za-z0-9._-]", "_"
  if ([string]::IsNullOrWhiteSpace($leaf)) {
    $leaf = "{0}_{1}.bin" -f $FallbackPrefix, $Index
  }

  return $leaf
}

function Is-ImageLikeUrl {
  param([string]$Url)
  if ([string]::IsNullOrWhiteSpace($Url)) { return $false }

  $l = $Url.ToLowerInvariant()
  if ($l -match "\.(png|jpe?g|gif|webp|bmp|tiff?)(\?|$)") { return $true }
  if ($l -match "action=dlattach") { return $true }
  if ($l -match "/attachments/") { return $true }
  return $false
}

function Extract-Urls {
  param(
    [string]$Html,
    [string]$PageUrl
  )

  $hrefs = New-Object System.Collections.Generic.List[string]
  $m = [regex]::Matches($Html, '(?:href|src)\s*=\s*["''][^"''#>]+["'']', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  foreach ($x in $m) {
    $raw = $x.Value -replace '^(?:href|src)\s*=\s*["'']', '' -replace '["'']$', ''
    $abs = Get-AbsoluteUrl -BaseUrl $PageUrl -RawUrl $raw
    if ($abs) { $hrefs.Add($abs) }
  }
  return $hrefs
}

function Extract-TopicLinks {
  param([System.Collections.Generic.List[string]]$Urls)
  $result = New-Object System.Collections.Generic.List[string]
  foreach ($u in $Urls) {
    if ($u -match "https?://www\.geigerzaehlerforum\.de/index\.php/topic,\d+(?:\.\d+)?\.html$") {
      $result.Add($u)
    }
  }
  return ($result | Select-Object -Unique)
}

function Extract-BoardLinks {
  param([System.Collections.Generic.List[string]]$Urls)
  $result = New-Object System.Collections.Generic.List[string]
  foreach ($u in $Urls) {
    if ($u -match "https?://www\.geigerzaehlerforum\.de/index\.php/board,6\.\d+\.html$") {
      $result.Add($u)
    }
  }
  return ($result | Select-Object -Unique)
}

$headers = Get-Headers -Cookie $CookieHeader -UA $UserAgent

$boardsDir = Join-Path $OutRoot "boards"
$topicsDir = Join-Path $OutRoot "topics"
$imagesDir = Join-Path $OutRoot "images"
New-DirIfMissing -Path $OutRoot
New-DirIfMissing -Path $boardsDir
New-DirIfMissing -Path $topicsDir
New-DirIfMissing -Path $imagesDir

$boardQueue = New-Object System.Collections.Generic.Queue[string]
$boardSeen = New-Object 'System.Collections.Generic.HashSet[string]'
$topicSeen = New-Object 'System.Collections.Generic.HashSet[string]'
$imageSeen = New-Object 'System.Collections.Generic.HashSet[string]'

$boardQueue.Enqueue($BoardUrl)

$boardCount = 0
while ($boardQueue.Count -gt 0) {
  $boardUrl = $boardQueue.Dequeue()
  if (-not $boardSeen.Add($boardUrl)) { continue }

  try {
    $boardFile = Join-Path $boardsDir (("board6_{0}.html" -f $boardCount))
    $html = Save-Html -Url $boardUrl -OutputFile $boardFile -Headers $headers
    $boardCount++

    $urls = Extract-Urls -Html $html -PageUrl $boardUrl
    foreach ($b in (Extract-BoardLinks -Urls $urls)) {
      if (-not $boardSeen.Contains($b)) {
        $boardQueue.Enqueue($b)
      }
    }

    foreach ($t in (Extract-TopicLinks -Urls $urls)) {
      [void]$topicSeen.Add($t)
    }
  } catch {
    Write-Warning ("Failed board page {0}: {1}" -f $boardUrl, $_.Exception.Message)
  }
}

$topicList = $topicSeen | Sort-Object

if (-not [string]::IsNullOrWhiteSpace($TopicLinksFile) -and (Test-Path $TopicLinksFile)) {
  foreach ($line in (Get-Content -Path $TopicLinksFile)) {
    $raw = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
    $u = $raw
    if ($u -notmatch '^https?://') {
      $u = Get-AbsoluteUrl -BaseUrl "https://www.geigerzaehlerforum.de/index.php/" -RawUrl $u
    }
    if ($u -and $u -match "https?://www\.geigerzaehlerforum\.de/index\.php/topic,\d+(?:\.\d+)?\.html$") {
      [void]$topicSeen.Add($u)
    }
  }
  $topicList = $topicSeen | Sort-Object
}

$topicManifestPath = Join-Path $OutRoot "topic_links.txt"
$topicList | Set-Content -Path $topicManifestPath -Encoding utf8

$imageRows = New-Object System.Collections.Generic.List[object]
$topicIndex = 0
foreach ($topicUrl in $topicList) {
  try {
    $topicFile = Join-Path $topicsDir (("topic_{0}.html" -f $topicIndex))
    $topicHtml = Save-Html -Url $topicUrl -OutputFile $topicFile -Headers $headers
    $topicIndex++

    $topicUrls = Extract-Urls -Html $topicHtml -PageUrl $topicUrl
    foreach ($candidate in $topicUrls) {
      if (-not (Is-ImageLikeUrl -Url $candidate)) { continue }
      if (-not $imageSeen.Add($candidate)) { continue }

      $imgIdx = $imageRows.Count
      $imgLeaf = Get-SafeNameFromUrl -Url $candidate -FallbackPrefix "img" -Index $imgIdx
      $imgName = ("{0:D6}_{1}" -f $imgIdx, $imgLeaf)
      $imgOut = Join-Path $imagesDir $imgName
      $status = "ok"

      try {
        Invoke-WebRequest -UseBasicParsing -Uri $candidate -OutFile $imgOut -Headers $headers
      } catch {
        $status = "error: " + $_.Exception.Message
      }

      $imageRows.Add([pscustomobject]@{
        topic_url = $topicUrl
        image_url = $candidate
        local_file = $imgOut
        status = $status
      })
    }
  } catch {
    Write-Warning ("Failed topic page {0}: {1}" -f $topicUrl, $_.Exception.Message)
  }
}

$imageManifestPath = Join-Path $OutRoot "downloaded_images.csv"
$imageRows | Export-Csv -Path $imageManifestPath -NoTypeInformation -Encoding UTF8

$okImages = ($imageRows | Where-Object { $_.status -eq "ok" }).Count
$errImages = ($imageRows | Where-Object { $_.status -ne "ok" }).Count
$summaryPath = Join-Path $OutRoot "download_summary.txt"
@(
  "board_pages=" + $boardCount,
  "topic_pages=" + $topicList.Count,
  "image_links=" + $imageRows.Count,
  "images_ok=" + $okImages,
  "images_error=" + $errImages,
  "topic_links_file=" + $topicManifestPath,
  "images_manifest=" + $imageManifestPath
) | Set-Content -Path $summaryPath -Encoding utf8

Write-Host "Download complete"
Write-Host ("Board pages: {0}" -f $boardCount)
Write-Host ("Topic pages: {0}" -f $topicList.Count)
Write-Host ("Image links: {0} (ok={1}, error={2})" -f $imageRows.Count, $okImages, $errImages)
Write-Host ("Summary: {0}" -f $summaryPath)
