$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path (Split-Path -Parent $scriptPath) "config\ramdisk-config.json"

if (-not (Test-Path $configPath)) {
    Write-Error "Configuration file not found: $configPath"
    exit 1
}

$config = Get-Content $configPath -Raw | ConvertFrom-Json

$ramDiskDrive = $config.ramdiskDrive.TrimEnd(':')
$backupPath = $config.backupPath

# Get backup destinations
$backupDestinations = @()
if ($config.PSObject.Properties.Name -contains 'multiBackup' -and $config.multiBackup.enabled) {
    $backupDestinations = $config.multiBackup.destinations | Where-Object { $_.enabled }
} else {
    $backupDestinations = @([PSCustomObject]@{
        name = "Primary"
        path = $backupPath
        enabled = $true
    })
}

Write-Host "`n=== RAMDisk Status ===" -ForegroundColor Cyan
Write-Host ""

$ramDiskExists = $false
$drive = Get-PSDrive -Name $ramDiskDrive -ErrorAction SilentlyContinue

if ($drive) {
    $ramDiskExists = $true
    $totalSize = $drive.Used + $drive.Free
    $usedPercent = if ($totalSize -gt 0) { [math]::Round(($drive.Used/$totalSize)*100, 1) } else { 0 }
    
    Write-Host "  Status: " -NoNewline
    Write-Host "MOUNTED" -ForegroundColor Green
    Write-Host "  Drive: ${ramDiskDrive}:"
    Write-Host "  Size: $([math]::Round($totalSize/1GB, 2)) GB"
    Write-Host "  Used: $([math]::Round($drive.Used/1GB, 2)) GB ($usedPercent%)"
    Write-Host "  Free: $([math]::Round($drive.Free/1GB, 2)) GB"
} else {
    Write-Host "  Status: " -NoNewline
    Write-Host "NOT MOUNTED" -ForegroundColor Red
}

Write-Host ""
Write-Host "=== Backup Destinations ($($backupDestinations.Count)) ===" -ForegroundColor Cyan
Write-Host ""

foreach ($dest in $backupDestinations) {
    $destDrive = Split-Path $dest.path -Qualifier
    $driveAvailable = Test-Path $destDrive
    
    Write-Host "  [$($dest.name)]" -ForegroundColor Yellow
    Write-Host "    Path: $($dest.path)"
    
    if (-not $driveAvailable) {
        Write-Host "    Status: " -NoNewline
        Write-Host "DRIVE NOT AVAILABLE" -ForegroundColor Red
        continue
    }
    
    $currentBackup = Join-Path $dest.path "current"
    
    if (Test-Path $currentBackup) {
        $size = (Get-ChildItem $currentBackup -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $files = (Get-ChildItem $currentBackup -Recurse -File -ErrorAction SilentlyContinue).Count
        $lastWrite = (Get-Item $currentBackup).LastWriteTime
        $age = [math]::Round(((Get-Date) - $lastWrite).TotalMinutes, 0)
        
        Write-Host "    Current: $([math]::Round($size/1GB, 2)) GB ($files files)"
        Write-Host "    Last sync: " -NoNewline
        if ($age -lt 15) {
            Write-Host "$age min ago" -ForegroundColor Green
        } elseif ($age -lt 30) {
            Write-Host "$age min ago" -ForegroundColor Yellow
        } else {
            Write-Host "$age min ago" -ForegroundColor Red
        }
    } else {
        Write-Host "    Current backup: " -NoNewline
        Write-Host "Not found" -ForegroundColor Yellow
    }
    
    # Show backup copies
    $backups = Get-ChildItem $dest.path -Filter "backup_*" -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    
    if ($backups) {
        Write-Host "    Versions: $($backups.Count)"
    }
    Write-Host ""
}

Write-Host "=== Scheduled Tasks ===" -ForegroundColor Cyan
Write-Host ""

$tasks = @("RamDisk-Startup", "RamDisk-Shutdown", "RamDisk-Sync")

# Check if we can query tasks (requires admin for SYSTEM tasks)
$testResult = schtasks /query /TN "\RamDisk-Startup" 2>&1 | Out-String

if ($testResult -match "Access is denied") {
    Write-Host "  " -NoNewline
    Write-Host "[!]" -ForegroundColor Yellow -NoNewline
    Write-Host " Tasks require admin rights to view (created as SYSTEM)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  To verify tasks, run in admin PowerShell:" -ForegroundColor DarkGray
    Write-Host "  schtasks /query /TN \RamDisk-Startup" -ForegroundColor DarkGray
} else {
    foreach ($taskName in $tasks) {
        $result = schtasks /query /TN "\$taskName" 2>&1 | Out-String
        
        if ($result -match "Ready|Running|Disabled") {
            if ($result -match "Ready") {
                Write-Host "  $taskName`: " -NoNewline
                Write-Host "Ready" -ForegroundColor Green
            } elseif ($result -match "Running") {
                Write-Host "  $taskName`: " -NoNewline
                Write-Host "Running" -ForegroundColor Green
            } elseif ($result -match "Disabled") {
                Write-Host "  $taskName`: " -NoNewline
                Write-Host "Disabled" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  $taskName`: " -NoNewline
            Write-Host "Not registered" -ForegroundColor Red
        }
    }
}

Write-Host ""
Write-Host "=== Monitor Process ===" -ForegroundColor Cyan
Write-Host ""

$monitor = Get-Process pwsh -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*ramdisk-monitor*" }

if ($monitor) {
    if ($monitor -is [Array]) {
        # Multiple monitor processes running
        Write-Host "  Status: " -NoNewline
        Write-Host "RUNNING (Multiple instances!)" -ForegroundColor Yellow
        Write-Host "  PIDs: $($monitor.Id -join ', ')"
        Write-Host "  Total Memory: $([math]::Round(($monitor | Measure-Object WorkingSet64 -Sum).Sum/1MB, 1)) MB"
    } else {
        # Single monitor process
        Write-Host "  Status: " -NoNewline
        Write-Host "RUNNING" -ForegroundColor Green
        Write-Host "  PID: $($monitor.Id)"
        Write-Host "  Memory: $([math]::Round($monitor.WorkingSet64/1MB, 1)) MB"
    }
} else {
    Write-Host "  Status: " -NoNewline
    Write-Host "NOT RUNNING" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Sync Configuration ===" -ForegroundColor Cyan
Write-Host ""

Write-Host "  Interval: Every $($config.syncInterval) minutes"
Write-Host "  Parallel sync: " -NoNewline
if ($config.PSObject.Properties.Name -contains 'multiBackup' -and $config.multiBackup.parallelSync) {
    Write-Host "Enabled" -ForegroundColor Green
} else {
    Write-Host "Disabled" -ForegroundColor Gray
}
Write-Host "  Keep backups: $($config.keepBackupCopies) versions"

Write-Host ""
Write-Host "=== Recent Logs ===" -ForegroundColor Cyan
Write-Host ""

$logPath = $config.logging.logPath

if (Test-Path $logPath) {
    $logs = Get-ChildItem $logPath -Filter "*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 5
    
    if ($logs) {
        foreach ($log in $logs) {
            Write-Host "  - $($log.Name) ($([math]::Round($log.Length/1KB, 1)) KB)" -ForegroundColor Gray
        }
    } else {
        Write-Host "  No logs found" -ForegroundColor Yellow
    }
} else {
    Write-Host "  Log directory not found" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=======================" -ForegroundColor Cyan
Write-Host ""
