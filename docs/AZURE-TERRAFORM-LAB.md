# Build the Azure Terraform lab

[Back to the dashboard README](../README.md)

This guide provisions the Azure SQL dashboard lab with
[Create-LabEnvironment.ps1](../Create-LabEnvironment.ps1) and
[Terraform](../terraform). For a new lab, the only manual configuration step
is creating the tfvars file. Run the script, sign in when prompted, and it
bootstraps remote state and deploys the lab. Hyper-V/Arc onboarding is separate.
Run commands from the repository root in PowerShell unless stated otherwise.

> Lab only: the configuration intentionally applies SQL misconfigurations.
> Azure VMs, disks, Bastion, networking, Log Analytics, and alerts can incur
> charges. SQL Developer images are for non-production use.

## What gets created

- Five Windows VMs named `sql-bpa-01` through `sql-bpa-05`, using SQL Server
  2019/2022 Developer marketplace images and system-assigned identities.
- Private VM NICs, a virtual network, SQL and Bastion subnets, network security,
  NAT-based outbound connectivity, and Azure Bastion.
- Managed data disks and SQL configuration through a Custom Script Extension.
- Sample databases and intentional misconfigurations; `sql-bpa-04` uses the
  `baseline` configuration for comparison.
- A generated administrator password stored in Key Vault.
- A Log Analytics workspace, a shared data collection endpoint (DCE), and
  assessment and performance data collection rules (DCRs) with Azure VM associations.
- Daily VM shutdown, by default at **19:00 UTC**.
- Subscription-wide SQL IaaS Agent automatic registration through the
  `Microsoft.SqlVirtualMachine/BulkRegistration` feature.
- Terraform-managed SQL IaaS resources with BPA enabled every Sunday at
  **09:00 UTC**, AMA on each VM, and the `SqlAssessment_CL` custom table.
- The `SQL-BPA-Alerts` email action group and 22 scheduled-query alert rules
  (21 enabled; the 7-day stale-assessment rule is intentionally disabled).
- The primary Azure Arc SQL dashboard workbook, published by Terraform.
- A separate backend resource group, storage account, and private blob container,
  bootstrapped by PowerShell before Terraform initializes.

See [VM definitions](../terraform/sql-vms.tf) for sizes, images, disks, databases,
and per-machine misconfigurations. Images, disks, databases, and
misconfigurations are defined in Terraform locals rather than the variable file.
VM sizes can be overridden individually with `vm_size_overrides`. The defaults
for `sql-bpa-01` and `sql-bpa-05` are `Standard_D2s_v5` and `Standard_D4s_v5`
because the original B-series sizes were unavailable in Sweden Central.
Published SKU eligibility does not guarantee real-time capacity.

## Prerequisites

- Terraform **1.5 or later**, Azure CLI, and Windows PowerShell available on
  the deployment workstation. The configuration invokes `powershell` and `az`.
- An Azure subscription with quota and marketplace image availability for the
  selected VM sizes and region.
- Permissions to deploy resources, register resource providers, and create
  role assignments (for example Contributor plus User Access Administrator,
  or Owner, at the appropriate scope).
- Subscription-level permission to register features and resource providers.
  Resource-group-only access is insufficient for automatic SQL VM registration.
- A signed-in identity allowed to create backend resources and assign itself
  **Storage Blob Data Contributor** on the backend account. The script creates
  this assignment if it cannot find a direct/inherited blob contributor/owner
  assignment for the identity. It cannot grant permissions that you are not
  authorized to assign.
- Network access to Azure management APIs and the backend blob endpoint.
  Existing storage firewall/private endpoint restrictions must permit access
  from the workstation; the script does not weaken existing network settings.
- An approved network path to the **lab Key Vault and script storage account**,
  not just the state backend. Organization policies can disable their public
  endpoints. Arrange private connectivity or approved exemptions with your
  administrator before deploying. The script does not create policy exemptions.
  An exemption scoped only to the backend account does not cover lab resources.

## 1. Configure the lab

```powershell
Copy-Item .\terraform\terraform.tfvars.example .\terraform\terraform.tfvars
```

Edit [the local variable file](../terraform/terraform.tfvars.example) using the
example as a template. Set the tenant/subscription IDs and backend resource
group, account, and container. Choose a prefix and region; defaults are
`sql-bpa-lab` and `swedencentral`.
Set `alert_email_address` to your real notification address; the example
address is a placeholder. This variable is required, including for existing
local variable files created before alerting was added.

Choose a **globally unique** backend storage account name with 3-24 lowercase
letters/digits only (no hyphens). The container name must be 3-63 lowercase
letters/digits or single hyphens, beginning and ending with a letter/digit.
Use a backend resource group different from `<prefix>-rg` so destroying the
lab cannot delete its state. Keep the example's top-level quoted-string format
for bootstrap values, including `location`; the script validates them before
creating resources.

The prefix also forms storage account names: keep it short and use lowercase
letters, digits, and hyphens, checking the resulting Azure naming limits and
global uniqueness. Keep state, passwords, and local configuration out of Git.
Terraform state contains sensitive values even when output is marked sensitive.

The script-storage account name includes a deterministic eight-character hash
of the lab resource-group ID to avoid the globally shared `<prefix>scripts`
name. It is truncated to Azure's 24-character limit. If a previous deployment
already created the old account, review the plan for storage/extension changes
before applying; do not import a globally colliding account owned by someone else.

To select alternative sizes without editing Terraform:

```hcl
vm_size_overrides = {
  sql-bpa-01 = "Standard_D2s_v5"
  sql-bpa-05 = "Standard_D4s_v5"
}
```

Changing the region after partial deployment can replace resources. Prefer
per-machine overrides and review the plan instead of restarting in a new region.

### Git exclusions and local files

The repository's [.gitignore](../.gitignore) excludes:

| Files | Behavior |
|---|---|
| All `*.tfvars` and `*.tfvars.json` under the Terraform directory, including subdirectories | Keep environment values local |
| `.terraform/` directories and `.terraform.lock.hcl` | Exclude initialization artifacts and the provider lock file |
| `*.tfstate` and `*.tfstate.*` | Exclude local state, backups, and state-lock metadata |
| `*.tfplan` | Exclude saved plans, including `lab.tfplan` |
| Terraform crash logs and override files | Exclude local diagnostics and overrides |

The [example variable file](../terraform/terraform.tfvars.example) remains
tracked because its name ends in `.example`, not `.tfvars`. Update that template
with placeholders when adding new inputs; do not commit real local values.
Terraform configuration (`.tf`) and the mocked tests remain tracked.

These rules do not remove files already tracked by Git or protect secrets in
arbitrarily named files. Check `git status` before committing. Remote state
still needs secure storage and access control. Because the provider lock file
is ignored in this repository, initialization can select newer provider
versions within the configured constraints.

### Subscription-wide SQL IaaS Agent automatic registration

[main.tf](../terraform/main.tf) enables `BulkRegistration` using Azure CLI in a
Terraform `local-exec` provisioner. It explicitly targets `subscription_id`,
waits up to 30 minutes for the feature to become `Registered`, and refreshes
the `Microsoft.SqlVirtualMachine` provider registration. CLI failures or a
registration timeout fail the Terraform apply rather than reporting success.

**Review and accept the terms before applying:** this opts the entire
subscription into [automatic SQL IaaS Agent registration](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/sql-agent-extension-automatic-registration-all-vms).
It covers eligible existing and future SQL Server VMs, not just this lab.
Registration does not restart SQL Server, but discovery/VM registration is
asynchronous: a registered subscription feature does not mean every VM's
extension has finished deploying.

Automatic registration itself does not configure assessment or monitoring.
The lab separately manages those through [sql-assessment.tf](../terraform/sql-assessment.tf).
On a new deployment, automatic registration is enabled after the lab's SQL VM
resources are created to avoid competing with Terraform registration.

The provisioner runs when its Terraform resource is created/replaced, not on
every apply, and does not detect out-of-band feature changes. To reapply it
after a manual change, plan with
`-replace=terraform_data.sql_vm_automatic_registration` and review the plan.

## 2. Run end-to-end deployment

```powershell
.\Create-LabEnvironment.ps1
```

The script:

1. Validates required commands, bootstrap configuration, account/container
   naming, and the notification address.
2. Signs in to the configured tenant and selects the configured subscription.
3. Creates or reuses the backend resource group and storage account. New
   accounts use Standard LRS, TLS 1.2 minimum, no anonymous blob access, and no
   shared-key authentication.
4. Grants the signed-in principal blob data access if needed, then creates or
   reuses the state container using the management API.
5. Waits up to 15 minutes for blob RBAC/DNS readiness using Microsoft Entra
   authentication. It stops on non-propagation errors or timeout.
6. Runs `terraform init` with the backend values from tfvars, `validate`,
   `plan`, and applies that saved plan. A failed command stops the workflow.
7. Prints outputs, including the deployed workbook ID, and removes the
   temporary saved plan.

**Running the script approves deployment and costs:** it prints the plan and
automatically applies it without a separate confirmation. Review the
configuration and subscription-wide registration terms before running.
No storage keys or service-principal secrets are required for bootstrap.

For a different variable file:

```powershell
.\Create-LabEnvironment.ps1 -TfvarsPath "C:\LabConfig\azure-lab.tfvars"
```

Rerun the same command to apply changes. Existing backend resources are reused;
the script does not delete state, replace an unavailable global storage name,
automatically migrate a different backend, or import resources deployed outside
the current Terraform state.

### Existing SQL VM resources

If these VMs were already registered by Azure, the portal, or PowerShell, import
their SQL VM resources before planning an apply. For example, from the
Terraform directory:

```powershell
terraform import 'azurerm_mssql_virtual_machine.sql[\"sql-bpa-01\"]' `
    "/subscriptions/<subscription-id>/resourceGroups/sql-bpa-lab-rg/providers/Microsoft.SqlVirtualMachine/sqlVirtualMachines/sql-bpa-01"
```

Repeat for each existing SQL VM. Likewise import an existing
`AzureMonitorWindowsAgent` extension into
`azurerm_virtual_machine_extension.azure_monitor["<vm-name>"]`, and an existing
`SqlAssessment_CL` table into `azapi_resource.sql_assessment_table`, if present.
Review the plan for licensing or extension changes before applying.

## 3. Inspect the deployment

```powershell
Push-Location .\terraform
terraform output
Pop-Location
```

The outputs include the VM names/private addresses, Bastion name, workspace
name, Key Vault name, workbook ID, and a command to retrieve the administrator password.
Treat the password as a secret and do not paste it into logs or documentation.

In the portal, verify each VM and its `configure-sql` extension succeeded.
Connect through Bastion using the configured administrator username and the
password in Key Vault. Check SQL Server is running and sample databases exist.
The shutdown schedule does not start VMs again automatically.

## 4. Verify BPA and its schedule

Terraform now enables SQL BPA and its native **weekly** schedule: Sunday at
09:00 UTC. Native BPA scheduling supports weekly/monthly recurrence, not daily.
VM time zones are explicitly UTC. Ensure VMs are started before the scheduled
run; the daily shutdown schedule does not start them.

The schedule is defined in
[sql-assessment.tf](../terraform/sql-assessment.tf), not in tfvars:

```hcl
assessment {
  enabled         = true
  run_immediately = false

  schedule {
    day_of_week     = "Sunday"
    start_time      = "09:00"
    weekly_interval = 1
  }
}
```

To change it, edit this block, review the Terraform plan, and apply. Check
`terraform output bpa_schedule` for the documented default; if changing the
schedule, also update that output in [outputs.tf](../terraform/outputs.tf).
Verify the applied settings under each SQL virtual machine's best practices
assessment configuration in the portal.

AMA collects assessment CSV files through the Terraform-created
`<prefix>-bpa-dcr` and shared DCE into the Terraform-created workspace's
`SqlAssessment_CL` table. Performance counters use the separate performance
DCR. This uses explicit collection associations rather than calling the
workspace-linking CLI workflow that can create additional `sqlbpa-*` rules.
AzAPI creates the custom table because AzureRM's table resource cannot create
custom table schemas.

No immediate assessment is requested during apply. To test before the next
Sunday, use `az sql vm start-assessment -g "<resource-group>" -n "sql-bpa-01"`,
then check completion and ingestion as described in
[agents, DCRs, and alerts](MONITORING-SETUP.md). Use Terraform to change these settings rather than a separate IaaS enablement
script, which could create schedule drift or an overlapping collection pipeline.
Arc/Hyper-V onboarding remains separate.

## 5. Verify Terraform-managed alerts

[alerts.tf](../terraform/alerts.tf) creates the `SQL-BPA-Alerts` email action
group and 22 scheduled-query rules against the lab workspace. There is no
separate alert deployment script step.

- Set `alert_email_address` in your local tfvars before planning. Existing local
  variable files must also have this newly required value.
- 21 rules are enabled. `SQL-BPA-17-StaleAssessment` is intentionally disabled:
  a 7-day freshness check cannot be implemented by the original query within
  the scheduled-query alert service's maximum 48-hour evaluation lookback.
- Heartbeat/performance-gap rules use a 48-hour lookback with their original
  10/15/30-minute absence thresholds. Machines never seen, or absent longer than
  48 hours, need separate inventory-based monitoring.
- The findings rule uses `SqlAssessment_CL`, not the legacy recommendation
  table. Query validation is skipped during creation so deployment can succeed
  before the first performance/heartbeat data arrives.

If alerts or the action group already exist from PowerShell, follow
[the import instructions](CREATING-ALERTS.md#import-existing-script-created-resources)
before applying. Do not run
an independent alert-creation script against these Terraform-managed resources.

After ingestion begins, verify the queries in Log Analytics, inspect the rules'
health in Azure Monitor, and test email delivery from the action group.
Expected VM shutdowns can trigger absence alerts; review suppression for the
lab's downtime. Alerting and query scans can incur costs.

The [alert reference](CREATING-ALERTS.md#terraform-deployment) describes the
intentional differences from the original PowerShell definitions.
With Terraform 1.15 or later, `terraform test` from the Terraform directory runs
provider-mocked configuration tests without deploying Azure resources. These
tests do not execute KQL or verify notification delivery.

## 6. Open the dashboard

Terraform publishes the primary workbook through
[workbook.tf](../terraform/workbook.tf). Open **Azure Monitor > Workbooks** in
the portal and select **Azure Arc SQL Dashboard** in the lab resource group.
Select the lab workspace and your resource scope. There is no manual JSON
import step for this deployment.

Verify CPU, storage I/O, and BPA panels independently after data arrives.
Migration readiness needs separate migration assessment data; enabling BPA
alone does not populate it. The [manual import instructions](../README.md#import-the-workbook)
remain useful when using the workbook without this lab.

## Troubleshooting and cleanup

### Recover from a partial apply

Keep the existing remote state and rerun the lab script after resolving the
errors. Terraform retains successfully created resources and plans the remaining
work. Do not delete the state, clear resource tracking, or destroy successful VMs
just to retry a failed deployment.

- **Findings alert KQL parse error at `latest`:** use the updated
  [alerts.tf](../terraform/alerts.tf), which uses `latestAssessmentRuns`.
  The corrected query has been executed against the lab workspace to verify
  parsing and the `_ResourceId`/`AggregatedValue` output schema.
- **Workbook source ID contains uppercase letters:** the workbook resource
  normalizes its workspace source ID to lowercase.
- **Script storage name already taken:** the updated name has a
  resource-group-specific suffix. Review the new name in the plan.
- **VM `SkuNotAvailable`:** use `vm_size_overrides` for the failed VM. The
  subscription SKU listing can show no restrictions while Azure still lacks
  capacity at allocation time.
- **SQL VM `Ext_AutomatedBackupError` / object-reference error:** this can
  originate in the SQL IaaS Agent extension even though this lab does not
  configure automated backup. Check the failed VM's SQL IaaS extension status
  rather than adding backup storage or changing the BPA schedule. Follow
  Microsoft's [extension repair procedure](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/sql-agent-extension-troubleshoot-known-issues#repair-extension):
  in the Azure portal, open **SQL virtual machines**, select the affected
  machine, then **Help > SQL IaaS Agent Extension Settings > Repair**.
  Repair resets extension-managed settings other than licensing; review any
  existing backup/patching configuration first. After repair succeeds, rerun
  the lab script to reconcile Terraform settings, including the BPA schedule.
  If Terraform reports that the SQL VM resource already exists, use the
  SQL VM import instructions above before retrying. Do not delete the VM,
  its disks, or Terraform state as a recovery shortcut. If repair fails,
  preserve the extension error details for Microsoft support.

### Key Vault and script-storage policy restrictions

`ForbiddenByConnection` while writing `vm-admin-password` is a Key Vault
network failure, not proof of missing Secrets Officer permissions. Terraform
writes the secret from the deployment workstation, so an approved private
endpoint/network route or approved public-endpoint access is required.

If you arrange exemptions, ensure they cover the actual lab resources in
`<prefix>-rg`, including the Key Vault and the newly named script-storage
account. An exemption prevents future policy enforcement but does not restore
endpoint settings already modified by policy. Have the administrator verify
the permitted network configuration before retrying.

The script-storage data plane must be reachable by both the deployment
workstation (upload) and the SQL VMs (extension download). Storage RBAC alone
does not provide this network path. Use approved firewall/VNet service-endpoint
or private-endpoint configuration as appropriate; a workstation-only IP rule
does not give the VMs access. Do not enable anonymous blob access or shared keys
to try to fix a network restriction.

If `azurerm_storage_blob.configure_sql` fails with **403 / EOF**, check the
script-storage account itself, not just the backend. `publicNetworkAccess =
Disabled` blocks the public blob endpoint even when the firewall's default
action is `Allow` and the deploying identity has Storage Blob Data Contributor.
The `AzureServices` bypass does not automatically permit workstation access.
An exemption must cover this account and be effective before its permitted
network settings are restored; the exemption alone does not enable the endpoint.

No automatic exemption creation or firewall relaxation is performed by this lab.

- For state access failures, verify the backend IDs, active subscription,
  storage networking, and blob data-plane RBAC. A role-assignment authorization
  error requires an identity with permission to assign roles; rerunning does
  not elevate your permissions. An unavailable storage name requires a new
  unique value in tfvars.
- For deployment failures, inspect the Terraform error and Azure deployment or
  extension logs. Check regional quota, marketplace image availability, and
  outbound access for script/database downloads before retrying.
- For configuration changes, review `terraform plan`; `script_version` can
  force the SQL configuration extension to rerun and reapply lab settings.

When finished, review and destroy the Terraform-managed lab:

```powershell
Push-Location .\terraform
terraform plan -destroy
terraform destroy
Pop-Location
```

Destroying the lab deletes its data and Key Vault resources; the provider is
configured to purge soft-deleted vaults on destroy. Back up anything needed.
Terraform-managed alert rules, the action group, and the workbook are also removed.
Separately remove script-created alerts, older workbooks, Arc resources, or associations
that are not tracked in Terraform before deleting shared dependencies.
The PowerShell-bootstrapped state backend and its role assignment are outside
this Terraform state and are retained. Do not delete the backend until you have
retired every deployment using it and securely handled any state backups.

**Automatic registration remains enabled after `terraform destroy`.** There
is intentionally no destroy-time unregistration because this is a shared
subscription setting. If you also want to disable it, first review the impact
on all other SQL VMs, then explicitly run:

```powershell
az feature unregister `
    --namespace Microsoft.SqlVirtualMachine `
    --name BulkRegistration `
    --subscription "<subscription-id>"
```

Disabling automatic registration does not unregister SQL VMs already registered.
