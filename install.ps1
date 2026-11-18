# Install the Bistro world into Graffitty's worlds folder.
#
#   gft world install bistro          # runs this script from the release's tag
#   .\install.ps1                     # latest release
#   .\install.ps1 v0.0.1              # a specific release
#
# It checks the zip against the release's SHA256SUMS and replaces
# $env:XDG_DATA_HOME\graffitty\worlds\bistro (default $HOME\.local\share\graffitty\worlds).
param([string]$Version = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$Repo = 'graffitty/bistro-world'
$Id = 'bistro'
$Zip = 'bistro-world.zip'

if (-not $Version -or $Version -eq 'latest') {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" `
        -Headers @{ 'User-Agent' = 'Bistro-Installer' } -TimeoutSec 60
    $Version = $release.tag_name
} elseif (-not $Version.StartsWith('v')) {
    $Version = 'v' + $Version
}
if ($Version -cnotmatch '^v[0-9]+\.[0-9]+\.[0-9]+(?:[.+-][0-9A-Za-z.+-]+)?$') {
    throw "Invalid release tag: $Version (expected e.g. v0.0.1)"
}

$dataHome = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path $HOME '.local\share' }
$worlds = Join-Path $dataHome 'graffitty\worlds'
New-Item -ItemType Directory -Force $worlds | Out-Null
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('bistro-install-' + [Guid]::NewGuid().ToString('N'))
# Unpack next to the destination, so installing is a rename.
$staging = Join-Path $worlds ('.bistro-install-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $temporary, $staging | Out-Null

$previousTls = [Net.ServicePointManager]::SecurityProtocol
try {
    [Net.ServicePointManager]::SecurityProtocol = $previousTls -bor [Net.SecurityProtocolType]::Tls12
    $base = "https://github.com/$Repo/releases/download/$Version"
    $manifest = Join-Path $temporary 'SHA256SUMS'
    $archive = Join-Path $temporary $Zip
    Write-Host "Downloading Bistro $Version..."
    Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS" -OutFile $manifest -TimeoutSec 60
    Invoke-WebRequest -UseBasicParsing -Uri "$base/$Zip" -OutFile $archive -TimeoutSec 1800

    $entries = @(
        foreach ($line in [IO.File]::ReadAllLines($manifest)) {
            if ($line -match '^([0-9a-fA-F]{64})\s+\*?(?:\./)?(.+)$' -and $Matches[2] -ceq $Zip) { $Matches[1] }
        }
    )
    if ($entries.Count -ne 1) { throw "SHA256SUMS must contain exactly one checksum for $Zip." }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $entries[0]) {
        throw "Checksum mismatch for $Zip; refusing to install it."
    }

    Expand-Archive -LiteralPath $archive -DestinationPath $staging
    $unpacked = Join-Path $staging $Id
    foreach ($file in @("$Id.pck", "$Id.json")) {
        if (-not (Test-Path -LiteralPath (Join-Path $unpacked $file) -PathType Leaf)) {
            throw "$Zip does not contain $Id\$file."
        }
    }

    # Replace the whole folder: the .pck and .json must always match.
    $target = Join-Path $worlds $Id
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    Move-Item -LiteralPath $unpacked -Destination $target
    Write-Host "Bistro $Version is installed at $target"
    Write-Host 'Restart Graffitty and choose View > World > Bistro.'
} finally {
    [Net.ServicePointManager]::SecurityProtocol = $previousTls
    Remove-Item -LiteralPath $temporary, $staging -Recurse -Force -ErrorAction SilentlyContinue
}
