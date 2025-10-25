#Requires -RunAsAdministrator

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path (Split-Path -Parent $scriptPath) "config\ramdisk-config.json"

if (-not (Test-Path $configPath)) {
    Write-Error "Configuration file not found: $configPath"
    exit 1
}

$config = Get-Content $configPath -Raw | ConvertFrom-Json

$ramDiskDrive = $config.ramdiskDrive.TrimEnd(':')
$backupPath = $config.backupPath
$syncInterval = $config.syncInterval
$logPath = $config.logging.logPath

if (-not (Test-Path $logPath)) {
    New-Item -ItemType Directory -Path $logPath -Force | Out-Null
}

$monitorLogFile = Join-Path $logPath "monitor_$(Get-Date -Format 'yyyyMMdd').log"

function Write-MonitorLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Add-Content -Path $monitorLogFile -Value $logMessage
}

function Test-RamDiskExists {
    param([string]$DriveLetter)
    $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue
    return ($drives | Where-Object { $_.Name -eq $DriveLetter }) -ne $null
}

function Invoke-SyncIfNeeded {
    if (-not (Test-RamDiskExists -DriveLetter $ramDiskDrive)) {
        Write-MonitorLog "RAMDisk not mounted, skipping sync" "WARN"
        return
    }
    
    $syncScript = Join-Path $scriptPath "sync-ramdisk.ps1"
    
    if (-not (Test-Path $syncScript)) {
        Write-MonitorLog "Sync script not found: $syncScript" "ERROR"
        return
    }
    
    Write-MonitorLog "Starting sync..." "INFO"
    
    try {
        $syncProcess = Start-Process -FilePath "pwsh" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$syncScript`"" -Wait -NoNewWindow -PassThru
        
        if ($syncProcess.ExitCode -eq 0) {
            Write-MonitorLog "Sync completed successfully" "INFO"
        } else {
            Write-MonitorLog "Sync failed with exit code: $($syncProcess.ExitCode)" "ERROR"
        }
        
    } catch {
        Write-MonitorLog "Sync error: $($_.Exception.Message)" "ERROR"
    }
}

Write-MonitorLog "=== RAMDisk Monitor Started ===" "INFO"
Write-MonitorLog "Sync interval: $syncInterval minutes" "INFO"
Write-MonitorLog "RAMDisk drive: ${ramDiskDrive}:" "INFO"

$syncIntervalSeconds = $syncInterval * 60

try {
    while ($true) {
        Invoke-SyncIfNeeded
        
        Write-MonitorLog "Next sync in $syncInterval minutes" "INFO"
        Start-Sleep -Seconds $syncIntervalSeconds
        
        $currentLogFile = Join-Path $logPath "monitor_$(Get-Date -Format 'yyyyMMdd').log"
        if ($currentLogFile -ne $monitorLogFile) {
            $monitorLogFile = $currentLogFile
            Write-MonitorLog "=== Continuing monitoring ===" "INFO"
        }
    }
    
} catch {
    Write-MonitorLog "Monitor stopped: $($_.Exception.Message)" "ERROR"
    exit 1
} finally {
    Write-MonitorLog "=== RAMDisk Monitor Stopped ===" "INFO"
}

exit 0
