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
$script:PackId = 'ammatias-' + $Pack.ToLowerInvariant()
if (-not $ManifestUri) { $ManifestUri = 'https://github.com/Ammatias/Valheim-Mod-Pack/releases/latest/download/' + $Pack.ToLowerInvariant() + '-manifest.json' }
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

function Get-SourceFile([string]$Uri, [string]$Destination, [bool]$Local) {
    Assert-SourceUri $Uri $Local
    if (([Uri]$Uri).IsFile) { [IO.File]::Copy(([Uri]$Uri).LocalPath, $Destination, $true); return }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $client = New-Object Net.WebClient
    $client.Headers['User-Agent'] = 'Ammatias-Midgard-Updater/1'
    try { $client.DownloadFile($Uri, $Destination) } finally { $client.Dispose() }
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
    if ((Get-Item -LiteralPath $path).Length -ne $File.bytes) { return $false }
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $File.sha256
}

function Expand-VerifiedPackage([string]$ArchivePath, $Package, [string]$Stage) {
    if ((Get-Item -LiteralPath $ArchivePath).Length -ne $Package.bytes -or
        (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Package.sha256) {
        throw "Downloaded package is damaged: $($Package.id)"
    }
    $expected = @{}
    foreach ($f in $Package.files) { $expected[$f.path] = $f }
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
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
        $manifestFile = Get-ContainedPath $stage 'manifest.json'
        $online = $true
        try { Get-SourceFile $Source $manifestFile $Local } catch {
            $installed = Get-ContainedPath $Root '.valheim-modpack/installed.json'
            if (-not (Test-Path -LiteralPath $installed -PathType Leaf)) { throw 'Cannot download the modpack manifest. Check your Internet connection.' }
            [IO.File]::Copy($installed, $manifestFile, $true)
            $online = $false
            Write-Host 'Updates are unavailable. Checking the installed modpack.' -ForegroundColor Yellow
        }
        $manifest = [IO.File]::ReadAllText($manifestFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
        Assert-Manifest $manifest $Root $Local
        $changed = New-Object Collections.ArrayList
        foreach ($package in $manifest.packages) {
            $needed = $false
            foreach ($file in $package.files) { if (-not (Test-CurrentFile $Root $file)) { $needed=$true } }
            if ($needed) { [void]$changed.Add($package) }
        }
        if (-not $online -and $changed.Count) { throw 'Installed files need repair, but the download source is offline.' }
        Write-Host ('Valheim ' + $manifest.version + ': ' + $changed.Count + ' component(s) to download.')
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
            $stateFile = Get-ContainedPath $stage 'installed.json'
            [IO.File]::WriteAllText($stateFile, ($manifest | ConvertTo-Json -Depth 15), (New-Object Text.UTF8Encoding($false)))
            Move-Item -LiteralPath $stateFile -Destination (Get-ContainedPath $Root '.valheim-modpack/installed.json') -Force
        } else {
        $new = Get-ContainedPath $stage 'new'
        [IO.Directory]::CreateDirectory($new) | Out-Null
        foreach ($package in $manifest.packages) {
            if ($changed -contains $package) {
                Write-Host ('Downloading ' + $package.id + '...')
                $zipPath = Get-ContainedPath $stage ($package.id + '.zip')
                Get-SourceFile $package.url $zipPath $Local
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
        foreach ($package in $manifest.packages) {
            foreach ($file in $package.files) {
                if ($file.preserve -and (Test-Path -LiteralPath (Get-ContainedPath $Root $file.path) -PathType Leaf)) { continue }
                if (-not (Test-CurrentFile $new $file)) { throw "Staged file check failed: $($file.path)" }
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
        $env:SteamAppId = '892970'
        $env:SteamGameId = '892970'
        Start-Process -FilePath (Join-Path $Root 'valheim.exe') -WorkingDirectory $Root
    }
}

if (-not $LibraryOnly) { Invoke-PackUpdate $GameDirectory $ManifestUri ([bool]$AllowLocalSource) ([bool]$NoLaunch) }
