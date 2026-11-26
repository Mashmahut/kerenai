# kerenai: Claude Code setup for Windows
#
# Installs (skips anything already installed):
#   Git, Node.js LTS, GitHub CLI, Google Chrome        (one admin prompt)
#   VS Code, Claude Code, Claude Desktop app,
#   Claude Code extension for VS Code                  (as the normal user)
# Connects:
#   GitHub account (browser login) and Git name/email
#
# Run:   the one-line command in README.md, or double-click install.bat
# Check: double-click check.bat   (reports status, changes nothing)
#
# Only official sources are used: winget (Microsoft), the vendors' own
# download servers, and the official Claude Code installer (claude.ai).
# This file must stay ASCII-only: Windows PowerShell 5.1 misreads UTF-8
# files without a BOM.

param(
    [switch]$Check,
    [switch]$AdminPart,
    [string]$LogDir
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar on PS 5.1
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

if (-not $LogDir) { $LogDir = Join-Path $env:USERPROFILE 'claude-setup-logs' }
if ($Check) {
    $Script:LogFile = $null   # check mode writes nothing to disk
} else {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    if ($AdminPart) { $Script:LogFile = Join-Path $LogDir 'admin.log' } else { $Script:LogFile = Join-Path $LogDir 'setup.log' }
}

if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { $Script:Arch = 'arm64' } else { $Script:Arch = 'x64' }

$Script:ChromeExtensionUrl = 'https://chromewebstore.google.com/detail/claude/fcoeoabgfenejglbffodgkkbkcdhcgfn'
$Script:ClaudeExtensionId = 'anthropic.claude-code'
$Script:RtlExtensionId = 'yechielby.claude-code-rtl'   # Hebrew right-to-left in the Claude Code panel

# ============================================================
# Output and logging
# ============================================================

function Write-Log([string]$Text) {
    if (-not $Script:LogFile) { return }
    try { Add-Content -Path $Script:LogFile -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text) -Encoding UTF8 } catch {}
}
function Say([string]$Text, [string]$Color = 'White') { Write-Host $Text -ForegroundColor $Color; Write-Log $Text }
function Step([string]$Num, [string]$Text) { Write-Host ''; Say "[$Num] $Text" 'Cyan' }
function Ok([string]$Text)   { Say "    [OK]   $Text" 'Green' }
function Skip([string]$Text) { Say "    [SKIP] $Text" 'DarkGray' }
function Warn([string]$Text) { Say "    [!!]   $Text" 'Yellow' }
function Fail([string]$Text) { Say "    [FAIL] $Text" 'Red' }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ============================================================
# PATH and detection
# ============================================================

function Update-SessionPath {
    $parts = @()
    foreach ($scope in 'Machine', 'User') {
        $p = [Environment]::GetEnvironmentVariable('Path', $scope)
        if ($p) { $parts += $p.Split(';') }
    }
    $extra = @(
        (Join-Path $env:USERPROFILE '.local\bin'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin'),
        (Join-Path $env:ProgramFiles 'Git\cmd'),
        (Join-Path $env:ProgramFiles 'nodejs'),
        (Join-Path $env:APPDATA 'npm'),
        (Join-Path $env:ProgramFiles 'GitHub CLI')
    )
    $parts += ($extra | Where-Object { Test-Path $_ })
    $seen = @{}
    $clean = foreach ($x in $parts) {
        $t = "$x".Trim()
        if ($t -and -not $seen.ContainsKey($t.ToLower())) { $seen[$t.ToLower()] = $true; $t }
    }
    $env:Path = ($clean -join ';')
}

function Find-Exe([string]$Name, [string[]]$Candidates) {
    foreach ($c in $Candidates) { if ($c -and (Test-Path $c)) { return $c } }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-GitExe  { Find-Exe 'git' @("$env:ProgramFiles\Git\cmd\git.exe", "${env:ProgramFiles(x86)}\Git\cmd\git.exe", "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe") }
function Get-GhExe   { Find-Exe 'gh'  @("$env:ProgramFiles\GitHub CLI\gh.exe", "${env:ProgramFiles(x86)}\GitHub CLI\gh.exe") }
function Get-CodeCmd { Find-Exe 'code' @("$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd", "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd") }

function Get-ChromeExe {
    foreach ($c in @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                     "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
                     "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

function Get-NodeInfo {
    $exe = Find-Exe 'node' @("$env:ProgramFiles\nodejs\node.exe")
    if (-not $exe) { return @{ Present = $false; Version = ''; Major = 0 } }
    $v = $null
    try { $v = & $exe -v 2>$null | Select-Object -First 1 } catch {}
    $major = 0
    if ("$v" -match '^v?(\d+)\.') { $major = [int]$Matches[1] }
    return @{ Present = $true; Version = "$v".Trim(); Major = $major }
}

# Returns the version only if claude really runs. A broken npm install can
# leave a 'claude' on PATH that throws instead of running.
function Get-ClaudeCodeVersion {
    $exe = Find-Exe 'claude' @("$env:USERPROFILE\.local\bin\claude.exe")
    if (-not $exe) { return $null }
    try {
        # npm installs a claude.ps1 wrapper that does not set an exit code,
        # so a printed version number is the proof that it runs
        $v = & $exe --version 2>$null | Select-Object -First 1
        if ("$v" -match '\d+\.\d+\.\d+') { return "$v".Trim() }
    } catch { Write-Log "claude --version failed: $($_.Exception.Message)" }
    return $null
}

# Reads the user's package list from the registry instead of Get-AppxPackage:
# Get-AppxPackage waits on the AppX service and can hang forever when that
# service is stuck (seen on a real machine with AppXSvc in StopPending).
function Test-ClaudeDesktop {
    $repo = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages'
    try {
        $pkg = Get-ChildItem -Path $repo -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'Claude_*' }
        if ($pkg) { return $true }
    } catch {}
    if (Test-Path (Join-Path $env:LOCALAPPDATA 'AnthropicClaude')) { return $true }   # older non-Store installer
    return $false
}

function Test-VSCodeExtension([string]$Id) {
    $code = Get-CodeCmd
    if (-not $code) { return $false }
    try {
        $list = & $code --list-extensions 2>$null
        return ($list -contains $Id)
    } catch { return $false }
}

function Test-ClaudeExtension { return (Test-VSCodeExtension $Script:ClaudeExtensionId) }
function Test-RtlExtension    { return (Test-VSCodeExtension $Script:RtlExtensionId) }

function Test-GitHubLogin {
    $gh = Get-GhExe
    if (-not $gh) { return $false }
    & $gh auth status --hostname github.com *> $null
    return ($LASTEXITCODE -eq 0)
}

function Get-GitIdentity {
    $git = Get-GitExe
    if (-not $git) { return @{ Name = ''; Email = '' } }
    $n = & $git config --global user.name 2>$null
    $e = & $git config --global user.email 2>$null
    return @{ Name = "$n".Trim(); Email = "$e".Trim() }
}

# Projects live outside OneDrive: Windows 11 often syncs Documents and the
# Desktop, and syncing .git or node_modules folders breaks things.
function Get-ProjectsDir {
    if ($env:USERPROFILE -match '^[\x21-\x7E]+$') { return (Join-Path $env:USERPROFILE 'Projects') }
    return 'C:\Projects'   # user folder has spaces or non-English letters
}

# ============================================================
# Download and install helpers
# ============================================================

function Get-Winget {
    $w = Get-Command winget -ErrorAction SilentlyContinue
    if ($w) { return $w.Source }
    try {
        # On a brand-new account winget may exist but not be registered yet
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop
        Start-Sleep -Seconds 3
    } catch { Write-Log "winget registration failed: $($_.Exception.Message)" }
    $w = Get-Command winget -ErrorAction SilentlyContinue
    if ($w) { return $w.Source }
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path $alias) { return $alias }
    return $null
}

function Install-WithWinget([string]$Id, [string[]]$ExtraArgs = @()) {
    $wg = Get-Winget
    if (-not $wg) { Write-Log "winget not available, cannot install $Id"; return }
    $wargs = @('install', '--id', $Id, '-e', '--source', 'winget',
               '--accept-package-agreements', '--accept-source-agreements',
               '--silent', '--disable-interactivity') + $ExtraArgs
    Write-Log ("winget " + ($wargs -join ' '))
    try {
        $out = & $wg @wargs 2>&1 | Out-String
        Write-Log $out
        Write-Log "winget exit code: $LASTEXITCODE"
    } catch { Write-Log "winget failed: $($_.Exception.Message)" }
}

function Save-Download([string]$Url, [string]$FileName) {
    $dest = Join-Path $env:TEMP $FileName
    Write-Log "Downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $dest -UseBasicParsing -ErrorAction Stop
    return $dest
}

function Get-GitHubReleaseAsset([string]$Repo, [string]$Pattern) {
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing -ErrorAction Stop
    $asset = $rel.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
    if (-not $asset) { throw "No file matching $Pattern in the latest $Repo release" }
    return $asset.browser_download_url
}

function Invoke-Msi([string]$File) {
    $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$File`" /qn /norestart" -Wait -PassThru -ErrorAction Stop
    Write-Log "msiexec exit code: $($p.ExitCode)"
}

# ============================================================
# Admin part: machine-wide tools (runs in the elevated window)
# ============================================================

function Install-Git {
    Step '1/7' 'Git'
    if (Get-GitExe) { Skip 'Git is already installed'; return }
    Say '    Installing Git (1-3 minutes)...'
    Install-WithWinget 'Git.Git'
    Update-SessionPath
    if (-not (Get-GitExe)) {
        try {
            if ($Script:Arch -eq 'arm64') { $pattern = '^Git-[\d\.]+-arm64\.exe$' } else { $pattern = '^Git-[\d\.]+-64-bit\.exe$' }
            $file = Save-Download (Get-GitHubReleaseAsset 'git-for-windows/git' $pattern) 'git-setup.exe'
            $p = Start-Process -FilePath $file -ArgumentList '/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/SUPPRESSMSGBOXES' -Wait -PassThru -ErrorAction Stop
            Write-Log "Git installer exit code: $($p.ExitCode)"
            Remove-Item $file -Force -ErrorAction SilentlyContinue
        } catch { Write-Log "Git direct download failed: $($_.Exception.Message)" }
        Update-SessionPath
    }
    if (Get-GitExe) { Ok 'Git installed' } else { Fail 'Git was not installed. Manual: https://git-scm.com/download/win' }
}

function Install-Node {
    Step '1/7' 'Node.js (LTS)'
    $node = Get-NodeInfo
    if ($node.Present) {
        if ($node.Major -ge 20) { Skip "Node.js $($node.Version) is already installed" }
        else { Warn "Node.js $($node.Version) is old. Left as is - update it later from https://nodejs.org" }
        return
    }
    Say '    Installing Node.js (1-2 minutes)...'
    Install-WithWinget 'OpenJS.NodeJS.LTS'
    Update-SessionPath
    if (-not (Get-NodeInfo).Present) {
        try {
            $index = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -UseBasicParsing -ErrorAction Stop
            $lts = $index | Where-Object { $_.lts } | Select-Object -First 1
            $file = Save-Download "https://nodejs.org/dist/$($lts.version)/node-$($lts.version)-$($Script:Arch).msi" 'node-setup.msi'
            Invoke-Msi $file
            Remove-Item $file -Force -ErrorAction SilentlyContinue
        } catch { Write-Log "Node.js direct download failed: $($_.Exception.Message)" }
        Update-SessionPath
    }
    $node = Get-NodeInfo
    if ($node.Present) { Ok "Node.js $($node.Version) installed" } else { Fail 'Node.js was not installed. Manual: https://nodejs.org' }
}

function Install-GhCli {
    Step '1/7' 'GitHub CLI'
    if (Get-GhExe) { Skip 'GitHub CLI is already installed'; return }
    Say '    Installing GitHub CLI...'
    Install-WithWinget 'GitHub.cli'
    Update-SessionPath
    if (-not (Get-GhExe)) {
        try {
            if ($Script:Arch -eq 'arm64') { $pattern = 'windows_arm64\.msi$' } else { $pattern = 'windows_amd64\.msi$' }
            $file = Save-Download (Get-GitHubReleaseAsset 'cli/cli' $pattern) 'gh-setup.msi'
            Invoke-Msi $file
            Remove-Item $file -Force -ErrorAction SilentlyContinue
        } catch { Write-Log "GitHub CLI direct download failed: $($_.Exception.Message)" }
        Update-SessionPath
    }
    if (Get-GhExe) { Ok 'GitHub CLI installed' } else { Fail 'GitHub CLI was not installed. Manual: https://cli.github.com' }
}

function Install-Chrome {
    Step '1/7' 'Google Chrome'
    if (Get-ChromeExe) { Skip 'Google Chrome is already installed'; return }
    Say '    Installing Google Chrome...'
    Install-WithWinget 'Google.Chrome'
    if (-not (Get-ChromeExe) -and $Script:Arch -eq 'x64') {
        try {
            $file = Save-Download 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi' 'chrome-setup.msi'
            Invoke-Msi $file
            Remove-Item $file -Force -ErrorAction SilentlyContinue
        } catch { Write-Log "Chrome direct download failed: $($_.Exception.Message)" }
    }
    if (Get-ChromeExe) { Ok 'Google Chrome installed' } else { Fail 'Chrome was not installed. Manual: https://www.google.com/chrome' }
}

# ============================================================
# User part: installs into the student's own account
# ============================================================

function Install-SystemTools {
    $missing = @()
    if (-not (Get-GitExe)) { $missing += 'Git' }
    if (-not (Get-NodeInfo).Present) { $missing += 'Node.js' }
    if (-not (Get-GhExe)) { $missing += 'GitHub CLI' }
    if (-not (Get-ChromeExe)) { $missing += 'Chrome' }

    Step '1/7' 'System tools: Git, Node.js, GitHub CLI, Chrome'
    if ($missing.Count -eq 0) { Skip 'All system tools are already installed'; return }

    Say ("    Missing: " + ($missing -join ', '))
    Say "    A Windows prompt will ask for permission. Click 'Yes'." 'Yellow'
    Say '    A second window opens and closes by itself when done.' 'Yellow'
    if (Test-Admin) {
        Install-Git; Install-Node; Install-GhCli; Install-Chrome
    }
    else {
        $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -AdminPart -LogDir `"$LogDir`""
        try {
            Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -Verb RunAs -Wait -ErrorAction Stop
        } catch {
            Fail "No permission was given, so Git, Node.js, GitHub CLI and Chrome were not installed."
            Warn 'Run the setup again and click Yes on the Windows prompt.'
            return
        }
    }
    Update-SessionPath
    foreach ($t in @(@('Git', (Get-GitExe)), @('Node.js', (Get-NodeInfo).Present), @('GitHub CLI', (Get-GhExe)), @('Chrome', (Get-ChromeExe)))) {
        if ($t[1]) { Ok "$($t[0]) ready" } else { Fail "$($t[0]) missing - see $Script:LogFile and $(Join-Path $LogDir 'admin.log')" }
    }
}

function Install-VSCode {
    Step '2/7' 'VS Code'
    if (Get-CodeCmd) { Skip 'VS Code is already installed'; return }
    Say '    Installing VS Code (1-2 minutes)...'
    Install-WithWinget 'Microsoft.VisualStudioCode' @('--scope', 'user', '--override', '/VERYSILENT /NORESTART /MERGETASKS=!runcode,addtopath')
    Update-SessionPath
    if (-not (Get-CodeCmd)) {
        try {
            $file = Save-Download "https://update.code.visualstudio.com/latest/win32-$($Script:Arch)-user/stable" 'vscode-setup.exe'
            $p = Start-Process -FilePath $file -ArgumentList '/VERYSILENT', '/NORESTART', '/MERGETASKS=!runcode,addtopath' -Wait -PassThru -ErrorAction Stop
            Write-Log "VS Code installer exit code: $($p.ExitCode)"
            Remove-Item $file -Force -ErrorAction SilentlyContinue
        } catch { Write-Log "VS Code direct download failed: $($_.Exception.Message)" }
        Update-SessionPath
    }
    if (Get-CodeCmd) { Ok 'VS Code installed' } else { Fail 'VS Code was not installed. Manual: https://code.visualstudio.com' }
}

function Install-ClaudeCode {
    Step '3/7' 'Claude Code'
    $v = Get-ClaudeCodeVersion
    if ($v) { Skip "Claude Code $v is already installed"; return }
    if (-not (Get-GitExe)) { Warn 'Git is missing. Claude Code on Windows needs Git to work properly.' }
    Say '    Installing Claude Code with the official installer from claude.ai...'
    $tmp = Join-Path $env:TEMP 'claude-code-install.ps1'
    try {
        Invoke-WebRequest -Uri 'https://claude.ai/install.ps1' -OutFile $tmp -UseBasicParsing -ErrorAction Stop
        # Separate process: the official script calls 'exit' on errors
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp 2>&1 | Out-String
        Write-Log $out
    } catch { Write-Log "Claude Code installer failed: $($_.Exception.Message)" }
    finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    Update-SessionPath
    $v = Get-ClaudeCodeVersion
    if ($v) { Ok "Claude Code $v installed" }
    else { Fail 'Claude Code was not installed. Manual, in PowerShell:  irm https://claude.ai/install.ps1 | iex' }
}

function Install-ClaudeDesktop {
    Step '4/7' 'Claude Desktop app'
    if (Test-ClaudeDesktop) { Skip 'Claude Desktop is already installed'; return }
    Say '    Installing the Claude Desktop app...'
    Install-WithWinget 'Anthropic.Claude'
    if (Test-ClaudeDesktop) { Ok 'Claude Desktop installed' } else { Fail 'Claude Desktop was not installed. Manual: https://claude.ai/download' }
}

function Install-ClaudeExtension {
    Step '5/7' 'Claude Code extension for VS Code, with Hebrew (RTL)'
    $code = Get-CodeCmd
    if (-not $code) { Fail 'VS Code not found, cannot add the extensions'; return }
    Install-VSCodeExtension $code $Script:ClaudeExtensionId 'Claude Code extension' 'Claude Code'
    Install-VSCodeExtension $code $Script:RtlExtensionId 'Hebrew (RTL) extension' 'Claude Code RTL'
    Set-VSCodeBasics
}

function Install-VSCodeExtension([string]$Code, [string]$Id, [string]$Label, [string]$SearchFor) {
    if (Test-VSCodeExtension $Id) { Skip "$Label is already installed"; return }
    try {
        $out = & $Code --install-extension $Id --force 2>&1 | Out-String
        Write-Log $out
    } catch { Write-Log "$Id install failed: $($_.Exception.Message)" }
    if (Test-VSCodeExtension $Id) { Ok "$Label installed" }
    else { Fail "$Label not installed. Manual: VS Code > Extensions (Ctrl+Shift+X) > search '$SearchFor'" }
}

# Adds two beginner-friendly settings. Never overrides a setting the user
# already has, and never rewrites a settings file it cannot read.
function Set-VSCodeBasics {
    $dir = Join-Path $env:APPDATA 'Code\User'
    $file = Join-Path $dir 'settings.json'
    $wanted = [ordered]@{ 'files.autoSave' = 'afterDelay'; 'editor.wordWrap' = 'on' }
    $obj = New-Object PSObject
    if (Test-Path $file) {
        $raw = [IO.File]::ReadAllText($file)
        if ($raw.Trim()) {
            try { $obj = $raw | ConvertFrom-Json -ErrorAction Stop }
            catch { Warn 'VS Code settings file has comments or a custom format - left untouched'; return }
        }
    }
    $changed = $false
    foreach ($k in $wanted.Keys) {
        if (-not ($obj.PSObject.Properties.Name -contains $k)) {
            $obj | Add-Member -NotePropertyName $k -NotePropertyValue $wanted[$k]
            $changed = $true
        }
    }
    if (-not $changed) { Skip 'VS Code auto-save and word wrap were already set'; return }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    [IO.File]::WriteAllText($file, ($obj | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
    Ok 'VS Code: auto-save and word wrap turned on'
}

function New-ProjectsFolder {
    Step '6/7' 'Projects folder'
    $dir = Get-ProjectsDir
    if (Test-Path $dir) { Skip "Projects folder already exists: $dir"; return }
    try {
        New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null
        Ok "Created $dir"
    } catch { Fail "Could not create $dir : $($_.Exception.Message)" }
}

function Connect-GitHub {
    Step '7/7' 'GitHub account and Git name/email'
    $gh = Get-GhExe
    if (-not $gh) { Fail 'GitHub CLI missing, cannot connect GitHub' }
    elseif (Test-GitHubLogin) {
        Skip 'GitHub is already connected'
        & $gh auth setup-git --hostname github.com *> $null
    }
    else {
        Write-Host ''
        Say '    Now we connect GitHub:' 'Yellow'
        Say '      1. Answer Y if asked "Authenticate Git with your GitHub credentials?"' 'Yellow'
        Say '      2. A one-time code is copied for you. Press Enter, a browser opens.' 'Yellow'
        Say '      3. Sign in to GitHub, paste the code (Ctrl+V), click Continue and Authorize.' 'Yellow'
        Write-Host ''
        & $gh auth login --hostname github.com --git-protocol https --web --clipboard
        if (Test-GitHubLogin) {
            & $gh auth setup-git --hostname github.com *> $null
            Ok 'Connected to GitHub'
        } else { Warn 'GitHub login not finished. Run the setup again later.' }
    }
    Set-GitIdentity
}

# Name and email stamped on every save point (commit). With GitHub connected
# we use the private no-reply address GitHub gives every account, so the
# student's real email never shows up in public projects.
function Set-GitIdentity {
    $git = Get-GitExe
    if (-not $git) { Fail 'Git missing, cannot set name and email'; return }
    $cur = Get-GitIdentity
    if ($cur.Name -and $cur.Email) { Skip "Git name and email already set ($($cur.Name))"; return }

    $login = $null; $id = $null; $ghName = $null
    $gh = Get-GhExe
    if ($gh -and (Test-GitHubLogin)) {
        try {
            $u = (& $gh api user 2>$null | Out-String) | ConvertFrom-Json
            $login = $u.login; $id = $u.id; $ghName = $u.name
        } catch { Write-Log "gh api user failed: $($_.Exception.Message)" }
    }

    $name = $cur.Name
    if (-not $name) { if ($ghName) { $name = $ghName } elseif ($login) { $name = $login } else { $name = Read-Host '    Your name for Git (English letters are best)' } }
    $email = $cur.Email
    if (-not $email) { if ($login -and $id) { $email = "$id+$login@users.noreply.github.com" } else { $email = Read-Host '    Your email for Git' } }

    if ($name)  { & $git config --global user.name "$name" }
    if ($email) { & $git config --global user.email "$email" }
    & $git config --global init.defaultBranch main
    if ($name -and $email) { Ok "Git name and email set: $name <$email>" } else { Warn 'Git name or email still missing' }
}

# ============================================================
# Summary (also what check.bat shows)
# ============================================================

function Show-Summary {
    Update-SessionPath
    $node = Get-NodeInfo
    $id = Get-GitIdentity
    $cc = Get-ClaudeCodeVersion
    $rows = @(
        @('Git',                     [bool](Get-GitExe)),
        @('Node.js',                 [bool]$node.Present),
        @('GitHub CLI',              [bool](Get-GhExe)),
        @('Google Chrome',           [bool](Get-ChromeExe)),
        @('VS Code',                 [bool](Get-CodeCmd)),
        @('Claude Code',             [bool]$cc),
        @('Claude Desktop app',      (Test-ClaudeDesktop)),
        @('Claude extension in VS Code', (Test-ClaudeExtension)),
        @('Hebrew (RTL) in VS Code', (Test-RtlExtension)),
        @('Projects folder',         (Test-Path (Get-ProjectsDir))),
        @('GitHub connected',        (Test-GitHubLogin)),
        @('Git name and email',      [bool]($id.Name -and $id.Email))
    )
    Write-Host ''
    Say '========================================' 'Cyan'
    Say '  Status' 'Cyan'
    Say '========================================' 'Cyan'
    $allOk = $true
    foreach ($r in $rows) {
        $label = $r[0].PadRight(30)
        if ($r[1]) { Say "  [OK] $label" 'Green' } else { Say "  [--] $label missing" 'Yellow'; $allOk = $false }
    }
    Write-Host ''
    Say "  Projects folder: $(Get-ProjectsDir)"
    if (-not $Check) { Say "  Log files:       $LogDir" }
    Write-Host ''
    Say '  Still done by hand (see the checklist):' 'White'
    Say '   - Sign in to Claude in VS Code and in the Claude Desktop app' 'White'
    Say '   - Add the Claude extension to Chrome and sign in' 'White'
    return $allOk
}

# ============================================================
# Main
# ============================================================

try {
    if ($AdminPart) {
        $Host.UI.RawUI.WindowTitle = 'kerenai: system tools'
        Say 'Installing system tools. This window closes by itself when done.' 'Cyan'
        Write-Log "=== Admin part started (arch $($Script:Arch)) ==="
        Install-Git; Install-Node; Install-GhCli; Install-Chrome
        Say 'Done. Closing in 5 seconds...' 'Green'
        Start-Sleep -Seconds 5
        exit 0
    }

    $Host.UI.RawUI.WindowTitle = 'kerenai setup'
    Write-Host ''
    Say '========================================' 'Magenta'
    Say '   kerenai: Claude Code setup for Windows' 'Magenta'
    Say '========================================' 'Magenta'
    Write-Log "=== Started. Check=$Check Arch=$($Script:Arch) Admin=$(Test-Admin) User=$env:USERNAME ==="

    if ($Check) {
        $null = Show-Summary
        exit 0
    }

    # Pre-flight
    $os = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
    Say "  Windows: $os ($($Script:Arch))" 'Gray'
    if (-not [Environment]::Is64BitOperatingSystem) { Fail 'This is 32-bit Windows. Claude Code needs 64-bit Windows.'; exit 1 }
    if ($Script:Arch -eq 'arm64') { Warn 'ARM processor detected (Snapdragon). Supported, but tell your teacher if something fails.' }
    if (Test-Admin) { Warn 'Running as administrator. Better: close this and run the setup again in a normal window.' }
    try { $null = Invoke-WebRequest -Uri 'https://api.github.com' -Method Head -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop }
    catch { if (-not $_.Exception.Response) { Fail 'No internet connection. Connect to the internet and run the setup again.'; exit 1 } }
    Say '  Existing installations are detected and skipped.' 'Gray'

    Install-SystemTools
    Install-VSCode
    Install-ClaudeCode
    Install-ClaudeDesktop
    Install-ClaudeExtension
    New-ProjectsFolder
    Connect-GitHub

    $allOk = Show-Summary
    Write-Host ''
    if ($allOk) { Say '  All done!' 'Green' } else { Say '  Some items are missing. Run the setup again; it only adds what is missing.' 'Yellow' }

    Write-Host ''
    $null = Read-Host '  Press Enter to open VS Code in the Projects folder'
    $code = Get-CodeCmd
    if ($code) {
        $codeExe = Join-Path (Split-Path (Split-Path $code)) 'Code.exe'
        if (Test-Path $codeExe) { Start-Process -FilePath $codeExe -ArgumentList "`"$(Get-ProjectsDir)`"" }
        else { Start-Process -FilePath $code -ArgumentList "`"$(Get-ProjectsDir)`"" }
    }
    $null = Read-Host '  Press Enter to open the Claude extension page in Chrome'
    $chrome = Get-ChromeExe
    if ($chrome) { Start-Process -FilePath $chrome -ArgumentList $Script:ChromeExtensionUrl } else { Start-Process $Script:ChromeExtensionUrl }
}
catch {
    Fail "Unexpected error: $($_.Exception.Message)"
    Write-Log $_.ScriptStackTrace
    Say "  Send this file to your teacher: $Script:LogFile" 'Yellow'
}
