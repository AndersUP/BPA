<#
.SYNOPSIS
    Seeds sample data and intentional SQL misconfigurations on Azure Windows lab VMs.
.DESCRIPTION
    Uses Azure CLI VM Run Command; no RDP, inbound SQL access, or guest passwords
    are needed. Requires an existing az login and permission to read VMs and
    execute Run Command. Use only on disposable labs with a default SQL instance.
    Preview is the default. Add -Apply to execute.
.EXAMPLE
    .\Invoke-AzureSqlLabMisconfigurations.ps1 -SubscriptionId '<subscription-id>'
.EXAMPLE
    .\Invoke-AzureSqlLabMisconfigurations.ps1 -SubscriptionId '<subscription-id>' `
        -ResourceGroupName 'sql-bpa-lab-rg' -Apply
.EXAMPLE
    .\Invoke-AzureSqlLabMisconfigurations.ps1 -SubscriptionId '<subscription-id>' `
        -VMNames 'sql-bpa-01','sql-bpa-02' -Databases misconfigdemo `
        -Misconfigs auto_shrink,filegrowth_pct -Apply -Confirm:$false
#>
#requires -Version 7.2
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [guid]$SubscriptionId,
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName = 'sql-bpa-lab-rg',
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9-]{0,63}$')]
    [string[]]$VMNames = @('sql-bpa-01', 'sql-bpa-02', 'sql-bpa-03', 'sql-bpa-04', 'sql-bpa-05'),
    [ValidateNotNullOrEmpty()]
    [ValidateSet('adventureworks', 'worldwideimporters', 'misconfigdemo')]
    [string[]]$Databases = @('adventureworks', 'misconfigdemo'),
    [ValidateNotNullOrEmpty()]
    [ValidateSet('maxdop_zero', 'maxmem_default', 'ctp_default', 'no_adhoc_opt',
        'auto_close', 'auto_shrink', 'page_verify_none', 'recovery_simple', 'filegrowth_pct')]
    [string[]]$Misconfigs = @('maxdop_zero', 'ctp_default', 'no_adhoc_opt', 'auto_shrink', 'filegrowth_pct'),
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$sourcePath = Join-Path $PSScriptRoot 'hyper-v\configure-sql-hyperv.ps1'
$source = Get-Content -LiteralPath $sourcePath -Raw
$targets = @($VMNames | Select-Object -Unique)
Write-Host "Targets: $($targets -join ', ') in $ResourceGroupName"
Write-Host "Databases: $($Databases -join ', '); misconfigurations: $($Misconfigs -join ', ')"
Write-Warning 'LAB ONLY: changes instance settings and ALL user databases, including any existing baseline VM. This is not a reversible operation; preserve original settings/backups.'
if (-not $Apply) {
    Write-Host 'Preview only. Add -Apply to execute Azure VM Run Command.'
    return
}
if (-not $PSCmdlet.ShouldProcess("$ResourceGroupName [$($targets -join ', ')]", 'Seed databases and deliberately misconfigure SQL Server')) { return }
Get-Command az -ErrorAction Stop | Out-Null

function Invoke-LabCli {
    param([string[]]$Arguments)
    $output = & az @Arguments --subscription "$SubscriptionId" --only-show-errors --output json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed ($($Arguments[0..1] -join ' ')): $($output -join "`n")" }
    ($output -join "`n") | ConvertFrom-Json
}

# Validate all targets before changing any VM.
foreach ($name in $targets) {
    $vm = Invoke-LabCli @('vm', 'show', '--resource-group', $ResourceGroupName, '--name', $name)
    if ($vm.storageProfile.osDisk.osType -ne 'Windows') { throw "$name is not a Windows VM." }
}

$marker = "SQL_LAB_COMPLETE_$([guid]::NewGuid().ToString('N'))"
$remoteScript = @"
`$ErrorActionPreference = 'Stop'
try {
    `$PSDefaultParameterValues['Invoke-Sqlcmd:AbortOnError'] = `$true
    & {
$source
    } -Databases '$($Databases -join ',')' -Misconfigs '$($Misconfigs -join ',')'
    Write-Output '$marker'
} catch {
    Write-Error -ErrorRecord `$_ -ErrorAction Continue
    exit 1
}
"@
$scriptPath = Join-Path ([IO.Path]::GetTempPath()) "sql-lab-$([guid]::NewGuid().ToString('N')).ps1"
try {
    Set-Content -LiteralPath $scriptPath -Value $remoteScript -Encoding utf8
    foreach ($name in $targets) {
        Write-Host "Applying SQL lab configuration on $name. Downloads/module installation can take several minutes."
        $result = Invoke-LabCli @('vm', 'run-command', 'invoke', '--resource-group', $ResourceGroupName,
            '--name', $name, '--command-id', 'RunPowerShellScript', '--scripts', "@$scriptPath")
        $messages = @($result.value | ForEach-Object { $_.message }) -join "`n"
        $failed = @($result.value | Where-Object { $_.code -match '/failed$' -or $_.level -eq 'Error' })
        if ($failed.Count -or $messages -notmatch "(?m)^$marker\s*$") {
            throw "SQL configuration did not confirm success on $name. Inspect C:\configure-sql-log.txt inside the VM and Run Command status before retrying. Remote output:`n$messages"
        }
        Write-Host "Completed: $name"
        [pscustomobject]@{ VMName = $name; Status = 'Completed'; Databases = $Databases -join ','; Misconfigs = $Misconfigs -join ',' }
    }
} finally {
    if (Test-Path -LiteralPath $scriptPath) { Remove-Item -LiteralPath $scriptPath -Force }
}
