#Requires -RunAsAdministrator
# RAMDisk Manager - Installation Script
# Version: 1.0.0

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# Helper functions
function Write-Step {
    param([string]$Message)
    Write-Host "`n> $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "  [!] $Message" -ForegroundColor Yellow
}

function Write-ErrorMsg {
    param([string]$Message)
    Write-Host "  [X] $Message" -ForegroundColor Red
}



# Header
Clear-Host
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "         RAMDisk Manager - Installation" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Check admin rights
Write-Step "Checking administrator privileges..."
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-ErrorMsg "This script requires administrator privileges!"
    Write-Host ""
    Write-Host "Please run PowerShell as Administrator and try again." -ForegroundColor Yellow
    exit 1
}
Write-Success "Administrator privileges confirmed"

# Get paths
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptPath "config\ramdisk-config.json"

# Load configuration
Write-Step "Loading configuration..."
if (-not (Test-Path $configPath)) {
    Write-ErrorMsg "Configuration file not found: $configPath"
    exit 1
}

$config = Get-Content $configPath -Raw | ConvertFrom-Json
Write-Success "Configuration loaded"

# Check system RAM
Write-Step "Analyzing system RAM..."

$totalRAM = (Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum
$totalRAMGB = [math]::Round($totalRAM / 1GB)

Write-Host "  * Total RAM: $totalRAMGB GB" -ForegroundColor White

if ($totalRAMGB -lt 8) {
    Write-ErrorMsg "Insufficient RAM. Minimum 8 GB required for RAMDisk"
    exit 1
}

# Parse configured size
$configuredSize = $config.ramdiskSize -replace '[^0-9]', ''
$configuredSizeGB = [int]$configuredSize

Write-Success "RAMDisk size from config: $configuredSizeGB GB"
Write-Host "  * Available for Windows: $($totalRAMGB - $configuredSizeGB) GB" -ForegroundColor Gray

# Warn if configured size is too large
if ($configuredSizeGB -ge ($totalRAMGB - 8)) {
    Write-Warning "RAMDisk size ($configuredSizeGB GB) leaves only $($totalRAMGB - $configuredSizeGB) GB for Windows!"
    Write-Host "  Consider reducing size in: $configPath" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Continue anyway? (Y/N): " -NoNewline -ForegroundColor Yellow
    $sizeConfirm = Read-Host
    if ($sizeConfirm -ne 'Y' -and $sizeConfirm -ne 'y') {
        Write-Host "Installation cancelled." -ForegroundColor Yellow
        Write-Host "Edit 'ramdiskSize' in config file and try again." -ForegroundColor Gray
        exit 0
    }
}

# Display final parameters
Write-Host ""
Write-Host "  Installation Parameters:" -ForegroundColor White
Write-Host "  ---------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "  * RAMDisk size:   $($config.ramdiskSize) ($configuredSizeGB GB)" -ForegroundColor White
Write-Host "  * Drive letter:   $($config.ramdiskDrive)" -ForegroundColor White
Write-Host "  * Backup path:    $($config.backupPath)" -ForegroundColor White
Write-Host "  * Sync interval:  every $($config.syncInterval) minutes" -ForegroundColor White
Write-Host "  * Backup copies:  $($config.keepBackupCopies) latest" -ForegroundColor White
Write-Host "  ---------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  To change size, edit: " -NoNewline -ForegroundColor Gray
Write-Host "config\ramdisk-config.json" -ForegroundColor Cyan
Write-Host ""

# Confirm
Write-Host "Continue installation? (Y/N): " -NoNewline -ForegroundColor Yellow
$confirmation = Read-Host
if ($confirmation -ne 'Y' -and $confirmation -ne 'y') {
    Write-Host "Installation cancelled." -ForegroundColor Yellow
    exit 0
}

# Check ImDisk
Write-Step "Checking ImDisk Toolkit..."
try {
    $imdiskTest = Get-Command imdisk.exe -ErrorAction Stop
    Write-Success "ImDisk Toolkit installed: $($imdiskTest.Source)"
} catch {
    # Try alternative paths
    $imdiskPaths = @(
        "$env:ProgramFiles\ImDisk\imdisk.exe",
        "${env:ProgramFiles(x86)}\ImDisk\imdisk.exe",
        "C:\Windows\System32\imdisk.exe"
    )
    
    $found = $false
    foreach ($path in $imdiskPaths) {
        if (Test-Path $path) {
            Write-Success "ImDisk Toolkit found at: $path"
            $found = $true
            break
        }
    }
    
    if (-not $found) {
        Write-ErrorMsg "ImDisk Toolkit not found!"
        Write-Host ""
        Write-Host "  Download and install ImDisk Toolkit:" -ForegroundColor Yellow
        Write-Host "  https://sourceforge.net/projects/imdisk-toolkit/" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  After installation, restart PowerShell and run this script again." -ForegroundColor Yellow
        exit 1
    }
}



# Create directories
Write-Step "Creating required directories..."

$directories = @(
    $config.backupPath,
    (Join-Path $config.backupPath "current"),
    $config.logging.logPath
)

foreach ($dir in $directories) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Success "Created: $dir"
    } else {
        Write-Host "  * Already exists: $dir" -ForegroundColor DarkGray
    }
}

# Remove old tasks
Write-Step "Removing old Task Scheduler tasks..."
$taskNames = @("RamDisk-Startup", "RamDisk-Shutdown", "RamDisk-Sync")

foreach ($taskName in $taskNames) {
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Success "Removed old task: $taskName"
    }
}

# Register tasks
Write-Step "Registering tasks in Task Scheduler..."

$taskFiles = @(
    @{Name = "RamDisk-Startup"; File = "RamDisk-Startup.xml"; Description = "Auto-start on Windows startup"; Script = "mount-ramdisk.ps1"},
    @{Name = "RamDisk-Shutdown"; File = "RamDisk-Shutdown.xml"; Description = "Save on shutdown"; Script = "sync-ramdisk.ps1"},
    @{Name = "RamDisk-Sync"; File = "RamDisk-Sync.xml"; Description = "Periodic sync"; Script = "sync-ramdisk.ps1"}
)

foreach ($task in $taskFiles) {
    $taskXmlPath = Join-Path $scriptPath "tasks\$($task.File)"
    
    if (-not (Test-Path $taskXmlPath)) {
        Write-ErrorMsg "Task file not found: $taskXmlPath"
        continue
    }
    
    try {
        # Read the XML content (UTF-16LE encoding is required for Windows Task Scheduler XML files)
        $xmlContent = Get-Content $taskXmlPath -Raw -Encoding Unicode
        
        # Build the actual script path based on current installation location
        $actualScriptPath = Join-Path $scriptPath "scripts\$($task.Script)"
        
        # Replace any hardcoded path with the actual installation path
        # Note: Uses Windows-style backslashes as Task Scheduler XML files always contain Windows paths
        # This regex matches the -File argument followed by any path ending with the script name
        $pattern = '(-File\s+")[^"]*\\scripts\\' + [regex]::Escape($task.Script) + '"'
        $replacement = "`$1$actualScriptPath`""
        $xmlContent = $xmlContent -replace $pattern, $replacement
        
        # Register the task with the modified XML
        Register-ScheduledTask -Xml $xmlContent -TaskName $task.Name -Force | Out-Null
        Write-Success "$($task.Name) - $($task.Description)"
    } catch {
        Write-ErrorMsg "Error registering $($task.Name): $($_.Exception.Message)"
    }
}

# Verify tasks
Write-Step "Verifying tasks..."
$registeredTasks = Get-ScheduledTask | Where-Object {$_.TaskName -like "RamDisk-*"}

if ($registeredTasks.Count -eq 3) {
    Write-Success "All tasks successfully registered"
} else {
    Write-Warning "Only $($registeredTasks.Count) of 3 tasks registered"
}

# Mount RAMDisk
Write-Step "Mounting RAMDisk..."
Write-Host "  This may take a moment..." -ForegroundColor DarkGray

try {
    $mountScript = Join-Path $scriptPath "scripts\mount-ramdisk.ps1"
    & $mountScript
    
    Start-Sleep -Seconds 2
    $ramDiskDrive = $config.ramdiskDrive.TrimEnd(':')
    $drive = Get-PSDrive -Name $ramDiskDrive -ErrorAction SilentlyContinue
    
    if ($drive) {
        Write-Success "RAMDisk successfully mounted on $($config.ramdiskDrive)"
        Write-Host "  * Size: $([math]::Round(($drive.Used + $drive.Free)/1GB, 2)) GB" -ForegroundColor White
        Write-Host "  * Free: $([math]::Round($drive.Free/1GB, 2)) GB" -ForegroundColor White
    } else {
        Write-Warning "RAMDisk mounted but not available for verification"
    }
} catch {
    Write-ErrorMsg "Error mounting RAMDisk: $($_.Exception.Message)"
}

# Create shortcut
Write-Step "Creating desktop shortcut..."

try {
    $desktopPath = [Environment]::GetFolderPath("Desktop")
    $ramDiskLink = Join-Path $desktopPath "RAMDisk ($($config.ramdiskDrive)).lnk"
    
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ramDiskLink)
    $shortcut.TargetPath = "$($config.ramdiskDrive)\"
    $shortcut.IconLocation = "%SystemRoot%\System32\imageres.dll,137"
    $shortcut.Description = "RAMDisk - fast memory disk"
    $shortcut.Save()
    
    Write-Success "Desktop shortcut created"
} catch {
    Write-Warning "Could not create shortcut: $($_.Exception.Message)"
}

# Setup PowerShell profile
Write-Step "Setting up PowerShell shortcuts..."

try {
    $profilePath = $PROFILE.CurrentUserAllHosts
    $profileDir = Split-Path $profilePath -Parent
    
    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }
    
    $ramdiskFunctions = @"

# ========== RAMDisk Manager Shortcuts ==========
function ramdisk {
    param([string]`$action = "help")
    
    `$scriptRoot = "$scriptPath"
    
    switch (`$action.ToLower()) {
        "mount"     { & "`$scriptRoot\scripts\mount-ramdisk.ps1" }
        "unmount"   { & "`$scriptRoot\scripts\unmount-ramdisk.ps1" }
        "sync"      { & "`$scriptRoot\scripts\sync-ramdisk.ps1" }
        "restore"   { & "`$scriptRoot\scripts\restore-ramdisk.ps1" }
        "status"    { & "`$scriptRoot\scripts\status-ramdisk.ps1" }
        "uninstall" { & "`$scriptRoot\scripts\uninstall.ps1" }
        "cd"        { Set-Location "$($config.ramdiskDrive)\" }
        "help"      {
            Write-Host ""
            Write-Host "RAMDisk Manager - Quick Commands" -ForegroundColor Cyan
            Write-Host "=================================" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "  ramdisk mount      " -ForegroundColor Yellow -NoNewline; Write-Host "- Mount RAMDisk"
            Write-Host "  ramdisk unmount    " -ForegroundColor Yellow -NoNewline; Write-Host "- Unmount RAMDisk"
            Write-Host "  ramdisk sync       " -ForegroundColor Yellow -NoNewline; Write-Host "- Sync to backup now"
            Write-Host "  ramdisk restore    " -ForegroundColor Yellow -NoNewline; Write-Host "- Restore from backup"
            Write-Host "  ramdisk status     " -ForegroundColor Yellow -NoNewline; Write-Host "- Show status"
            Write-Host "  ramdisk uninstall  " -ForegroundColor Yellow -NoNewline; Write-Host "- Remove RAMDisk system"
            Write-Host "  ramdisk cd         " -ForegroundColor Yellow -NoNewline; Write-Host "- Go to RAMDisk"
            Write-Host "  ram                " -ForegroundColor Yellow -NoNewline; Write-Host "- Quick alias for ramdisk"
            Write-Host ""
        }
        default {
            Write-Host "Unknown action: `$action" -ForegroundColor Red
            Write-Host "Use 'ramdisk help' for available commands" -ForegroundColor Yellow
        }
    }
}

# Quick alias (use 'ram' instead of 'rd' which conflicts with Remove-Item)
Set-Alias -Name ram -Value ramdisk -Force -ErrorAction SilentlyContinue

# Auto-add RAMDisk to PATH if mounted
if (Test-Path "$($config.ramdiskDrive)\") {
    if (`$env:PATH -notlike "*$($config.ramdiskDrive)\*") {
        `$env:PATH += ";$($config.ramdiskDrive)\"
    }
}
# ===============================================

"@
    
    $existingProfile = ""
    if (Test-Path $profilePath) {
        $existingProfile = Get-Content $profilePath -Raw
    }
    
    # Remove old RAMDisk section if exists
    if ($existingProfile -match "# ========== RAMDisk Manager Shortcuts ==========") {
        $existingProfile = $existingProfile -replace "(?s)# ========== RAMDisk Manager Shortcuts ==========.*?# ===============================================\s*", ""
    }
    
    # Add new section
    $newProfile = $existingProfile.TrimEnd() + "`n" + $ramdiskFunctions
    Set-Content -Path $profilePath -Value $newProfile -Encoding UTF8
    
    Write-Success "PowerShell shortcuts added to profile"
    Write-Host "  * Use: " -NoNewline -ForegroundColor Gray
    Write-Host "ramdisk <command>" -ForegroundColor Cyan -NoNewline
    Write-Host " or " -NoNewline -ForegroundColor Gray
    Write-Host "rd <command>" -ForegroundColor Cyan
    Write-Host "  * Type: " -NoNewline -ForegroundColor Gray
    Write-Host "ramdisk help" -ForegroundColor Yellow -NoNewline
    Write-Host " for all commands" -ForegroundColor Gray
} catch {
    Write-Warning "Could not setup profile: $($_.Exception.Message)"
}

# Final info
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "            Installation completed successfully!" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""

Write-Host "  [>] RAMDisk mounted:" -ForegroundColor Cyan
Write-Host "      $($config.ramdiskDrive)\" -ForegroundColor White
Write-Host ""
Write-Host "  [>] Backup location:" -ForegroundColor Cyan
Write-Host "      $($config.backupPath)" -ForegroundColor White
Write-Host ""
Write-Host "  [>] Logs location:" -ForegroundColor Cyan
Write-Host "      $($config.logging.logPath)" -ForegroundColor White
Write-Host ""
Write-Host "  [>] Settings:" -ForegroundColor Cyan
Write-Host "      * Auto-start on Windows startup: [OK]" -ForegroundColor Green
Write-Host "      * Auto-save on shutdown: [OK]" -ForegroundColor Green
Write-Host "      * Sync every $($config.syncInterval) min: [OK]" -ForegroundColor Green
Write-Host ""

Write-Host "  [>] Quick commands:" -ForegroundColor Cyan
Write-Host "      ramdisk mount        # Mount RAMDisk" -ForegroundColor Yellow
Write-Host "      ramdisk unmount      # Unmount RAMDisk" -ForegroundColor Yellow
Write-Host "      ramdisk sync         # Sync now" -ForegroundColor Yellow
Write-Host "      ramdisk status       # Show status" -ForegroundColor Yellow
Write-Host "      ramdisk uninstall    # Remove system" -ForegroundColor Yellow
Write-Host "      ram help             # Show all commands (short alias)" -ForegroundColor Yellow
Write-Host ""
Write-Host "  [>] Alternative (full paths):" -ForegroundColor Cyan
Write-Host "      .\scripts\mount-ramdisk.ps1" -ForegroundColor Gray
Write-Host "      .\scripts\status-ramdisk.ps1" -ForegroundColor Gray
Write-Host ""

Write-Host "================================================================" -ForegroundColor Yellow
Write-Host "  IMPORTANT: Restart PowerShell terminal to use quick commands!" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Yellow
Write-Host ""

Write-Host "  [>] Documentation: README.md" -ForegroundColor Yellow
Write-Host ""

# Offer to open RAMDisk
Write-Host "Open RAMDisk in Explorer? (Y/N): " -NoNewline -ForegroundColor Yellow
$openExplorer = Read-Host

if ($openExplorer -eq 'Y' -or $openExplorer -eq 'y') {
    Start-Process explorer.exe -ArgumentList "$($config.ramdiskDrive)\"
}

Write-Host ""
Write-Host "Done! RAMDisk is ready to use!" -ForegroundColor Green
Write-Host ""

exit 0
