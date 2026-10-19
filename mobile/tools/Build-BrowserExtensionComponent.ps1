[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('chrome', 'edge', 'aside', 'firefox')]
    [string]$Browser,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\build\browser-components'),

    # Optional public key for an existing store listing. This changes only the
    # staged package manifest; canonical extension source identity is preserved.
    [string]$ManifestPublicKey
)

$ErrorActionPreference = 'Stop'

$mobileRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$assetRoot = Join-Path $mobileRoot 'assets\browser_extensions'
$sourceName = if ($Browser -eq 'firefox') { 'firefox' } else { 'chrome' }
$sourceDirectory = Join-Path $assetRoot $sourceName

if (-not (Test-Path -LiteralPath (Join-Path $sourceDirectory 'manifest.json') -PathType Leaf)) {
    throw "Extension source manifest not found: $(Join-Path $sourceDirectory 'manifest.json')"
}

$outputPath = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
$stagePath = Join-Path ([System.IO.Path]::GetTempPath()) ("focusfense-{0}-{1}" -f $Browser, [guid]::NewGuid().ToString('N'))
$archiveTempPath = "$stagePath.zip"

try {
    New-Item -ItemType Directory -Path $stagePath -Force | Out-Null
    Copy-Item -Path (Join-Path $sourceDirectory '*') -Destination $stagePath -Recurse -Force

    if ($Browser -eq 'aside') {
        $asideManifest = Join-Path $assetRoot 'aside\manifest.json'
        if (-not (Test-Path -LiteralPath $asideManifest -PathType Leaf)) {
            throw "Aside manifest not found: $asideManifest"
        }
        Copy-Item -LiteralPath $asideManifest -Destination (Join-Path $stagePath 'manifest.json') -Force
    }

    $manifestPath = Join-Path $stagePath 'manifest.json'
    $manifestText = Get-Content -LiteralPath $manifestPath -Raw
    if (-not [string]::IsNullOrWhiteSpace($ManifestPublicKey)) {
        $encodedKey = [Convert]::ToBase64String([Convert]::FromBase64String($ManifestPublicKey))
        if ($encodedKey -ne $ManifestPublicKey) {
            throw 'ManifestPublicKey must be canonical base64-encoded DER public-key data.'
        }
        if ($manifestText -notmatch '(?m)"key"\s*:') {
            throw 'The source manifest has no key field to override for the store package.'
        }
        $escapedKey = $ManifestPublicKey.Replace('\', '\\').Replace('"', '\"')
        $manifestText = [regex]::Replace(
            $manifestText,
            '(?m)("key"\s*:\s*")[^"]*(")',
            ('$1' + $escapedKey + '$2'),
            1
        )
        Set-Content -LiteralPath $manifestPath -Value $manifestText -Encoding utf8
    }
    $manifest = $manifestText | ConvertFrom-Json
    $version = [string]$manifest.version
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "Extension manifest has no version: $manifestPath"
    }

    $references = [System.Collections.Generic.List[string]]::new()
    if ($manifest.background.service_worker) { $references.Add([string]$manifest.background.service_worker) }
    foreach ($sectionName in @('action', 'browser_action', 'page_action')) {
        $section = $manifest.$sectionName
        if ($section.default_popup) { $references.Add([string]$section.default_popup) }
    }
    if ($manifest.options_ui.page) { $references.Add([string]$manifest.options_ui.page) }
    if ($manifest.options_page) { $references.Add([string]$manifest.options_page) }
    if ($manifest.devtools_page) { $references.Add([string]$manifest.devtools_page) }
    if ($manifest.chrome_url_overrides) {
        foreach ($property in $manifest.chrome_url_overrides.PSObject.Properties) {
            $references.Add([string]$property.Value)
        }
    }
    if ($manifest.icons) {
        foreach ($property in $manifest.icons.PSObject.Properties) {
            $references.Add([string]$property.Value)
        }
    }
    foreach ($contentScript in @($manifest.content_scripts)) {
        foreach ($file in @($contentScript.js) + @($contentScript.css)) {
            if ($file) { $references.Add([string]$file) }
        }
    }
    foreach ($resourceGroup in @($manifest.web_accessible_resources)) {
        foreach ($resource in @($resourceGroup.resources)) {
            if ($resource -and $resource -notmatch '[*?]') { $references.Add([string]$resource) }
        }
    }

    foreach ($reference in ($references | Select-Object -Unique)) {
        $relativePath = $reference.Replace('/', '\')
        if ([System.IO.Path]::IsPathRooted($relativePath) -or $relativePath -match '(^|\\)\.\.(\\|$)') {
            throw "Unsafe path in extension manifest: $reference"
        }
        $referencedFile = Join-Path $stagePath $relativePath
        if (-not (Test-Path -LiteralPath $referencedFile -PathType Leaf)) {
            throw "Manifest references a missing file: $reference"
        }
    }

    $files = @(Get-ChildItem -LiteralPath $stagePath -File -Recurse | Sort-Object FullName)
    if ($files.Count -eq 0) { throw 'Extension component contains no files.' }
    $fileRecords = @($files | ForEach-Object {
        [pscustomobject]@{
            path = [System.IO.Path]::GetRelativePath($stagePath, $_.FullName).Replace('\', '/')
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            bytes = $_.Length
        }
    })
    $metadata = [ordered]@{
        component = 'browser-extension'
        browser = $Browser
        source = "assets/browser_extensions/$sourceName"
        manifestVersion = $version
        builtUtc = [DateTime]::UtcNow.ToString('o')
        files = $fileRecords
    }
    $metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stagePath 'component.json') -Encoding utf8

    $archivePath = Join-Path $outputPath ("focusfense-{0}-{1}.zip" -f $Browser, $version)
    Compress-Archive -Path (Join-Path $stagePath '*') -DestinationPath $archiveTempPath -CompressionLevel Optimal
    Move-Item -LiteralPath $archiveTempPath -Destination $archivePath -Force

    [pscustomobject]@{
        browser = $Browser
        version = $version
        source = $sourceDirectory
        fileCount = $files.Count + 1
        archive = $archivePath
        archiveBytes = (Get-Item -LiteralPath $archivePath).Length
    }
} finally {
    if (Test-Path -LiteralPath $stagePath) {
        Remove-Item -LiteralPath $stagePath -Recurse -Force
    }
    if (Test-Path -LiteralPath $archiveTempPath) {
        Remove-Item -LiteralPath $archiveTempPath -Force
    }
}
