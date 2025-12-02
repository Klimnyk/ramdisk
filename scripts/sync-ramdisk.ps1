[CmdletBinding()]
param(
    [switch]$Final,
    [switch]$CreateBackup,
    [switch]$Sequential  # Force sequential sync instead of parallel
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

# Multi-backup settings
$multiBackupEnabled = $false
$parallelSync = $false
$backupDestinations = @()

if ($config.PSObject.Properties.Name -contains 'multiBackup') {
    $multiBackupEnabled = $config.multiBackup.enabled
    $parallelSync = $config.multiBackup.parallelSync -and (-not $Sequential)
    
    if ($multiBackupEnabled -and $config.multiBackup.destinations) {
        $backupDestinations = $config.multiBackup.destinations | Where-Object { $_.enabled } | Sort-Object priority
    }
}

# Fallback to single backup path if multi-backup not configured
if ($backupDestinations.Count -eq 0) {
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

$logFile = Join-Path $logPath "sync_$(Get-Date -Format 'yyyyMMdd').log"

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
    
    Add-Content -Path $logFile -Value $logMessage -ErrorAction SilentlyContinue
}

function Test-RamDiskExists {
    param([string]$DriveLetter)
    $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue
    return $null -ne ($drives | Where-Object { $_.Name -eq $DriveLetter })
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

function Invoke-FastRobocopy {
    param(
        [string]$Source,
        [string]$Target,
        [string]$DestinationName,
        [int]$KeepCopies = 1,
        [switch]$CreateVersionBackup
    )
    
    $result = @{
        Success = $false
        ExitCode = -1
        Duration = 0
        TargetSize = 0
        Error = $null
    }
    
    $startTime = Get-Date
    
    try {
        # Ensure target directory exists
        if (-not (Test-Path $Target)) {
            New-Item -ItemType Directory -Path $Target -Force | Out-Null
        }
        
        # Create version backup if requested
        if ($CreateVersionBackup) {
            $backupDir = Join-Path (Split-Path $Target -Parent) "backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            
            if (Test-Path $Target) {
                try {
                    Copy-Item -Path $Target -Destination $backupDir -Recurse -Force -ErrorAction Stop
                    Write-Log "[$DestinationName] Version backup created: $backupDir" "INFO"
                    
                    # Cleanup old backups - use per-destination keepBackupCopies
                    $backupRoot = Split-Path $Target -Parent
                    $backups = Get-ChildItem $backupRoot -Filter "backup_*" -Directory | Sort-Object Name -Descending
                    
                    if ($backups.Count -gt $KeepCopies) {
                        $toDelete = $backups | Select-Object -Skip $KeepCopies
                        
                        foreach ($old in $toDelete) {
                            try {
                                Remove-Item $old.FullName -Recurse -Force -ErrorAction Stop
                                Write-Log "[$DestinationName] Removed old backup: $($old.Name)" "INFO"
                            } catch {
                                Write-Log "[$DestinationName] Failed to remove old backup: $($_.Exception.Message)" "WARN"
                            }
                        }
                    }
                } catch {
                    Write-Log "[$DestinationName] Failed to create version backup: $($_.Exception.Message)" "WARN"
                }
            }
        }
        
        # Build Robocopy arguments - optimized for speed
        $robocopyArgs = @(
            $Source,
            $Target,
            "/MIR",           # Mirror mode - sync deletions too
            "/COPY:DAT",      # Copy Data, Attributes, Timestamps
            "/DCOPY:DAT",     # Copy directory timestamps
            "/R:2",           # 2 retries (fast fail)
            "/W:3",           # 3 second wait between retries
            "/MT:32",         # 32 threads for maximum speed
            "/XA:SH",         # Exclude system and hidden
            "/NFL",           # No file list
            "/NDL",           # No directory list
            "/NP",            # No progress
            "/BYTES",         # Show bytes
            "/J"              # Unbuffered I/O (faster for large files)
        )
        
        # Add exclusions from config
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
        
        # Run Robocopy
        $robocopyProcess = Start-Process -FilePath "robocopy" -ArgumentList $robocopyArgs -Wait -NoNewWindow -PassThru
        
        $result.ExitCode = $robocopyProcess.ExitCode
        $result.Duration = ((Get-Date) - $startTime).TotalSeconds
        $result.TargetSize = Get-DirectorySize -Path $Target
        
        if ($result.ExitCode -ge 8) {
            $result.Error = "Robocopy failed with exit code $($result.ExitCode)"
        } else {
            $result.Success = $true
        }
        
    } catch {
        $result.Error = $_.Exception.Message
        $result.Duration = ((Get-Date) - $startTime).TotalSeconds
    }
    
    return $result
}

# ============= MAIN SCRIPT =============

$syncType = if ($Final) { "FINAL" } else { "INCREMENTAL" }
$syncMode = if ($parallelSync -and $backupDestinations.Count -gt 1) { "PARALLEL" } else { "SEQUENTIAL" }

Write-Log "=== Starting $syncType sync ($syncMode mode) ===" "INFO"
Write-Log "Destinations: $($backupDestinations.Count)" "INFO"

if (-not (Test-RamDiskExists -DriveLetter $ramDiskDrive)) {
    Write-Log "RAMDisk ${ramDiskDrive}: not found" "ERROR"
    exit 1
}

$sourceDir = "${ramDiskDrive}:\"
$sourceSize = Get-DirectorySize -Path $sourceDir
Write-Log "Source: $sourceDir ($([math]::Round($sourceSize/1GB, 2)) GB)" "INFO"

$overallStartTime = Get-Date
$results = @{}

# ============= PARALLEL SYNC (using background processes) =============
if ($parallelSync -and $backupDestinations.Count -gt 1) {
    Write-Log "Starting parallel backup to $($backupDestinations.Count) destinations..." "INFO"
    
    $processes = @()
    
    foreach ($dest in $backupDestinations) {
        $targetDir = Join-Path $dest.path "current"
        
        # Verify destination drive exists
        $destDrive = Split-Path $dest.path -Qualifier
        if (-not (Test-Path $destDrive)) {
            Write-Log "[$($dest.name)] Drive not available: $destDrive" "ERROR"
            $results[$dest.name] = @{
                Success = $false
                Error = "Drive not available"
                Duration = 0
            }
            continue
        }
        
        # Ensure destination directory exists
        if (-not (Test-Path $dest.path)) {
            New-Item -ItemType Directory -Path $dest.path -Force | Out-Null
        }
        if (-not (Test-Path $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }
        
        Write-Log "[$($dest.name)] Starting -> $targetDir" "INFO"
        
        # Build robocopy arguments
        $robocopyArgs = @($sourceDir, $targetDir, "/MIR", "/COPY:DAT", "/DCOPY:DAT", "/R:2", "/W:3", "/MT:16", "/XA:SH", "/NFL", "/NDL", "/NP", "/BYTES")
        
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
        
        # Start robocopy process (non-blocking)
        $proc = Start-Process -FilePath "robocopy" -ArgumentList $robocopyArgs -NoNewWindow -PassThru
        
        $processes += @{
            Process = $proc
            Name = $dest.name
            Path = $targetDir
            StartTime = Get-Date
            DestConfig = $dest
        }
    }
    
    # Wait for all processes with timeout
    $timeout = if ($config.multiBackup.syncTimeoutSeconds) { $config.multiBackup.syncTimeoutSeconds } else { 300 }
    
    Write-Log "Waiting for $($processes.Count) processes (timeout: ${timeout}s)..." "INFO"
    
    foreach ($procInfo in $processes) {
        $remainingTime = $timeout - ((Get-Date) - $procInfo.StartTime).TotalSeconds
        if ($remainingTime -lt 1) { $remainingTime = 1 }
        
        $completed = $procInfo.Process.WaitForExit([int]($remainingTime * 1000))
        $duration = ((Get-Date) - $procInfo.StartTime).TotalSeconds
        
        if ($completed) {
            $exitCode = $procInfo.Process.ExitCode
            $success = $exitCode -lt 8
            
            $results[$procInfo.Name] = @{
                Success = $success
                ExitCode = $exitCode
                Duration = $duration
                Error = $null
            }
            
            if ($success) {
                Write-Log "[$($procInfo.Name)] Completed in $([math]::Round($duration, 2))s (Exit: $exitCode)" "SUCCESS"
            } else {
                Write-Log "[$($procInfo.Name)] Failed with exit code: $exitCode" "ERROR"
            }
            
            # Create version backup if requested (after successful sync)
            if ($success -and ($CreateBackup -or $Final)) {
                $destKeepCopies = if ($procInfo.DestConfig.PSObject.Properties.Name -contains 'keepBackupCopies') { 
                    $procInfo.DestConfig.keepBackupCopies 
                } else { 
                    $keepBackupCopies 
                }
                
                $backupDir = Join-Path (Split-Path $procInfo.Path -Parent) "backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                if (Test-Path $procInfo.Path) {
                    # Use robocopy for fast backup copy
                    $backupArgs = @($procInfo.Path, $backupDir, "/MIR", "/MT:16", "/NFL", "/NDL", "/NP", "/R:1", "/W:1")
                    $backupProc = Start-Process -FilePath "robocopy" -ArgumentList $backupArgs -Wait -NoNewWindow -PassThru
                    if ($backupProc.ExitCode -lt 8) {
                        Write-Log "[$($procInfo.Name)] Timestamped backup created" "INFO"
                    }
                    
                    # Cleanup old backups
                    $backupRoot = Split-Path $procInfo.Path -Parent
                    $backups = Get-ChildItem $backupRoot -Filter "backup_*" -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
                    
                    if ($backups.Count -gt $destKeepCopies) {
                        $toDelete = $backups | Select-Object -Skip $destKeepCopies
                        foreach ($old in $toDelete) {
                            Remove-Item $old.FullName -Recurse -Force -ErrorAction SilentlyContinue
                            Write-Log "[$($procInfo.Name)] Removed old backup: $($old.Name)" "INFO"
                        }
                    }
                }
            }
        } else {
            Write-Log "[$($procInfo.Name)] Timeout after ${timeout}s" "ERROR"
            $results[$procInfo.Name] = @{ Success = $false; Error = "Timeout"; Duration = $timeout }
            
            try {
                $procInfo.Process.Kill()
            } catch { }
        }
    }
    
} else {
    # ============= SEQUENTIAL SYNC =============
    Write-Log "Running sequential backup..." "INFO"
    
    foreach ($dest in $backupDestinations) {
        $targetDir = Join-Path $dest.path "current"
        
        # Verify destination drive exists
        $destDrive = Split-Path $dest.path -Qualifier
        if (-not (Test-Path $destDrive)) {
            Write-Log "[$($dest.name)] Drive not available: $destDrive" "ERROR"
            $results[$dest.name] = @{
                Success = $false
                Error = "Drive not available"
                Duration = 0
            }
            continue
        }
        
        Write-Log "[$($dest.name)] Starting sync -> $targetDir" "INFO"
        
        # Get per-destination keepBackupCopies or use global default
        $destKeepCopies = if ($dest.PSObject.Properties.Name -contains 'keepBackupCopies') { 
            $dest.keepBackupCopies 
        } else { 
            $keepBackupCopies 
        }
        
        $syncResult = Invoke-FastRobocopy `
            -Source $sourceDir `
            -Target $targetDir `
            -DestinationName $dest.name `
            -KeepCopies $destKeepCopies `
            -CreateVersionBackup:($CreateBackup -or $Final)
        
        $results[$dest.name] = $syncResult
        
        if ($syncResult.Success) {
            Write-Log "[$($dest.name)] Completed in $([math]::Round($syncResult.Duration, 2))s" "SUCCESS"
        } else {
            Write-Log "[$($dest.name)] Failed: $($syncResult.Error)" "ERROR"
        }
    }
}

# ============= SUMMARY =============

$overallDuration = ((Get-Date) - $overallStartTime).TotalSeconds
$successCount = ($results.Values | Where-Object { $_.Success }).Count

Write-Log "=== Sync Statistics ===" "INFO"
Write-Log "Total duration: $([math]::Round($overallDuration, 2)) seconds" "INFO"
Write-Log "Source size: $([math]::Round($sourceSize/1GB, 2)) GB" "INFO"
Write-Log "Destinations: $successCount/$($results.Count) successful" "INFO"

foreach ($destName in $results.Keys) {
    $r = $results[$destName]
    $status = if ($r.Success) { "OK" } else { "FAIL" }
    $duration = [math]::Round($r.Duration, 2)
    Write-Log "  - $destName`: $status ($duration`s)" "INFO"
}

if ($overallDuration -gt 0 -and $successCount -gt 0) {
    $speed = $sourceSize / $overallDuration / 1MB
    Write-Log "Effective speed: $([math]::Round($speed, 2)) MB/s" "INFO"
}

# Log rotation
try {
    $maxLogSize = $config.logging.maxLogSizeMB * 1MB
    $keepLogDays = $config.logging.keepLogDays
    
    $oldLogs = Get-ChildItem $logPath -Filter "*.log" | Where-Object { 
        $_.LastWriteTime -lt (Get-Date).AddDays(-$keepLogDays) 
    }
    
    foreach ($oldLog in $oldLogs) {
        try {
            Remove-Item $oldLog.FullName -Force
        } catch {}
    }
    
    if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt $maxLogSize) {
        $archiveName = $logFile -replace '\.log$', "_$(Get-Date -Format 'HHmmss').log"
        Move-Item $logFile $archiveName -Force
    }
    
} catch {
    Write-Log "Log rotation error: $($_.Exception.Message)" "WARN"
}

Write-Log "=== Sync completed ===" "INFO"

# Exit with error if all syncs failed
if ($successCount -eq 0) {
    exit 1
}

exit 0
