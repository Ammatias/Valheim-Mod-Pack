param(
    [string]$GameDirectory = $PSScriptRoot,
    [ValidateSet('Midgard','Helheim')][string]$Pack = 'Midgard',
    [string]$ManifestUri = '',
    [switch]$NoLaunch,
    [switch]$AllowLocalSource,
    [switch]$LibraryOnly
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$Pack = if ($Pack -ieq 'Midgard') { 'Midgard' } else { 'Helheim' }
$script:PackId = 'ammatias-' + $Pack.ToLowerInvariant()
if (-not $ManifestUri) { $ManifestUri = 'https://raw.githubusercontent.com/Ammatias/Valheim-Mod-Pack/main/' + $Pack + '/latest.json?t=' + [DateTime]::UtcNow.Ticks }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-ContainedPath([string]$Root, [string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or $Relative -match '[\\:*?"<>|\x00-\x1f]' -or
        $Relative.StartsWith('/') -or $Relative.Split('/') -contains '..' -or
        $Relative.Split('/') -contains '.' -or $Relative -match '//|/$') {
        throw "Unsafe package path: $Relative"
    }
    foreach ($part in $Relative.Split('/')) {
        if ($part -match '[. ]$|^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') { throw "Unsafe Windows name: $Relative" }
    }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $result = [IO.Path]::GetFullPath((Join-Path $base $Relative.Replace('/', [IO.Path]::DirectorySeparatorChar)))
    if (-not $result.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes game folder: $Relative"
    }
    return $result
}

function Assert-PlainPath([string]$Path, [string]$Root) {
    $current = [IO.Path]::GetFullPath($Path)
    $base = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    while ($current.Length -ge $base.Length) {
        if (Test-Path -LiteralPath $current) {
            $entry = Get-Item -LiteralPath $current -Force
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Linked folders are unsupported: $current" }
        }
        if ($current.Equals($base, [StringComparison]::OrdinalIgnoreCase)) { break }
        $current = [IO.Path]::GetDirectoryName($current)
        if (-not $current) { throw 'Path validation failed' }
    }
}

function Test-ManagedName([string]$Name) {
    return $Name -match '^BepInEx/(core|plugins|patchers|config)/.+' -or
        $Name -in @('winhttp.dll', 'doorstop_config.ini', '.doorstop_version')
}

function Assert-PlainTree([string]$Path, [string]$Root) {
    Assert-PlainPath $Path $Root
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($Path)
    while ($pending.Count) {
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($pending.Pop())) {
            $attributes = [IO.File]::GetAttributes($entry)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Linked content is unsupported: $entry" }
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) { $pending.Push($entry) }
        }
    }
}

function Assert-SourceUri([string]$Value, [bool]$Local) {
    $uri = [Uri]$Value
    if ($Local -and $uri.IsFile) { return }
    if ($uri.Scheme -ne 'https' -or $uri.Host -notin @('github.com', 'raw.githubusercontent.com')) {
        throw 'Downloads must use the official HTTPS GitHub source'
    }
    if ($uri.UserInfo -or $uri.Fragment) { throw 'Invalid download URL' }
}

function Format-TransferProgress([string]$Activity, [long]$Received, [long]$Total, [double]$Seconds, [int]$Width) {
    $speed = $Received / [Math]::Max(0.001, $Seconds) / 1MB
    $percent = 0
    if ($Total -gt 0) {
        $percent = [int][Math]::Min(100, [Math]::Floor(100.0 * $Received / $Total))
        $status = '{0,3}% {1,5:N1}/{2,5:N1} MiB {3,5:N1} MiB/s' -f $percent, ($Received / 1MB), ($Total / 1MB), $speed
    } else {
        $status = '{0:N1} MiB {1:N1} MiB/s' -f ($Received / 1MB), $speed
    }
    $prefix = $Activity + ' '
    $barWidth = [Math]::Min(28, $Width - $prefix.Length - $status.Length - 3)
    if ($barWidth -lt 8) {
        $prefix = ''
        $barWidth = [Math]::Min(28, $Width - $status.Length - 3)
    }
    if ($barWidth -lt 4) {
        $status = if ($Total -gt 0) { '{0}% {1:N1} MiB/s' -f $percent, $speed } else { '{0:N1} MiB' -f ($Received / 1MB) }
        $barWidth = [Math]::Min(28, $Width - $status.Length - 3)
    }
    if ($barWidth -lt 1) {
        $status = if ($Total -gt 0) { '{0}%' -f $percent } else { 'Downloading' }
        $barWidth = [Math]::Max(1, $Width - $status.Length - 3)
    }
    if ($Total -gt 0) {
        $filled = [int][Math]::Floor($barWidth * $percent / 100.0)
        $bar = if ($percent -eq 100) { '=' * $barWidth } else { ('=' * $filled) + '>' + ('-' * ($barWidth - $filled - 1)) }
    } else {
        $position = [int]([Math]::Floor($Received / 65536.0) % $barWidth)
        $bar = ('-' * $position) + '>' + ('-' * ($barWidth - $position - 1))
    }
    $line = $prefix + '[' + $bar + '] ' + $status
    return $line.Substring(0, [Math]::Min($line.Length, [Math]::Max(1, $Width)))
}

$script:TransferLineLength = 0
$script:TransferLineActive = $false
function Write-TransferProgress([string]$Activity, [long]$Received, [long]$Total, [double]$Seconds) {
    $width = 79
    try { if ([Console]::WindowWidth -gt 1) { $width = [Console]::WindowWidth - 1 } } catch { }
    $line = Format-TransferProgress $Activity $Received $Total $Seconds $width
    $length = [Math]::Min($width, [Math]::Max($line.Length, $script:TransferLineLength))
    Write-Host -NoNewline ("`r" + $line.PadRight($length))
    $script:TransferLineLength = $line.Length
    $script:TransferLineActive = $true
}

function Complete-TransferLine {
    if ($script:TransferLineActive) { Write-Host '' }
    $script:TransferLineLength = 0
    $script:TransferLineActive = $false
}

function Write-FileProgress([string]$Activity, [int]$Done, [int]$Total, [Diagnostics.Stopwatch]$Clock, [ref]$LastShown) {
    if ($Done -eq 0 -or $Done -eq $Total -or $Clock.ElapsedMilliseconds - $LastShown.Value -ge 1000) {
        $percent = if ($Total -gt 0) { [int][Math]::Floor(100.0 * $Done / $Total) } else { 100 }
        Write-Host ('{0}: {1}% ({2} / {3} files)' -f $Activity, $percent, $Done, $Total)
        $LastShown.Value = $Clock.ElapsedMilliseconds
    }
}

function Copy-DownloadStream([IO.Stream]$SourceStream, [string]$Destination, [long]$TotalBytes, [string]$Activity) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $received = [long]0
    $lastShown = [long]0
    $outputStream = $null
    $success = $false
    try {
        $outputStream = [IO.File]::Create($Destination)
        $buffer = New-Object byte[] 1048576
        if ($Activity) { Write-TransferProgress $Activity 0 $TotalBytes 0 }
        while (($count = $SourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $received += $count
            if ($TotalBytes -gt 0 -and $received -gt $TotalBytes) { throw 'Download exceeds the expected size.' }
            $outputStream.Write($buffer, 0, $count)
            if ($Activity -and $clock.ElapsedMilliseconds - $lastShown -ge 250) {
                Write-TransferProgress $Activity $received $TotalBytes $clock.Elapsed.TotalSeconds
                $lastShown = $clock.ElapsedMilliseconds
            }
        }
        if ($TotalBytes -gt 0 -and $received -ne $TotalBytes) { throw 'Download ended before all expected bytes arrived.' }
        if ($Activity) { Write-TransferProgress $Activity $received $TotalBytes $clock.Elapsed.TotalSeconds }
        $success = $true
    } finally {
        if ($Activity) { Complete-TransferLine }
        if ($outputStream) { $outputStream.Dispose() }
        if (-not $success -and (Test-Path -LiteralPath $Destination)) { Remove-Item -LiteralPath $Destination -Force }
    }
}

function Get-SourceFile([string]$Uri, [string]$Destination, [bool]$Local, [long]$ExpectedBytes = 0, [string]$Activity = '') {
    Assert-SourceUri $Uri $Local
    if (([Uri]$Uri).IsFile) {
        $inputStream = [IO.File]::OpenRead(([Uri]$Uri).LocalPath)
        try {
            $total = if ($ExpectedBytes -gt 0) { $ExpectedBytes } else { $inputStream.Length }
            Copy-DownloadStream $inputStream $Destination $total $Activity
        } finally { $inputStream.Dispose() }
        return
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $request = [Net.HttpWebRequest]::Create($Uri)
    $request.UserAgent = 'Valheim-Modpack-Updater/1'
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 30000
    $response = $null
    $inputStream = $null
    if ($Activity) { Write-Host ($Activity + ': connecting...') }
    try {
        $response = $request.GetResponse()
        if ($ExpectedBytes -gt 0 -and $response.ContentLength -gt 0 -and $response.ContentLength -ne $ExpectedBytes) {
            throw 'Download size differs from the expected archive size.'
        }
        $total = if ($ExpectedBytes -gt 0) { $ExpectedBytes } else { $response.ContentLength }
        $inputStream = $response.GetResponseStream()
        Copy-DownloadStream $inputStream $Destination $total $Activity
    } finally {
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

function Read-ReleaseManifest([string]$Uri, [string]$Destination, [bool]$Local) {
    Get-SourceFile $Uri $Destination $Local
    $manifest = [IO.File]::ReadAllText($Destination, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($manifest.PSObject.Properties.Name -contains 'manifest_url') {
        if ($manifest.pack_id -ne $script:PackId -or $manifest.schema -ne 1) { throw 'Wrong modpack release pointer' }
        Get-SourceFile $manifest.manifest_url $Destination $Local
        $manifest = [IO.File]::ReadAllText($Destination, [Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    return $manifest
}

function Assert-Manifest($Manifest, [string]$Root, [bool]$Local) {
    if ($Manifest.schema -ne 1 -or $Manifest.pack_id -ne $script:PackId -or
        -not $Manifest.version -or @($Manifest.packages).Count -eq 0 -or @($Manifest.packages).Count -gt 200) {
        throw 'Unexpected modpack manifest'
    }
    $names = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $ids = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $total = [long]0
    foreach ($package in $Manifest.packages) {
        if ($package.id -notmatch '^[a-z0-9-]{1,80}$' -or -not $ids.Add($package.id) -or
            $package.sha256 -notmatch '^[a-f0-9]{64}$' -or $package.bytes -le 0 -or $package.bytes -gt 2GB) {
            throw 'Invalid package metadata'
        }
        Assert-SourceUri $package.url $Local
        if (@($package.files).Count -eq 0) { throw 'Empty package' }
        foreach ($file in $package.files) {
            $null = Get-ContainedPath $Root $file.path
            if (-not (Test-ManagedName $file.path) -or -not $names.Add($file.path) -or
                $file.sha256 -notmatch '^[a-f0-9]{64}$' -or $file.bytes -lt 0 -or $file.bytes -gt 2GB -or
                ($file.preserve -and -not $file.path.StartsWith('BepInEx/config/'))) { throw 'Invalid package file' }
            $total += $file.bytes
        }
    }
    if ($names.Count -gt 10000 -or $total -gt 10GB) { throw 'Package exceeds size limits' }
    $essentialFiles = @('winhttp.dll', 'doorstop_config.ini', 'BepInEx/core/BepInEx.dll',
        'BepInEx/core/BepInEx.Preloader.dll', 'BepInEx/core/0Harmony.dll', 'BepInEx/plugins/ValheimPlus.dll')
    if ($script:PackId -eq 'ammatias-helheim') { $essentialFiles += 'BepInEx/plugins/Morgott.Core/Morgott.Core.dll' }
    foreach ($essential in $essentialFiles) {
        if (-not $names.Contains($essential)) { throw "Required loader file missing: $essential" }
    }
}

function Test-CurrentFile([string]$Root, $File) {
    $path = Get-ContainedPath $Root $File.path
    Assert-PlainPath $path $Root
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    if ($File.preserve) { return $true }
    if ((Get-Item -LiteralPath $path -Force).Length -ne $File.bytes) { return $false }
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $File.sha256
}

function Expand-VerifiedPackage([string]$ArchivePath, $Package, [string]$Stage) {
    Write-Host 'Verifying downloaded archive...'
    if ((Get-Item -LiteralPath $ArchivePath).Length -ne $Package.bytes -or
        (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Package.sha256) {
        throw "Downloaded package is damaged: $($Package.id)"
    }
    $expected = @{}
    foreach ($f in $Package.files) { $expected[$f.path] = $f }
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $lastShown = [long]0
    Write-FileProgress 'Extracting and verifying' 0 $expected.Count $clock ([ref]$lastShown)
    try {
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            $destination = Get-ContainedPath $Stage $name
            $unixType = ($entry.ExternalAttributes -shr 16) -band 0xF000
            if (-not $expected.ContainsKey($name) -or -not $seen.Add($name) -or
                $unixType -eq 0xA000 -or $entry.Length -ne $expected[$name].bytes) { throw 'Unexpected ZIP entry' }
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
            $inputStream = $entry.Open()
            $outputStream = [IO.File]::Create($destination)
            try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose(); $inputStream.Dispose() }
            if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected[$name].sha256) {
                throw "Unpacked file is damaged: $name"
            }
            Write-FileProgress 'Extracting and verifying' $seen.Count $expected.Count $clock ([ref]$lastShown)
        }
        if ($seen.Count -ne $expected.Count) { throw 'ZIP package is incomplete' }
    } finally { $zip.Dispose() }
}

function Commit-PackFiles([string]$Root, [string]$Stage, $Manifest) {
    $operations = New-Object Collections.ArrayList
    foreach ($directory in @('BepInEx/core', 'BepInEx/plugins', 'BepInEx/patchers')) {
        $source = Get-ContainedPath $Stage ('new/' + $directory)
        [IO.Directory]::CreateDirectory($source) | Out-Null
        [void]$operations.Add(@{ Relative=$directory; Source=$source; Old=$false; New=$false })
    }
    foreach ($package in $Manifest.packages) {
        foreach ($file in $package.files) {
            if ($file.path -match '^BepInEx/(core|plugins|patchers)/') { continue }
            $destination = Get-ContainedPath $Root $file.path
            if ($file.preserve -and (Test-Path -LiteralPath $destination -PathType Leaf)) { continue }
            [void]$operations.Add(@{ Relative=$file.path; Source=(Get-ContainedPath $Stage ('new/' + $file.path)); Old=$false; New=$false })
        }
    }
    $stateSource = Get-ContainedPath $Stage 'new-installed.json'
    [IO.File]::WriteAllText($stateSource, ($Manifest | ConvertTo-Json -Depth 15), (New-Object Text.UTF8Encoding($false)))
    [void]$operations.Add(@{ Relative='.valheim-modpack/installed.json'; Source=$stateSource; Old=$false; New=$false })
    try {
        foreach ($op in $operations) {
            $destination = Get-ContainedPath $Root $op.Relative
            $old = Get-ContainedPath $Stage ('old/' + $op.Relative)
            Assert-PlainPath $destination $Root
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
            if (Test-Path -LiteralPath $destination) {
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($old)) | Out-Null
                Move-Item -LiteralPath $destination -Destination $old
                $op.Old = $true
            }
            Move-Item -LiteralPath $op.Source -Destination $destination
            $op.New = $true
        }
    } catch {
        $failure = $_
        try {
            for ($i=$operations.Count-1; $i -ge 0; $i--) {
                $op = $operations[$i]
                $destination = Get-ContainedPath $Root $op.Relative
                $old = Get-ContainedPath $Stage ('old/' + $op.Relative)
                if ($op.New -and (Test-Path -LiteralPath $destination)) { Remove-Item -LiteralPath $destination -Recurse -Force }
                if ($op.Old) { Move-Item -LiteralPath $old -Destination $destination }
            }
        } catch {
            $recovery = New-Object IO.IOException("Automatic rollback failed. Recovery files remain in $Stage")
            $recovery.Data['MidgardRecoveryPath'] = $Stage
            throw $recovery
        }
        throw $failure
    }
}

function Invoke-PackUpdate([string]$Root, [string]$Source, [bool]$Local, [bool]$SkipLaunch) {
    $Root = [IO.Path]::GetFullPath($Root)
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'valheim.exe') -PathType Leaf)) { throw 'Put the launcher next to valheim.exe.' }
    Assert-PlainPath $Root $Root
    if ($script:PackId -eq 'ammatias-midgard' -and (Get-ChildItem -LiteralPath (Join-Path $Root 'BepInEx/plugins') -Filter 'Morgott.Core.dll' -Recurse -ErrorAction SilentlyContinue)) {
        throw 'Yggdrasil detected. Use a separate game folder for Midgard.'
    }
    if ($script:PackId -eq 'ammatias-helheim' -and
        ((Get-ChildItem -LiteralPath (Join-Path $Root 'BepInEx/plugins') -Filter 'PlanBuild.dll' -Recurse -ErrorAction SilentlyContinue) -or
         (Get-ChildItem -LiteralPath (Join-Path $Root 'BepInEx/plugins') -Filter 'Monstrum.dll' -Recurse -ErrorAction SilentlyContinue))) {
        throw 'Midgard mods detected. Use a separate game folder for Helheim.'
    }
    if (Get-Process -Name valheim, valheim_server -ErrorAction SilentlyContinue) { throw 'Close Valheim before updating mods.' }
    foreach ($directory in @('BepInEx/core', 'BepInEx/plugins', 'BepInEx/patchers', 'BepInEx/config')) {
        Assert-PlainTree (Get-ContainedPath $Root $directory) $Root
    }
    $installedState = Get-ContainedPath $Root '.valheim-modpack/installed.json'
    if (Test-Path -LiteralPath $installedState -PathType Leaf) {
        $previous = [IO.File]::ReadAllText($installedState) | ConvertFrom-Json
        if ($previous.pack_id -ne $script:PackId) { throw 'This game folder belongs to the other modpack. Use a separate folder.' }
    }
    $cache = Get-ContainedPath $Root '.valheim-modpack'
    Assert-PlainPath $cache $Root
    [IO.Directory]::CreateDirectory($cache) | Out-Null
    $lockPath = Get-ContainedPath $Root '.valheim-modpack/update.lock'
    $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $stage = Get-ContainedPath $Root ('.valheim-modpack/stage-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    $keepStage = $false
    try {
        Write-Host ('Checking for ' + $Pack + ' updates...') -ForegroundColor Cyan
        $manifestFile = Get-ContainedPath $stage 'manifest.json'
        $online = $true
        try { $manifest = Read-ReleaseManifest $Source $manifestFile $Local } catch {
            $installed = Get-ContainedPath $Root '.valheim-modpack/installed.json'
            if (-not (Test-Path -LiteralPath $installed -PathType Leaf)) { throw 'Cannot download the modpack manifest. Check your Internet connection.' }
            [IO.File]::Copy($installed, $manifestFile, $true)
            $manifest = [IO.File]::ReadAllText($manifestFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $online = $false
            Write-Host 'Updates are unavailable. Checking the installed modpack.' -ForegroundColor Yellow
        }
        Assert-Manifest $manifest $Root $Local
        $changed = New-Object Collections.ArrayList
        $fileCount = 0
        foreach ($package in $manifest.packages) { $fileCount += @($package.files).Count }
        $checked = 0
        $checkClock = [Diagnostics.Stopwatch]::StartNew()
        $lastShown = [long]0
        Write-FileProgress 'Checking installed files' 0 $fileCount $checkClock ([ref]$lastShown)
        foreach ($package in $manifest.packages) {
            $needed = $false
            foreach ($file in $package.files) {
                if (-not (Test-CurrentFile $Root $file)) { $needed=$true }
                $checked++
                Write-FileProgress 'Checking installed files' $checked $fileCount $checkClock ([ref]$lastShown)
            }
            if ($needed) { [void]$changed.Add($package) }
        }
        if (-not $online -and $changed.Count) { throw 'Installed files need repair, but the download source is offline.' }
        Write-Host ($Pack + ' ' + $manifest.version)
        $expectedNames = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($package in $manifest.packages) { foreach ($file in $package.files) { [void]$expectedNames.Add($file.path) } }
        $extraFiles = $false
        foreach ($directory in @('BepInEx/core', 'BepInEx/plugins', 'BepInEx/patchers')) {
            $path = Get-ContainedPath $Root $directory
            if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
            foreach ($file in @(Get-ChildItem -LiteralPath $path -Recurse -File -Force)) {
                $relative = $file.FullName.Substring($Root.TrimEnd([IO.Path]::DirectorySeparatorChar).Length + 1).Replace([IO.Path]::DirectorySeparatorChar, '/')
                if (-not $expectedNames.Contains($relative) -and $file.Name -ne 'passwords.json') { $extraFiles = $true }
            }
        }
        if ($changed.Count -eq 0 -and -not $extraFiles) {
            Write-Host 'Already up to date. No download needed.' -ForegroundColor Green
            $stateFile = Get-ContainedPath $stage 'installed.json'
            [IO.File]::WriteAllText($stateFile, ($manifest | ConvertTo-Json -Depth 15), (New-Object Text.UTF8Encoding($false)))
            Move-Item -LiteralPath $stateFile -Destination (Get-ContainedPath $Root '.valheim-modpack/installed.json') -Force
        } else {
        $new = Get-ContainedPath $stage 'new'
        [IO.Directory]::CreateDirectory($new) | Out-Null
        if ($changed.Count -eq 0) { Write-Host 'Preparing installed files...' }
        foreach ($package in $manifest.packages) {
            if ($changed -contains $package) {
                $zipPath = Get-ContainedPath $stage ($package.id + '.zip')
                Get-SourceFile $package.url $zipPath $Local $package.bytes ('Downloading ' + $Pack)
                Expand-VerifiedPackage $zipPath $package $new
            } else {
                foreach ($file in $package.files) {
                    if ($file.preserve) { continue }
                    $sourcePath = Get-ContainedPath $Root $file.path
                    $target = Get-ContainedPath $new $file.path
                    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
                    [IO.File]::Copy($sourcePath, $target, $true)
                }
            }
        }
        # Recheck staged managed files before changing the installed folders.
        $checked = 0
        $checkClock.Restart()
        $lastShown = [long]0
        Write-FileProgress 'Checking prepared files' 0 $fileCount $checkClock ([ref]$lastShown)
        foreach ($package in $manifest.packages) {
            foreach ($file in $package.files) {
                if (-not ($file.preserve -and (Test-Path -LiteralPath (Get-ContainedPath $Root $file.path) -PathType Leaf))) {
                    if (-not (Test-CurrentFile $new $file)) { throw "Staged file check failed: $($file.path)" }
                }
                $checked++
                Write-FileProgress 'Checking prepared files' $checked $fileCount $checkClock ([ref]$lastShown)
            }
        }
        # AutoServerPassword can keep its local store beside the plugin.
        $oldPlugins = Get-ContainedPath $Root 'BepInEx/plugins'
        if (Test-Path -LiteralPath $oldPlugins -PathType Container) {
            foreach ($passwordFile in @(Get-ChildItem -LiteralPath $oldPlugins -Filter 'passwords.json' -File -Recurse)) {
                $relative = $passwordFile.FullName.Substring($Root.TrimEnd([IO.Path]::DirectorySeparatorChar).Length + 1).Replace([IO.Path]::DirectorySeparatorChar, '/')
                $target = Get-ContainedPath $new $relative
                if (Test-Path -LiteralPath $target) { throw 'A published package must not replace saved passwords.' }
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
                [IO.File]::Copy($passwordFile.FullName, $target, $false)
            }
        }
        Write-Host 'Installing verified files...'
        Commit-PackFiles $Root $stage $manifest
        }
        Write-Host 'Valheim modpack is ready.' -ForegroundColor Green
    } catch {
        if ($_.Exception.Data.Contains('MidgardRecoveryPath')) { $keepStage = $true }
        throw
    } finally {
        if (-not $keepStage -and (Test-Path -LiteralPath $stage)) { Remove-Item -LiteralPath $stage -Recurse -Force }
        $lock.Dispose()
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
    if (-not $SkipLaunch) {
        Write-Host 'Starting Valheim...' -ForegroundColor Cyan
        $env:SteamAppId = '892970'
        $env:SteamGameId = '892970'
        Start-Process -FilePath (Join-Path $Root 'valheim.exe') -WorkingDirectory $Root
    }
}

if (-not $LibraryOnly) { Invoke-PackUpdate $GameDirectory $ManifestUri ([bool]$AllowLocalSource) ([bool]$NoLaunch) }
