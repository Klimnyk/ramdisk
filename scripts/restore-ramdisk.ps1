[CmdletBinding()]
param(
    [switch]$UseBackup,
    [string]$BackupDate
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
    } else {
        Write-Host $logMessage
    }
    
    Add-Content -Path $logFile -Value $logMessage
}

function Test-RamDiskExists {
    param([string]$DriveLetter)
    $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue
    return ($drives | Where-Object { $_.Name -eq $DriveLetter }) -ne $null
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

Write-Log "=== Restoring data to RAMDisk ===" "INFO"

if (-not (Test-RamDiskExists -DriveLetter $ramDiskDrive)) {
    Write-Log "Drive ${ramDiskDrive}: not found. Please mount RAMDisk first" "ERROR"
    exit 1
}

$sourceDir = $null

if ($BackupDate) {
    $sourceDir = Join-Path $backupPath "backup_$BackupDate"
    
    if (-not (Test-Path $sourceDir)) {
        Write-Log "Backup not found: $sourceDir" "ERROR"
        
        $availableBackups = Get-ChildItem -Path $backupPath -Directory -Filter "backup_*" | Sort-Object Name -Descending
        
        if ($availableBackups) {
            Write-Log "Available backups:" "INFO"
            foreach ($backup in $availableBackups) {
                Write-Log "  - $($backup.Name)" "INFO"
            }
        }
        
        exit 1
    }
    
    Write-Log "Using backup: $BackupDate" "INFO"
    
} elseif ($UseBackup) {
    $backupDirs = Get-ChildItem -Path $backupPath -Directory -Filter "backup_*" | Sort-Object Name -Descending | Select-Object -First 1
    
    if (-not $backupDirs) {
        Write-Log "No backups found" "ERROR"
        exit 1
    }
    
    $sourceDir = $backupDirs.FullName
    Write-Log "Using latest backup: $($backupDirs.Name)" "INFO"
    
} else {
    $sourceDir = Join-Path $backupPath "current"
    
    if (-not (Test-Path $sourceDir)) {
        Write-Log "Backup not found: $sourceDir" "WARN"
        Write-Log "RAMDisk will remain empty" "INFO"
        exit 0
    }
    
    Write-Log "Using current backup" "INFO"
}

$targetDir = "${ramDiskDrive}:\"

Write-Log "Source: $sourceDir" "INFO"
Write-Log "Target: $targetDir" "INFO"

$sourceSize = Get-DirectorySize -Path $sourceDir
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
    $robocopyArgs = @(
        $sourceDir,
        $targetDir,
        "/E",
        "/COPY:DAT",
        "/DCOPY:DAT",
        "/R:3",
        "/W:5",
        "/MT:32",
        "/NFL",
        "/NDL",
        "/NP"
    )
    
    $robocopyProcess = Start-Process -FilePath "robocopy" -ArgumentList $robocopyArgs -Wait -NoNewWindow -PassThru
    
    $exitCode = $robocopyProcess.ExitCode
    
    if ($exitCode -ge 8) {
        Write-Log "Restore completed with errors (Exit Code: $exitCode)" "ERROR"
        exit 1
    } elseif ($exitCode -ge 4) {
        Write-Log "Some errors detected during restore (Exit Code: $exitCode)" "WARN"
    } else {
        Write-Log "Restore successful (Exit Code: $exitCode)" "INFO"
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

Write-Log "=== Restore completed ===" "INFO"

exit 0
