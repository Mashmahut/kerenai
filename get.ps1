# kerenai: one-line setup for Windows
#
# Install (paste into a normal PowerShell window, not as administrator):
#   irm https://raw.githubusercontent.com/Mashmahut/kerenai/v1.0.1/get.ps1 | iex
#
# Status check only (changes nothing):
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Mashmahut/kerenai/v1.0.1/get.ps1))) -Check
#
# Downloads this exact version of the setup files from GitHub into a
# 'kerenai' folder and runs installer.ps1 from there. The installer must
# exist as a file because it re-launches itself for the admin prompt.
# Same method as the official Claude Code installer (irm ... | iex).
#
# This file must stay ASCII-only, and must never call 'exit':
# it runs inside the user's own PowerShell window.

param([switch]$Check)

& {
    param([bool]$CheckOnly)

    $Version = 'v1.0.1'    # the tag this file is published under
    $Repo = 'Mashmahut/kerenai'
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

    # Same rule as the Projects folder: no spaces or non-English letters in the path
    if ($env:USERPROFILE -match '^[\x21-\x7E]+$') { $dest = Join-Path $env:USERPROFILE 'kerenai' }
    else { $dest = 'C:\kerenai' }
    $tmp = Join-Path $env:TEMP ('kerenai-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

    Write-Host ''
    Write-Host "  kerenai $($Version): downloading the setup files..." -ForegroundColor Cyan
    try {
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        $zip = Join-Path $tmp 'kerenai.zip'
        Invoke-WebRequest -Uri "https://github.com/$Repo/archive/refs/tags/$Version.zip" -OutFile $zip -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        $src = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1
        if (-not $src -or -not (Test-Path (Join-Path $src.FullName 'installer.ps1'))) { throw 'installer.ps1 is missing from the download' }
        # Overwrite our own files only; anything else in the folder is left alone
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        Copy-Item -Path (Join-Path $src.FullName '*') -Destination $dest -Recurse -Force
    }
    catch {
        Write-Host "  Download failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '  Check the internet connection, then paste the same line again.' -ForegroundColor Yellow
        return
    }
    finally {
        Remove-Item -Recurse -Force -Path $tmp -ErrorAction SilentlyContinue
    }
    Write-Host "  Saved in $dest" -ForegroundColor Gray

    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $dest 'installer.ps1'))
    if ($CheckOnly) { $psArgs += '-Check' }
    & powershell.exe @psArgs
} $Check.IsPresent
