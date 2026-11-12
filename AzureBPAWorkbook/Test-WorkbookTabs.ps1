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
if (-not $header.Contains('properties.migration.assessment') -or
    -not $header.Contains('Unified inventory and BPA runs do not establish migration readiness') -or
    -not $header.Contains('SSMS 22+') -or -not $header.Contains('not ingested by this workbook')) {
    throw 'Migration header must identify the actual readiness source and native SQL VM assessment limitation.'
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
function Get-WorkbookItems($items) {
    foreach ($item in $items) {
        $item
        if ($item.type -eq 12) { Get-WorkbookItems $item.content.items }
    }
}
$windows = @($latest.items | Where-Object { $_.name -eq 'group - Windows Health' })[0]
$windowsItems = @(Get-WorkbookItems $windows.content.items)
$windowsHeading = @($windowsItems | Where-Object { $_.name -eq 'text - windows-header' })[0]
if ($windowsHeading.content.json -cne '# Windows Health') { throw 'Windows header must contain only its title.' }
$windowsParameters = @($windowsItems | Where-Object { $_.type -eq 9 } | ForEach-Object { $_.content.parameters })
foreach ($initial in @{ WinSection = 'machines'; WinDetailTab = 'updates'; WinSoftwareTab = 'defender'; WinMachineId = 'All' }.GetEnumerator()) {
    $parameter = @($windowsParameters | Where-Object { $_.name -eq $initial.Key })
    if ($parameter.Count -ne 1 -or $parameter[0].value -cne $initial.Value) {
        throw "Windows parameter $($initial.Key) must be initialized to '$($initial.Value)' before queries execute."
    }
}
$windowsGrid = @($windowsItems | Where-Object { $_.name -eq 'win-machines-grid' })[0].content
$windowsSelection = @($windowsGrid.exportedParameters | Where-Object { $_.parameterName -eq 'WinMachineId' })
if ($windowsSelection.Count -ne 1 -or $windowsSelection[0].fieldName -ne 'MachineId' -or $windowsSelection[0].defaultValue -ne 'All') {
    throw 'Windows machine rows must export the full resource ID and default to All.'
}
$windowsReset = @($windowsItems | Where-Object { $_.name -eq 'win-detail-reset' })[0].content.links[0]
if ($windowsReset.cellValue -ne 'WinMachineId' -or $windowsReset.subTarget -ne 'All') {
    throw 'Windows tab must provide a reset to all machines.'
}
$windowsQueries = @($windowsItems | Where-Object { $_.type -eq 3 })
foreach ($query in $windowsQueries) {
    $kql = $query.content.query
    if ($query.content.queryType -eq 1) {
        if ($query.content.crossComponentResources[0] -ne '{Subscription}') {
            throw "Windows query $($query.name) must use Resource Graph scoped to selected subscriptions."
        }
        if ($query.name -notlike 'win-detail-*' -and
            (-not $kql.Contains("properties.osType =~ 'windows'") -or -not $kql.Contains("'*' in ({ResourceGroup})") -or
             -not $kql.Contains('resourceGroup in~ ({ResourceGroup})'))) {
            throw "Windows query $($query.name) must be limited to Windows Arc machines in the selected resource groups."
        }
        if ([regex]::Matches($kql, '\bpatchassessmentresources\b').Count -gt 1 -or
            [regex]::Matches($kql, '\bjoin\b').Count -gt 3 -or [regex]::Matches($kql, 'mv-expand').Count -gt 3) {
            throw "Windows query $($query.name) exceeds Resource Graph join/mv-expand limits or repeats the remote assessment table."
        }
    } elseif ($query.content.crossComponentResources[0] -ne '{WinWorkspace}') {
        throw "Windows Log Analytics query $($query.name) must use the Change Tracking workspace selector."
    }
}
foreach ($name in @('win-detail-updates-grid', 'win-upd-catalogue', 'win-upd-details')) {
    $kql = @($windowsQueries | Where-Object { $_.name -eq $name })[0].content.query
    foreach ($required in @('patchassessmentresources', 'PatchAssessmentId == AssessmentId', 'PatchUpdatedAt >= AssessmentStartedAt',
        'PatchUpdatedAt <= AssessmentTime', "AssessmentStatus =~ 'Succeeded'", 'PatchDetailsTruncated', 'mv-expand PatchRow = PatchRows limit 2000',
        '| where PatchValid')) {
        if (-not $kql.Contains($required)) { throw "Windows patch query $name lacks $required" }
    }
}
if (-not @($windowsQueries | Where-Object { $_.name -eq 'win-detail-updates-grid' })[0].content.query.Contains("MachineId == '{WinMachineId}'")) {
    throw 'Windows machine patch details must be restricted to the selected machine.'
}
Write-Output "PASS: eight tabs; compact layouts and title-only headers; storage query fidelity; readiness defaults; Advisor and Updates scope, selection, and patch guards; Windows Health scope, selection, and patch guards."
