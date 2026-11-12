# Migrating existing DCR/DCE resources to Terraform

[Back to the Azure lab guide](AZURE-TERRAFORM-LAB.md)

The lab manages a shared DCE, BPA/performance DCRs, and Azure VM associations
through [bpa-assessment-dcr.tf](../terraform/bpa-assessment-dcr.tf) and
[performance-counters-dcr.tf](../terraform/performance-counters-dcr.tf).
Use explicit Terraform imports for pre-existing resources. No discovery/import
helper script is required.

## 1. Inventory and back up

Authenticate to the intended subscription, then list resources:

```powershell
az account set --subscription "<subscription-id>"
az monitor data-collection rule list -g "<resource-group>" -o table
az monitor data-collection endpoint list -g "<resource-group>" -o table
az monitor data-collection rule association list --resource "<machine-resource-id>"
```

Save resource configurations and securely back up existing Terraform state
before migration. Check each rule's source paths, streams, transformations,
destination workspace, and endpoint. Do not select the first matching rule by
name pattern alone.

## 2. Reconcile configuration before importing

The lab defaults are:

| Resource | Name |
|---|---|
| Shared endpoint | `<prefix>-dce` |
| Assessment rule | `<prefix>-bpa-dcr` |
| Performance rule | `<prefix>-sql-perfcounters-dcr` |
| Assessment table | `SqlAssessment_CL` |

Azure assessment-managed `sqlbpa-*` resources may differ from these definitions.
Import does not rename resources or make the assessment service adopt an
arbitrary DCR. Align the Terraform names and properties with the resources you
intend to retain before applying; review [Arc DCR reuse](ENABLE-ARC-SQL-BPA.md)
if the assessment service owns the collection pipeline.

## 3. Import verified resource IDs

Initialize Terraform as described in the lab guide. From the Terraform
directory, substitute the actual resource IDs:

```powershell
terraform import azurerm_monitor_data_collection_endpoint.bpa_assessment `
    "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Insights/dataCollectionEndpoints/<dce-name>"

terraform import azurerm_monitor_data_collection_rule.bpa_assessment `
    "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Insights/dataCollectionRules/<bpa-dcr-name>"

terraform import azurerm_monitor_data_collection_rule.sql_perf_counters `
    "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Insights/dataCollectionRules/<perf-dcr-name>"
```

Also import existing associations instead of attempting duplicate creation.
For example:

```powershell
terraform import 'azurerm_monitor_data_collection_rule_association.bpa_azure_vms[\"sql-bpa-01\"]' `
    "<vm-resource-id>/providers/Microsoft.Insights/dataCollectionRuleAssociations/<existing-association-name>"
```

Use the corresponding `sql_vms_perf["<vm-name>"]` and
`bpa_dce_azure_vms["<vm-name>"]` addresses for performance and endpoint
associations. The DCE association name is `configurationAccessEndpoint`.
Repeat only for resources that already exist and are not already tracked.

The lab also manages SQL IaaS resources, AMA, and the custom assessment table.
See [existing SQL VM resources](AZURE-TERRAFORM-LAB.md#existing-sql-vm-resources)
and [alert imports](CREATING-ALERTS.md#import-existing-script-created-resources)
when adopting a previously deployed lab.

## 4. Review, apply, and verify

```powershell
terraform plan -out=migration.tfplan
terraform apply migration.tfplan
```

Stop and investigate any unexpected replacement, deletion, schema change, or
destination change. Do not delete a working collection pipeline merely to
resolve a Terraform conflict. Importing alone does not ensure a non-destructive
apply.

After applying, verify AMA health and data in `Perf`, `Heartbeat`, and
`SqlAssessment_CL` using [the monitoring guide](MONITORING-SETUP.md).
Avoid duplicate CSV collection and verify ingestion before retiring old
associations. Arc machine associations remain outside this lab's Terraform
configuration and require separate management.
