#Requires -RunAsAdministrator

[CmdletBinding()]
param([switch]$Force)

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path (Split-Path -Parent $scriptPath) "config\ramdisk-config.json"

if (-not (Test-Path $configPath)) {
    Write-Error "Config not found: $configPath"
    exit 1
}

$config = Get-Content $configPath -Raw | ConvertFrom-Json

$ramDiskDrive = $config.ramdiskDrive.TrimEnd(':')
$ramDiskSize = $config.ramdiskSize
$backupPath = $config.backupPath
$fileSystem = $config.fileSystem
$volumeLabel = $config.labels.volumeLabel
$logPath = $config.logging.logPath
$useAWE = $config.performance.useAWE
$allocationUnit = $config.performance.allocationUnit

if (-not (Test-Path $logPath)) {
    New-Item -ItemType Directory -Path $logPath -Force | Out-Null
}

$logFile = Join-Path $logPath "mount_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Message"
    Write-Host $logMessage
    Add-Content -Path $logFile -Value $logMessage
}

Write-Log "=== Starting RAMDisk mount ==="

# Check if disk already exists
$drive = Get-PSDrive -Name $ramDiskDrive -ErrorAction SilentlyContinue
if ($drive -and -not $Force) {
    Write-Log "Drive ${ramDiskDrive}: already exists. Use -Force to remount"
    exit 1
}

if ($drive -and $Force) {
    Write-Log "Unmounting existing drive..."
    $unmountScript = Join-Path $scriptPath "unmount-ramdisk.ps1"
    & $unmountScript
    Start-Sleep -Seconds 2
}

# Create RAMDisk
Write-Log "Creating RAMDisk ${ramDiskSize} on ${ramDiskDrive}:"

$imdiskArgs = @(
    "-a"
    "-t", "vm"
    "-s", $ramDiskSize
    "-m", "${ramDiskDrive}:"
)

# Add AWE option for maximum speed (keeps RAMDisk in physical memory, never swaps)
if ($useAWE) {
    $imdiskArgs += "-o"
    $imdiskArgs += "awe"
    Write-Log "AWE mode enabled - RAMDisk will stay in physical memory"
}

Write-Log "Command: imdisk $($imdiskArgs -join ' ')"

$process = Start-Process -FilePath "imdisk" -ArgumentList $imdiskArgs -Wait -NoNewWindow -PassThru

if ($process.ExitCode -ne 0) {
    Write-Log "ERROR: ImDisk returned code $($process.ExitCode)"
    exit 1
}

Write-Log "RAMDisk device created successfully"

# Format the disk manually
Write-Log "Formatting ${ramDiskDrive}: with $fileSystem..."

# Wait for disk to be recognized by the system
Write-Log "Waiting for disk to be recognized..."
Start-Sleep -Seconds 3

# Check if volume exists, if not try diskpart initialization
$volume = Get-Volume -DriveLetter $ramDiskDrive -ErrorAction SilentlyContinue
if (-not $volume) {
    Write-Log "Volume not found, attempting diskpart initialization..."
    
    # Create diskpart script
    $diskpartScript = @"
select volume ${ramDiskDrive}
format fs=$fileSystem quick
assign letter=${ramDiskDrive}
"@
    $diskpartFile = Join-Path $env:TEMP "ramdisk_format.txt"
    $diskpartScript | Out-File -FilePath $diskpartFile -Encoding ASCII
    
    try {
        $diskpartResult = diskpart /s $diskpartFile 2>&1
        Remove-Item $diskpartFile -Force -ErrorAction SilentlyContinue
        Write-Log "Diskpart format attempted"
        Start-Sleep -Seconds 2
    } catch {
        Write-Log "Diskpart method failed: $($_.Exception.Message)"
    }
}

try {
    $allocationUnitValue = if ($allocationUnit -gt 0) { $allocationUnit } else { 4096 }
    Write-Log "Using allocation unit: $allocationUnitValue bytes ($(($allocationUnitValue/1024))KB)"
    
    # Try PowerShell Format-Volume
    $volume = Get-Volume -DriveLetter $ramDiskDrive -ErrorAction SilentlyContinue
    if ($volume) {
        Format-Volume -DriveLetter $ramDiskDrive `
            -FileSystem $fileSystem `
            -NewFileSystemLabel $volumeLabel `
            -AllocationUnitSize $allocationUnitValue `
            -Force `
            -Confirm:$false `
            -Full:$false | Out-Null
        
        Write-Log "Quick format completed successfully"
    } else {
        throw "Volume still not available after initialization"
    }
} catch {
    Write-Log "ERROR: Format failed: $($_.Exception.Message)"
    Write-Log "Trying format.com as fallback..."
    
    # Fallback: use format.com with echo for auto-confirm
    try {
        $formatCmd = "echo Y | format ${ramDiskDrive}: /FS:$fileSystem /Q /V:$volumeLabel"
        Write-Log "Running: $formatCmd"
        Invoke-Expression $formatCmd | Out-Null
        Start-Sleep -Seconds 2
        
        if (Test-Path "${ramDiskDrive}:\") {
            Write-Log "Format completed using format.com"
        } else {
            throw "Format.com failed"
        }
    } catch {
        Write-Log "ERROR: All format methods failed: $($_.Exception.Message)"
        Write-Log "Forcing removal of unformatted disk..."
        imdisk -D -m "${ramDiskDrive}:"
        exit 1
    }
}

# Wait for drive to be fully available
$timeout = 10
$elapsed = 0
while (-not (Test-Path "${ramDiskDrive}:\") -and $elapsed -lt $timeout) {
    Start-Sleep -Milliseconds 500
    $elapsed += 0.5
}

if (-not (Test-Path "${ramDiskDrive}:\")) {
    Write-Log "ERROR: Drive not available after ${timeout}s"
    exit 1
}

Write-Log "Drive ${ramDiskDrive}: is available"

# Set volume label and optimize settings
Write-Log "Restoring data from backup..."

$backupCurrent = Join-Path $backupPath "current"
if (Test-Path $backupCurrent) {
    $restoreScript = Join-Path $scriptPath "restore-ramdisk.ps1"
    & $restoreScript
    Write-Log "Data restored successfully"
} else {
    Write-Log "No backup found. Creating empty RAMDisk"
    New-Item -ItemType Directory -Path "${ramDiskDrive}:\Projects" -Force | Out-Null
    New-Item -ItemType Directory -Path "${ramDiskDrive}:\Cache" -Force | Out-Null
    New-Item -ItemType Directory -Path "${ramDiskDrive}:\Temp" -Force | Out-Null
}

# Disable indexing
try {
    $vol = Get-WmiObject -Class Win32_Volume -Filter "DriveLetter='${ramDiskDrive}:'"
    if ($vol) {
        $vol.IndexingEnabled = $false
        $vol.Put() | Out-Null
        Write-Log "Indexing disabled"
    }
} catch {
    Write-Log "Could not disable indexing: $($_.Exception.Message)"
}

# Start monitoring if not running
$monitorProcess = Get-Process -Name "pwsh" -ErrorAction SilentlyContinue | 
    Where-Object { $_.CommandLine -like "*ramdisk-monitor.ps1*" }

if (-not $monitorProcess) {
    Write-Log "Starting sync monitoring..."
    $monitorScript = Join-Path $scriptPath "ramdisk-monitor.ps1"
    Start-Process pwsh -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$monitorScript`"" -WindowStyle Hidden
    Write-Log "Monitoring started"
}

$driveInfo = Get-PSDrive -Name $ramDiskDrive
Write-Log "=== RAMDisk mounted successfully ==="
Write-Log "Drive: ${ramDiskDrive}:"
Write-Log "Size: $([math]::Round(($driveInfo.Used + $driveInfo.Free)/1GB, 2)) GB"
Write-Log "Free: $([math]::Round($driveInfo.Free/1GB, 2)) GB"
Write-Log "Backup: $backupPath"

Write-Host ""
Write-Host "RAMDisk successfully mounted on ${ramDiskDrive}:" -ForegroundColor Green
Write-Host "Size: $([math]::Round(($driveInfo.Used + $driveInfo.Free)/1GB, 2)) GB" -ForegroundColor White
Write-Host "Ready to use!" -ForegroundColor Green
Write-Host ""
