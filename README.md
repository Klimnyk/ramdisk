# RAMDisk Manager with ImDisk - Complete Solution

## Overview

This solution creates a RAMDisk with automatic change synchronization every 10 minutes, persistence on reboot, and a backup mechanism to protect against data loss. RAMDisk size is configurable through a configuration file.

## Key Features

- ✅ **Configurable RAMDisk** based on ImDisk (1-64 GB via config)
- ✅ **Maximum speed** with AWE mode and 64KB clusters (+70-100% faster!)
- ✅ **Automatic synchronization** every 10 minutes (only changed files)
- ✅ **Persistence on shutdown/reboot**
- ✅ **Backup mechanism** to protect against power loss
- ✅ **Quick mount/unmount** of the disk
- ✅ **Optimized for Python projects**
- ✅ **Maximum stability**
- ✅ **Simple JSON configuration**

## Project Structure

```
ramdisk/
├── scripts/
│   ├── mount-ramdisk.ps1        # Mount RAMDisk
│   ├── unmount-ramdisk.ps1      # Unmount RAMDisk
│   ├── sync-ramdisk.ps1         # Synchronize changes
│   ├── restore-ramdisk.ps1      # Restore data
│   └── ramdisk-monitor.ps1      # Monitoring and auto-sync
├── tasks/
│   ├── RamDisk-Startup.xml      # Auto-start on Windows boot
│   ├── RamDisk-Shutdown.xml     # Save on shutdown
│   └── RamDisk-Sync.xml         # Periodic synchronization
├── config/
│   └── ramdisk-config.json      # Configuration
├── docs/
│   └── MONITOR-INFO.md          # Detailed monitor description
└── install.ps1                   # Automatic installation
```

## Quick Start

### Step 1: Install ImDisk

1. Download ImDisk Toolkit: https://sourceforge.net/projects/imdisk-toolkit/
2. Install ImDisk Toolkit 
3. Verify installation with command:
   ```powershell
   imdisk -h
   ```

### Step 2: Automatic Installation

Run PowerShell **as Administrator** and execute:

```powershell
cd G:\Projects\ramdisk
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
.\install.ps1
```

The script will automatically:

- ✅ Read configuration from `config/ramdisk-config.json`
- ✅ Check system and warn if size is too large
- ✅ Create necessary directories
- ✅ Configure RAMDisk on drive R:
- ✅ Create tasks in Task Scheduler
- ✅ Set up PowerShell shortcuts (ramdisk/ram commands)
- ✅ Add R:\ to PATH
- ✅ Mount RAMDisk

**Changing RAMDisk Size:**

Edit `config/ramdisk-config.json`:

```json
{
  "ramdiskSize": "32G",  
  "ramdiskDrive": "R:",
  "backupPath": "D:\\ramdisk_backup",
  ...
}
```

Then run `.\install.ps1` again to apply changes.

**IMPORTANT:** After installation, restart PowerShell terminal to activate quick commands!

### Step 3: Restart Terminal

**Close and reopen PowerShell** to activate quick commands.

### Step 4: Verification and Usage

```powershell
# Check status
ram status

# Manual sync
ram sync

# Navigate to RAMDisk
ram cd

# Show all commands
ram help
```

### Step 5: Manual Control (alternative)

If quick commands don't work, use full paths:

#### Mount RAMDisk
```powershell
.\scripts\mount-ramdisk.ps1
```

#### Unmount RAMDisk (with save)
```powershell
.\scripts\unmount-ramdisk.ps1
```

#### Manual Synchronization
```powershell
.\scripts\sync-ramdisk.ps1
```

## ⚙️ How It Works

### 1. On Windows Startup
- `RamDisk-Startup` task runs automatically
- Creates 32 GB RAMDisk on drive R:
- Restores data from G:\ramdisk_backup
- Starts background synchronization process

### 2. During Operation
- Every 10 minutes `sync-ramdisk.ps1` runs
- Uses Robocopy to copy **only changed** files
- Preserves metadata, attributes, and permissions
- Maintains synchronization log

### 3. On Windows Shutdown
- `RamDisk-Shutdown` task triggers automatically
- Performs final synchronization of all data
- RAMDisk is properly unmounted
- All data is safely saved

### 4. Power Loss Protection
- Regular synchronization every 10 minutes
- Creates backup copies (last 3 versions)
- Power loss only loses changes from last 10 minutes
- Automatically restores last state on power recovery

## 🔧 Configuration

Edit `config\ramdisk-config.json` to change parameters:

```json
{
  "ramdiskSize": "32G",           # RAMDisk size
  "ramdiskDrive": "R:",           # Drive letter
  "backupPath": "D:\\ramdisk_backup",  # Backup path
  "syncInterval": 10,             # Sync interval (minutes)
  "keepBackupCopies": 3,          # Number of backup copies
  "fileSystem": "NTFS"            # File system
}
```

## 🛡️ Security and Reliability

### Backup Mechanism
- **Main copy**: G:\ramdisk_backup\current
- **Backup copies**: G:\ramdisk_backup\backup_YYYYMMDD_HHMMSS (last 3)
- **Sync logs**: G:\ramdisk_backup\logs

### Recovery After Failure
```powershell
# Restore from last backup copy
.\scripts\restore-ramdisk.ps1 -UseBackup

# Restore from specific date
.\scripts\restore-ramdisk.ps1 -BackupDate "20231220_143000"
```

## 🔍 Monitoring and Logging

### View Synchronization Logs
```powershell
Get-Content "G:\ramdisk_backup\logs\sync_$(Get-Date -Format 'yyyyMMdd').log" -Tail 50
```

### Check RAMDisk Status
```powershell
imdisk -l -u R:
```

**Note:** Scheduled Tasks are created with SYSTEM account and require admin rights to view. To check via admin PowerShell:

```powershell
schtasks /query /TN "\RamDisk-Startup"
schtasks /query /TN "\RamDisk-Shutdown"
schtasks /query /TN "\RamDisk-Sync"
```
