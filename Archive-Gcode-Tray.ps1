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
$script:ArchiveCount = 0
$script:LastArchived = $null
$script:Status = "Stopped"
$script:ConfigPath = Join-Path $env:APPDATA "GcodeArchiveWatcher\config.xml"
$script:ScriptPath = $MyInvocation.MyCommand.Path
$script:LogFile = Join-Path $PSScriptRoot "watcher.log"
$script:MainForm = $null
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
            $metadata.PostDate = $dateLine.ToString() -replace '.*post modified:\s*', '' -replace '\).*', '' -replace '[/-]', '_'
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
        
        $files = Get-ChildItem $WatchPath -Filter *.nc -File -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            if ([string]::IsNullOrWhiteSpace($file.FullName)) { continue }
            
            $key = $file.FullName.ToLowerInvariant()
            [System.Threading.Monitor]::Enter($script:KnownFilesLock)
            try {
                if (-not $script:KnownFiles.ContainsKey($key)) {
                    Write-Log "New file: $($file.Name) (from $WatchPath)"
                    $script:KnownFiles[$key] = $file.LastWriteTimeUtc
                    Archive-File -FilePath $file.FullName
                } else {
                    $lastWrite = $file.LastWriteTimeUtc
                    $knownWrite = $script:KnownFiles[$key]
                    if ($lastWrite -gt $knownWrite) {
                        Write-Log "Modified: $($file.Name) (from $WatchPath)"
                        $script:KnownFiles[$key] = $lastWrite
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

function Update-TrayIcon {
    if ($script:Notifier) {
        $iconText = "G-Code Archive`nStatus: $script:Status`nArchived: $script:ArchiveCount"
        if ($script:LastArchived) {
            $lastFile = Split-Path $script:LastArchived -Leaf
            $potential = "$iconText`nLast: $lastFile"
            if ($potential.Length -gt $script:MaxTrayTextLength) {
                $available = $script:MaxTrayTextLength - ($iconText.Length + 6)
                if ($available -gt 3) {
                    $lastFile = $lastFile.Substring(0, $available - 1) + "..."
                } else {
                    $lastFile = "..."
                }
            }
            $iconText += "`nLast: $lastFile"
        }
        # Final truncation to ensure within limit
        if ($iconText.Length -gt $script:MaxTrayTextLength) {
            $iconText = $iconText.Substring(0, $script:MaxTrayTextLength)
        }
        $script:Notifier.Text = $iconText
    }
}

function Show-BalloonTip {
    param([string]$Title, [string]$Message, [int]$Icon = 1)
    if ($script:Notifier) {
        $script:Notifier.ShowBalloonTip(3000, $Title, $Message, $Icon)
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
            # Get only Fixed (3) and Removable (2) drives using WMI for consistency
            $drives = Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -in @(2,3) } | ForEach-Object { $_.DeviceID + '\' }
            $watchPaths = $drives
            Write-Log "Watching all drives: $($drives -join ', ')"
        } else {
            $watchPaths = @($script:Context.WatchPath)
            Write-Log "Watching single path: $($script:Context.WatchPath)"
        }
        
        $script:KnownFiles = @{}
        $script:KnownFilesLock = New-Object Object
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
        
        $script:MainForm = New-Object System.Windows.Forms.Form
        $script:MainForm.ShowInTaskbar = $false
        $script:MainForm.WindowState = 'Minimized'
        $script:MainForm.Size = New-Object System.Drawing.Size(0,0)
        $script:MainForm.FormBorderStyle = 'None'
        $script:MainForm.ShowIcon = $false
        $script:MainForm.add_Shown({ $script:MainForm.Hide() })
        
        $script:WatchPaths = $watchPaths
        $script:WatchedDrives = @{}
        foreach ($p in $watchPaths) { $script:WatchedDrives[$p.ToLowerInvariant()] = $true }
        $script:TimerTickCount = 0
        
        $script:Timer = New-Object System.Windows.Forms.Timer
        $script:Timer.Interval = 1000
        $timerTickScript = {
            try {
                $script:TimerTickCount++
                if ($script:Context.WatchAllDrives) {
                    # Detect new drives (Fixed or Removable) using consistent WMI method
                    try {
                        $drives = Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -in @(2,3) } | ForEach-Object { $_.DeviceID + '\' }
                        foreach ($drive in $drives) {
                            $driveKey = $drive.ToLowerInvariant()
                            if (-not $script:WatchedDrives.ContainsKey($driveKey)) {
                                Write-Log "New drive detected: $drive"
                                $script:WatchedDrives[$driveKey] = $true
                                $script:WatchPaths += $drive
                                if (Test-Path $drive) {
                                    Get-ChildItem $drive -Filter *.nc -File -ErrorAction SilentlyContinue | ForEach-Object {
                                        $key = $_.FullName.ToLowerInvariant()
                                        [System.Threading.Monitor]::Enter($script:KnownFilesLock)
                                        try {
                                            if (-not $script:KnownFiles.ContainsKey($key)) {
                                                $script:KnownFiles[$key] = $_.LastWriteTimeUtc
                                            }
                                        }
                                        finally {
                                            [System.Threading.Monitor]::Exit($script:KnownFilesLock)
                                        }
                                    }
                                }
                                Write-Log "Now watching $drive"
                            }
                        }
                    } catch {
                        Write-Log "ERROR: Drive detection failed: $_"
                    }
                }
                
                # Check existing watch paths for files and removed drives
                $pathsToRemove = @()
                foreach ($path in $script:WatchPaths) {
                    $pathExists = $false
                    try {
                        $pathExists = Test-Path $path -ErrorAction SilentlyContinue
                    } catch {
                        Write-Log "WARNING: Test-Path failed for $path`: $_"
                    }
                    
                    if ($pathExists) {
                        try { 
                            Check-ForNewFiles -WatchPath $path 
                        } catch { 
                            Write-Log "Tick error for $path`: $_" 
                        }
                    } else {
                        # Drive removed - mark for cleanup
                        $pathKey = $path.ToLowerInvariant()
                        if ($script:WatchedDrives.ContainsKey($pathKey)) {
                            Write-Log "Drive removed: $path"
                            $pathsToRemove += $path
                        }
                    }
                }
                
                # Remove defunct drives after iteration (avoid modifying collection during foreach)
                if ($pathsToRemove.Count -gt 0) {
                    [System.Threading.Monitor]::Enter($script:KnownFilesLock)
                    try {
                        foreach ($path in $pathsToRemove) {
                            $pathKey = $path.ToLowerInvariant()
                            $script:WatchedDrives.Remove($pathKey) | Out-Null
                            # Remove all KnownFiles entries for this drive
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
                        $script:WatchPaths = $script:WatchPaths | Where-Object { $pathsToRemove -notcontains $_ }
                    }
                    finally {
                        [System.Threading.Monitor]::Exit($script:KnownFilesLock)
                    }
                }
            }
            catch {
                Write-Log "ERROR in timer tick: $_"
            }
        }
        $null = $script:Timer.add_Tick($timerTickScript)
        $script:Timer.Start()
        Write-Log "Timer started. Enabled=$($script:Timer.Enabled), Interval=$($script:Timer.Interval)"
        
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
        $script:Timer.Stop()
        $script:Timer.Dispose()
        $script:Timer = $null
    }
    if ($script:MainForm) {
        $script:MainForm.Dispose()
        $script:MainForm = $null
    }
    $script:KnownFiles = $null
    $script:Status = "Stopped"
    Update-TrayIcon
    Write-Log "Watcher stopped"
}

function Create-TrayIcon {
    # Create custom icon: folder with gear (archive symbol)
    $iconSize = 32
    $bitmap = New-Object System.Drawing.Bitmap($iconSize, $iconSize)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)
    
    # Draw folder body (tabbed folder shape)
    $folderColor = [System.Drawing.Color]::FromArgb(0, 120, 215) # Blue folder
    $folderPen = New-Object System.Drawing.Pen($folderColor, 2)
    $folderBrush = New-Object System.Drawing.SolidBrush($folderColor)
    
    $folderRect = New-Object System.Drawing.RectangleF(4, 6, 24, 22)
    $folderTabRect = New-Object System.Drawing.RectangleF(8, 2, 8, 6)
    
    # Folder back
    $graphics.FillRectangle($folderBrush, $folderRect)
    $graphics.DrawRectangle($folderPen, $folderRect.X, $folderRect.Y, $folderRect.Width-1, $folderRect.Height-1)
    
    # Folder tab
    $graphics.FillRectangle($folderBrush, $folderTabRect)
    $graphics.DrawRectangle($folderPen, $folderTabRect.X, $folderTabRect.Y, $folderTabRect.Width-1, $folderTabRect.Height-1)
    
    # Draw gear (cog) symbol in center
    $gearColor = [System.Drawing.Color]::White
    $gearBrush = New-Object System.Drawing.SolidBrush($gearColor)
    $gearPen = New-Object System.Drawing.Pen($gearColor, 2)
    $centerX = 16
    $centerY = 17
    $outerRadius = 6
    $innerRadius = 3
    $teeth = 6
    
    $angleStep = [Math]::PI * 2 / $teeth
    $points = New-Object System.Collections.Generic.List[System.Drawing.PointF]
    
    for ($i = 0; $i -lt $teeth * 2; $i++) {
        $angle = $i * $angleStep
        $radius = if ($i % 2 -eq 0) { $outerRadius } else { $innerRadius }
        $x = $centerX + [Math]::Cos($angle) * $radius
        $y = $centerY + [Math]::Sin($angle) * $radius
        $points.Add([System.Drawing.PointF]::new([float]$x, [float]$y))
    }
    
    $graphics.FillPolygon($gearBrush, $points.ToArray())
    $graphics.DrawPolygon($gearPen, $points.ToArray())
    
    # Cut out center hole (draw circle with folder color)
    $holeBrush = New-Object System.Drawing.SolidBrush($folderColor)
    $graphics.FillEllipse($holeBrush, $centerX - 1.5, $centerY - 1.5, 3, 3)
    
    $graphics.Dispose()
    
    $iconHandle = $bitmap.GetHicon()
    $notifyIconIcon = [System.Drawing.Icon]::FromHandle($iconHandle)
    
    $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $notifyIcon.Icon = $notifyIconIcon
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
    $targetPath = $script:ScriptPath
    $wsh = $null
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $shortcut = $wsh.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = "powershell.exe"
        $shortcut.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$targetPath`" -StartNow"
        $shortcut.WorkingDirectory = Split-Path $targetPath -Parent
        $shortcut.IconLocation = $targetPath
        $shortcut.Save()
    }
    finally {
        if ($wsh -ne $null) {
            [System.Runtime.Interopservices.Marshal]::ReleaseComObject($wsh) | Out-Null
        }
    }
}

function Remove-AutoStart {
    $shortcutPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\GcodeArchiveWatcher.lnk"
    if (Test-Path $shortcutPath) { Remove-Item $shortcutPath -Force }
}
#endregion

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

if ($StartNow) {
    Write-Log "=== G-Code Archive Watcher Starting ==="
    if (Start-Watcher) {
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

# Ensure we have a form for the message loop, even if watcher not started
if (-not $script:MainForm) {
    $script:MainForm = New-Object System.Windows.Forms.Form
    $script:MainForm.ShowInTaskbar = $false
    $script:MainForm.WindowState = 'Minimized'
    $script:MainForm.Size = New-Object System.Drawing.Size(0,0)
    $script:MainForm.FormBorderStyle = 'None'
    $script:MainForm.ShowIcon = $false
    $script:MainForm.add_Shown({ $script:MainForm.Hide() })
}
[System.Windows.Forms.Application]::Run($script:MainForm)

Stop-Watcher
if ($script:Notifier) {
    $script:Notifier.Visible = $false
    $script:Notifier.Dispose()
}
[System.Windows.Forms.Application]::Exit()
#endregion
