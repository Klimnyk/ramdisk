#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$KeepBackup
)

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path (Split-Path -Parent $scriptPath) "config\ramdisk-config.json"

if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    $ramDiskDrive = $config.ramdiskDrive.TrimEnd(':')
    $backupPath = $config.backupPath
} else {
    $ramDiskDrive = "R"
    $backupPath = "D:\RamDisk_Backup"
}

Write-Host ""
Write-Host "RAMDisk Uninstall" -ForegroundColor Red
Write-Host "==================" -ForegroundColor Red
Write-Host ""

Write-Host "This will:" -ForegroundColor Yellow
Write-Host "  1. Stop monitor processes" -ForegroundColor White
Write-Host "  2. Unmount RAMDisk (with final sync)" -ForegroundColor White
Write-Host "  3. Remove Task Scheduler tasks" -ForegroundColor White
Write-Host "  4. Remove desktop shortcuts" -ForegroundColor White
if (-not $KeepBackup) {
    Write-Host "  5. DELETE ALL BACKUPS" -ForegroundColor Red
}
Write-Host ""

$confirmation = Read-Host "Continue? (yes/no)"
if ($confirmation -ne "yes") {
    Write-Host "Uninstall cancelled" -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "Starting uninstall..." -ForegroundColor Cyan

Write-Host "Stopping monitor process..." -ForegroundColor Yellow
try {
    $monitors = Get-Process pwsh -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*ramdisk-monitor*" }
    if ($monitors) {
        $monitors | Stop-Process -Force
        Write-Host "  Monitor stopped" -ForegroundColor Green
    } else {
        Write-Host "  No monitor running" -ForegroundColor Gray
    }
} catch {
    Write-Host "  Warning: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host "Unmounting RAMDisk..." -ForegroundColor Yellow
try {
    # Check if RAMDisk exists via ImDisk
    $imdiskList = imdisk -l 2>&1
    $hasImDisk = $imdiskList -match "\\Device\\ImDisk"
    
    if ($hasImDisk) {
        Write-Host "  Found ImDisk device, attempting to unmount..." -ForegroundColor Gray
        
        # Try final sync if drive is accessible
        $driveExists = Get-PSDrive -Name $ramDiskDrive -ErrorAction SilentlyContinue
        if ($driveExists -and (Test-Path "${ramDiskDrive}:\")) {
            $syncScript = Join-Path $scriptPath "sync-ramdisk.ps1"
            if (Test-Path $syncScript) {
                Write-Host "  Final sync..." -ForegroundColor Gray
                & $syncScript -Final -CreateBackup -ErrorAction SilentlyContinue
            }
        }
        
        # Force unmount using -D (force flag)
        Write-Host "  Forcing unmount..." -ForegroundColor Gray
        $unmountResult = imdisk -D -m "${ramDiskDrive}:" 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  RAMDisk unmounted successfully" -ForegroundColor Green
        } else {
            Write-Host "  Warning: Unmount returned code $LASTEXITCODE" -ForegroundColor Yellow
            Write-Host "  Trying alternative method..." -ForegroundColor Gray
            
            # Try to find device number and remove by unit
            $deviceInfo = imdisk -l -m "${ramDiskDrive}:" 2>&1
            if ($deviceInfo -match "Device Number:\s+(\d+)") {
                $deviceNum = $matches[1]
                Write-Host "  Removing device $deviceNum..." -ForegroundColor Gray
                imdisk -D -u $deviceNum
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  Device removed successfully" -ForegroundColor Green
                }
            }
        }
    } else {
        Write-Host "  RAMDisk not mounted" -ForegroundColor Gray
    }
} catch {
    Write-Host "  Warning: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host "Removing tasks..." -ForegroundColor Yellow
$taskNames = @("RamDisk-Startup", "RamDisk-Shutdown", "RamDisk-Sync")
$removedCount = 0
foreach ($taskName in $taskNames) {
    try {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-Host "  Removed: $taskName" -ForegroundColor Green
            $removedCount++
        }
    } catch {
        Write-Host "  Warning: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
if ($removedCount -gt 0) {
    Write-Host "  Removed $removedCount task(s)" -ForegroundColor Green
}

Write-Host "Removing shortcuts..." -ForegroundColor Yellow
$desktopPath = [Environment]::GetFolderPath("Desktop")
$shortcutNames = @("RAMDisk.lnk", "RAMDisk Status.lnk")
$removedShortcuts = 0
foreach ($shortcutName in $shortcutNames) {
    $shortcutPath = Join-Path $desktopPath $shortcutName
    if (Test-Path $shortcutPath) {
        Remove-Item $shortcutPath -Force
        Write-Host "  Removed: $shortcutName" -ForegroundColor Green
        $removedShortcuts++
    }
}
if ($removedShortcuts -eq 0) {
    Write-Host "  No shortcuts found" -ForegroundColor Gray
}

if ($KeepBackup) {
    Write-Host "Keeping backups at: $backupPath" -ForegroundColor Cyan
} else {
    Write-Host "Removing backups..." -ForegroundColor Yellow
    if (Test-Path $backupPath) {
        try {
            $size = (Get-ChildItem $backupPath -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
            $sizeGB = [math]::Round($size / 1GB, 2)
            Write-Host "  Backup size: $sizeGB GB" -ForegroundColor Gray
            Write-Host ""
            Write-Host "WARNING: This will delete ALL backups!" -ForegroundColor Red
            $finalConfirm = Read-Host "Type DELETE to confirm"
            if ($finalConfirm -eq "DELETE") {
                Remove-Item $backupPath -Recurse -Force
                Write-Host "  All backups deleted" -ForegroundColor Green
            } else {
                Write-Host "  Deletion cancelled - files kept" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  Warning: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  No backup directory found" -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "Uninstall Complete" -ForegroundColor Green
Write-Host ""

if ($KeepBackup -and (Test-Path $backupPath)) {
    Write-Host "Backups preserved at:" -ForegroundColor Cyan
    Write-Host "  $backupPath" -ForegroundColor White
    Write-Host ""
}

Write-Host "ImDisk Toolkit is still installed." -ForegroundColor Yellow
Write-Host "To remove it, uninstall manually from Windows Settings." -ForegroundColor Yellow
Write-Host ""