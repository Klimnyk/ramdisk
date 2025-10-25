[CmdletBinding()]
param(
    [switch]$Final,
    [switch]$CreateBackup
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
$keepBackupCopies = $config.keepBackupCopies

if (-not (Test-Path $logPath)) {
    New-Item -ItemType Directory -Path $logPath -Force | Out-Null
}

$logFile = Join-Path $logPath "sync_$(Get-Date -Format 'yyyyMMdd').log"

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
    
    Add-Content -Path $logFile -Value $logMessage -ErrorAction SilentlyContinue
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

$syncType = if ($Final) { "FINAL" } else { "INCREMENTAL" }
Write-Log "=== Starting $syncType sync ===" "INFO"

if (-not (Test-RamDiskExists -DriveLetter $ramDiskDrive)) {
    Write-Log "RAMDisk ${ramDiskDrive}: not found" "ERROR"
    exit 1
}

$sourceDir = "${ramDiskDrive}:\"
$targetDir = Join-Path $backupPath "current"

if (-not (Test-Path $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    Write-Log "Created backup directory: $targetDir" "INFO"
}

if ($CreateBackup -or $Final) {
    $backupDir = Join-Path $backupPath "backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    
    if (Test-Path $targetDir) {
        Write-Log "Creating backup copy: $backupDir" "INFO"
        
        try {
            Copy-Item -Path $targetDir -Destination $backupDir -Recurse -Force -ErrorAction Stop
            Write-Log "Backup copy created successfully" "INFO"
        } catch {
            Write-Log "Failed to create backup copy: $($_.Exception.Message)" "WARN"
        }
        
        $backups = Get-ChildItem $backupPath -Filter "backup_*" -Directory | Sort-Object Name -Descending
        
        if ($backups.Count -gt $keepBackupCopies) {
            $toDelete = $backups | Select-Object -Skip $keepBackupCopies
            
            foreach ($old in $toDelete) {
                try {
                    Remove-Item $old.FullName -Recurse -Force -ErrorAction Stop
                    Write-Log "Removed old backup: $($old.Name)" "INFO"
                } catch {
                    Write-Log "Failed to remove old backup $($old.Name): $($_.Exception.Message)" "WARN"
                }
            }
        }
    }
}

Write-Log "Source: $sourceDir" "INFO"
Write-Log "Target: $targetDir" "INFO"

$sourceSize = Get-DirectorySize -Path $sourceDir
Write-Log "Source size: $([math]::Round($sourceSize/1GB, 2)) GB" "INFO"

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
        "/XA:SH",
        "/NFL",
        "/NDL",
        "/NP",
        "/BYTES"
    )
    
    if ($config.sync.excludeDirs) {
        foreach ($dir in $config.sync.excludeDirs) {
            $robocopyArgs += "/XD"
            $robocopyArgs += $dir
        }
    }
    
    if ($config.sync.excludeFiles) {
        foreach ($file in $config.sync.excludeFiles) {
            $robocopyArgs += "/XF"
            $robocopyArgs += $file
        }
    }
    
    Write-Log "Starting Robocopy..." "INFO"
    
    $robocopyProcess = Start-Process -FilePath "robocopy" -ArgumentList $robocopyArgs -Wait -NoNewWindow -PassThru
    
    $exitCode = $robocopyProcess.ExitCode
    
    if ($exitCode -ge 8) {
        Write-Log "Sync completed with errors (Exit Code: $exitCode)" "ERROR"
        exit 1
    } elseif ($exitCode -ge 4) {
        Write-Log "Some errors detected during sync (Exit Code: $exitCode)" "WARN"
    } elseif ($exitCode -ge 1) {
        Write-Log "Sync successful with changes (Exit Code: $exitCode)" "INFO"
    } else {
        Write-Log "Sync successful, no changes (Exit Code: $exitCode)" "INFO"
    }
    
} catch {
    Write-Log "Sync error: $($_.Exception.Message)" "ERROR"
    exit 1
}

$endTime = Get-Date
$duration = $endTime - $startTime

$targetSize = Get-DirectorySize -Path $targetDir

Write-Log "=== Sync Statistics ===" "INFO"
Write-Log "Duration: $($duration.TotalSeconds.ToString('F2')) seconds" "INFO"
Write-Log "Backup size: $([math]::Round($targetSize/1GB, 2)) GB" "INFO"

if ($duration.TotalSeconds -gt 0) {
    $speed = $sourceSize / $duration.TotalSeconds / 1MB
    Write-Log "Average speed: $([math]::Round($speed, 2)) MB/s" "INFO"
}

try {
    $maxLogSize = $config.logging.maxLogSizeMB * 1MB
    $keepLogDays = $config.logging.keepLogDays
    
    $oldLogs = Get-ChildItem $logPath -Filter "*.log" | Where-Object { 
        $_.LastWriteTime -lt (Get-Date).AddDays(-$keepLogDays) 
    }
    
    foreach ($oldLog in $oldLogs) {
        try {
            Remove-Item $oldLog.FullName -Force
            Write-Log "Removed old log: $($oldLog.Name)" "INFO"
        } catch {
            Write-Log "Failed to remove old log: $($oldLog.Name)" "WARN"
        }
    }
    
    if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt $maxLogSize) {
        $archiveName = $logFile -replace '\.log$', "_$(Get-Date -Format 'HHmmss').log"
        Move-Item $logFile $archiveName -Force
        Write-Log "Log rotated to: $archiveName" "INFO"
    }
    
} catch {
    Write-Log "Log rotation error: $($_.Exception.Message)" "WARN"
}

Write-Log "=== Sync completed ===" "INFO"

exit 0
