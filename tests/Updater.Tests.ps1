param([string]$Updater = (Join-Path $PSScriptRoot '../Update-Valheim.ps1'))
$ErrorActionPreference = 'Stop'
. $Updater -LibraryOnly
$suite = Join-Path ([IO.Path]::GetTempPath()) ('midgard-tests-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($suite) | Out-Null
$script:passed = 0
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Throws([scriptblock]$Action, [string]$Message) {
    $failed = $false
    try { & $Action } catch { $failed = $true }
    Assert $failed $Message
}
function Write-File([string]$Path, [string]$Value) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Value)
}
function File-Uri([string]$Path) {
    $u = New-Object UriBuilder
    $u.Scheme='file'; $u.Host=''; $u.Path=[IO.Path]::GetFullPath($Path)
    return $u.Uri.AbsoluteUri
}
function Fixture([string]$Name, [string]$PackName = 'Midgard') {
    $folder = Join-Path $suite $Name
    $game = Join-Path $folder "Game with spaces and 'apostrophe'"
    [IO.Directory]::CreateDirectory($game) | Out-Null
    Write-File (Join-Path $game 'valheim.exe') 'FAKE GAME - NEVER EXECUTE'
    $source = Join-Path $folder 'source'
    [IO.Directory]::CreateDirectory($source) | Out-Null
    $files = @(
        @{ path='winhttp.dll'; data='loader'; preserve=$false },
        @{ path='doorstop_config.ini'; data='doorstop'; preserve=$false },
        @{ path='.doorstop_version'; data='version'; preserve=$false },
        @{ path='BepInEx/core/BepInEx.dll'; data='core'; preserve=$false },
        @{ path='BepInEx/core/BepInEx.Preloader.dll'; data='preloader'; preserve=$false },
        @{ path='BepInEx/core/0Harmony.dll'; data='harmony'; preserve=$false },
        @{ path='BepInEx/plugins/ValheimPlus.dll'; data='plugin'; preserve=$false },
        @{ path='BepInEx/config/mod.cfg'; data='default settings'; preserve=$true }
    )
    if ($PackName -eq 'Helheim') { $files += @{path='BepInEx/plugins/Morgott.Core/Morgott.Core.dll';data='morgott';preserve=$false} }
    $records = @()
    $zipPath = Join-Path $source 'component.zip'
    $stream = [IO.File]::Create($zipPath)
    $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in $files) {
            $bytes = [Text.Encoding]::UTF8.GetBytes($f.data)
            $entry = $zip.CreateEntry($f.path)
            $out = $entry.Open()
            try { $out.Write($bytes, 0, $bytes.Length) } finally { $out.Dispose() }
            $hash = [Security.Cryptography.SHA256]::Create()
            try { $sha = [BitConverter]::ToString($hash.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() } finally { $hash.Dispose() }
            $records += [pscustomobject]@{path=$f.path; bytes=$bytes.Length; sha256=$sha; preserve=$f.preserve}
        }
    } finally { $zip.Dispose(); $stream.Dispose() }
    $m = [pscustomobject]@{schema=1; pack_id=('ammatias-' + $PackName.ToLowerInvariant()); version='test-1'; packages=@(
        [pscustomobject]@{id='fixture'; sha256=(Get-FileHash -LiteralPath $zipPath).Hash.ToLowerInvariant();
            bytes=(Get-Item -LiteralPath $zipPath).Length; url=(File-Uri $zipPath); files=$records}
    )}
    $manifest = Join-Path $source 'manifest.json'
    [IO.File]::WriteAllText($manifest, ($m | ConvertTo-Json -Depth 10))
    return @{Game=$game; Manifest=$manifest; Zip=$zipPath; Data=$m; Root=$folder}
}
function Test([string]$Name, [scriptblock]$Action) {
    try { & $Action } catch { throw "Test '$Name' failed: $($_.Exception.Message)`n$($_.ScriptStackTrace)" }
    $script:passed++
    Write-Host "PASS $Name"
}
try {
    Test 'reject path traversal, ADS, Windows device names and absolute paths' {
        foreach ($name in @('../world/file', '/outside', 'C:/outside', 'BepInEx/a:stream', 'BepInEx/CON.txt', 'BepInEx/a./b', 'BepInEx\\plugins/x.dll')) {
            Throws { Get-ContainedPath $suite $name } "Accepted unsafe path $name"
        }
    }
    Test 'reject non-GitHub downloads and plaintext HTTP' {
        foreach ($uri in @('http://github.com/file', 'https://evil.example/file', 'file:///tmp/file')) {
            Throws { Assert-SourceUri $uri $false } "Accepted untrusted download $uri"
        }
    }
    Test 'install, preserve saves/settings/passwords, prune foreign DLL, no launch' {
        $f = Fixture 'install'
        Write-File (Join-Path $f.Game 'BepInEx/plugins/obsolete.dll') 'obsolete'
        Write-File (Join-Path $f.Game 'BepInEx/plugins/AutoServerPassword/passwords.json') 'private password fixture'
        Write-File (Join-Path $f.Game 'BepInEx/config/mod.cfg') 'my settings'
        Write-File (Join-Path $f.Game 'worlds_local/my-world.db') 'world data'
        Invoke-PackUpdate $f.Game (File-Uri $f.Manifest) $true $true
        Assert ((Get-Content -LiteralPath (Join-Path $f.Game 'BepInEx/config/mod.cfg') -Raw) -eq 'my settings') 'Settings overwritten'
        Assert ((Get-Content -LiteralPath (Join-Path $f.Game 'worlds_local/my-world.db') -Raw) -eq 'world data') 'World changed'
        Assert ((Get-Content -LiteralPath (Join-Path $f.Game 'BepInEx/plugins/AutoServerPassword/passwords.json') -Raw) -eq 'private password fixture') 'Saved password removed'
        Assert (-not (Test-Path -LiteralPath (Join-Path $f.Game 'BepInEx/plugins/obsolete.dll'))) 'Obsolete plugin remains'
        Assert ((Get-Content -LiteralPath (Join-Path $f.Game 'valheim.exe') -Raw) -eq 'FAKE GAME - NEVER EXECUTE') 'Game binary changed'
        Assert (@(Get-ChildItem -LiteralPath (Join-Path $f.Game '.valheim-modpack') -Filter 'stage-*').Count -eq 0) 'Staging left behind'
    }
    Test 'no package download when files match; launch offline verified installation' {
        $f = Fixture 'offline'
        Invoke-PackUpdate $f.Game (File-Uri $f.Manifest) $true $true
        $plugin = Join-Path $f.Game 'BepInEx/plugins/ValheimPlus.dll'
        $stamp = [IO.File]::GetLastWriteTimeUtc($plugin)
        Remove-Item -LiteralPath $f.Zip
        Invoke-PackUpdate $f.Game (File-Uri $f.Manifest) $true $true
        Assert ([IO.File]::GetLastWriteTimeUtc($plugin) -eq $stamp) 'Unchanged plugin was rewritten'
        Remove-Item -LiteralPath $f.Manifest
        Invoke-PackUpdate $f.Game (File-Uri $f.Manifest) $true $true
    }
    Test 'release pointer resolves the correct pack and caches the complete manifest' {
        $f=Fixture 'release-pointer'
        $pointer=Join-Path $f.Root 'latest.json'
        [IO.File]::WriteAllText($pointer,(@{schema=1;pack_id='ammatias-midgard';manifest_url=(File-Uri $f.Manifest)} | ConvertTo-Json))
        Invoke-PackUpdate $f.Game (File-Uri $pointer) $true $true
        $cached=Get-Content -LiteralPath (Join-Path $f.Game '.valheim-modpack/installed.json') -Raw | ConvertFrom-Json
        Assert ($cached.pack_id -eq 'ammatias-midgard' -and @($cached.packages).Count -eq 1) 'Incomplete pointer cached instead of manifest'
        Remove-Item -LiteralPath $f.Zip,$f.Manifest,$pointer
        Invoke-PackUpdate $f.Game (File-Uri $pointer) $true $true
    }
    Test 'release pointer cannot select the other pack' {
        $f=Fixture 'wrong-pointer'
        $pointer=Join-Path $f.Root 'latest.json'
        [IO.File]::WriteAllText($pointer,(@{schema=1;pack_id='ammatias-helheim';manifest_url=(File-Uri $f.Manifest)} | ConvertTo-Json))
        Throws { Invoke-PackUpdate $f.Game (File-Uri $pointer) $true $true } 'Wrong release pointer accepted'
        Assert (-not (Test-Path -LiteralPath (Join-Path $f.Game 'BepInEx/plugins'))) 'Wrong pointer modified plugins'
    }
    Test 'damaged download leaves installed files intact' {
        $f = Fixture 'damage'
        Write-File (Join-Path $f.Game 'BepInEx/plugins/old.dll') 'keep me'
        [IO.File]::WriteAllText($f.Zip, 'damaged download')
        Throws { Invoke-PackUpdate $f.Game (File-Uri $f.Manifest) $true $true } 'Corrupt package accepted'
        Assert ((Get-Content -LiteralPath (Join-Path $f.Game 'BepInEx/plugins/old.dll') -Raw) -eq 'keep me') 'Old plugin lost'
    }
    Test 'Yggdrasil folder rejected before any installed file changes' {
        $f = Fixture 'yggdrasil'
        Write-File (Join-Path $f.Game 'BepInEx/plugins/Morgott.Core/Morgott.Core.dll') 'yggdrasil'
        Throws { Invoke-PackUpdate $f.Game (File-Uri $f.Manifest) $true $true } 'Mixed Yggdrasil and Midgard'
        Assert (-not (Test-Path -LiteralPath (Join-Path $f.Game '.valheim-modpack'))) 'Wrong folder was modified'
    }
    Test 'install Helheim separately and reject Midgard in its folder' {
        $f=Fixture 'helheim' 'Helheim'
        $script:PackId='ammatias-helheim'
        try { Invoke-PackUpdate $f.Game (File-Uri $f.Manifest) $true $true } finally { $script:PackId='ammatias-midgard' }
        Assert (Test-Path -LiteralPath (Join-Path $f.Game 'BepInEx/plugins/Morgott.Core/Morgott.Core.dll')) 'Helheim plugin missing'
        Throws { Invoke-PackUpdate $f.Game (File-Uri $f.Manifest) $true $true } 'Mixed pack installation accepted'
    }
    Test 'Helheim refuses unmarked Midgard folder' {
        $f=Fixture 'unmarked-midgard' 'Helheim'
        Write-File (Join-Path $f.Game 'BepInEx/plugins/PlanBuild/PlanBuild.dll') 'midgard'
        $script:PackId='ammatias-helheim'
        try { Throws { Invoke-PackUpdate $f.Game (File-Uri $f.Manifest) $true $true } 'Midgard folder overwritten' } finally { $script:PackId='ammatias-midgard' }
        Assert (-not (Test-Path -LiteralPath (Join-Path $f.Game '.valheim-modpack'))) 'Wrong pack folder modified'
    }
    Test 'duplicate Windows paths in manifest rejected' {
        $f = Fixture 'duplicate'
        $f.Data.packages[0].files += $f.Data.packages[0].files[0]
        Throws { Assert-Manifest $f.Data $f.Game $true } 'Duplicate path accepted'
    }
    Test 'ZIP traversal rejected even when archive hash is valid' {
        $f = Fixture 'zip-traversal'
        $zip = [IO.Compression.ZipFile]::Open($f.Zip, [IO.Compression.ZipArchiveMode]::Update)
        try { $entry=$zip.CreateEntry('../escaped.txt'); $out=$entry.Open(); $out.WriteByte(65); $out.Dispose() } finally { $zip.Dispose() }
        $package=$f.Data.packages[0]
        $package.sha256=(Get-FileHash -LiteralPath $f.Zip).Hash.ToLowerInvariant()
        $package.bytes=(Get-Item -LiteralPath $f.Zip).Length
        $stage=Join-Path $f.Root 'zip-stage'; [IO.Directory]::CreateDirectory($stage) | Out-Null
        Throws { Expand-VerifiedPackage $f.Zip $package $stage } 'ZIP traversal accepted'
        Assert (-not (Test-Path -LiteralPath (Join-Path $f.Root 'escaped.txt'))) 'ZIP escaped staging'
    }
    Test 'linked game content is rejected without touching its target' {
        $f=Fixture 'linked-content'
        $outside=Join-Path $f.Root 'outside'; Write-File (Join-Path $outside 'keep.txt') 'untouched'
        $link=Join-Path $f.Game 'BepInEx/plugins/linked'
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($link)) | Out-Null
        $kind=if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'Junction' } else { 'SymbolicLink' }
        $null=New-Item -ItemType $kind -Path $link -Target $outside
        try {
            Throws { Invoke-PackUpdate $f.Game (File-Uri $f.Manifest) $true $true } 'Linked folder accepted'
            Assert ((Get-Content -LiteralPath (Join-Path $outside 'keep.txt') -Raw) -eq 'untouched') 'External file changed'
        } finally { [IO.Directory]::Delete($link) }
    }
    Test 'failed commit restores previous loader, mods and patchers' {
        $f = Fixture 'rollback'
        Write-File (Join-Path $f.Game 'BepInEx/core/original.dll') 'original core'
        Write-File (Join-Path $f.Game 'BepInEx/plugins/original.dll') 'original plugin'
        $stage = Join-Path $f.Game '.valheim-modpack/stage-fixture'
        Write-File (Join-Path $stage 'new/BepInEx/core/new.dll') 'new core'
        # The root loader source is intentionally absent: failure occurs after directory replacements.
        Throws { Commit-PackFiles $f.Game $stage $f.Data } 'Incomplete staged commit accepted'
        Assert ((Get-Content -LiteralPath (Join-Path $f.Game 'BepInEx/core/original.dll') -Raw) -eq 'original core') 'Core rollback failed'
        Assert ((Get-Content -LiteralPath (Join-Path $f.Game 'BepInEx/plugins/original.dll') -Raw) -eq 'original plugin') 'Plugin rollback failed'
    }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Test 'CMD bootstrap handles spaces and apostrophes and refuses the wrong pack' {
            $f=Fixture 'cmd-bootstrap'
            Write-File (Join-Path $f.Game 'BepInEx/plugins/Morgott.Core/Morgott.Core.dll') 'yggdrasil'
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../Midgard/Midgard-Modpack.bat') -Destination $f.Game
            Push-Location $f.Game
            try { $result=& cmd.exe /d /c 'Midgard-Modpack.bat <nul' 2>&1; $code=$LASTEXITCODE } finally { Pop-Location }
            Assert ($code -eq 1) 'Wrong-folder CMD bootstrap unexpectedly succeeded'
            Assert (($result -join "`n") -match 'Yggdrasil detected') 'CMD quoting failed before the pack guard'
            Assert (-not (Test-Path -LiteralPath (Join-Path $f.Game '.valheim-modpack'))) 'CMD modified a Yggdrasil folder'
        }
    }
    Write-Host "PASSED $script:passed tests"
} finally {
    if ($suite.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        try { Remove-Item -LiteralPath $suite -Recurse -Force } catch { Write-Warning ('Fixture cleanup: ' + $_.Exception.Message) }
    }
}
