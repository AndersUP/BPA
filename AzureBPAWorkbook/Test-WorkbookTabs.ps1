#requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$latestPath = Join-Path $PSScriptRoot 'Azure Arc SQL Dasbboard w cpu and io and assessment.json'
$latest = Get-Content -LiteralPath $latestPath -Raw | ConvertFrom-Json -AsHashtable
$historical = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'olderVersions') -Filter '*.json' -File)
if ($historical.Count -ne 3) { throw 'Expected three historical workbook versions.' }
$links = @($latest.items | Where-Object { $_.type -eq 11 -and $_.content.style -eq 'tabs' }).content.links
$targets = @($links.subTarget)
if (@($targets | Select-Object -Unique).Count -ne $targets.Count) { throw 'Duplicate top-level tab targets.' }
foreach ($link in $links) {
    $groups = @($latest.items | Where-Object {
        $_.ContainsKey('conditionalVisibility') -and $_.conditionalVisibility.parameterName -eq $link.cellValue -and
        $_.conditionalVisibility.value -eq $link.subTarget
    })
    if ($groups.Count -ne 1 -or $groups[0].content.items.Count -eq 0) {
        throw "Tab must have exactly one nonempty content group: $($link.linkLabel)"
    }
}
foreach ($file in $historical) {
    $old = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
    $oldLinks = @($old.items | Where-Object { $_.type -eq 11 -and $_.content.style -eq 'tabs' }).content.links
    foreach ($link in $oldLinks) {
        if ($link.subTarget -notin $targets) { throw "Missing historical tab: $($link.linkLabel) from $($file.Name)" }
    }
    if ($oldLinks.subTarget -contains 'StorageIO') {
        $oldStorage = @($old.items | Where-Object { $_.ContainsKey('conditionalVisibility') -and $_.conditionalVisibility.value -eq 'StorageIO' })[0]
        $newStorage = @($latest.items | Where-Object { $_.ContainsKey('conditionalVisibility') -and $_.conditionalVisibility.value -eq 'StorageIO' })[0]
        $storageComparison = $newStorage | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
        foreach ($panel in $storageComparison.content.items) {
            if ($panel.name -in @('query - disk-config', 'query - storage-checklist',
                'query - io-summary', 'query - bpa-storage-findings')) {
                $originalPanel = @($oldStorage.content.items | Where-Object { $_.name -eq $panel.name })[0]
                $panel.content.size = $originalPanel.content.size
            }
        }
        if (($oldStorage | ConvertTo-Json -Depth 100 -Compress) -cne ($storageComparison | ConvertTo-Json -Depth 100 -Compress)) {
            throw 'Storage must preserve original queries, parameters and drill-downs; only selected panel sizes may differ.'
        }
    }
}
foreach ($target in @('Resources', 'BPADashboard', 'CustomMonitoring', 'StorageIO', 'MigrationAssessment', 'AzureAdvisor', 'AzureUpdates', 'WindowsHealth')) {
    if ($target -notin $targets) { throw "Missing required tab: $target" }
}
$storage = @($latest.items | Where-Object { $_.ContainsKey('conditionalVisibility') -and $_.conditionalVisibility.value -eq 'StorageIO' })[0]
$parameterNames = @($storage.content.items | Where-Object { $_.type -eq 9 } |
    ForEach-Object { $_.content.parameters.name })
if ('IoWorkspace' -notin $parameterNames -or 'IoTimeRange' -notin $parameterNames) {
    throw 'Storage workspace/time selectors are missing.'
}
$exporters = @($storage.content.items | Where-Object { $_.content['exportParameterName'] -eq 'SelectedIoMachine' })
if ($exporters.Count -ne 1 -or $exporters[0].content.exportFieldName -ne 'Computer') {
    throw 'Storage machine selection must export Computer for chart drill-downs.'
}
$migration = @($latest.items | Where-Object { $_.ContainsKey('conditionalVisibility') -and $_.conditionalVisibility.value -eq 'MigrationAssessment' })[0]
foreach ($filter in @('fMI', 'fDB', 'fVM')) {
    $initializers = @($migration.content.items | Where-Object { $_.type -eq 9 } |
        ForEach-Object { $_.content.parameters } | Where-Object { $_.name -eq $filter })
    if ($initializers.Count -ne 1 -or $initializers[0].value -cne 'All') {
        throw "Readiness filter $filter must be explicitly initialized to All before chart selection."
    }
    $initializerIndex = [array]::IndexOf($migration.content.items,
        @($migration.content.items | Where-Object { $_.name -eq 'mig-readiness-filter-defaults' })[0])
    $firstChartIndex = [array]::IndexOf($migration.content.items,
        @($migration.content.items | Where-Object { $_.name -eq 'query - mig-db-readiness' })[0])
    if ($initializerIndex -lt 0 -or $initializerIndex -ge $firstChartIndex) {
        throw 'Readiness filter initialization must precede the charts and dependent queries.'
    }
    $exports = @($migration.content.items | Where-Object { $_.type -eq 3 } |
        ForEach-Object { $_.content['exportedParameters'] } |
        Where-Object { $null -ne $_ -and $_.parameterName -eq $filter })
    if ($exports.Count -ne 1 -or -not $exports[0].ContainsKey('defaultValue') -or
        $exports[0].defaultValue -cne 'All' -or $exports[0].fieldName -ne 'Readiness') {
        throw "Readiness chart filter $filter must export All when no readiness is selected."
    }
    foreach ($consumer in @('query - mig-comparison', 'query - mig-summary-grid')) {
        $queryItems = @($migration.content.items | Where-Object { $_.name -eq $consumer })
        if ($queryItems.Count -ne 1 -or
            -not $queryItems[0].content.query.Contains(('"{' + $filter + '}" == "All"')) -or
            -not $queryItems[0].content.query.Contains(('_bucket == "{' + $filter + '}"'))) {
            throw "Migration query $consumer must accept the default unfiltered value for $filter."
        }
    }
}
foreach ($removed in @('text - iaas-coverage-header', 'text - iaas-bpa-evidence-header',
    'parameters - migration-bpa-workspace', 'query - iaas-bpa-run-evidence',
    'query - iaas-coverage-tiles', 'query - iaas-coverage-grid', 'query - iaas-bpa-inventory-merged')) {
    if ($removed -in $migration.content.items.name) {
        throw "Removed IaaS proxy section must not be reintroduced: $removed"
    }
}
$migrationJson = $migration | ConvertTo-Json -Depth 100 -Compress
foreach ($orphan in @('MigrationBpaWorkspace', 'MigrationBpaTimeRange', 'Merge/1.0')) {
    if ($migrationJson.Contains($orphan)) { throw "Orphaned IaaS component/reference: $orphan" }
}
$header = @($migration.content.items | Where-Object { $_.name -eq 'text - migration-header' })[0].content.json
if ($header -ne '# Migration Assessment') {
    throw 'Migration header must contain only the tab title.'
}
$advisor = @($latest.items | Where-Object { $_.name -eq 'group - Azure Advisor' })[0]
$advisorQueries = @($advisor.content.items | Where-Object { $_.type -eq 3 })
if ($advisorQueries.Count -ne 6 -or
    @($advisorQueries | Where-Object { $_.content.visualization -eq 'piechart' }).Count -ne 3) {
    throw 'Advisor must have totals, three summary pies, machine totals, and recommendation details.'
}
$advisorParameters = @($advisor.content.items | Where-Object { $_.type -eq 9 } |
    ForEach-Object { $_.content.parameters })
if ($advisorParameters.Count -ne 1 -or $advisorParameters[0].name -ne 'AdvisorMachineId' -or
    $advisorParameters[0].value -ne 'All') {
    throw 'Advisor machine selection must initialize to All before queries execute.'
}
foreach ($query in $advisorQueries) {
    if ($query.content.queryType -ne 1 -or $query.content.crossComponentResources[0] -ne '{Subscription}') {
        throw 'Advisor must use Resource Graph scoped to selected subscriptions, not a Logs workspace.'
    }
    foreach ($required in @('advisorresources', 'microsoft.advisor/recommendations',
        'microsoft.sqlvirtualmachine/sqlvirtualmachines', 'microsoft.azurearcdata/sqlserverinstances',
        'properties.detectedProperties.mssqldiscovered', 'properties.resourceMetadata.resourceId',
        "'*' in ({ResourceGroup})", 'MachineResourceGroup in~ ({ResourceGroup})',
        'pack_array(MachineId, tolower(id))', 'summarize by MachineId, Machine, MachineResourceGroup, HostType, TargetId',
        'join kind=leftouter',
        'summarize arg_max(coalesce(UpdatedAt, datetime(1900-01-01)), *) by MachineId, RecommendationId')) {
        if (-not $query.content.query.Contains($required)) { throw "Advisor query $($query.name) lacks $required" }
    }
}
$advisorMachines = @($advisorQueries | Where-Object { $_.name -eq 'query - advisor-machines' })[0].content
$selection = $advisorMachines.exportedParameters[0]
if ($selection.parameterName -ne 'AdvisorMachineId' -or $selection.fieldName -ne 'MachineId' -or
    $selection.defaultValue -ne 'All') {
    throw 'Advisor machine rows must export full resource IDs with an All default.'
}
$advisorDetail = @($advisorQueries | Where-Object { $_.name -eq 'query - advisor-details' })[0].content
if (-not $advisorDetail.query.Contains("'{AdvisorMachineId}' == 'All' or MachineId == '{AdvisorMachineId}'")) {
    throw 'Advisor details must support estate-wide results and individual machine selection.'
}
$reset = @($advisor.content.items | Where-Object { $_.name -eq 'links - advisor-reset' })[0].content.links[0]
if ($reset.cellValue -ne 'AdvisorMachineId' -or $reset.subTarget -ne 'All') {
    throw 'Advisor must provide a reset to all SQL hosts.'
}
$updates = @($latest.items | Where-Object { $_.name -eq 'group - Azure Updates' })[0]
$updateQueries = @($updates.content.items | Where-Object { $_.type -eq 3 })
if ($updateQueries.Count -ne 7 -or
    @($updateQueries | Where-Object { $_.content.visualization -eq 'piechart' }).Count -ne 3) {
    throw 'Updates must include totals, three pies, host summary, patch catalogue, and selected-machine detail.'
}
$updateParameter = @($updates.content.items | Where-Object { $_.type -eq 9 } |
    ForEach-Object { $_.content.parameters })
if ($updateParameter.Count -ne 1 -or $updateParameter[0].name -ne 'UpdatesMachineId' -or
    $updateParameter[0].value -ne 'All') {
    throw 'Update machine selection must initialize to All, independently of Advisor selection.'
}
foreach ($query in $updateQueries) {
    if ($query.content.queryType -ne 1 -or $query.content.crossComponentResources[0] -ne '{Subscription}' -or
        [regex]::Matches($query.content.query, '\bpatchassessmentresources\b').Count -ne 1) {
        throw 'Updates must use scoped Resource Graph and reference the remote assessment table only once.'
    }
    foreach ($required in @('microsoft.compute/virtualmachines/patchassessmentresults',
        'microsoft.hybridcompute/machines/patchassessmentresults/softwarepatches',
        'properties.containerResourceId', 'properties.virtualMachineResourceId',
        'MachineResourceGroup in~ ({ResourceGroup})', 'join kind=leftouter',
        'make_list_if', 'dynamic([null])', 'No assessment returned', 'Assessment not successful',
        'Assessment time unknown', 'AssessmentTime < ago(24h)',
        'PatchAssessmentId == AssessmentId', 'PatchUpdatedAt >= AssessmentStartedAt',
        'PatchUpdatedAt <= AssessmentTime', "AssessmentStatus =~ 'Succeeded'",
        'PatchDetailsTruncated', 'mv-expand PatchRow = PatchRows limit 2000')) {
        if (-not $query.content.query.Contains($required)) { throw "Updates query $($query.name) lacks $required" }
    }
}
$updateMachines = @($updateQueries | Where-Object { $_.name -eq 'query - updates-machines' })[0].content
$export = $updateMachines.exportedParameters[0]
if ($export.parameterName -ne 'UpdatesMachineId' -or $export.fieldName -ne 'MachineId' -or
    $export.defaultValue -ne 'All') {
    throw 'Update machine rows must export the full host resource ID and default to All.'
}
$updateDetails = @($updateQueries | Where-Object { $_.name -eq 'query - updates-details' })[0].content
if (-not $updateDetails.query.Contains("'{UpdatesMachineId}' == 'All' or MachineId == '{UpdatesMachineId}'") -or
    -not $updateDetails.query.Contains('| where PatchValid')) {
    throw 'Update details must filter valid patches and support selecting a host or viewing all hosts.'
}
$updateReset = @($updates.content.items | Where-Object { $_.name -eq 'links - updates-reset' })[0].content.links[0]
if ($updateReset.cellValue -ne 'UpdatesMachineId' -or $updateReset.subTarget -ne 'All') {
    throw 'Updates must provide a reset to all SQL hosts.'
}
foreach ($groupName in @('group - Storage IO', 'group - Azure Advisor', 'group - Azure Updates')) {
    $group = @($latest.items | Where-Object { $_.name -eq $groupName })[0]
    foreach ($item in $group.content.items) {
        if ($item.name -in @('query - disk-config', 'query - storage-checklist',
            'query - io-summary', 'query - bpa-storage-findings', 'query - advisor-machines',
            'query - advisor-details') -or
            ($groupName -eq 'group - Azure Advisor' -and $item.content['visualization'] -eq 'piechart')) {
            if ($item.content.size -ne 3) { throw "Panel should use compact sizing: $($item.name)" }
        }
        if ($item.name -in @('query - advisor-totals', 'query - updates-totals') -and
            $item.content.size -ne 4) {
            throw "Single-row totals must use minimal height: $($item.name)"
        }
    }
}
foreach ($entry in @(
    @{ Group = $advisor; Name = 'text - advisor-header'; Text = '# Azure Advisor for SQL Hosts' },
    @{ Group = $updates; Name = 'text - updates-header'; Text = '# Azure Updates for SQL Hosts' }
)) {
    $heading = @($entry.Group.content.items | Where-Object { $_.name -eq $entry.Name })[0]
    if ($heading.content.json -cne $entry.Text) { throw "Header must contain only its title: $($entry.Name)" }
}
$windows = @($latest.items | Where-Object { $_.name -eq 'group - Windows Health' })
if ($targets.Count -ne 8 -or $windows.Count -ne 1) {
    throw 'Expected eight tabs including Windows Health.'
}
$windowsParameters = @($windows[0].content.items | Where-Object { $_.type -eq 9 } |
    ForEach-Object { $_.content.parameters.name })
foreach ($parameter in @('WinSection', 'WinDetailTab', 'WinSoftwareTab', 'WinMachineId', 'WinMachineName', 'WinWorkspace', 'WinSwTimeRange')) {
    if ($parameter -notin $windowsParameters) { throw "Missing Windows Health parameter: $parameter" }
}
foreach ($section in @('win-section-machines', 'win-section-baseline', 'win-section-software')) {
    if ($section -notin $windows[0].content.items.name) { throw "Missing Windows Health section: $section" }
}
$windowsSectionLinks = @($windows[0].content.items | Where-Object { $_.name -eq 'win-section-tabs' })[0].content.links
if ('updates' -in $windowsSectionLinks.subTarget -or 'win-section-updates' -in $windows[0].content.items.name) {
    throw 'Windows Health must not duplicate the estate Updates subtab.'
}
function Get-WindowsQueryItems($item) {
    if ($item.content.ContainsKey('query')) { $item }
    foreach ($child in $item.content['items']) { Get-WindowsQueryItems $child }
}
$windowsQueries = @(Get-WindowsQueryItems $windows[0])
foreach ($queryItem in $windowsQueries) {
    $query = $queryItem.content.query
    if ($queryItem.name -in @('win-tiles', 'win-machines-grid', 'win-detail-updates-grid',
        'win-bl-tiles', 'win-bl-machines', 'win-bl-mc', 'win-bl-policy', 'win-sw-def-grid')) {
        foreach ($required in @('microsoft.compute/virtualmachines', 'microsoft.hybridcompute/machines',
            'microsoft.sqlvirtualmachine/sqlvirtualmachines', 'microsoft.azurearcdata/sqlserverinstances',
            'properties.detectedProperties.mssqldiscovered', 'properties.storageProfile.osDisk.osType',
            'MachineResourceGroup in~ ({ResourceGroup})')) {
            if (-not $query.Contains($required)) {
                throw "Windows SQL host scope missing $required in $($queryItem.name)"
            }
        }
    }
    if ($queryItem.content.queryType -eq 0 -and
        (-not $query.Contains("'{WinMachineId}' != 'All' and tolower(_ResourceId) == '{WinMachineId}'") -or
        $query.Contains("Computer =~ '{WinMachineName}'"))) {
        throw "Change Tracking must match the selected SQL host by resource ID: $($queryItem.name)"
    }
}
$windowsGrid = @($windowsQueries | Where-Object name -eq 'win-machines-grid')[0].content.query
if (-not $windowsGrid.Contains('microsoft.compute/virtualmachines/patchassessmentresults') -or
    -not $windowsGrid.Contains('Not applicable (Azure VM)') -or
    -not $windowsGrid.Contains('| project MachineId, Machine, HostType, OS,')) {
    throw 'Windows Health must show native SQL VM patch assessment and host type without an Arc connection requirement.'
}
$baselineGroup = @($windows[0].content.items | Where-Object name -eq 'win-section-baseline')[0]
$baselineNote = @($baselineGroup.content.items | Where-Object name -eq 'text - baseline-explanation')[0]
if ($null -eq $baselineNote -or $baselineGroup.content.items[0].name -ne 'text - baseline-explanation' -or
    -not $baselineNote.content.json.Contains('guestconfigurationresources') -or
    -not $baselineNote.content.json.Contains('not included in these coverage counts')) {
    throw 'Baseline section must explain the Machine Configuration source and separate Azure Policy counts.'
}
$defenderSoftware = @($windowsQueries | Where-Object name -eq 'win-sw-def-grid')[0]
$cveTable = @($windowsQueries | Where-Object name -eq 'win-defender-cves')[0]
$softwareSection = @($windows[0].content.items | Where-Object name -eq 'win-section-software')[0]
$softwareDefenderGroup = @($softwareSection.content.items | Where-Object name -eq 'win-sw-defender')[0]
$defenderLink = @($softwareDefenderGroup.content.items | Where-Object name -eq 'text - defender-portal-link')[0]
if ($null -eq $cveTable -or $null -eq $defenderLink -or
    -not $defenderLink.content.json.Contains('SecurityMenuBlade/~/inventory') -or
    -not $cveTable.content.query.Contains("microsoft.security/assessments") -or
    -not $cveTable.content.query.Contains('CvesDetails') -or
    $cveTable.content.query.Contains('{WinMachineId}') -or
    -not $cveTable.content.query.Contains('MachineResourceGroup in~ ({ResourceGroup})') -or
    -not $cveTable.content.query.Contains('MachineNames = make_set(Machine, 25)') -or
    -not $cveTable.content.query.Contains('Machines = dcount(MachineId)') -or
    -not $cveTable.content.query.Contains('HostTypes = make_set(HostType, 5)') -or
    -not $cveTable.content.query.Contains('CVEFixedVersion') -or
    -not $cveTable.content.query.Contains('NVD') -or
    -not $defenderSoftware.content.query.Contains('numberOfKnownVulnerabilities')) {
    throw 'Defender software must retain inventory counts and show selected-host CVE-level assessment details with portal/NVD links.'
}
Write-Output "PASS: eight tabs including Windows Health; compact layouts and title-only headers; storage query fidelity; readiness defaults; Advisor and Updates scope, selection, and patch guards."
