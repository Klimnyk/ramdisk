#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Benchmark disk speed comparison: RAMDisk vs C: drive
.DESCRIPTION
    Tests read/write speeds on both RAMDisk and system drive
    Compares sequential and random I/O performance
.EXAMPLE
    .\benchmark-speed.ps1
.EXAMPLE
    .\benchmark-speed.ps1 -Detailed
#>

[CmdletBinding()]
param(
    [switch]$Detailed,
    [int]$TestSizeMB = 500,
    [int]$RandomBlockSizeKB = 4
)

$ErrorActionPreference = "Stop"

# Colors
$ColorHeader = "Cyan"
$ColorSuccess = "Green"
$ColorWarning = "Yellow"
$ColorInfo = "White"

function Write-Header {
    param([string]$Text)
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor $ColorHeader
    Write-Host " $Text" -ForegroundColor $ColorHeader
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor $ColorHeader
    Write-Host ""
}

function Write-Result {
    param([string]$Test, [double]$Speed, [string]$Unit = "MB/s")
    $speedStr = [math]::Round($Speed, 2).ToString("N2")
    Write-Host "  $($Test.PadRight(30)): " -NoNewline -ForegroundColor $ColorInfo
    Write-Host "$speedStr $Unit" -ForegroundColor $ColorSuccess
}

function Test-SequentialWrite {
    param([string]$Path, [int]$SizeMB)
    
    $testFile = Join-Path $Path "benchmark_write.dat"
    $data = New-Object byte[] ($SizeMB * 1MB)
    
    # Fill with random data
    $random = New-Object Random
    $random.NextBytes($data)
    
    $sw = [Diagnostics.Stopwatch]::StartNew()
    [IO.File]::WriteAllBytes($testFile, $data)
    $sw.Stop()
    
    $speed = $SizeMB / $sw.Elapsed.TotalSeconds
    
    Remove-Item $testFile -Force -ErrorAction SilentlyContinue
    
    return $speed
}

function Test-SequentialRead {
    param([string]$Path, [int]$SizeMB)
    
    $testFile = Join-Path $Path "benchmark_read.dat"
    $data = New-Object byte[] ($SizeMB * 1MB)
    
    # Create test file
    [IO.File]::WriteAllBytes($testFile, $data)
    
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $readData = [IO.File]::ReadAllBytes($testFile)
    $sw.Stop()
    
    $speed = $SizeMB / $sw.Elapsed.TotalSeconds
    
    Remove-Item $testFile -Force -ErrorAction SilentlyContinue
    
    return $speed
}

function Test-RandomWrite {
    param([string]$Path, [int]$BlockSizeKB, [int]$Operations = 1000)
    
    $testFile = Join-Path $Path "benchmark_random.dat"
    $blockSize = $BlockSizeKB * 1KB
    $data = New-Object byte[] $blockSize
    
    $stream = [IO.File]::Create($testFile)
    $stream.SetLength($Operations * $blockSize)
    
    $random = New-Object Random
    $sw = [Diagnostics.Stopwatch]::StartNew()
    
    for ($i = 0; $i -lt $Operations; $i++) {
        $random.NextBytes($data)
        $position = $random.Next(0, $Operations) * $blockSize
        $stream.Position = $position
        $stream.Write($data, 0, $blockSize)
    }
    
    $stream.Flush()
    $sw.Stop()
    $stream.Close()
    
    $totalMB = ($Operations * $blockSize) / 1MB
    $speed = $totalMB / $sw.Elapsed.TotalSeconds
    
    Remove-Item $testFile -Force -ErrorAction SilentlyContinue
    
    return $speed
}

function Test-RandomRead {
    param([string]$Path, [int]$BlockSizeKB, [int]$Operations = 1000)
    
    $testFile = Join-Path $Path "benchmark_random_read.dat"
    $blockSize = $BlockSizeKB * 1KB
    $totalSize = $Operations * $blockSize
    
    # Create test file
    $stream = [IO.File]::Create($testFile)
    $stream.SetLength($totalSize)
    $stream.Close()
    
    $stream = [IO.File]::OpenRead($testFile)
    $buffer = New-Object byte[] $blockSize
    
    $random = New-Object Random
    $sw = [Diagnostics.Stopwatch]::StartNew()
    
    for ($i = 0; $i -lt $Operations; $i++) {
        $position = $random.Next(0, $Operations) * $blockSize
        $stream.Position = $position
        [void]$stream.Read($buffer, 0, $blockSize)
    }
    
    $sw.Stop()
    $stream.Close()
    
    $totalMB = $totalSize / 1MB
    $speed = $totalMB / $sw.Elapsed.TotalSeconds
    
    Remove-Item $testFile -Force -ErrorAction SilentlyContinue
    
    return $speed
}

function Test-FileCreation {
    param([string]$Path, [int]$FileCount = 100)
    
    $testDir = Join-Path $Path "benchmark_files"
    New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    
    $sw = [Diagnostics.Stopwatch]::StartNew()
    
    for ($i = 0; $i -lt $FileCount; $i++) {
        $file = Join-Path $testDir "file_$i.txt"
        "Test data $i" | Out-File $file
    }
    
    $sw.Stop()
    $filesPerSec = $FileCount / $sw.Elapsed.TotalSeconds
    
    Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
    
    return $filesPerSec
}

function Get-DriveInfo {
    param([string]$DriveLetter)
    
    $drive = Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue
    
    if ($drive) {
        $totalGB = [math]::Round(($drive.Used + $drive.Free) / 1GB, 2)
        $freeGB = [math]::Round($drive.Free / 1GB, 2)
        $usedGB = [math]::Round($drive.Used / 1GB, 2)
        
        return @{
            Total = $totalGB
            Free = $freeGB
            Used = $usedGB
            Available = $drive.Free -gt ($TestSizeMB * 1MB * 2)
        }
    }
    
    return $null
}

# Main script
Clear-Host

Write-Header "DISK SPEED BENCHMARK TEST"

Write-Host "Configuration:" -ForegroundColor $ColorWarning
Write-Host "  Test size: $TestSizeMB MB" -ForegroundColor $ColorInfo
Write-Host "  Random block: $RandomBlockSizeKB KB" -ForegroundColor $ColorInfo
Write-Host ""

# Check drives
$ramDrive = "R"
$sysDrive = "C"

$ramInfo = Get-DriveInfo $ramDrive
$sysInfo = Get-DriveInfo $sysDrive

if (-not $ramInfo) {
    Write-Host "ERROR: RAMDisk (R:) not found!" -ForegroundColor Red
    Write-Host "Please mount RAMDisk first: .\scripts\mount-ramdisk.ps1" -ForegroundColor Yellow
    exit 1
}

if (-not $ramInfo.Available) {
    Write-Host "ERROR: Not enough space on RAMDisk" -ForegroundColor Red
    exit 1
}

if (-not $sysInfo.Available) {
    Write-Host "WARNING: Not enough space on C: drive, reducing test size" -ForegroundColor Yellow
    $TestSizeMB = 100
}

Write-Host "Drive Information:" -ForegroundColor $ColorWarning
Write-Host "  RAMDisk (R:): $($ramInfo.Used) GB used / $($ramInfo.Total) GB total" -ForegroundColor $ColorInfo
Write-Host "  System  (C:): $($sysInfo.Used) GB used / $($sysInfo.Total) GB total" -ForegroundColor $ColorInfo

# RAMDisk Tests
Write-Header "RAMDisk (R:) Performance"

$ramResults = @{}

Write-Host "Testing Sequential Write..." -ForegroundColor $ColorWarning
$ramResults.SeqWrite = Test-SequentialWrite -Path "${ramDrive}:\" -SizeMB $TestSizeMB
Write-Result "Sequential Write" $ramResults.SeqWrite

Write-Host "Testing Sequential Read..." -ForegroundColor $ColorWarning
$ramResults.SeqRead = Test-SequentialRead -Path "${ramDrive}:\" -SizeMB $TestSizeMB
Write-Result "Sequential Read" $ramResults.SeqRead

Write-Host "Testing Random Write (4K blocks)..." -ForegroundColor $ColorWarning
$ramResults.RndWrite = Test-RandomWrite -Path "${ramDrive}:\" -BlockSizeKB $RandomBlockSizeKB -Operations 2000
Write-Result "Random Write (4K)" $ramResults.RndWrite

Write-Host "Testing Random Read (4K blocks)..." -ForegroundColor $ColorWarning
$ramResults.RndRead = Test-RandomRead -Path "${ramDrive}:\" -BlockSizeKB $RandomBlockSizeKB -Operations 2000
Write-Result "Random Read (4K)" $ramResults.RndRead

if ($Detailed) {
    Write-Host "Testing File Creation..." -ForegroundColor $ColorWarning
    $ramResults.FileCreate = Test-FileCreation -Path "${ramDrive}:\" -FileCount 200
    Write-Result "File Creation" $ramResults.FileCreate "files/sec"
}

# System Drive Tests
Write-Header "System Drive (C:) Performance"

$sysTestPath = "C:\Temp\benchmark"
if (-not (Test-Path $sysTestPath)) {
    New-Item -ItemType Directory -Path $sysTestPath -Force | Out-Null
}

$sysResults = @{}

Write-Host "Testing Sequential Write..." -ForegroundColor $ColorWarning
$sysResults.SeqWrite = Test-SequentialWrite -Path $sysTestPath -SizeMB $TestSizeMB
Write-Result "Sequential Write" $sysResults.SeqWrite

Write-Host "Testing Sequential Read..." -ForegroundColor $ColorWarning
$sysResults.SeqRead = Test-SequentialRead -Path $sysTestPath -SizeMB $TestSizeMB
Write-Result "Sequential Read" $sysResults.SeqRead

Write-Host "Testing Random Write (4K blocks)..." -ForegroundColor $ColorWarning
$sysResults.RndWrite = Test-RandomWrite -Path $sysTestPath -BlockSizeKB $RandomBlockSizeKB -Operations 2000
Write-Result "Random Write (4K)" $sysResults.RndWrite

Write-Host "Testing Random Read (4K blocks)..." -ForegroundColor $ColorWarning
$sysResults.RndRead = Test-RandomRead -Path $sysTestPath -BlockSizeKB $RandomBlockSizeKB -Operations 2000
Write-Result "Random Read (4K)" $sysResults.RndRead

if ($Detailed) {
    Write-Host "Testing File Creation..." -ForegroundColor $ColorWarning
    $sysResults.FileCreate = Test-FileCreation -Path $sysTestPath -FileCount 200
    Write-Result "File Creation" $sysResults.FileCreate "files/sec"
}

# Cleanup
Remove-Item $sysTestPath -Recurse -Force -ErrorAction SilentlyContinue

# Comparison
Write-Header "PERFORMANCE COMPARISON"

function Show-Comparison {
    param([string]$TestName, [double]$RamSpeed, [double]$SysSpeed, [string]$Unit = "MB/s")
    
    $improvement = (($RamSpeed - $SysSpeed) / $SysSpeed) * 100
    $ratio = $RamSpeed / $SysSpeed
    
    $ramStr = [math]::Round($RamSpeed, 2).ToString("N2").PadLeft(10)
    $sysStr = [math]::Round($SysSpeed, 2).ToString("N2").PadLeft(10)
    $improvStr = [math]::Round($improvement, 1).ToString("N1").PadLeft(7)
    $ratioStr = [math]::Round($ratio, 2).ToString("N2").PadLeft(6)
    
    Write-Host "  $($TestName.PadRight(25))" -NoNewline -ForegroundColor $ColorInfo
    Write-Host " | " -NoNewline
    Write-Host "RAM: $ramStr $Unit" -NoNewline -ForegroundColor $ColorSuccess
    Write-Host " | " -NoNewline
    Write-Host "SYS: $sysStr $Unit" -NoNewline -ForegroundColor $ColorWarning
    Write-Host " | " -NoNewline
    
    if ($improvement -gt 0) {
        Write-Host "+$improvStr%" -NoNewline -ForegroundColor Green
    } else {
        Write-Host "$improvStr%" -NoNewline -ForegroundColor Red
    }
    
    Write-Host " | " -NoNewline
    Write-Host "${ratioStr}x" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "  Test Name                  | RAMDisk      | System Drive | Improve |  Ratio" -ForegroundColor $ColorHeader
Write-Host "  " + ("-" * 85) -ForegroundColor $ColorHeader

Show-Comparison "Sequential Write" $ramResults.SeqWrite $sysResults.SeqWrite
Show-Comparison "Sequential Read" $ramResults.SeqRead $sysResults.SeqRead
Show-Comparison "Random Write (4K)" $ramResults.RndWrite $sysResults.RndWrite
Show-Comparison "Random Read (4K)" $ramResults.RndRead $sysResults.RndRead

if ($Detailed) {
    Show-Comparison "File Creation" $ramResults.FileCreate $sysResults.FileCreate "files/s"
}

Write-Host ""

# Summary
Write-Header "SUMMARY"

$avgRamSpeed = ($ramResults.SeqWrite + $ramResults.SeqRead + $ramResults.RndWrite + $ramResults.RndRead) / 4
$avgSysSpeed = ($sysResults.SeqWrite + $sysResults.SeqRead + $sysResults.RndWrite + $sysResults.RndRead) / 4
$overallImprovement = (($avgRamSpeed - $avgSysSpeed) / $avgSysSpeed) * 100

Write-Host "  Average RAMDisk Speed: " -NoNewline -ForegroundColor $ColorInfo
Write-Host "$([math]::Round($avgRamSpeed, 2)) MB/s" -ForegroundColor $ColorSuccess

Write-Host "  Average System Speed:  " -NoNewline -ForegroundColor $ColorInfo
Write-Host "$([math]::Round($avgSysSpeed, 2)) MB/s" -ForegroundColor $ColorWarning

Write-Host ""
Write-Host "  Overall Performance Gain: " -NoNewline -ForegroundColor $ColorInfo
Write-Host "+$([math]::Round($overallImprovement, 1))%" -ForegroundColor Green
Write-Host "  Speed Multiplier: " -NoNewline -ForegroundColor $ColorInfo
Write-Host "$([math]::Round($avgRamSpeed / $avgSysSpeed, 2))x faster" -ForegroundColor Cyan

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor $ColorHeader
Write-Host ""