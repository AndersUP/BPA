<#
.SYNOPSIS
    Configures SQL Server with sample databases and intentional misconfigurations.
    Runs inside a Hyper-V VM via PowerShell Direct.

.PARAMETER Databases
    Comma-separated list: adventureworks, worldwideimporters, misconfigdemo

.PARAMETER Misconfigs
    Comma-separated flags: maxdop_zero, maxmem_default, ctp_default, no_adhoc_opt,
    tempdb_one_file, auto_close, auto_shrink, page_verify_none, recovery_simple,
    filegrowth_pct, data_log_same_vol, baseline
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Databases,
    [Parameter(Mandatory)] [string] $Misconfigs
)

$ErrorActionPreference = 'Stop'
$logFile = "C:\configure-sql-log.txt"

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts - $Message" | Tee-Object -FilePath $logFile -Append
}

$dataPath  = "C:\SQLData"
$logPath   = "C:\SQLLog"
$tempPath  = "C:\SQLTempDB"
$backupDir = "C:\SQLBackups"

$misconfigList = $Misconfigs -split ','
$databaseList  = $Databases -split ','

if ($misconfigList -contains 'data_log_same_vol') { $logPath = $dataPath -replace 'SQLData','SQLLog' }

foreach ($dir in @($dataPath, $logPath, $tempPath, $backupDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

Write-Log "Paths: Data=$dataPath, Log=$logPath, TempDB=$tempPath"

# ---------------------------------------------------------------------------
# Ensure SqlServer module is available
# ---------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Write-Log "Installing SqlServer module..."
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue
    Install-Module -Name SqlServer -Force -AllowClobber -Scope AllUsers
}
Import-Module SqlServer -Force

$sqlInstance = "localhost"

# ---------------------------------------------------------------------------
# Detect SQL Server version for correct backup selection
# ---------------------------------------------------------------------------
$versionInfo = Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "SELECT SERVERPROPERTY('ProductMajorVersion') AS MajorVersion" -TrustServerCertificate
$sqlMajorVersion = [int]$versionInfo.MajorVersion
Write-Log "SQL Server major version: $sqlMajorVersion"

# ---------------------------------------------------------------------------
# Download sample database backups
# ---------------------------------------------------------------------------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$downloads = @{}

if ($databaseList -contains 'adventureworks') {
    if ($sqlMajorVersion -ge 16) {
        $downloads['AdventureWorks'] = @{
            Url     = 'https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2022.bak'
            BakFile = "$backupDir\AdventureWorks2022.bak"
            DbName  = 'AdventureWorks2022'
        }
    } else {
        $downloads['AdventureWorks'] = @{
            Url     = 'https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2019.bak'
            BakFile = "$backupDir\AdventureWorks2019.bak"
            DbName  = 'AdventureWorks2019'
        }
    }
}

if ($databaseList -contains 'worldwideimporters') {
    $downloads['WideWorldImporters'] = @{
        Url     = 'https://github.com/Microsoft/sql-server-samples/releases/download/wide-world-importers-v1.0/WideWorldImporters-Full.bak'
        BakFile = "$backupDir\WideWorldImporters-Full.bak"
        DbName  = 'WideWorldImporters'
    }
}

foreach ($key in $downloads.Keys) {
    $dl = $downloads[$key]
    if (-not (Test-Path $dl.BakFile)) {
        Write-Log "Downloading $key..."
        $partialFile = "$($dl.BakFile).partial"
        Invoke-WebRequest -Uri $dl.Url -OutFile $partialFile -UseBasicParsing
        Move-Item -LiteralPath $partialFile -Destination $dl.BakFile -Force
        Write-Log "Downloaded $key."
    } else {
        Write-Log "$key already downloaded."
    }
}

# ---------------------------------------------------------------------------
# Restore databases
# ---------------------------------------------------------------------------
foreach ($key in $downloads.Keys) {
    $dl = $downloads[$key]
    $dbName = $dl.DbName

    $dbCheck = Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "SELECT DB_ID('$dbName') AS DbId" -TrustServerCertificate
    if ($null -ne $dbCheck.DbId -and $dbCheck.DbId -ne [DBNull]::Value) {
        Write-Log "$dbName already exists, skipping."
        continue
    }

    Write-Log "Restoring $dbName..."
    $fileList = Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "RESTORE FILELISTONLY FROM DISK = '$($dl.BakFile)'" -TrustServerCertificate

    $moves = @()
    foreach ($f in $fileList) {
        if ($f.Type -eq 'D') {
            $ext = if ($f.FileId -eq 1) { '.mdf' } else { '.ndf' }
            $dest = Join-Path $dataPath "$($f.LogicalName)$ext"
        }
        elseif ($f.Type -eq 'L') {
            $dest = Join-Path $logPath "$($f.LogicalName).ldf"
        }
        elseif ($f.Type -eq 'S') {
            $dest = Join-Path $dataPath $f.LogicalName
        }
        else {
            $dest = Join-Path $dataPath $f.LogicalName
        }
        $moves += "MOVE '$($f.LogicalName)' TO '$dest'"
    }

    $restoreQ = @"
RESTORE DATABASE [$dbName]
FROM DISK = '$($dl.BakFile)'
WITH $($moves -join ",`n"), REPLACE, RECOVERY
"@
    Invoke-Sqlcmd -ServerInstance $sqlInstance -Query $restoreQ -QueryTimeout 600 -TrustServerCertificate
    Write-Log "Restored $dbName."
}

# ---------------------------------------------------------------------------
# Create MisconfigDemo database
# ---------------------------------------------------------------------------
if ($databaseList -contains 'misconfigdemo') {
    $dbCheck = Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "SELECT DB_ID('MisconfigDemo') AS DbId" -TrustServerCertificate
    if ($null -eq $dbCheck.DbId -or $dbCheck.DbId -eq [DBNull]::Value) {
        Write-Log "Creating MisconfigDemo..."

        $mdf = Join-Path $dataPath "MisconfigDemo.mdf"
        $ldf = Join-Path $dataPath "MisconfigDemo_log.ldf"

        Invoke-Sqlcmd -ServerInstance $sqlInstance -TrustServerCertificate -Query @"
CREATE DATABASE [MisconfigDemo]
ON PRIMARY (NAME = N'MisconfigDemo', FILENAME = N'$mdf', SIZE = 8MB, FILEGROWTH = 10%)
LOG ON (NAME = N'MisconfigDemo_log', FILENAME = N'$ldf', SIZE = 8MB, FILEGROWTH = 10%);
"@
    } else {
        Write-Log "MisconfigDemo already exists; checking sample schema."
    }
        Invoke-Sqlcmd -ServerInstance $sqlInstance -TrustServerCertificate -QueryTimeout 120 -Query @"
USE [MisconfigDemo];
SET XACT_ABORT ON;
BEGIN TRANSACTION;

IF OBJECT_ID(N'dbo.Customers', N'U') IS NULL
CREATE TABLE dbo.Customers (
    CustomerID INT IDENTITY(1,1) PRIMARY KEY,
    FirstName NVARCHAR(50), LastName NVARCHAR(50),
    Email NVARCHAR(100), CreatedDate DATETIME DEFAULT GETDATE()
);
IF OBJECT_ID(N'dbo.Orders', N'U') IS NULL
CREATE TABLE dbo.Orders (
    OrderID INT IDENTITY(1,1) PRIMARY KEY,
    CustomerID INT FOREIGN KEY REFERENCES dbo.Customers(CustomerID),
    OrderDate DATETIME DEFAULT GETDATE(),
    TotalAmount DECIMAL(18,2), Status NVARCHAR(20)
);
IF OBJECT_ID(N'dbo.OrderItems', N'U') IS NULL
CREATE TABLE dbo.OrderItems (
    OrderItemID INT IDENTITY(1,1) PRIMARY KEY,
    OrderID INT FOREIGN KEY REFERENCES dbo.Orders(OrderID),
    ProductName NVARCHAR(100), Quantity INT, UnitPrice DECIMAL(18,2)
);

SET NOCOUNT ON;
DECLARE @i INT = 1;
WHILE @i <= 1000
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dbo.Customers WHERE Email = CONCAT('user', @i, '@example.com'))
    INSERT INTO dbo.Customers (FirstName, LastName, Email)
    VALUES (CONCAT('First', @i), CONCAT('Last', @i), CONCAT('user', @i, '@example.com'));
    SET @i = @i + 1;
END;

DECLARE @j INT = (SELECT COUNT(*) + 1 FROM dbo.Orders);
WHILE @j <= 5000
BEGIN
    INSERT INTO dbo.Orders (CustomerID, OrderDate, TotalAmount, Status)
    VALUES (
        ABS(CHECKSUM(NEWID())) % 1000 + 1,
        DATEADD(DAY, -ABS(CHECKSUM(NEWID())) % 365, GETDATE()),
        ROUND(RAND(CHECKSUM(NEWID())) * 500, 2),
        CASE ABS(CHECKSUM(NEWID())) % 3
            WHEN 0 THEN 'Pending' WHEN 1 THEN 'Shipped' ELSE 'Delivered'
        END
    );
    SET @j = @j + 1;
END;
COMMIT TRANSACTION;
"@
        Write-Log "MisconfigDemo created with sample data."
}

# ---------------------------------------------------------------------------
# Instance-level misconfigurations
# ---------------------------------------------------------------------------
Write-Log "Applying misconfigurations: $Misconfigs"

$adv = "EXEC sp_configure 'show advanced options', 1; RECONFIGURE;"

if ($misconfigList -contains 'maxdop_zero') {
    Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "$adv EXEC sp_configure 'max degree of parallelism', 0; RECONFIGURE;" -TrustServerCertificate
    Write-Log "MAXDOP = 0"
}

if ($misconfigList -contains 'maxmem_default') {
    Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "$adv EXEC sp_configure 'max server memory (MB)', 2147483647; RECONFIGURE;" -TrustServerCertificate
    Write-Log "Max server memory = default"
}

if ($misconfigList -contains 'ctp_default') {
    Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "$adv EXEC sp_configure 'cost threshold for parallelism', 5; RECONFIGURE;" -TrustServerCertificate
    Write-Log "Cost threshold = 5"
}

if ($misconfigList -contains 'no_adhoc_opt') {
    Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "$adv EXEC sp_configure 'optimize for ad hoc workloads', 0; RECONFIGURE;" -TrustServerCertificate
    Write-Log "Optimize for ad hoc = 0"
}

if ($misconfigList -contains 'tempdb_one_file') {
    Write-Log "TempDB: 1 file (default)"
}

# ---------------------------------------------------------------------------
# Database-level misconfigurations
# ---------------------------------------------------------------------------
$userDbs = Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "SELECT name FROM sys.databases WHERE database_id > 4" -TrustServerCertificate

foreach ($db in $userDbs) {
    $n = $db.name

    if ($misconfigList -contains 'auto_close') {
        Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "ALTER DATABASE [$n] SET AUTO_CLOSE ON;" -TrustServerCertificate
        Write-Log "AUTO_CLOSE ON: $n"
    }

    if ($misconfigList -contains 'auto_shrink') {
        Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "ALTER DATABASE [$n] SET AUTO_SHRINK ON;" -TrustServerCertificate
        Write-Log "AUTO_SHRINK ON: $n"
    }

    if ($misconfigList -contains 'page_verify_none') {
        Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "ALTER DATABASE [$n] SET PAGE_VERIFY NONE;" -TrustServerCertificate
        Write-Log "PAGE_VERIFY NONE: $n"
    }

    if ($misconfigList -contains 'recovery_simple') {
        Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "ALTER DATABASE [$n] SET RECOVERY SIMPLE;" -TrustServerCertificate
        Write-Log "RECOVERY SIMPLE: $n"
    }

    if ($misconfigList -contains 'filegrowth_pct') {
        $files = Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "SELECT name FROM [$n].sys.database_files WHERE type IN (0, 1)" -TrustServerCertificate
        foreach ($f in $files) {
            Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "ALTER DATABASE [$n] MODIFY FILE (NAME = '$($f.name)', FILEGROWTH = 10%);" -TrustServerCertificate
        }
        Write-Log "FileGrowth 10%: $n"
    }
}

# ---------------------------------------------------------------------------
# Baseline configuration (correct settings for comparison)
# ---------------------------------------------------------------------------
if ($misconfigList -contains 'baseline') {
    Write-Log "Applying baseline (correct) configuration..."

    # Proper max memory for a 4GB VM — leave 1GB for OS
    Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "$adv EXEC sp_configure 'max server memory (MB)', 3072; RECONFIGURE;" -TrustServerCertificate
    Write-Log "Max server memory = 3072 MB"

    # MAXDOP = 2 for 2-vCPU VM
    Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "EXEC sp_configure 'max degree of parallelism', 2; RECONFIGURE;" -TrustServerCertificate
    Write-Log "MAXDOP = 2"

    # Cost threshold = 50
    Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "EXEC sp_configure 'cost threshold for parallelism', 50; RECONFIGURE;" -TrustServerCertificate
    Write-Log "Cost threshold = 50"

    # Optimize for ad hoc workloads
    Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "EXEC sp_configure 'optimize for ad hoc workloads', 1; RECONFIGURE;" -TrustServerCertificate
    Write-Log "Optimize for ad hoc = 1"

    # Add tempdb file (2 vCPUs = 2 files)
    $existing = Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "SELECT COUNT(*) AS cnt FROM tempdb.sys.database_files WHERE type = 0" -TrustServerCertificate
    if ($existing.cnt -lt 2) {
        $tf = Join-Path $tempPath "tempdev2.ndf"
        Invoke-Sqlcmd -ServerInstance $sqlInstance -Query @"
ALTER DATABASE [tempdb] ADD FILE (
    NAME = N'tempdev2',
    FILENAME = N'$tf',
    SIZE = 64MB,
    FILEGROWTH = 64MB
);
"@ -TrustServerCertificate
        Write-Log "TempDB expanded to 2 files"
    } else {
        Write-Log "TempDB already has $($existing.cnt) data files"
    }

    # Fixed file growth and PAGE_VERIFY CHECKSUM on all user databases
    $baselineDbs = Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "SELECT name FROM sys.databases WHERE database_id > 4" -TrustServerCertificate
    foreach ($db in $baselineDbs) {
        $files = Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "SELECT name FROM [$($db.name)].sys.database_files WHERE type IN (0, 1)" -TrustServerCertificate
        foreach ($f in $files) {
            Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "ALTER DATABASE [$($db.name)] MODIFY FILE (NAME = '$($f.name)', FILEGROWTH = 64MB);" -TrustServerCertificate
        }
        Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "ALTER DATABASE [$($db.name)] SET PAGE_VERIFY CHECKSUM;" -TrustServerCertificate
    }
    Write-Log "Baseline database settings applied."
}

Write-Log "=== Configuration complete ==="
