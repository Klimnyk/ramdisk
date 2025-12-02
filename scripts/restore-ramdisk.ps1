[CmdletBinding()]
param(
    [switch]$UseBackup,
    [string]$BackupDate,
    [string]$FromDestination  # Specify which backup destination to use (by name)
)

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path (Split-Path -Parent $scriptPath) "config\ramdisk-config.json"

if (-not (Test-Path $configPath)) {
    Write-Error "Configuration file not found: $configPath"
    exit 1
}

$config = Get-Content $configPath -Raw | ConvertFrom-Json

$ramDiskDrive = $config.ramdiskDrive.TrimEnd(':')
$backupPath = $config.backupPath
$logPath = $config.logging.logPath

# Get backup destinations
$backupDestinations = @()
if ($config.PSObject.Properties.Name -contains 'multiBackup' -and $config.multiBackup.enabled) {
    $backupDestinations = $config.multiBackup.destinations | Where-Object { $_.enabled } | Sort-Object priority
} else {
    $backupDestinations = @([PSCustomObject]@{
        name = "Primary"
        path = $backupPath
        enabled = $true
        priority = 1
    })
}

if (-not (Test-Path $logPath)) {
    New-Item -ItemType Directory -Path $logPath -Force | Out-Null
}

$logFile = Join-Path $logPath "restore_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    if ($Level -eq "ERROR") {
        Write-Host $logMessage -ForegroundColor Red
    } elseif ($Level -eq "WARN") {
        Write-Host $logMessage -ForegroundColor Yellow
    } elseif ($Level -eq "SUCCESS") {
        Write-Host $logMessage -ForegroundColor Green
    } else {
        Write-Host $logMessage
    }
    
    Add-Content -Path $logFile -Value $logMessage
}

function Test-RamDiskExists {
    param([string]$DriveLetter)
    $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue
    return ($null -ne ($drives | Where-Object { $_.Name -eq $DriveLetter }))
}

function Get-DirectorySize {
    param([string]$Path)
    
    if (-not (Test-Path $Path)) {
        return 0
    }
    
    try {
        $size = (Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue | 
                 Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        return $size
    } catch {
        return 0
    }
}

function Find-BestBackupSource {
    param(
        [array]$Destinations,
        [string]$PreferredName,
        [switch]$UseVersionBackup,
        [string]$VersionDate
    )
    
    $result = @{
        Found = $false
        Path = $null
        Name = $null
        Size = 0
        LastWrite = $null
    }
    
    # Filter destinations
    $candidates = $Destinations
    if ($PreferredName) {
        $candidates = $Destinations | Where-Object { $_.name -eq $PreferredName }
        if ($candidates.Count -eq 0) {
            Write-Log "Destination '$PreferredName' not found, trying all destinations" "WARN"
            $candidates = $Destinations
        }
    }
    
    foreach ($dest in $candidates) {
        $destDrive = Split-Path $dest.path -Qualifier
        if (-not (Test-Path $destDrive)) {
            Write-Log "[$($dest.name)] Drive not available: $destDrive" "WARN"
            continue
        }
        
        $sourcePath = $null
        
        if ($VersionDate) {
            # Look for specific version backup
            $sourcePath = Join-Path $dest.path "backup_$VersionDate"
            if (-not (Test-Path $sourcePath)) {
                Write-Log "[$($dest.name)] Backup not found: backup_$VersionDate" "WARN"
                continue
            }
        } elseif ($UseVersionBackup) {
            # Find latest version backup
            $backups = Get-ChildItem $dest.path -Filter "backup_*" -Directory -ErrorAction SilentlyContinue | 
                       Sort-Object Name -Descending | Select-Object -First 1
            if ($backups) {
                $sourcePath = $backups.FullName
            } else {
                Write-Log "[$($dest.name)] No version backups found" "WARN"
                continue
            }
        } else {
            # Use current backup
            $sourcePath = Join-Path $dest.path "current"
            if (-not (Test-Path $sourcePath)) {
                Write-Log "[$($dest.name)] Current backup not found" "WARN"
                continue
            }
        }
        
        if (Test-Path $sourcePath) {
            $size = Get-DirectorySize -Path $sourcePath
            $lastWrite = (Get-Item $sourcePath).LastWriteTime
            
            # Return first valid source (sorted by priority)
            $result.Found = $true
            $result.Path = $sourcePath
            $result.Name = $dest.name
            $result.Size = $size
            $result.LastWrite = $lastWrite
            
            return $result
        }
    }
    
    return $result
}

Write-Log "=== Restoring data to RAMDisk ===" "INFO"

if (-not (Test-RamDiskExists -DriveLetter $ramDiskDrive)) {
    Write-Log "Drive ${ramDiskDrive}: not found. Please mount RAMDisk first" "ERROR"
    exit 1
}

# Find best backup source
Write-Log "Available backup destinations:" "INFO"
foreach ($dest in $backupDestinations) {
    $destDrive = Split-Path $dest.path -Qualifier
    $available = Test-Path $destDrive
    $status = if ($available) { "Available" } else { "Not available" }
    Write-Log "  - $($dest.name): $($dest.path) [$status]" "INFO"
}

$backupSource = Find-BestBackupSource `
    -Destinations $backupDestinations `
    -PreferredName $FromDestination `
    -UseVersionBackup:$UseBackup `
    -VersionDate $BackupDate

if (-not $backupSource.Found) {
    Write-Log "No valid backup source found!" "ERROR"
    
    # Show available backups
    Write-Log "Available backups:" "INFO"
    foreach ($dest in $backupDestinations) {
        $destDrive = Split-Path $dest.path -Qualifier
        if (-not (Test-Path $destDrive)) { continue }
        
        $backups = Get-ChildItem $dest.path -Filter "backup_*" -Directory -ErrorAction SilentlyContinue | 
                   Sort-Object Name -Descending
        
        if ($backups) {
            Write-Log "[$($dest.name)]:" "INFO"
            foreach ($backup in ($backups | Select-Object -First 5)) {
                Write-Log "    - $($backup.Name)" "INFO"
            }
        }
    }
    
    exit 1
}

$sourceDir = $backupSource.Path
$targetDir = "${ramDiskDrive}:\"

Write-Log "Using backup from: $($backupSource.Name)" "SUCCESS"
Write-Log "Source: $sourceDir" "INFO"
Write-Log "Target: $targetDir" "INFO"
Write-Log "Last modified: $($backupSource.LastWrite)" "INFO"

$sourceSize = $backupSource.Size
Write-Log "Data size to restore: $([math]::Round($sourceSize/1GB, 2)) GB" "INFO"

$drive = Get-PSDrive -Name $ramDiskDrive
$freeSpace = $drive.Free

Write-Log "Free on RAMDisk: $([math]::Round($freeSpace/1GB, 2)) GB" "INFO"

if ($sourceSize -gt $freeSpace) {
    Write-Log "Not enough space on RAMDisk for restore!" "ERROR"
    Write-Log "Required: $([math]::Round($sourceSize/1GB, 2)) GB, Available: $([math]::Round($freeSpace/1GB, 2)) GB" "ERROR"
    exit 1
}

Write-Log "Starting data restore..." "INFO"

$startTime = Get-Date

try {
    # Optimized robocopy for fast restore
    $robocopyArgs = @(
        $sourceDir,
        $targetDir,
        "/E",            # Copy subdirectories including empty
        "/COPY:DAT",     # Copy Data, Attributes, Timestamps
        "/DCOPY:DAT",    # Copy directory timestamps
        "/R:3",          # 3 retries
        "/W:5",          # 5 second wait
        "/MT:32",        # 32 threads for max speed
        "/NFL",          # No file list
        "/NDL",          # No directory list
        "/NP",           # No progress
        "/J"             # Unbuffered I/O (faster)
    )
    
    $robocopyProcess = Start-Process -FilePath "robocopy" -ArgumentList $robocopyArgs -Wait -NoNewWindow -PassThru
    
    $exitCode = $robocopyProcess.ExitCode
    
    if ($exitCode -ge 8) {
        Write-Log "Restore completed with errors (Exit Code: $exitCode)" "ERROR"
        exit 1
    } elseif ($exitCode -ge 4) {
        Write-Log "Some errors detected during restore (Exit Code: $exitCode)" "WARN"
    } else {
        Write-Log "Restore successful (Exit Code: $exitCode)" "SUCCESS"
    }
    
} catch {
    Write-Log "Restore error: $($_.Exception.Message)" "ERROR"
    exit 1
}

$endTime = Get-Date
$duration = $endTime - $startTime

$targetSize = Get-DirectorySize -Path $targetDir

Write-Log "=== Restore Statistics ===" "INFO"
Write-Log "Duration: $($duration.TotalSeconds.ToString('F2')) seconds" "INFO"
Write-Log "Data restored: $([math]::Round($targetSize/1GB, 2)) GB" "INFO"

if ($duration.TotalSeconds -gt 0) {
    $speed = $targetSize / $duration.TotalSeconds / 1MB
    Write-Log "Average speed: $([math]::Round($speed, 2)) MB/s" "INFO"
}

$driveInfo = Get-PSDrive -Name $ramDiskDrive
Write-Log "Used: $([math]::Round($driveInfo.Used/1GB, 2)) GB" "INFO"
Write-Log "Free: $([math]::Round($driveInfo.Free/1GB, 2)) GB" "INFO"

Write-Log "=== Restore completed ===" "SUCCESS"

exit 0
