# G-Code Archive Watcher with System Tray
# Monitors all drives or specific folder for .nc files and archives them
param(
    [string]$WatchPath = ".",
    [string]$ArchiveRoot = "gcode_archive",
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$StartNow
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

#region Global Variables
$script:Context = $null
$script:Notifier = $null
$script:Timer = $null
$script:TimerTickCount = 0
$script:WatchPaths = $null
$script:WatchedDrives = $null
$script:KnownFiles = $null
$script:KnownFilesLock = $null
$script:DriveListLock = $null
$script:ArchiveCount = 0
$script:LastArchived = $null
$script:Status = "Stopped"
$script:ConfigPath = Join-Path $env:APPDATA "GcodeArchiveWatcher\config.xml"
$script:ScriptPath = $MyInvocation.MyCommand.Path
$script:LogFile = Join-Path $PSScriptRoot "watcher.log"
$script:MainForm = $null
$script:DriveChangeEventsRegistered = $false
$script:DriveRefreshInProgress = $false
$script:TimerElapsedRunning = $false
$script:MaxArchivesPerTick = 10
# Cached USB detection state
$script:CurrentUsbState = $null
$script:LastIconUsbState = $null
# Pre-created tray icons (set after function definitions)
$script:IconGreen = $null
$script:IconRed = $null
$script:IconDefault = $null
# Constants
$script:MaxBasenameLength = 100
$script:MaxTrayTextLength = 63
#endregion

#region Functions
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Message"
    Write-Host $logMessage
    Add-Content -Path $script:LogFile -Value $logMessage -ErrorAction SilentlyContinue
}

# Pre-created simple colored circle icons (fast)
function New-ColorIcon {
    param([System.Drawing.Color]$Color)
    try {
        $bmp = New-Object System.Drawing.Bitmap(16,16)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.FillEllipse((New-Object System.Drawing.SolidBrush($Color)), 0,0,16,16)
        $g.Dispose()
        $hicon = $bmp.GetHicon()
        $icon = [System.Drawing.Icon]::FromHandle($hicon)
        # Optionally clone to own the handle? Keep simple for now.
        return $icon
    } catch {
        Write-Log "ERROR: Failed to create color icon: $_"
        return $null
    }
}

function Save-Config {
    param([hashtable]$Config)
    $configDir = Split-Path $script:ConfigPath -Parent
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }
    # Write safe XML format
    $xmlContent = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <WatchPath>$($Config.WatchPath)</WatchPath>
  <WatchAllDrives>$($Config.WatchAllDrives)</WatchAllDrives>
  <ArchiveRoot>$($Config.ArchiveRoot)</ArchiveRoot>
  <AutoStart>$($Config.AutoStart)</AutoStart>
</configuration>
"@
    $xmlContent | Out-File -FilePath $script:ConfigPath -Encoding UTF8 -Force
}

function Load-Config {
    try {
        if (Test-Path $script:ConfigPath) {
            [xml]$xml = Get-Content $script:ConfigPath -Encoding UTF8 -ErrorAction Stop
            # Safely parse booleans
            $watchAll = $false
            $autoStart = $false
            [bool]::TryParse($xml.configuration.WatchAllDrives, [ref]$watchAll) | Out-Null
            [bool]::TryParse($xml.configuration.AutoStart, [ref]$autoStart) | Out-Null
            $config = @{
                WatchPath = $xml.configuration.WatchPath
                WatchAllDrives = $watchAll
                ArchiveRoot = $xml.configuration.ArchiveRoot
                AutoStart = $autoStart
            }
            # Validate essential keys exist
            if ($null -eq $config.WatchPath) { $config.WatchPath = "." }
            if ($null -eq $config.ArchiveRoot) { $config.ArchiveRoot = "gcode_archive" }
            return $config
        }
    }
    catch {
        Write-Log "WARNING: Failed to load config from $script:ConfigPath : $_"
    }
    # Return defaults
    return @{
        WatchPath = (Resolve-Path . -ErrorAction SilentlyContinue).Path
        WatchAllDrives = $true
        ArchiveRoot = "gcode_archive"
        AutoStart = $true
    }
}

function Initialize-Environment {
    $script:Context = Load-Config
    
    if (-not $script:Context.WatchAllDrives) {
        $watchPath = $script:Context.WatchPath
        if (-not (Test-Path $watchPath)) {
            $watchPath = (Resolve-Path . -ErrorAction SilentlyContinue).Path
            if (-not $watchPath) { $watchPath = $PWD.Path }
            $script:Context.WatchPath = $watchPath
        }
        $archiveRoot = $script:Context.ArchiveRoot
        if (-not [System.IO.Path]::IsPathRooted($archiveRoot)) {
            $archiveRoot = Join-Path $watchPath $archiveRoot
        }
        $script:Context.ArchiveRoot = $archiveRoot
    } else {
        $scriptDir = Split-Path $script:ScriptPath -Parent
        $archiveRoot = Join-Path $scriptDir "gcode_archive_all"
        $script:Context.ArchiveRoot = $archiveRoot
        $script:Context.WatchPath = "All Drives"
    }
    
    if (-not (Test-Path $script:Context.ArchiveRoot)) {
        New-Item -ItemType Directory -Path $script:Context.ArchiveRoot -Force | Out-Null
    }
    
    Write-Log "Initialized: WatchAllDrives=$($script:Context.WatchAllDrives), ArchiveRoot=$($script:Context.ArchiveRoot)"
    Update-TrayIcon
    
    # Initialize drive change detection
    Initialize-DriveWatcher
}

function Get-GcodeMetadata {
    param([string]$FilePath)
    
    $metadata = @{
        ProgramName = ""
        PostVersion = ""
        PostDate = ""
        Tools = @()
        Timestamp = Get-Date
    }
    
    try {
        $lines = Get-Content $FilePath -TotalCount 50 -Encoding UTF8 -ErrorAction Stop
        
        $programLine = $lines | Select-String -Pattern '^O\d+' | Select-Object -First 1
        if ($programLine) { $metadata.ProgramName = $programLine.ToString().Trim() }
        
        $versionLine = $lines | Select-String -Pattern 'post version:' | Select-Object -First 1
        if ($versionLine) {
            $metadata.PostVersion = $versionLine.ToString() -replace '.*post version:\s*', '' -replace '\).*', '' -replace '\s+', '_'
        }
        
        $dateLine = $lines | Select-String -Pattern 'post modified:' | Select-Object -First 1
        if ($dateLine) {
            $metadata.PostDate = ($dateLine.ToString() -replace '.*post modified:\s*', '' -replace '\).*', '' -replace '[/-]', '_').Trim()
        }
        
        $toolLines = $lines | Select-String -Pattern '\(T\d+\s+D=' | ForEach-Object {
            if ($_ -match 'T(\d+)') { $matches[1] }
        }
        $metadata.Tools = $toolLines | Sort-Object -Unique | Where-Object { $_ }
    }
    catch {
        Write-Log "WARNING: Failed to extract metadata from $FilePath`: $_"
    }
    
    return $metadata
}

function New-ArchiveFilename {
    param([string]$SourceFile, [object]$Metadata)
    
    $timestamp = $Metadata.Timestamp.ToString("yyyy-MM-dd_HH-mm-ss")
    $dateFolder = $Metadata.Timestamp.ToString("yyyy\\MM\\dd")
    
    $parts = @($timestamp)
    if ($Metadata.ProgramName) {
        # Sanitize: remove path separators and control characters, replace invalid filename chars
        $programNameClean = $Metadata.ProgramName -replace '[\\/:*?"<>|]', '_' -replace '[\x00-\x1F\x7F]', '_'
        $parts += $programNameClean
    }
    if ($Metadata.PostVersion) {
        $verClean = $Metadata.PostVersion -replace '[^\w\-]', '_'
        if ($verClean) { $parts += "post_$verClean" }
    }
    if (($Metadata.Tools) -and ($Metadata.Tools.Count -gt 0)) {
        $parts += "tools_" + ($Metadata.Tools -join '_')
    }
    
    $basename = $parts -join '_'
    if (-not $basename) { $basename = $timestamp + "_gcode" }
    
    # Limit basename length to avoid MAX_PATH issues (leave room for path + .nc)
    if ($basename.Length -gt $script:MaxBasenameLength) {
        $basename = $basename.Substring(0, $script:MaxBasenameLength)
    }
    
    $archiveDir = Join-Path $script:Context.ArchiveRoot $dateFolder
    $fullPath = Join-Path $archiveDir ($basename + ".nc")
    
    $counter = 1
    $maxCounter = 1000
    while ((Test-Path $fullPath) -and ($counter -lt $maxCounter)) {
        $fullPath = Join-Path $archiveDir ($basename + "_$counter.nc")
        $counter++
    }
    
    if ($counter -ge $maxCounter) {
        throw "Maximum filename collision attempts reached ($maxCounter). Archive directory may be full or malformed."
    }
    
    return $fullPath, $archiveDir
}

function Check-ForNewFiles {
    param([string]$WatchPath)
    
    try {
        if (-not (Test-Path $WatchPath)) { return }
        
        $files = Get-ChildItem $WatchPath -Filter *.nc -File -Recurse -ErrorAction SilentlyContinue
        $localArchiveCount = 0
        foreach ($file in $files) {
            if ([string]::IsNullOrWhiteSpace($file.FullName)) { continue }
            
            # Skip files that are inside the archive root to avoid infinite loops
            $fullPath = $file.FullName
            if ($fullPath.StartsWith($script:Context.ArchiveRoot, [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            
            # Throttle: stop if we've archived too many files this call (max per path)
            if ($localArchiveCount -ge $script:MaxArchivesPerTick) {
                break
            }
            
            $key = $fullPath.ToLowerInvariant()
            [System.Threading.Monitor]::Enter($script:KnownFilesLock)
            try {
                if (-not $script:KnownFiles.ContainsKey($key)) {
                    Write-Log "New file: $($file.Name) (from $WatchPath)"
                    $script:KnownFiles[$key] = $file.LastWriteTimeUtc
                    $localArchiveCount++
                    Archive-File -FilePath $file.FullName
                } else {
                    $lastWrite = $file.LastWriteTimeUtc
                    $knownWrite = $script:KnownFiles[$key]
                    if ($lastWrite -gt $knownWrite) {
                        Write-Log "Modified: $($file.Name) (from $WatchPath)"
                        $script:KnownFiles[$key] = $lastWrite
                        $localArchiveCount++
                        Archive-File -FilePath $file.FullName
                    }
                }
            }
            finally {
                [System.Threading.Monitor]::Exit($script:KnownFilesLock)
            }
        }
    }
    catch {
        Write-Log "ERROR in Check-ForNewFiles: $_"
    }
}

function Archive-File {
    param([string]$FilePath)
    
    Write-Log "Archiving: $((Split-Path $FilePath -Leaf))"
    
    try {
        # Retry metadata extraction up to 3 times if file is locked
        $metaRetries = 3
        $metaAttempt = 0
        $metadata = $null
        while ($metaAttempt -lt $metaRetries) {
            try {
                $metadata = Get-GcodeMetadata -FilePath $FilePath
                break
            }
            catch [System.IO.IOException] {
                $metaAttempt++
                if ($metaAttempt -lt $metaRetries) {
                    Write-Log "Metadata locked, retry $metaAttempt/$metaRetries in 500ms..."
                    Start-Sleep -Milliseconds 500
                } else {
                    throw
                }
            }
        }
        
        $destPath, $archiveDir = New-ArchiveFilename -SourceFile $FilePath -Metadata $metadata
        
        if (-not (Test-Path $archiveDir)) {
            New-Item -ItemType Directory -Path $archiveDir -Force -ErrorAction SilentlyContinue | Out-Null
            if (-not (Test-Path $archiveDir)) {
                Write-Log "Created directory: $archiveDir"
            }
        }
        
        # Retry copy up to 3 times with delay (handle locked files)
        $copyRetries = 3
        $copyAttempt = 0
        $copied = $false
        while (($copyAttempt -lt $copyRetries) -and (-not $copied)) {
            try {
                Copy-Item $FilePath $destPath -Force -ErrorAction Stop
                $copied = $true
            }
            catch [System.IO.IOException] {
                $copyAttempt++
                if ($copyAttempt -lt $copyRetries) {
                    Write-Log "File locked, retry $copyAttempt/$copyRetries in 500ms..."
                    Start-Sleep -Milliseconds 500
                } else {
                    throw
                }
            }
        }
        
        if (-not $copied) {
            throw "Failed to copy after $copyRetries attempts"
        }
        
        # Verify copy integrity by comparing file sizes
        try {
            $srcInfo = Get-Item $FilePath -ErrorAction Stop
            $dstInfo = Get-Item $destPath -ErrorAction Stop
            if ($srcInfo.Length -ne $dstInfo.Length) {
                Remove-Item $destPath -Force -ErrorAction SilentlyContinue
                throw "File size mismatch: source $($srcInfo.Length) bytes vs destination $($dstInfo.Length) bytes"
            }
        } catch {
            if (Test-Path $destPath) { Remove-Item $destPath -Force -ErrorAction SilentlyContinue }
            throw "Copy validation failed: $_"
        }
        
        $script:ArchiveCount++
        $script:LastArchived = $destPath
        
        $logFile = Join-Path $script:Context.ArchiveRoot "archive_log.csv"
        # Safely compute relative path
        $relativePath = $destPath
        if ($destPath.StartsWith($script:Context.ArchiveRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $relativePath = $destPath.Substring($script:Context.ArchiveRoot.Length)
            if ($relativePath.StartsWith('\')) { $relativePath = $relativePath.Substring(1) }
        }
        $logEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$(Split-Path $FilePath -Leaf),$relativePath,$($metadata.ProgramName),$($metadata.Tools -join ';')"
        Add-Content -Path $logFile -Value $logEntry -ErrorAction SilentlyContinue
        
        Update-TrayIcon
        Show-BalloonTip "G-Code Archived" "$(Split-Path $FilePath -Leaf) -> $(Split-Path $destPath -Leaf)" 1
        Write-Log "Archived to: $relativePath"
    }
    catch {
        Write-Log "ERROR: Archive failed: $_"
        Show-BalloonTip "Archive Failed" "$(Split-Path $FilePath -Leaf): $_" 2
    }
}

function Get-UsbStateFast {
    # Fast check: iterate watched paths and see if any is a removable drive (type 2)
    foreach ($p in $script:WatchPaths) {
        $drive = $p.TrimEnd('\')
        if ($drive -match '^[A-Z]:$') {
            try {
                $disk = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='$drive'" -ErrorAction SilentlyContinue
                if ($disk -and $disk.DriveType -eq 2) { return $true }
            } catch { }
        }
    }
    return $false
}

function Update-TrayIcon {
    # Exit early if notifier not ready
    if (-not $script:Notifier) { return }

    # Marshal to UI thread if needed
    if ($script:MainForm -and $script:MainForm.InvokeRequired) {
        try {
            $null = $script:MainForm.BeginInvoke([Action]{ Update-TrayIcon })
        } catch { }
        return
    }

    try {
        $usbDetected = $script:CurrentUsbState

        # Only change icon if state changed
        if ($usbDetected -ne $script:LastIconUsbState) {
            $newIcon = if ($usbDetected) { $script:IconGreen } else { $script:IconRed }
            if ($newIcon -and $newIcon -ne $script:Notifier.Icon) {
                $script:Notifier.Icon = $newIcon
                Write-Log "Icon set to: $(if($usbDetected){'GREEN'}else{'RED'})"
            }
        }
        # Always update last observed state
        $script:LastIconUsbState = $usbDetected

        # Update tooltip text only (fast)
        $iconText = "G-Code Archive`nStatus: $script:Status`nArchived: $script:ArchiveCount"
        $iconText += "`nUSB: $(if($usbDetected){'Connected'}else{'Disconnected'})"
        if ($script:LastArchived) {
            $lastFile = Split-Path $script:LastArchived -Leaf
            if ("$iconText`nLast: $lastFile".Length -gt $script:MaxTrayTextLength) {
                $avail = $script:MaxTrayTextLength - ($iconText.Length + 6)
                if ($avail -gt 3) { $lastFile = $lastFile.Substring(0,$avail-1) + '...' } else { $lastFile = '...' }
            }
            $iconText += "`nLast: $lastFile"
        }
        if ($iconText.Length -gt $script:MaxTrayTextLength) { $iconText = $iconText.Substring(0,$script:MaxTrayTextLength) }
        $script:Notifier.Text = $iconText
    }
    catch {
        Write-Log "WARNING: Update-TrayIcon failed: $_"
    }
}

function Show-BalloonTip {
    param([string]$Title, [string]$Message, [int]$Icon = 1)
    if ($script:Notifier) {
        if ($script:MainForm -and $script:MainForm.InvokeRequired) {
            try {
                $script:MainForm.BeginInvoke([Action]{ Show-BalloonTip -Title $Title -Message $Message -Icon $Icon }) | Out-Null
            }
            catch {
                # Swallow exceptions during early startup
            }
            return
        }
        try {
            $script:Notifier.ShowBalloonTip(3000, $Title, $Message, $Icon)
        }
        catch {
            # Ignore UI errors
        }
    }
}

function Start-Watcher {
    if ($script:Timer -and $script:Timer.Enabled) {
        Write-Log "Watcher already running"
        return $false
    }
    
    try {
        Write-Log "Starting watcher..."
        Initialize-Environment
        
        $watchPaths = @()
        if ($script:Context.WatchAllDrives) {
            $drives = Get-RemovableAndFixedDrives
            $watchPaths = $drives
            Write-Log "Watching all drives: $($drives -join ', ')"
        } else {
            $watchPaths = @($script:Context.WatchPath)
            Write-Log "Watching single path: $($script:Context.WatchPath)"
        }
        
        $script:KnownFiles = @{}
        $script:KnownFilesLock = New-Object Object
        $script:DriveListLock = New-Object Object
        foreach ($path in $watchPaths) {
            if (Test-Path $path) {
                Get-ChildItem $path -Filter *.nc -File -ErrorAction SilentlyContinue | ForEach-Object {
                    $key = $_.FullName.ToLowerInvariant()
                    if (-not $script:KnownFiles.ContainsKey($key)) {
                        $script:KnownFiles[$key] = $_.LastWriteTimeUtc
                    }
                }
            }
        }
        Write-Log "Initial scan: $($script:KnownFiles.Count) existing .nc file(s) ignored"
        
        # Create hidden main form (original pattern)
        $script:MainForm = New-Object System.Windows.Forms.Form
        $script:MainForm.ShowInTaskbar = $false
        $script:MainForm.WindowState = 'Minimized'
        $script:MainForm.Size = New-Object System.Drawing.Size(1,1)
        $script:MainForm.FormBorderStyle = 'None'
        $script:MainForm.ShowIcon = $false
        $script:MainForm.add_HandleCreated({
            Write-Log "MainForm handle created"
        })
        $script:MainForm.add_Shown({
            try {
                Write-Log "MainForm Shown: Visible=$($script:MainForm.Visible), Handle=$($script:MainForm.IsHandleCreated)"
                $script:MainForm.Hide()
                Write-Log "MainForm Hide() called"
            } catch {
                Write-Log "ERROR in Shown handler: $_"
            }
        })
        
        $script:WatchPaths = $watchPaths
        $script:WatchedDrives = @{}
        foreach ($p in $watchPaths) { $script:WatchedDrives[$p.ToLowerInvariant()] = $true }
        $script:TimerTickCount = 0
        
        # Determine initial USB detection state
        $script:CurrentUsbState = Get-UsbStateFast
        Write-Log "Initial USB state: $script:CurrentUsbState"
        $script:LastIconUsbState = $null  # Force first icon set

        # Setup timer
        
        # Setup timer
        $script:Timer = New-Object System.Windows.Forms.Timer
        $script:Timer.Interval = 2000
        $null = $script:Timer.add_Tick({ TimerTick })
        $script:Timer.Start()
        Write-Log "Timer started (System.Windows.Forms.Timer, Enabled=$($script:Timer.Enabled), Interval=$($script:Timer.Interval)ms)"
        
        # Start WMI drive event watcher
        Start-DriveWatcher
        
        # Initial drive detection
        Refresh-DriveDetection
        
        $script:Status = "Watching"
        Update-TrayIcon
        Write-Log "Watcher started successfully"
        return $true
    }
    catch {
        Write-Log "ERROR: Failed to start watcher: $_"
        return $false
    }
}

function Stop-Watcher {
    if ($script:Timer) {
        try {
            $script:Timer.Dispose()
        }
        catch {
            # Ignore dispose errors
        }
        $script:Timer = $null
    }
    $script:TimerElapsedRunning = $false
    
    # Stop WMI drive event watcher
    Stop-DriveWatcher
    
    if ($script:MainForm) {
        $script:MainForm.Dispose()
        $script:MainForm = $null
    }
    $script:KnownFiles = $null
    $script:Status = "Stopped"
    Update-TrayIcon
    Write-Log "Watcher stopped"
}

function TimerTick {
    try {
        $script:TimerTickCount++
        Write-Log "TimerTick: $script:TimerTickCount"
        
        # Queue background work to avoid blocking UI thread
        $tickCount = $script:TimerTickCount
        $null = [System.Threading.ThreadPool]::QueueUserWorkItem({
            param($count)
            
            try {
                # Every 5 ticks (10 seconds) refresh drive list
                if ($count % 5 -eq 0) {
                    Write-Log "Background refresh drive detection (tick $count)..."
                    Refresh-DriveDetection
                }
                
                # Snapshot watch paths (thread-safe)
                [System.Threading.Monitor]::Enter($script:DriveListLock)
                try {
                    $pathsToScan = $script:WatchPaths.Clone()
                }
                finally {
                    [System.Threading.Monitor]::Exit($script:DriveListLock)
                }
                
                foreach ($path in $pathsToScan) {
                    if (Test-Path $path -ErrorAction SilentlyContinue) {
                        Check-ForNewFiles -WatchPath $path
                    }
                }
            }
            catch {
                Write-Log "ERROR in background tick work: $_"
            }
        }, $tickCount)
    }
    catch {
        Write-Log "ERROR in timer tick: $_"
    }
}

function Create-TrayIcon {
    # Use pre-created colored icons; fallback to simple ball if not ready
    $initialIcon = if ($script:IconGreen) { $script:IconGreen } else { $script:IconRed }
    
    $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $notifyIcon.Icon = $initialIcon
    $notifyIcon.Text = "G-Code Archive Watcher"
    $notifyIcon.Visible = $true
    
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    
    $showStatusItem = $menu.Items.Add("Show Status")
    $showStatusItem.add_Click({
        [System.Windows.Forms.MessageBox]::Show(
            "Status: $script:Status`nWatching: $($script:Context.WatchPath)`nArchive Root: $($script:Context.ArchiveRoot)`nTotal Archived: $script:ArchiveCount`nLast: $(if($script:LastArchived){Split-Path $script:LastArchived -Leaf}else{'None'})",
            "G-Code Archive Watcher", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information
        )
    })
    
    $openArchiveItem = $menu.Items.Add("Open Archive Folder")
    $openArchiveItem.add_Click({
        if (Test-Path $script:Context.ArchiveRoot) { Invoke-Item $script:Context.ArchiveRoot }
    })
    
    [void]$menu.Items.Add("-")
    
    if ($script:Context.WatchAllDrives) {
        $watchAllItem = $menu.Items.Add("Watch All Drives: ON")
        $watchAllItem.Checked = $true
    } else {
        $watchAllItem = $menu.Items.Add("Watch All Drives: OFF")
        $watchAllItem.Checked = $false
    }
    $watchAllItem.add_Click({
        $script:Context.WatchAllDrives = -not $script:Context.WatchAllDrives
        Save-Config -Config $script:Context
        $watchAllItem.Text = "Watch All Drives: $(if($script:Context.WatchAllDrives){'ON'}else{'OFF'})"
        $watchAllItem.Checked = $script:Context.WatchAllDrives
        Show-BalloonTip "Watch Mode Changed" "Watch All Drives is now $(if($script:Context.WatchAllDrives){'ON'}else{'OFF'})" 1
        Write-Log "Watch All Drives set to: $($script:Context.WatchAllDrives)"
        Initialize-Environment
        if ($script:Timer -and $script:Timer.Enabled) {
            Stop-Watcher
            Start-Watcher
        }
    })
    
    [void]$menu.Items.Add("-")
    
    if ($script:Context.AutoStart) {
        $autoStartItem = $menu.Items.Add("Auto-Start: ON")
        $autoStartItem.Checked = $true
    } else {
        $autoStartItem = $menu.Items.Add("Auto-Start: OFF")
        $autoStartItem.Checked = $false
    }
    $autoStartItem.add_Click({
        $script:Context.AutoStart = -not $script:Context.AutoStart
        Save-Config -Config $script:Context
        $autoStartItem.Text = "Auto-Start: $(if($script:Context.AutoStart){'ON'}else{'OFF'})"
        $autoStartItem.Checked = $script:Context.AutoStart
        if ($script:Context.AutoStart) { Set-AutoStart } else { Remove-AutoStart }
    })
    
    [void]$menu.Items.Add("-")
    
    $changeWatchItem = $menu.Items.Add("Change Watch Folder...")
    $changeWatchItem.add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = "Select folder to watch (used when Watch All Drives is OFF)"
        $dialog.SelectedPath = $script:Context.WatchPath
        $dialog.ShowNewFolderButton = $false
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $newPath = $dialog.SelectedPath
            if (Test-Path $newPath) {
                $script:Context.WatchPath = $newPath
                Save-Config -Config $script:Context
                Show-BalloonTip "Watch Folder Changed" "Now monitoring:`n$newPath" 1
                Write-Log "Watch path changed to: $newPath"
                if ($script:Timer -and $script:Timer.Enabled) {
                    Stop-Watcher
                    Start-Watcher
                }
            }
        }
    })
    
    [void]$menu.Items.Add("-")
    
    $startItem = $menu.Items.Add("Start Watching")
    $startItem.add_Click({
        if (Start-Watcher) {
            Show-BalloonTip "Watcher Started" "Monitoring" 1
        }
    })
    
    $stopItem = $menu.Items.Add("Stop Watching")
    $stopItem.add_Click({
        Stop-Watcher
        Show-BalloonTip "Watcher Stopped" "File monitoring is paused" 2
    })
    
    [void]$menu.Items.Add("-")
    
    $exitItem = $menu.Items.Add("Exit")
    $exitItem.add_Click({
        Write-Log "Exit menu item clicked"
        Stop-Watcher
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
        [System.Windows.Forms.Application]::Exit()
    })
    
    $notifyIcon.ContextMenuStrip = $menu
    $notifyIcon.add_DoubleClick({ $showStatusItem.PerformClick() })
    return $notifyIcon
}

function Set-AutoStart {
    $shortcutPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\GcodeArchiveWatcher.lnk"
    $vbsPath = $script:ScriptPath -replace '\.ps1$', '.vbs'
    $wsh = $null
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $shortcut = $wsh.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = "wscript.exe"
        $shortcut.Arguments = "`"$vbsPath`" `"$script:ScriptPath`""
        $shortcut.WorkingDirectory = Split-Path $script:ScriptPath -Parent
        $shortcut.IconLocation = $script:ScriptPath
        $shortcut.Save()
        Write-Log "Auto-start shortcut created: $shortcutPath -> $vbsPath"
    }
    finally {
        if ($wsh -ne $null) {
            [System.Runtime.Interopservices.Marshal]::ReleaseComObject($wsh) | Out-Null
        }
    }
}

function Get-RemovableAndFixedDrives {
    $drives = @()
    try {
        $logicalDisks = Get-WmiObject Win32_LogicalDisk -ErrorAction SilentlyContinue
        foreach ($disk in $logicalDisks) {
            # DriveType: 2=Removable, 3=Fixed
            if ($disk.DriveType -eq 2 -or $disk.DriveType -eq 3) {
                $drives += $disk.DeviceID + '\'
            }
        }
    }
    catch {
        Write-Log "ERROR: Failed to query drives via WMI: $_"
    }
    return $drives
}

function Initialize-DriveWatcher {
    # Set up WMI event watchers for USB drive insertion/removal using PowerShell events
    try {
        # Watch for drive insertion
        $queryInsert = "SELECT * FROM __InstanceCreationEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_LogicalDisk'"
        $eventSinkInsert = New-Object Management.ManagementEventWatcher
        $eventSinkInsert.Query = New-Object Management.WqlEventQuery($queryInsert)
        
        # Watch for drive removal
        $queryRemove = "SELECT * FROM __InstanceDeletionEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_LogicalDisk'"
        $eventSinkRemove = New-Object Management.ManagementEventWatcher
        $eventSinkRemove.Query = New-Object Management.WqlEventQuery($queryRemove)
        
        # Store references so we can stop them later
        $script:WmiEventWatcher = @{
            Insert = $eventSinkInsert
            Remove = $eventSinkRemove
        }
        
        Write-Log "WMI drive event watchers initialized"
    }
    catch {
        Write-Log "WARNING: Failed to initialize WMI watchers: $_"
        $script:WmiEventWatcher = $null
    }
}

function Start-DriveWatcher {
    if ($script:WmiEventWatcher) {
        try {
            # Start listening for WMI events using asynchronous event pattern
            $script:WmiEventWatcher.Insert.Start()
            $script:WmiEventWatcher.Remove.Start()
            
            # Register PowerShell event handlers for the events
            Register-ObjectEvent -InputObject $script:WmiEventWatcher.Insert -EventName "EventArrived" -Action {
                param($sender, $e)
                $drive = $e.NewEvent.TargetInstance.DeviceID + '\'
                Write-Log "WMI: Drive inserted event: $drive"
                Refresh-DriveDetection
            } | Out-Null
            
            Register-ObjectEvent -InputObject $script:WmiEventWatcher.Remove -EventName "EventArrived" -Action {
                param($sender, $e)
                $drive = $e.NewEvent.TargetInstance.DeviceID + '\'
                Write-Log "WMI: Drive removed event: $drive"
                Refresh-DriveDetection
            } | Out-Null
            
            $script:DriveChangeEventsRegistered = $true
            Write-Log "WMI drive event watchers started"
        }
        catch {
            Write-Log "WARNING: Failed to start WMI watchers: $_"
        }
    }
}

function Stop-DriveWatcher {
    if ($script:DriveChangeEventsRegistered) {
        try {
            # Unregister PowerShell events
            Get-EventSubscriber | Where-Object { $_.SourceObject -eq $script:WmiEventWatcher.Insert -or $_.SourceObject -eq $script:WmiEventWatcher.Remove } | ForEach-Object {
                Unregister-Event -SourceIdentifier $_.SourceIdentifier -Force
            }
            $script:DriveChangeEventsRegistered = $false
        }
        catch {
            Write-Log "WARNING: Error unregistering WMI events: $_"
        }
    }
    
    if ($script:WmiEventWatcher) {
        try {
            $script:WmiEventWatcher.Insert.Stop()
            $script:WmiEventWatcher.Remove.Stop()
            $script:WmiEventWatcher.Insert.Dispose()
            $script:WmiEventWatcher.Remove.Dispose()
            Write-Log "WMI drive event watchers stopped"
        }
        catch {
            Write-Log "WARNING: Error stopping WMI watchers: $_"
        }
        $script:WmiEventWatcher = $null
    }
}

function Refresh-DriveDetection {
    # Prevent concurrent executions
    if ($script:DriveRefreshInProgress) {
        return
    }
    $script:DriveRefreshInProgress = $true
    
    try {
        Write-Log "Refreshing drive detection..."
        
        # Get current Fixed/Removable drives
        $currentDrives = Get-RemovableAndFixedDrives
        
        # Lock drive list for modifications
        [System.Threading.Monitor]::Enter($script:DriveListLock)
        try {
            # Find new drives - only add to watch list, don't scan contents
            foreach ($drive in $currentDrives) {
                $driveKey = $drive.ToLowerInvariant()
                if (-not $script:WatchedDrives.ContainsKey($driveKey)) {
                    Write-Log "New drive detected: $drive"
                    $script:WatchedDrives[$driveKey] = $true
                    $script:WatchPaths += $drive
                    Write-Log "Now watching $drive"
                    Show-BalloonTip "Drive Added" "Now monitoring $drive for G-code files" 1
                }
            }
            
            # Find removed drives
            $pathsToRemove = @()
            foreach ($path in $script:WatchPaths) {
                if (-not ($currentDrives -contains $path)) {
                    $pathKey = $path.ToLowerInvariant()
                    if ($script:WatchedDrives.ContainsKey($pathKey)) {
                        Write-Log "Drive removed: $path"
                        $pathsToRemove += $path
                    }
                }
            }
            
            # Clean up removed drives from watch list
            if ($pathsToRemove.Count -gt 0) {
                foreach ($path in $pathsToRemove) {
                    $pathKey = $path.ToLowerInvariant()
                    $script:WatchedDrives.Remove($pathKey) | Out-Null
                }
                $script:WatchPaths = $script:WatchPaths | Where-Object { $pathsToRemove -notcontains $_ }
                Show-BalloonTip "Drive Removed" "$($pathsToRemove.Count) drive(s) removed from monitoring" 1
            }
        }
        finally {
            [System.Threading.Monitor]::Exit($script:DriveListLock)
        }
        
        # Remove KnownFiles entries for any removed drives (separate lock)
        if ($pathsToRemove.Count -gt 0) {
            [System.Threading.Monitor]::Enter($script:KnownFilesLock)
            try {
                foreach ($path in $pathsToRemove) {
                    $pathKey = $path.ToLowerInvariant()
                    $keysToRemove = @()
                    foreach ($kvp in $script:KnownFiles.GetEnumerator()) {
                        if ($kvp.Key.StartsWith($pathKey, [StringComparison]::OrdinalIgnoreCase)) {
                            $keysToRemove += $kvp.Key
                        }
                    }
                    foreach ($k in $keysToRemove) {
                        $script:KnownFiles.Remove($k) | Out-Null
                    }
                }
            }
            finally {
                [System.Threading.Monitor]::Exit($script:KnownFilesLock)
            }
         }
     }
     catch {
         Write-Log "ERROR in Refresh-DriveDetection: $_"
     }
     finally {
         $script:DriveRefreshInProgress = $false
     }
     
    # Update cached USB detection state (fast, no logging)
    $newUsbState = Get-UsbStateFast
    if ($newUsbState -ne $script:CurrentUsbState) {
        $script:CurrentUsbState = $newUsbState
    }
    
    # Update tray icon color based on current drive state
    Update-TrayIcon
}

function Remove-AutoStart {
    $shortcutPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\GcodeArchiveWatcher.lnk"
    if (Test-Path $shortcutPath) { Remove-Item $shortcutPath -Force }
}

#endregion

# Pre-create tray icons for fast assignment
$script:IconGreen = New-ColorIcon -Color ([System.Drawing.Color]::FromArgb(0,180,0))
$script:IconRed = New-ColorIcon -Color ([System.Drawing.Color]::FromArgb(220,0,0))
Write-Log "Icons created: Green=$($null -ne $script:IconGreen), Red=$($null -ne $script:IconRed)"

#region Main
if ($Install) {
    Save-Config @{
        WatchPath = (Resolve-Path .).Path
        WatchAllDrives = $true
        ArchiveRoot = "gcode_archive"
        AutoStart = $true
    }
    Set-AutoStart
    Write-Host "G-Code Archive Watcher installed for auto-start." -ForegroundColor Green
    Write-Host "Configuration saved to: $script:ConfigPath" -ForegroundColor Cyan
    exit 0
}

if ($Uninstall) {
    Remove-AutoStart
    if (Test-Path $script:ConfigPath) { Remove-Item $script:ConfigPath -Force }
    Write-Host "G-Code Archive Watcher uninstalled." -ForegroundColor Yellow
    exit 0
}

Initialize-Environment
$script:Notifier = Create-TrayIcon

if ($script:Context.AutoStart) { Set-AutoStart }

# Start watcher unconditionally - it's needed for both interactive and auto-start modes
$watcherStarted = Start-Watcher
if (-not $script:MainForm) {
    Write-Log "FATAL: MainForm not created after Start-Watcher. Exiting."
    exit 1
}

if ($StartNow) {
    Write-Log "=== G-Code Archive Watcher Starting ==="
    if ($watcherStarted) {
        Write-Host "G-Code Archive Watcher started" -ForegroundColor Green
        Write-Host "Watching: $($script:Context.WatchPath)" -ForegroundColor Cyan
        Write-Host "Archive: $($script:Context.ArchiveRoot)" -ForegroundColor Cyan
        Write-Host "Auto-Start: $(if($script:Context.AutoStart){'Enabled'}else{'Disabled'})" -ForegroundColor Cyan
        Write-Host "`nCheck system tray for status icon." -ForegroundColor Yellow
        Write-Host "Right-click icon for menu options." -ForegroundColor Yellow
        Write-Host "Press Ctrl+C to exit" -ForegroundColor Yellow
    } else {
        Write-Host "Watcher already running or failed to start." -ForegroundColor Red
        Show-BalloonTip "Watcher Failed" "Could not start the watcher. Check log for details." 2
    }
}

# Add diagnostic handlers
if ($script:MainForm) {
    $script:MainForm.add_FormClosed({ Write-Log "MainForm FormClosed event fired" })
    $script:MainForm.add_FormClosing({ param($sender,$e) Write-Log "MainForm FormClosing: CloseReason=$($e.CloseReason)" })
    $script:MainForm.add_Resize({ Write-Log "MainForm Resize: WindowState=$($script:MainForm.WindowState), Visible=$($script:MainForm.Visible), HandleCreated=$($script:MainForm.IsHandleCreated)" })
}

Write-Log "Starting message loop (MainForm visible: $($script:MainForm.Visible))..."
try {
    [System.Windows.Forms.Application]::Run($script:MainForm)
    Write-Log "Message loop exited normally"
}
catch {
    Write-Log "ERROR in message loop: $_"
}
finally {
    Write-Log "Message loop cleanup"
}

Stop-Watcher
if ($script:Notifier) {
    $script:Notifier.Visible = $false
    $script:Notifier.Dispose()
}
[System.Windows.Forms.Application]::Exit()
#endregion
