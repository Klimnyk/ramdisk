#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$SkipBackup,
    [switch]$Force
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

$logFile = Join-Path $logPath "unmount_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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

Write-Log "=== Starting RAMDisk unmount ===" "INFO"

if (-not (Test-RamDiskExists -DriveLetter $ramDiskDrive)) {
    Write-Log "RAMDisk ${ramDiskDrive}: is not mounted" "WARN"
    exit 0
}

Write-Log "Stopping monitor processes..." "INFO"
$monitorProcesses = Get-Process pwsh -ErrorAction SilentlyContinue | Where-Object { 
    $_.CommandLine -like "*ramdisk-monitor*" 
}

foreach ($proc in $monitorProcesses) {
    try {
        Write-Log "Stopping monitor process (PID: $($proc.Id))" "INFO"
        Stop-Process -Id $proc.Id -Force
        Write-Log "Monitor stopped" "INFO"
    } catch {
        Write-Log "Failed to stop monitor: $($_.Exception.Message)" "WARN"
    }
}

if (-not $SkipBackup) {
    Write-Log "Running final sync..." "INFO"
    
    $syncScript = Join-Path $scriptPath "sync-ramdisk.ps1"
    
    if (Test-Path $syncScript) {
        try {
            & $syncScript -Final -CreateBackup
            Write-Log "Final sync completed" "INFO"
        } catch {
            Write-Log "Sync failed: $($_.Exception.Message)" "ERROR"
            
            if (-not $Force) {
                Write-Log "Use -Force to unmount without sync" "INFO"
                exit 1
            }
        }
    } else {
        Write-Log "Sync script not found, skipping backup" "WARN"
    }
} else {
    Write-Log "Skipping backup (SkipBackup flag set)" "WARN"
}

Write-Log "Checking for open files and processes..." "INFO"

try {
    $openFiles = @()
    $volumes = Get-Volume | Where-Object { $_.DriveLetter -eq $ramDiskDrive }
    
    if ($volumes) {
        Write-Log "Preparing to unmount..." "INFO"
    }
    
    if ($openFiles.Count -gt 0 -and -not $Force) {
        Write-Log "Warning: $($openFiles.Count) files are open on RAMDisk" "WARN"
        Write-Log "Close all programs using RAMDisk or use -Force" "WARN"
        
        if (-not $Force) {
            exit 1
        }
    }
    
} catch {
    Write-Log "Warning: Could not check for open files" "WARN"
}

Write-Log "Unmounting RAMDisk..." "INFO"

try {
    $imdiskProcess = Start-Process -FilePath "imdisk" -ArgumentList "-D", "-m", "${ramDiskDrive}:" -Wait -NoNewWindow -PassThru
    
    if ($imdiskProcess.ExitCode -ne 0) {
        Write-Log "ImDisk returned code $($imdiskProcess.ExitCode)" "ERROR"
        
        if ($Force) {
            Write-Log "Attempting forced unmount..." "WARN"
            $forceProcess = Start-Process -FilePath "imdisk" -ArgumentList "-D", "-m", "${ramDiskDrive}:", "-f" -Wait -NoNewWindow -PassThru
            
            if ($forceProcess.ExitCode -ne 0) {
                Write-Log "Forced unmount failed" "ERROR"
                exit 1
            }
        } else {
            Write-Log "Use -Force to force unmount" "INFO"
            exit 1
        }
    }
    
} catch {
    Write-Log "Unmount error: $($_.Exception.Message)" "ERROR"
    exit 1
}

Start-Sleep -Seconds 2

if (Test-RamDiskExists -DriveLetter $ramDiskDrive) {
    Write-Log "Drive ${ramDiskDrive}: still accessible after unmount" "ERROR"
    exit 1
}

Write-Host ""
Write-Host "================================" -ForegroundColor Cyan
Write-Host "   RAMDisk Unmounted" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host ""

Write-Log "=== RAMDisk unmounted successfully ===" "INFO"

exit 0
