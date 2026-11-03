# install-coop-re7.ps1: one-click setup for the coop-re7 Resident Evil 7 co-op mod.
#
#  1. Finds RE7 in your Steam libraries and copies it to a separate co-op folder
#     (your normal install is never modified).
#  2. Downloads REFramework and its C# add-on from the official release and checks
#     each file's SHA-256 before using it.
#  3. Installs the co-op files from this kit, keeping any friend ID you already set.
#  4. Backs up your RE7 saves.
#  5. Creates "Start RE7 Co-op" (in the co-op folder and on your desktop).
#
# Run it with Install.cmd (double-click). Options for advanced use:
#   -Destination <folder>   where the co-op copy goes (default: Documents\RE7-coop, or C:\RE7-coop
#                           when Documents is synced by OneDrive)
#   -GameSource <folder>    RE7 folder to copy from (default: found in Steam)
#   -NoGameCopy             only (re)install the mod files into an existing co-op folder
#   -BackupDir <folder>     where save backups go (default: next to the co-op folder)

param(
    [string]$Destination = "",
    [string]$GameSource = "",
    [switch]$NoGameCopy,
    [string]$BackupDir = "",
    [switch]$NoShortcut
)

$ErrorActionPreference = "Stop"

# OneDrive moves big files online-only (or never finishes uploading them), which leaves the
# game copy incomplete: it starts, but the world renders black. Keep it out of OneDrive.
$Base = [Environment]::GetFolderPath("MyDocuments")
if ($Base -match "OneDrive") { $Base = $env:SystemDrive + "\" }
if ($Destination -eq "") { $Destination = Join-Path $Base "RE7-coop" }
if ($BackupDir -eq "") { $BackupDir = Join-Path $Base "RE7-coop-save-backups" }
if ($Destination -match "OneDrive") {
    Write-Host "FAILED: $Destination is inside OneDrive; pick a folder outside it with -Destination" -ForegroundColor Red
    exit 1
}
$Kit = Split-Path -Parent $MyInvocation.MyCommand.Path

# Pinned, verified REFramework nightly (supports the current RT build of RE7).
$Release = "https://github.com/praydog/REFramework-nightly/releases/download/nightly-01433-d4611aef1d63effd3a736bdf9404ea702428017d"
$Downloads = @(
    @{ Name = "REFramework.zip"; Sha = "b3ff4f497be6f108ef494c2c02156b61b8d04f3171378ecc0dc28c218ee296b3" },
    @{ Name = "csharp-api.zip";  Sha = "87a909fedbec028ccd7017cc1dfb671d9f4206f07520bcb114fc6ecd74e8629b" }
)
$AppId = "418370"

function Step($n, $text) { Write-Host ""; Write-Host "[$n/6] $text" -ForegroundColor Cyan }
function Ok($text) { Write-Host "      OK  $text" -ForegroundColor Green }
function Warn($text) { Write-Host "      !!  $text" -ForegroundColor Yellow }
function Fail($text) { Write-Host ""; Write-Host "FAILED: $text" -ForegroundColor Red; exit 1 }

Write-Host "coop-re7 installer" -ForegroundColor White
Write-Host "Co-op folder: $Destination"

# ---------------------------------------------------------------- 1. checks
Step 1 "Checking your PC"
$runtimes = ""
try { $runtimes = (& dotnet --list-runtimes) -join "`n" } catch { }
if ($runtimes -match "Microsoft\.NETCore\.App 10\.") { Ok ".NET 10 runtime found" }
else {
    Warn ".NET 10 runtime not found. The co-op network plugin needs it."
    Warn "Install '.NET Runtime 10' (Windows x64) from https://dotnet.microsoft.com/download/dotnet/10.0"
    Warn "and run this installer again. (Continuing; everything else will be set up.)"
}

function Find-RE7 {
    $steam = $null
    try { $steam = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction Stop).SteamPath } catch { }
    if (-not $steam) { $steam = "${env:ProgramFiles(x86)}\Steam" }
    $libs = @($steam)
    $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
    if (Test-Path $vdf) {
        foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += $m.Groups[1].Value -replace '\\\\', '\' }
    }
    foreach ($lib in ($libs | Select-Object -Unique)) {
        $p = Join-Path $lib "steamapps\common\RESIDENT EVIL 7 biohazard"
        if (Test-Path (Join-Path $p "re7.exe")) { return @{ Game = $p; Steam = $steam; Lib = $lib } }
    }
    return @{ Game = $null; Steam = $steam; Lib = $null }
}
$found = Find-RE7
if (-not $GameSource) { $GameSource = $found.Game }
if (-not $NoGameCopy) {
    if (-not $GameSource -or -not (Test-Path (Join-Path $GameSource "re7.exe"))) {
        Fail "Couldn't find Resident Evil 7 in your Steam libraries. Install it from Steam first (or pass -GameSource)."
    }
    Ok "RE7 found: $GameSource"
}
# RE7 has two Steam versions: the current ray-tracing (RT) build, and the older DX11 one
# on the "dx11_non-rt" beta branch. REFramework detects either; coop-re7 is tested on RT.
if ($found.Lib) {
    $acf = Join-Path $found.Lib "steamapps\appmanifest_$AppId.acf"
    if ((Test-Path $acf) -and ((Get-Content $acf -Raw) -match '"BetaKey"\s+"([^"]+)"')) {
        Warn "Your RE7 is on the Steam beta branch '$($Matches[1])' (the older non-RT version)."
        Warn "coop-re7 is tested on the current (RT) version. It should work, but if the other player"
        Warn "doesn't appear, switch RE7 back to 'None' under Properties > Betas in Steam and reinstall."
        Warn "Both players can be on different versions."
    }
}

# ---------------------------------------------------------------- 2. game copy
Step 2 "Copying the game to the co-op folder (your normal install is not changed)"
if ($NoGameCopy) {
    if (-not (Test-Path (Join-Path $Destination "re7.exe"))) { Fail "-NoGameCopy was given but $Destination has no re7.exe" }
    Ok "using the existing copy in $Destination"
} else {
    $size = (Get-ChildItem $GameSource -Recurse -File | Measure-Object Length -Sum).Sum
    $drive = Get-PSDrive -Name ([IO.Path]::GetPathRoot((New-Item -ItemType Directory -Force $Destination).FullName).Substring(0, 1))
    if ($drive.Free -lt ($size + 2GB)) {
        Fail ("Not enough free space on {0}: need {1:N1} GB, have {2:N1} GB" -f $drive.Name, (($size + 2GB) / 1GB), ($drive.Free / 1GB))
    }
    Write-Host ("      copying {0:N1} GB, this can take a while..." -f ($size / 1GB))
    robocopy $GameSource $Destination /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NP /MT:8 | Out-Null
    if ($LASTEXITCODE -ge 8) { Fail "copying the game failed (robocopy exit $LASTEXITCODE)" }
    Ok "game copied"
}
Set-Content -Path (Join-Path $Destination "steam_appid.txt") -Value $AppId -Encoding Ascii
Ok "steam_appid.txt written (lets the copy start outside Steam's library)"

# ---------------------------------------------------------------- 3. REFramework
Step 3 "Downloading REFramework (official release, hash-checked)"
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("coop-re7-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force $tmp | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($d in $Downloads) {
    $file = Join-Path $tmp $d.Name
    Invoke-WebRequest -UseBasicParsing -Uri "$Release/$($d.Name)" -OutFile $file
    $hash = (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $d.Sha) { Fail "$($d.Name) failed its integrity check (got $hash). Nothing was installed from it." }
    Ok "$($d.Name) verified"
}
# Only dinput8.dll from REFramework.zip (the other files are for VR and can cause issues).
$zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $tmp "REFramework.zip"))
try {
    $entry = $zip.Entries | Where-Object { $_.FullName -eq "dinput8.dll" }
    if (-not $entry) { Fail "dinput8.dll not found in REFramework.zip" }
    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $Destination "dinput8.dll"), $true)
} finally { $zip.Dispose() }
Expand-Archive -Path (Join-Path $tmp "csharp-api.zip") -DestinationPath $Destination -Force
Remove-Item $tmp -Recurse -Force
Ok "REFramework + C# add-on installed"

# ---------------------------------------------------------------- 4. mod files
Step 4 "Installing the co-op files"
$src = Join-Path $Kit "reframework"
if (-not (Test-Path $src)) { Fail "this kit's reframework folder is missing (run the installer from the unpacked kit)" }
$config = Join-Path $Destination "reframework\data\coopnet_config.json"
$keepConfig = Test-Path $config
Get-ChildItem $src -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($src.Length + 1)
    $to = Join-Path (Join-Path $Destination "reframework") $rel
    if ($keepConfig -and $rel -eq "data\coopnet_config.json") { return }   # keep the friend ID already set
    New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
    Copy-Item $_.FullName $to -Force
}
Ok ("co-op scripts and network plugin installed" + $(if ($keepConfig) { " (kept your existing settings)" } else { "" }))

# ---------------------------------------------------------------- 5. saves
Step 5 "Backing up your RE7 saves"
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$userdata = Join-Path $found.Steam "userdata"
$any = $false
if (Test-Path $userdata) {
    foreach ($u in Get-ChildItem $userdata -Directory) {
        $remote = Join-Path $u.FullName "$AppId\remote"
        if (Test-Path $remote) {
            $to = Join-Path $BackupDir "$stamp\$($u.Name)"
            New-Item -ItemType Directory -Force $to | Out-Null
            Copy-Item "$remote\*" $to -Recurse -Force
            $any = $true
        }
    }
}
if ($any) { Ok "saves backed up to $BackupDir\$stamp" } else { Warn "no RE7 saves found yet (fine if you haven't played)" }

# ---------------------------------------------------------------- 6. launcher
Step 6 "Creating the launcher"
$launcher = Join-Path $Destination "Start RE7 Co-op.cmd"
Set-Content -Path $launcher -Encoding Ascii -Value "@echo off`r`ncd /d `"%~dp0`"`r`nstart `"`" `"%~dp0re7.exe`""
Ok "Start RE7 Co-op.cmd created"
if (-not $NoShortcut) {
    try {
        $lnk = Join-Path ([Environment]::GetFolderPath("Desktop")) "Start RE7 Co-op.lnk"
        $sh = New-Object -ComObject WScript.Shell
        $s = $sh.CreateShortcut($lnk)
        $s.TargetPath = Join-Path $Destination "re7.exe"
        $s.WorkingDirectory = $Destination
        $s.Save()
        Ok "desktop shortcut created"
    } catch { Warn "couldn't create the desktop shortcut; use Start RE7 Co-op.cmd in $Destination" }
}

Write-Host ""
Write-Host "All done." -ForegroundColor Green
Write-Host "1. Start Steam, then launch 'Start RE7 Co-op' and load a save."
Write-Host "2. Press Insert. In the RE7 Co-op window, open 'Connect, saving and display'."
Write-Host "3. Click Connect next to your friend's name; they click Accept."
