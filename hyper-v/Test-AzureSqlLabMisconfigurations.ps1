#requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$runner = Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-AzureSqlLabMisconfigurations.ps1'
$tokens = $null; $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($runner, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count) { throw "Runner syntax errors: $errors" }
$state = @{ Calls=0; Runs=0; Scenario='success'; Paths=@() }
function az {
    $state.Calls++
    $global:LASTEXITCODE = 0
    if ($args[1] -eq 'show') {
        @{ storageProfile=@{ osDisk=@{ osType='Windows' } } } | ConvertTo-Json -Depth 5
        return
    }
    $state.Runs++
    $path = $args[[array]::IndexOf($args, '--scripts') + 1].Substring(1)
    $state.Paths += $path
    $text = Get-Content -LiteralPath $path -Raw
    [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { throw "Remote script syntax errors: $errors" }
    $marker = [regex]::Match($text, 'SQL_LAB_COMPLETE_[a-f0-9]+').Value
    if (-not $marker -or $text -notlike '*AbortOnError*') { throw 'Missing remote success/error checks.' }
    $message = if ($state.Scenario -eq 'success') { "[stdout]`n$marker`n[stderr]" } else { 'SQL login failed' }
    @{ value=@(@{ code='ComponentStatus/StdOut/succeeded'; level='Info'; message=$message }) } | ConvertTo-Json -Depth 5
}
$subscription = '00000000-0000-0000-0000-000000000001'
& $runner -SubscriptionId $subscription
& $runner -SubscriptionId $subscription -Apply -WhatIf
if ($state.Calls) { throw 'Preview/WhatIf called Azure.' }
$results = @(& $runner -SubscriptionId $subscription -Apply -Confirm:$false)
if ($state.Runs -ne 5 -or $results.Count -ne 5) { throw 'Did not configure all five targets.' }
foreach ($path in $state.Paths) {
    if (Test-Path -LiteralPath $path) { throw 'Temporary script was not cleaned up.' }
}
$state.Scenario='failure'; $state.Runs=0
$failure = $null
try { & $runner -SubscriptionId $subscription -Apply -Confirm:$false } catch { $failure = $_ }
if (-not $failure -or $failure.Exception.Message -notlike '*did not confirm success*' -or $state.Runs -ne 1) {
    throw 'Missing completion marker did not stop the batch.'
}
foreach ($path in $state.Paths) {
    if (Test-Path -LiteralPath $path) { throw 'Failure path leaked a temporary script.' }
}
Write-Output 'PASS: syntax, preview/WhatIf, five VM execution, remote failure detection, and cleanup.'
