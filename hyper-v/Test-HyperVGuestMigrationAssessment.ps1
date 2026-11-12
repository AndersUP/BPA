#requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'Enable-HyperVGuestMigrationAssessment.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Syntax errors: $errors" }
foreach ($node in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $true)) {
    . ([scriptblock]::Create($node.Extent.Text))
}
$state=@{Enabled=$false; Patches=0; Posts=0; Job='InProgress'; Http=200; Pages=0}
$id='/subscriptions/test/resourceGroups/lab/providers/Microsoft.AzureArcData/sqlServerInstances/arcsql-01'
function Invoke-AzRestMethod {
    param($Path,$Method,$Payload)
    if ($state.Http -ne 200) { return [pscustomobject]@{StatusCode=$state.Http;Content='RBAC denied'} }
    if ($Path -notlike '*api-version=2026-01-01*') { throw 'Incorrect migration API version.' }
    if ($Method -eq 'PATCH') {
        $body=$Payload|ConvertFrom-Json -AsHashtable
        if ($body.properties.Count -ne 1 -or $body.properties.migration.assessment.Count -ne 1 -or
            $body.properties.migration.assessment.enabled -ne $true) { throw 'Patch modified unrelated settings.' }
        $state.Enabled=$true; $state.Patches++
    }
    $result=@{properties=@{migration=@{assessment=@{enabled=$state.Enabled;settings=@{preserve='yes'}}}}}
    if ($Method -eq 'POST') {
        if ($Path -notlike '*/runMigrationAssessment?*') { throw 'Incorrect run action.' }
        $state.Posts++; $result=@{jobStatus=$state.Job;jobException='test diagnostic'}
    }
    if ($Path -match '/sqlServerInstances\?') {
        $state.Pages++
        $result=@{value=@(@{id=$id})}
        if ($state.Pages -eq 1) {
            $result.nextLink='https://management.azure.com/test/sqlServerInstances?api-version=2026-01-01&skip=1'
        }
    }
    [pscustomobject]@{StatusCode=200;Content=($result|ConvertTo-Json -Depth 20)}
}
function Start-Sleep { throw 'Unexpected polling.' }
$instance=[pscustomobject]@{id=$id;name='arcsql-01';properties=[pscustomobject]@{}}
$result=Enable-MigrationInstance -Instance $instance
if (-not $result.Enabled -or $state.Patches -ne 1 -or $state.Posts) { throw 'Enable-only failed.' }
$instance.properties=[pscustomobject]@{migration=[pscustomobject]@{assessment=[pscustomobject]@{enabled=$true}}}
$result=Enable-MigrationInstance -Instance $instance -Trigger
if ($state.Patches -ne 1 -or $state.Posts -ne 1 -or $result.Status -ne 'Run requested: InProgress') {
    throw 'Rerun must skip the patch and label the run as pending, not completed.'
}
$state.Job='Failed'
$failure=$null
try { Enable-MigrationInstance -Instance $instance -Trigger } catch { $failure=$_ }
if (-not $failure -or "$failure" -notlike '*test diagnostic*') { throw 'Failed job must expose diagnostics.' }
$state.Http=403
$failure=$null
try { Enable-MigrationInstance -Instance $instance -Trigger } catch { $failure=$_ }
if (-not $failure -or "$failure" -notlike '*HTTP 403*') { throw 'RBAC failure was hidden.' }
$state.Http=200
$instances=@(Get-MigrationInstances -GroupId '/test')
if ($instances.Count -ne 2 -or $state.Pages -ne 2) { throw 'Instance pagination failed.' }
$parameter=$ast.ParamBlock.Parameters|Where-Object {$_.Name.VariablePath.UserPath -eq 'VMName'}
$defaults=@(& ([scriptblock]::Create($parameter.DefaultValue.Extent.Text)))
if (($defaults -join ',') -ne 'arcsql-01,arcsql-02,arcsql-03,arcsql-04,arcsql-05,arcsql-06,arcsql-07,arcsql-08') {
    throw 'Expected default guest names 01 through 08.'
}
& {
    $statements=@($ast.EndBlock.Statements|Where-Object {
        $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] -and
        $_.Extent.Text -notmatch '^\$principal =' -and $_.Extent.Text -notmatch '^if \(-not \$principal\.'
    })
    $script=[scriptblock]::Create($ast.ParamBlock.Extent.Text+"`n"+(($statements|ForEach-Object {$_.Extent.Text})-join "`n"))
    $batch=@{Checks=0;Changes=0;Fail=$false}
    $sub='11111111-1111-1111-1111-111111111111'
    $group="/subscriptions/$sub/resourceGroups/lab"
    function Import-Module {}
    function Get-Module { 'Available' }
    function Disable-AzContextAutosave {}
    function Get-AzContext { [pscustomobject]@{Environment=[pscustomobject]@{Name='AzureCloud'}} }
    function Set-AzContext {}
    function Get-VM { [pscustomobject]@{State='Running'} }
    function Get-MigrationInstances {
        foreach ($n in 1..8) {
            $name='arcsql-{0:00}' -f $n
            [pscustomobject]@{name=$name;id="$group/providers/Microsoft.AzureArcData/sqlServerInstances/$name"
                properties=[pscustomobject]@{containerResourceId="$group/providers/Microsoft.HybridCompute/machines/$name"}}
        }
    }
    function Invoke-MigrationArm {
        param($Path)
        if ($Path -match '/extensions/') {
            return [pscustomobject]@{properties=[pscustomobject]@{provisioningState='Succeeded';typeHandlerVersion='1.1.2594.118'}}
        }
        [pscustomobject]@{location='swedencentral';properties=[pscustomobject]@{status='Connected'}}
    }
    function Invoke-Command {
        param($ArgumentList)
        if ($ArgumentList -ne 'telemetry.swedencentral.arcdataservices.com') { throw 'Incorrect telemetry region.' }
        $batch.Checks++
        if ($batch.Fail -and $batch.Checks -eq 8) { throw 'Simulated guest connectivity failure' }
        [pscustomobject]@{Endpoint=$ArgumentList;Addresses='192.0.2.1';Tcp443=$true;TlsValidated=$true;Protocol='Tls12'}
    }
    function Enable-MigrationInstance {
        if ($batch.Checks -ne 8) { throw 'All eight guests must pass preflight before changes.' }
        $batch.Changes++
    }
    $p=@{SubscriptionId=$sub;ResourceGroupName='lab'
        GuestCredential=[PSCredential]::new('Administrator',(ConvertTo-SecureString 'Test-only!' -AsPlainText -Force))}
    & $script @p -CheckOnly | Out-Null
    if ($batch.Checks -ne 8 -or $batch.Changes) { throw 'CheckOnly must inspect eight guests without mutation.' }
    $batch.Checks=0
    & $script @p | Out-Null
    if ($batch.Changes -ne 8) { throw 'Expected eight enabled instances.' }
    $batch.Checks=0; $batch.Changes=0; $batch.Fail=$true
    $failure=$null
    try { & $script @p | Out-Null } catch { $failure=$_ }
    if (-not $failure -or $batch.Changes) { throw 'Guest connectivity failure must block all mutations.' }
}
Write-Output 'PASS: syntax; eight default guests; minimal PATCH; verification; rerun; job/RBAC errors; pagination; existing sign-in; CheckOnly; all-guest preflight gating.'
