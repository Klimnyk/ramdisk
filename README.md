# RAMDisk Manager with ImDisk - Complete Solution

## Overview

This solution creates a RAMDisk with automatic change synchronization every 10 minutes, persistence on reboot, and a backup mechanism to protect against data loss. RAMDisk size is configurable through a configuration file.

## Key Features

- ✅ **Configurable RAMDisk** based on ImDisk (1-64 GB via config)
- ✅ **Maximum speed** with AWE mode and 64KB clusters (+70-100% faster!)
- ✅ **Automatic synchronization** every 10 minutes (only changed files)
- ✅ **Multi-destination backup** - sync to 2+ drives simultaneously!
- ✅ **Parallel backup mode** - backup to multiple drives at the same time
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
│   ├── sync-ramdisk.ps1         # Synchronize changes (supports parallel multi-disk)
│   ├── restore-ramdisk.ps1      # Restore data (from any backup destination)
│   ├── status-ramdisk.ps1       # Show status of all backup destinations
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
cd C:\path\to\ramdisk
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
  "backupPath": "D:\\ramdisk_backup",  # Primary backup path
  "syncInterval": 10,             # Sync interval (minutes)
  "keepBackupCopies": 1,          # Default backup versions per destination
  "fileSystem": "NTFS"            # File system
}
```

### Multi-Destination Backup (NEW!)

Enable backup to multiple drives simultaneously for redundancy. With 2 drives, you don't need multiple backup versions on each drive - the redundancy comes from having 2 separate drives!

```json
{
  "multiBackup": {
    "enabled": true,
    "parallelSync": true,          // Sync to all drives at once (faster!)
    "destinations": [
      {
        "name": "Primary",
        "path": "D:\\ramdisk_backup",
        "enabled": true,
        "priority": 1,             // Used first for restore
        "keepBackupCopies": 1      // 1 version per drive (2 total)
      },
      {
        "name": "Secondary", 
        "path": "E:\\ramdisk_backup",
        "enabled": true,
        "priority": 2,
        "keepBackupCopies": 1      // 1 version per drive (2 total)
      }
    ],
    "failoverOnError": true,       // Continue if one drive fails
    "syncTimeoutSeconds": 300      // Max time per sync operation
  }
}
```

**Benefits of Multi-Destination Backup:**

- 🛡️ **Redundancy** - Data survives if one drive fails
- ⚡ **Parallel sync** - Both drives sync simultaneously (no extra time!)
- 💾 **Space efficient** - 1 backup per drive instead of 3 on one drive
- 🔄 **Automatic failover** - Restore from any available backup
- 📊 **Status monitoring** - See all destinations in `ram status`

**Sync Commands:**

```powershell
# Normal sync (parallel to all destinations)
ram sync

# Force sequential sync (one drive at a time)
.\scripts\sync-ramdisk.ps1 -Sequential

# Restore from specific destination
.\scripts\restore-ramdisk.ps1 -FromDestination "Secondary"
```

## 🛡️ Security and Reliability

### Backup Mechanism

With multi-destination backup enabled:
- **Primary (D:)**: D:\ramdisk_backup\current + 1 version backup
- **Secondary (E:)**: E:\ramdisk_backup\current + 1 version backup
- **Sync logs**: D:\ramdisk_backup\logs

Total: 2 current copies + 2 version backups = **4 copies of your data!**

### Recovery After Failure

```powershell
# Restore from last backup copy (auto-selects best source)
.\scripts\restore-ramdisk.ps1 -UseBackup

# Restore from specific destination
.\scripts\restore-ramdisk.ps1 -FromDestination "Secondary"

# Restore from specific date
.\scripts\restore-ramdisk.ps1 -BackupDate "20231220_143000"
```

## 🔍 Monitoring and Logging

### View Synchronization Logs

```powershell
Get-Content "D:\ramdisk_backup\logs\sync_$(Get-Date -Format 'yyyyMMdd').log" -Tail 50
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
