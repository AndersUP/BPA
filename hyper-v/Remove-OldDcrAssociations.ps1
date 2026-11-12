# Remove old DCR and DCE associations that are blocking Terraform from replacing resources
# Run this script before terraform apply

param(
    [string]$ResourceGroupName = "sql-bpa-lab-rg",
    [string]$OldDcrName = "7e0dbe80-ef63-4552-9dc7-691d96ad6cb6_swedencentral_DCR_1",
    [string]$OldDceName = "swedencentral-DCE-1"
)

Write-Host "Removing all associations for DCR: $OldDcrName" -ForegroundColor Cyan
Write-Host "Removing all associations for DCE: $OldDceName" -ForegroundColor Cyan

# Get all VMs in the resource group
$vms = az vm list --resource-group $ResourceGroupName --query "[].name" -o tsv
$arcMachines = az resource list --resource-group $ResourceGroupName `
    --resource-type "Microsoft.HybridCompute/machines" `
    --query "[].name" -o tsv

# Function to remove all DCR and DCE associations from a VM
function Remove-VmDcrAssociations {
    param($VmName, $VmType = "vm")
    
    Write-Host "  Checking $VmName..." -ForegroundColor Yellow
    
    $resourceType = if ($VmType -eq "arc") { 
        "microsoft.hybridcompute/machines" 
    } else { 
        "microsoft.compute/virtualmachines" 
    }
    
    # Get all associations as JSON and parse
    $response = az rest --method GET --uri `
        "https://management.azure.com/subscriptions/7a06440f-dea7-4668-8d49-5b7c4ebcf187/resourceGroups/$ResourceGroupName/providers/$resourceType/$VmName/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=2022-06-01" `
        2>$null
    
    if ($response) {
        $allAssociations = $response | ConvertFrom-Json
        # Filter by association name containing the DCR GUID OR the old DCR reference OR DCE name "configurationaccessendpoint"
        $dcrGuid = "7e0dbe80-ef63-4552-9dc7-691d96ad6cb6"
        $matchingAssociations = $allAssociations.value | Where-Object { 
            $_.name -match $dcrGuid -or 
            $_.properties.dataCollectionRuleId -match $OldDcrName -or
            ($_.name -eq "configurationaccessendpoint" -and $_.properties.dataCollectionEndpointId -match $OldDceName)
        }
        
        if ($matchingAssociations) {
            foreach ($assoc in $matchingAssociations) {
                $assocType = if ($assoc.properties.dataCollectionEndpointId) { "DCE" } else { "DCR" }
                Write-Host "    Deleting $assocType association: $($assoc.name)" -ForegroundColor Gray
                az rest --method DELETE --uri `
                    "https://management.azure.com/subscriptions/7a06440f-dea7-4668-8d49-5b7c4ebcf187/resourceGroups/$ResourceGroupName/providers/$resourceType/$VmName/providers/Microsoft.Insights/dataCollectionRuleAssociations/$($assoc.name)?api-version=2022-06-01" `
                    2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "      ✓ Deleted" -ForegroundColor Green
                } else {
                    Write-Host "      ✗ Failed" -ForegroundColor Red
                }
            }
        } else {
            Write-Host "    No matching associations found" -ForegroundColor Gray
        }
    } else {
        Write-Host "    Failed to query associations" -ForegroundColor Red
    }
}

# Remove associations from Azure VMs
Write-Host "`nRemoving DCR and DCE associations from Azure VMs:" -ForegroundColor Cyan
foreach ($vm in $vms) {
    Remove-VmDcrAssociations -VmName $vm -VmType "vm"
}

# Remove associations from Arc machines
Write-Host "`nRemoving DCR and DCE associations from Arc machines:" -ForegroundColor Cyan
foreach ($machine in $arcMachines) {
    Remove-VmDcrAssociations -VmName $machine -VmType "arc"
}

Write-Host "`n✓ All DCR and DCE associations removed. You can now run 'terraform apply'" -ForegroundColor Green
