<#
.SYNOPSIS
    Downloads private Azure Blob ISO files onto the Windows lab host.
.DESCRIPTION
    Uses Windows BITS. Loads iso-urls.txt beside the script when present.
    Otherwise, with no BlobUrls argument, prompts securely for four SAS
    URLs. Does not log URLs or overwrite existing files. Failed partial downloads
    are removed. A reported SHA256 is informational, not publisher verification.
.EXAMPLE
    .\Download-LabIsos.ps1 -DestinationDirectory 'F:\ISO'
.EXAMPLE
    # $urls contains your SAS URLs. Do not store them in scripts or Git.
    .\Download-LabIsos.ps1 -BlobUrls $urls -DestinationDirectory 'F:\ISO'
.EXAMPLE
    .\Download-LabIsos.ps1 -UrlFile 'C:\LabSecrets\iso-urls.txt'
    # One complete SAS URL per line. Keep this file outside Git.
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    [uri[]]$BlobUrls,
    [string]$UrlFile,
    [ValidateNotNullOrEmpty()]
    [string]$DestinationDirectory = 'F:\ISO'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module BitsTransfer -ErrorAction Stop
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

if ($BlobUrls -and $UrlFile) { throw 'Specify either BlobUrls or UrlFile, not both.' }
if (-not $BlobUrls) {
    if (-not $UrlFile) {
        $candidate = Join-Path $PSScriptRoot 'iso-urls.txt'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $UrlFile = $candidate }
    }
    if ($UrlFile) {
        $lines = @(Get-Content -LiteralPath $UrlFile -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($lines.Count -eq 0) { throw 'The URL file is empty. Add one complete HTTPS blob SAS URL per line.' }
        $BlobUrls = @(
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $parsed = $null
                if (-not [uri]::TryCreate($lines[$i].Trim(), [UriKind]::Absolute, [ref]$parsed)) {
                    throw "Invalid URL on nonempty line $($i + 1) of the URL file. Enter URLs only, without quotes or PowerShell code."
                }
                $parsed
            }
        )
    }
}

if (-not $BlobUrls) {
    $labels = @(
        'Windows Server 2022',
        'Windows Server 2025',
        'SQL Server 2022 Enterprise',
        'SQL Server 2025 Enterprise'
    )
    $BlobUrls = @(
        foreach ($label in $labels) {
            $secret = Read-Host "Paste the complete SAS URL for $label" -AsSecureString
            $text = [PSCredential]::new('sas', $secret).GetNetworkCredential().Password.Trim()
            $parsed = $null
            if (-not [uri]::TryCreate($text, [UriKind]::Absolute, [ref]$parsed)) {
                throw "Invalid URL for $label. Paste the entire HTTPS blob SAS URL."
            }
            $parsed
            $text = $null
        }
    )
}

$names = @{}
$urlIndex = 0
$downloads = @(
    foreach ($url in $BlobUrls) {
        $urlIndex++
        if (-not $url.IsAbsoluteUri -or $url.Scheme -ne 'https' -or
            $url.Host -notlike '*.blob.core.windows.net' -or $url.UserInfo -or $url.Fragment) {
            throw 'Only absolute HTTPS Azure Blob URLs without user information or fragments are accepted.'
        }
        $name = [uri]::UnescapeDataString(($url.AbsolutePath -split '/')[-1])
        if ($name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]*\.iso$') {
            throw "URL #${urlIndex} does not end in a valid ISO blob filename. Paste one complete blob URL, without surrounding quotes, not a container link. The URL has been omitted."
        }
        if ($names.ContainsKey($name)) {
            throw "URL #${urlIndex} repeats ISO '$name' from URL #$($names[$name]). Paste a different ISO URL at each prompt. No downloads have started."
        }
        $names[$name] = $urlIndex
        [pscustomobject]@{ Url=$url; Name=$name; Path=(Join-Path $DestinationDirectory $name) }
    }
)
if ($downloads.Count -eq 0) { throw 'Supply at least one blob URL.' }
foreach ($download in $downloads) {
    if ((Test-Path -LiteralPath $download.Path) -or (Test-Path -LiteralPath "$($download.Path).partial")) {
        throw "Destination or partial file already exists for $($download.Name). Inspect it before retrying; no files have been overwritten."
    }
}
New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
foreach ($download in $downloads) {
    $partial = "$($download.Path).partial"
    Write-Host "Downloading $($download.Name) ..."
    try {
        Start-BitsTransfer -Source $download.Url.AbsoluteUri -Destination $partial `
            -DisplayName 'Lab ISO download' -Description $download.Name -ErrorAction Stop
        if ((Get-Item -LiteralPath $partial).Length -eq 0) { throw 'The downloaded file is empty.' }
        Move-Item -LiteralPath $partial -Destination $download.Path -ErrorAction Stop
    } catch {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
        # BITS exception messages can contain the SAS URL; do not echo them.
        throw "Download failed for $($download.Name). Check SAS expiry/read access, available disk space, outbound HTTPS, and the BITS service. SAS details have been omitted."
    }
    $file = Get-Item -LiteralPath $download.Path
    $hash = Get-FileHash -LiteralPath $download.Path -Algorithm SHA256
    [pscustomobject]@{
        File = $file.FullName
        SizeGB = [math]::Round($file.Length / 1GB, 2)
        SHA256 = $hash.Hash
    }
}
