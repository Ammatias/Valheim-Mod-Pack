@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "VALHEIM_PACK_ROOT=%~dp0"
if not exist "%~dp0valheim.exe" (
  echo Put Midgard-Modpack.bat next to valheim.exe in the Midgard game folder.
  pause
  exit /b 1
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "try { $ErrorActionPreference='Stop'; $root=$env:VALHEIM_PACK_ROOT; if (Get-ChildItem -LiteralPath (Join-Path $root 'BepInEx/plugins') -Filter 'Morgott.Core.dll' -Recurse -ErrorAction SilentlyContinue) { throw 'Yggdrasil detected. Use a separate game folder for Midgard.' }; [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; $cache=Join-Path $root '.valheim-modpack'; if ((Test-Path -LiteralPath $cache) -and (((Get-Item -LiteralPath $cache -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Linked updater cache is unsupported.' }; $state=Join-Path $cache 'installed.json'; if ((Test-Path -LiteralPath $state) -and ((Get-Content -LiteralPath $state -Raw | ConvertFrom-Json).pack_id -ne 'ammatias-midgard')) { throw 'This folder belongs to the other modpack. Use a separate game folder.' }; [IO.Directory]::CreateDirectory($cache) | Out-Null; $runner=Join-Path $cache 'Update-Valheim.ps1'; $tmp=Join-Path $cache ('runner-'+[guid]::NewGuid().ToString('N')+'.tmp'); try { $client=New-Object Net.WebClient; try { $client.DownloadFile('https://raw.githubusercontent.com/Ammatias/Valheim-Mod-Pack/main/Update-Valheim.ps1',$tmp) } finally { $client.Dispose() }; Move-Item -LiteralPath $tmp -Destination $runner -Force } catch { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp }; if (-not (Test-Path -LiteralPath $runner)) { throw }; Write-Host 'Updater is offline. Using the installed updater.' }; & $runner -GameDirectory $root -Pack 'Midgard' } catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }"
if errorlevel 1 (
  pause
  exit /b 1
)
exit /b 0
