# Azure-hosted Arc SQL lab using the Jumpstart nested-VM pattern

[Back to the dashboard README](../README.md)

Use [Create-ArcJumpstartLab.ps1](../Create-ArcJumpstartLab.ps1) to provision
**one Azure x64 Hyper-V host with five nested Windows Server/SQL Server 2019
Developer guests**, register the guests with Azure Arc, and associate this
repository's existing monitoring rules. Your local laptop can be ARM64: it
launches Azure deployments rather than running the guests locally.

## Relationship to Azure Arc Jumpstart

The [repository you linked](https://github.com/Azure/arc_jumpstart_docs/) contains
documentation. Its [Azure SQL Server scenario](https://github.com/Azure/arc_jumpstart_docs/tree/main/docs/azure_arc_jumpstart/azure_arc_sqlsrv/azure/azure_arm_template_sqlsrv_winsrv_defender)
links to the implementation in
[microsoft/azure_arc](https://github.com/microsoft/azure_arc/tree/main/azure_arc_sqlsrv_jumpstart/azure/windows/defender_sql/arm_template).
The upstream scenario creates one nested SQL guest, a workspace, and enables
Defender for SQL at subscription scope.

This is a **tailored, Jumpstart-inspired bootstrap**, not an unmodified ArcBox
deployment or an automated clone of the documentation repository. It uses
Jumpstart's published `JSSQL19Base.vhdx` Developer lab image and its nested
Hyper-V pattern, with this repository's own host/guest automation. Source
behavior was checked against upstream revision
`e2c114eed98d18105dcf3a718bef965d5112781b`.
No upstream PowerShell scripts are downloaded or executed by this bootstrap.
The published VHDX URL itself is mutable and is not pinned by that Git commit.

Differences are intentional:

- Five guests share one host; each gets 8 GB RAM and two virtual CPUs.
- Reuses the existing workspace, assessment DCR, performance DCR, and DCE.
- Does **not** enable or change subscription-wide Defender plans.
- Does **not** disable the outer Azure host's VM agent.
- Does **not** assert Software Assurance or enable SQL pay-as-you-go.
- No public inbound IP on the host. A NAT Gateway provides explicit outbound
  access, including on subnets where default outbound access is disabled.

## Prerequisites and costs

- Windows with **PowerShell 7.2+**, Azure CLI, and `az login` to the correct
  tenant/subscription. Local Hyper-V is not required.
- A dedicated resource group for this lab, separate from the monitoring group.
  The bootstrap creates it and marks it `Purpose=ArcSqlJumpstartLab`.
- Rights to deploy VM/network resources, register resource providers, manage
  Arc extensions and DCR associations, and assign the **Azure Connected Machine
  Onboarding** role on the dedicated lab group.
- An existing service principal and unexpired secret. Supply its application
  ID and secret when prompted. The bootstrap resolves its object ID using
  Microsoft Graph using the signed-in tenant (without the subscription-only
  CLI argument) and grants only the onboarding role on the lab group; your
  signed-in CLI identity configures monitoring/extensions afterward.
- Existing compatible monitoring resources from this repository's Terraform
  lab, including `SqlAssessment_CL`. They are discovered in the monitoring
  group unless you pass explicit resource IDs. Both DCRs must target only the
  selected workspace and use the selected DCE and workspace region.
- Sufficient regional quota/capacity for **16 D-series vCPUs**, and permissions
  under your organization's policies. The default host is `Standard_D16s_v5`
  with 64 GB RAM. `Standard_D16s_v4` and `Standard_D16s_v3` are alternative
  nested-virtualization sizes. Listing a SKU does not guarantee allocation.
- Approved outbound access to Azure Arc/Monitor endpoints, Microsoft's agent
  download, and `jumpstartprodsg.blob.core.windows.net`.
- The initial Administrator credentials for Jumpstart's published Developer
  image. Consult the `Creating VM Credentials` section of the upstream
  [ArcServersLogonScript.ps1](https://github.com/microsoft/azure_arc/blob/e2c114eed98d18105dcf3a718bef965d5112781b/azure_arc_sqlsrv_jumpstart/azure/windows/defender_sql/arm_template/scripts/ArcServersLogonScript.ps1).
  Do not reuse those published demo credentials as your new lab password.
- Review the image's evaluation/licensing terms and expiration. These are
  isolated, disposable, non-production guests, not licensed production servers.

**Azure charges apply** for the host, OS disk, 512 GB Premium SSD data disk,
NAT Gateway, outbound public IP, bandwidth, and monitoring ingestion/retention.
There is no automatic shutdown or deletion in this bootstrap. Stopping the
host does not stop disk/NAT/IP charges.

The NAT public IP is not attached to the host NIC and cannot be used to RDP
into it. Use Azure Run Command, or arrange approved private connectivity/Bastion
separately. No inbound RDP/SQL firewall rules are opened.

## Preview and deploy

Rerunning with the same lab layout waits for an existing guest Run Command
before modifying the host. It checks the execution state, exit code, and
`ARC_SQL_GUESTS_READY` marker, then reuses verified guest setup and continues
extension and monitoring configuration without submitting another guest run.
A failed resumed run stops explicitly; a wait timeout can be resumed by rerunning.
Multiple active commands or an unrelated active command require manual inspection.

Run from the repository root in PowerShell 7:

```powershell
az login --tenant "<tenant-id>"

# Local preview only: no Azure requests, credentials, or deployment.
.\Create-ArcJumpstartLab.ps1 `
    -SubscriptionId "<subscription-id>" `
    -MonitoringResourceGroupName "sql-bpa-lab-rg"

# Explicit deployment; prompts for the three credentials below.
.\Create-ArcJumpstartLab.ps1 `
    -SubscriptionId "<subscription-id>" `
    -MonitoringResourceGroupName "sql-bpa-lab-rg" `
    -ResourceGroupName "arc-sql-jumpstart-rg" `
    -Location "swedencentral" `
    -Deploy
```

The prompts request:

1. **New lab credentials:** an allowed Windows host administrator username
   (default `arcadmin`) and a unique password of at least 12 characters.
   The same password replaces the nested guests' built-in Administrator password.
2. **Initial image credentials:** the upstream image's Administrator credentials.
   Each new guest boots without network connectivity until its password is rotated.
   For the published image, pass `-UsePublishedImageCredential` instead of
   `-ImageCredential` to use the public demo login documented by the pinned
   upstream source. The guest password is then replaced with the new lab password
   before network attachment. Do not use this option with a different/custom image.
3. **Onboarding service principal:** application/client ID as the username and
   client secret as the password.

Alternatively, pass `-LabCredential`, `-ImageCredential`, and
`-OnboardingCredential` as `PSCredential` objects obtained with `Get-Credential`.
For repeated runs without password prompts, follow the script's comment-based
`.EXAMPLE` blocks (`Get-Help .\Create-ArcJumpstartLab.ps1 -Examples`).
They save credentials once outside the repository with `Export-Clixml`, then
load them with `Import-Clixml` and pass all deployment parameters using splatting.
On Windows, the saved passwords can only be decrypted by the same Windows user
on the same computer. Treat these files as sensitive and delete them when no
longer needed; recreate them when credentials change.
Add `-NonInteractive` to require all three credentials (or the published-image
option in place of `ImageCredential`) before any Azure calls
rather than prompting for missing ones. Use `-Confirm:$false` to suppress
ShouldProcess confirmation prompts.
Do not put passwords/secrets in command history, scripts, transcripts, or Git.

Credentials are supplied through ARM secure parameters and managed Run Command
protected parameters. Local JSON parameter files are created in a unique
directory restricted to the current Windows identity and removed in `finally`.
An abrupt process termination can prevent cleanup; treat any leftover
`arc-sql-<guid>` directory in your Windows temporary folder as sensitive.

Optional parameters:

| Parameter | Default / purpose |
|---|---|
| `-MachineCount` | `5`; supported range 1-5 |
| `-MachinePrefix` | `arcsql`; names become `arcsql-01` through `arcsql-05` |
| `-HostName` | `arcsql-host` |
| `-VmSize` | `Standard_D16s_v5` |
| `-WorkspaceResourceId` | Explicit workspace ARM resource ID |
| `-AssessmentDcrResourceId` | Explicit assessment DCR ARM resource ID |
| `-PerformanceDcrResourceId` | Explicit performance DCR ARM resource ID |
| `-DataCollectionEndpointResourceId` | Explicit DCE ARM resource ID |

`-Deploy -WhatIf` also performs no deployment. Existing groups without the
bootstrap's ownership/layout tags are rejected. Keep the same host name,
machine prefix, and count when resuming an existing lab.

## Automation and verification

The bootstrap:

1. Validates existing monitoring resources and checks regional SKU restrictions.
2. Creates the dedicated group, host, outbound networking, and disks.
3. Installs Hyper-V on the Azure host and restarts that host if required.
4. Downloads the base SQL image once and creates per-guest differencing disks.
5. Rotates guest passwords, assigns unique names/static NAT addresses, starts
   SQL Server, and blocks IMDS **inside the nested guests only** before onboarding.
6. Connects each guest with the supplied onboarding service principal.
7. Installs/verifies AMA and the SQL extension and associates both existing
   DCRs plus the DCE with each **Arc machine**, not the outer Azure VM.
8. Verifies connected Arc machines, successful extension provisioning, matching
   association IDs, and discovered SQL inventory before reporting completion.

Guest provisioning can take hours; the managed Run Command has a four-hour
timeout. Monitor its instance view on the outer VM if the launcher disconnects.
The host VM agent stays running so Azure Run Command remains available.

### Progress in the console

The launcher prints timestamped messages for eight phases: validation,
credentials/providers/permissions, host deployment, Hyper-V, guest setup,
extensions/monitoring, SQL inventory, and completion. Each message includes the
total elapsed time. It identifies each server, extension, and association as
it is processed and reports resources that are reused.

During guest setup, it polls every 30 seconds and displays the actual number
of requested Arc machines that are connected, such as `Arc connected: 2/5`.
It also displays the latest guest setup message when Azure exposes managed
Run Command output. Azure can buffer that output, so guest messages are
best-effort rather than a guaranteed live stream. The initial image download
is approximately 53 GB; `0/5` connected during that download is expected.
Messages show completed phases and observed counts, not a time estimate or
an invented percentage. A synchronous Azure deployment/role operation may
remain at its announced phase for several minutes before returning.

### Reruns and idempotency

The bootstrap is **designed to be rerunnable with the same configuration**,
not a strictly no-op second run:

- It reuses the group, host/network/disks, base image, existing guests, Arc
  registrations, and existing onboarding role assignment.
- Already registered providers are skipped. A deallocated host is started.
- Guests already accepting the lab password do not have that password reset
  again, avoiding password-history/minimum-age problems.
- ARM host configuration, extensions, and monitoring associations are
  reconciled again. Guest networking, time zone, and SQL service are checked
  when guest setup executes; a verified completed setup is reused.
- A new managed Run Command is created only when no verified completed setup
  can be reused and no existing setup is being resumed.
- The original layout and credentials must be retained. This is not a
  password-rotation, resizing, or guest-count migration tool. Existing guest
  runs are awaited, but the
  preflight is not a distributed lock: never launch two copies together.

This behavior is covered by local mocks and focused guest-function tests,
not yet by a verified live Azure deployment.

The base image already contains SQL Server. This bootstrap does not call
`Create-HyperVLab.ps1`, install from ISOs, restore sample databases, or
automatically apply the optional SQL misconfigurations.

### BPA is separate from connectivity and collection

The SQL extension uses `LicenseOnly`; the bootstrap does not assert paid
entitlement for these Developer lab instances. **It does not enable BPA or
create a BPA schedule.** Associating the assessment DCR only prepares CSV
collection if assessments are subsequently enabled through an eligible,
supported licensing configuration.

See [Arc BPA prerequisites and enablement](ENABLE-ARC-SQL-BPA.md) before enabling
license-gated features. Do not select `Paid` merely to bypass a licensing check.
Avoid generating assessment-managed duplicate DCRs alongside your existing
custom collection. Migration assessment is separate too.

CPU/disk data should arrive in the existing workspace's `Perf` table after AMA
starts. The bootstrap verifies deployment wiring, not that telemetry has arrived.
Use [the monitoring queries](MONITORING-SETUP.md#5-verify-the-pipeline-before-importing-the-workbook)
and select the new Arc resource group in the workbook. Until assessments run,
empty BPA panels are expected.

## Recovery and cleanup

- Failures are surfaced; no existing VM or disk is deleted to repair a run.
  Partial Azure deployments remain billable. Fix the specific error, then
  rerun with the original layout and credentials.
- Do not launch concurrent bootstraps. After a launcher timeout/disconnection,
  inspect the host's managed Run Commands and wait for or stop the existing
  command before retrying.
- Wrong initial image credentials stop guest preparation; they are not replaced
  with hard-coded defaults. Use the same new lab password on a retry.
- The differencing disks require their shared parent VHDX. Do not move, edit,
  or delete the base image after guests have been created.
- Organizational policy can block NAT, VMs, agents, networking, or extensions.
  Arrange approved configuration/exemptions; the script does not bypass policy.
- This lab uses ARM deployments, **not the existing Terraform state**. The
  shared monitoring resources remain owned by the original deployment.
- To retire the lab, review the exact dedicated resource group's contents in
  Azure, then delete **only that lab group**. This removes its host, disks,
  networking, Arc registrations, and group-scoped role assignment. Do not
  delete the monitoring group/workspace/DCRs/DCE. Your existing service principal
  is not deleted. Retained workspace data still follows its retention policy.

## Local checks

Run the non-deploying checks from the repository root:

```powershell
.\jumpstart\Test-ArcJumpstartLab.ps1
```

These validate syntax, template safety invariants, preview/WhatIf behavior, and
monitoring-resource validation with mocks. They do not prove a successful live
deployment or availability/licensing of the upstream image.
