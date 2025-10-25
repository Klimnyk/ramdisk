$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path (Split-Path -Parent $scriptPath) "config\ramdisk-config.json"

if (-not (Test-Path $configPath)) {
    Write-Error "Configuration file not found: $configPath"
    exit 1
}

$config = Get-Content $configPath -Raw | ConvertFrom-Json

$ramDiskDrive = $config.ramdiskDrive.TrimEnd(':')
$backupPath = $config.backupPath

Write-Host "`n=== RAMDisk Status ===" -ForegroundColor Cyan
Write-Host ""

$ramDiskExists = $false
$drive = Get-PSDrive -Name $ramDiskDrive -ErrorAction SilentlyContinue

if ($drive) {
    $ramDiskExists = $true
    Write-Host "  Status: " -NoNewline
    Write-Host "MOUNTED" -ForegroundColor Green
    Write-Host "  Drive: ${ramDiskDrive}:"
    Write-Host "  Size: $([math]::Round($drive.Used/1GB + $drive.Free/1GB, 2)) GB"
    Write-Host "  Used: $([math]::Round($drive.Used/1GB, 2)) GB ($([math]::Round(($drive.Used/($drive.Used+$drive.Free))*100, 1))%)"
    Write-Host "  Free: $([math]::Round($drive.Free/1GB, 2)) GB"
} else {
    Write-Host "  Status: " -NoNewline
    Write-Host "NOT MOUNTED" -ForegroundColor Red
}

Write-Host ""
Write-Host "=== Backup Information ===" -ForegroundColor Cyan
Write-Host ""

if (Test-Path $backupPath) {
    $currentBackup = Join-Path $backupPath "current"
    
    if (Test-Path $currentBackup) {
        $size = (Get-ChildItem $currentBackup -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $files = (Get-ChildItem $currentBackup -Recurse -File -ErrorAction SilentlyContinue).Count
        
        Write-Host "  Current backup: $([math]::Round($size/1GB, 2)) GB ($files files)"
    } else {
        Write-Host "  Current backup: Not found" -ForegroundColor Yellow
    }
    
    $backups = Get-ChildItem $backupPath -Filter "backup_*" -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    
    if ($backups) {
        Write-Host "  Backup copies: $($backups.Count)"
        Write-Host ""
        Write-Host "  Recent backups:"
        foreach ($backup in ($backups | Select-Object -First 5)) {
            $date = $backup.Name -replace 'backup_', ''
            $size = (Get-ChildItem $backup.FullName -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            Write-Host "    - $date ($([math]::Round($size/1GB, 2)) GB)"
        }
    } else {
        Write-Host "  Backup copies: None"
    }
} else {
    Write-Host "  Backup directory not found" -ForegroundColor Red
}

Write-Host ""
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
