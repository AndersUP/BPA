#requires -Version 7.2
$ErrorActionPreference = 'Stop'
$runner = Join-Path (Split-Path $PSScriptRoot -Parent) 'Download-LabIsos.ps1'
$tokens=$null; $errors=$null
[System.Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors) | Out-Null
if ($errors.Count) { throw "Syntax errors: $errors" }
function Import-Module { param($Name) }
$state = @{ Calls=0; Fail=$false }
function Start-BitsTransfer {
    param($Source, $Destination, $DisplayName, $Description, $ErrorAction)
    $state.Calls++
    [IO.File]::WriteAllText($Destination, 'mock ISO contents')
    if ($state.Fail) { throw "Mock error with secret URL $Source" }
}
$root = Join-Path ([IO.Path]::GetTempPath()) "iso-test-$([guid]::NewGuid().ToString('N'))"
try {
    $files = @(
        'en-us_windows_server_2022_updated_dec_2025_x64_dvd_84450f64.iso',
        'en-us_windows_server_2025_updated_oct_2026_x64_dvd_005af0c9.iso',
        'enu_sql_server_2022_enterprise_edition_x64_dvd_aa36de9e.iso',
        'enu_sql_server_2025_enterprise_edition_x64_dvd_dd8b2bab.iso'
    )
    $urls = @($files | ForEach-Object { "https://example.blob.core.windows.net/iso/${_}?sig=mock-secret" })
    $results = @(& $runner -BlobUrls $urls -DestinationDirectory $root)
    if ($results.Count -ne 4) { throw 'The four supplied ISO filename shapes were not accepted.' }
    foreach ($file in $files) { Remove-Item -LiteralPath (Join-Path $root $file) -Force }
    $failure=$null
    try { & $runner -BlobUrls @($urls[0], $urls[0]) -DestinationDirectory $root } catch { $failure=$_ }
    if (-not $failure -or $failure.Exception.Message -notlike '*URL #2 repeats ISO*' -or $failure.Exception.Message -match 'mock-secret') {
        throw 'Duplicate filename error was not precise and sanitized.'
    }
    $failure=$null
    try { & $runner -BlobUrls 'https://example.blob.core.windows.net/iso/?sig=mock-secret' -DestinationDirectory $root } catch { $failure=$_ }
    if (-not $failure -or $failure.Exception.Message -notlike '*URL #1 does not end*' -or $failure.Exception.Message -match 'mock-secret') {
        throw 'Invalid filename error was not precise and sanitized.'
    }
    $state.Calls=0
    $result = & $runner -BlobUrls 'https://example.blob.core.windows.net/iso/test.iso?sig=mock-secret' -DestinationDirectory $root
    if ($state.Calls -ne 1 -or -not (Test-Path -LiteralPath $result.File) -or $result.SHA256.Length -ne 64) { throw 'Download output invalid.' }
    $failure=$null
    try { & $runner -BlobUrls 'https://example.blob.core.windows.net/iso/test.iso' -DestinationDirectory $root } catch { $failure=$_ }
    if (-not $failure -or $state.Calls -ne 1) { throw 'Existing file was not protected.' }
    $urlFile = Join-Path $root 'iso-urls.txt'
    [IO.File]::WriteAllText($urlFile, "https://example.blob.core.windows.net/iso/from-file.iso?sig=mock-secret`r`n")
    $fromFile = & $runner -UrlFile $urlFile -DestinationDirectory $root
    if (-not (Test-Path -LiteralPath $fromFile.File)) { throw 'URL-file download did not succeed.' }
    $state.Fail=$true; $failure=$null
    try { & $runner -BlobUrls 'https://example.blob.core.windows.net/iso/failed.iso?sig=mock-secret' -DestinationDirectory $root } catch { $failure=$_ }
    if (-not $failure -or $failure.Exception.Message -match 'mock-secret' -or (Test-Path -LiteralPath (Join-Path $root 'failed.iso.partial'))) {
        throw 'Failure leaked a URL or left a partial file.'
    }
    Write-Output 'PASS: syntax, successful download/hash, overwrite protection, sanitized failure, partial cleanup.'
} finally {
    foreach ($name in @('test.iso','failed.iso.partial','iso-urls.txt','from-file.iso') + $files) {
        $file = Join-Path $root $name
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root }
}
