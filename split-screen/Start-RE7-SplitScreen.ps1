# Start-RE7-SplitScreen.ps1: two players on ONE PC. Two copies of RE7 + coop-re7 talk over 127.0.0.1 (the mod's
# "udp" mode), each copy gets one controller, and each player plays on their own screen (or half of one), borderless.
#
# Needs: coop-re7 installed with Install.cmd (the co-op folder), Steam running, two controllers that Windows sees as
# XInput pads 0 and 1 (Xbox pads, or PlayStation pads through DS4Windows / Steam Input).
#
# First time: double-click "Split screen setup.cmd" (= this script with -Setup). It copies the launcher next to the
# co-op folder, downloads Couchlink's input hook (pinned release, SHA-256 checked) and puts "RE7 Co-op split screen"
# on the desktop. Then start the game with that shortcut.
#
# Options:
#   -Layout screens   each player borderless full screen on their own screen: player 1 = main screen, player 2 = the
#                     biggest other screen (default)
#   -Layout split     top and bottom half of the main screen
#   -Pads 0,1         XInput pad index for player 1 and player 2
#   -NoSave           block saving for both players. Default: player 1 saves, player 2 never does, because both
#                     copies run under one Steam account and so share one save folder. Next session both pick Continue.
#   -Source <dir>     the co-op folder made by Install.cmd (default: the installer's default)
#   -Seats <dir>      where the two player folders go (same NTFS drive as -Source: big files are hardlinks)
#   -Rebuild          rebuild the player folders (after updating coop-re7)
#   -PlaceOnly        start nothing: take the two running copies and keep their windows placed
#   -NoDialog         print messages instead of showing message boxes (for scripts and tests)
#
# Why not Couchlink's own launcher: with RE7 + REFramework, the second copy it started stalled before its first frame
# in 6 of 7 runs. Restyling or moving a copy's window while REFramework suspends the game's threads to install its
# hooks froze the game; this script touches the windows only once the mod reports in. Couchlink's input hook itself
# (stand-in xinput1_3.dll, MIT, https://github.com/cranebeaker/couchlink) works fine and is what this script uses.
param(
    [ValidateSet('screens', 'split')][string]$Layout = 'screens',
    [int[]]$Pads = @(0, 1),
    [switch]$NoSave,
    [string]$Source = '',
    [string]$Seats = '',
    [switch]$Rebuild,
    [switch]$PlaceOnly,
    [switch]$Setup,
    [switch]$NoDialog
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$Title = 'RE7 Co-op split screen'
# Started from a desktop shortcut with no console: show any failure in a message box.
trap {
    if ($NoDialog) { Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red }
    else { [System.Windows.Forms.MessageBox]::Show("$Title could not start:`n`n$($_.Exception.Message)", $Title) | Out-Null }
    exit 1
}

# Couchlink release that carries the input hook (pinned, checked).
$CouchlinkZip = 'https://github.com/cranebeaker/couchlink/releases/download/v0.1.16/Couchlink-0.1.16-windows-x64.zip'
$CouchlinkSha = '35abfd350cfc5c59b9a33e8a9c6e8acd1554d63fd6bb689d30a9d27056d418dc'

# Same default as install-coop-re7.ps1.
if (-not $Source) {
    $base = [Environment]::GetFolderPath('MyDocuments')
    if ($base -match 'OneDrive') { $base = $env:SystemDrive + '\' }
    $Source = Join-Path $base 'RE7-coop'
}
if (-not $Seats) { $Seats = "$Source-players" }
$HookDir = Join-Path $Seats 'hook'
$HookDll = Join-Path $HookDir 'xinput1_3.dll'

Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public static class Win {
  public delegate bool P(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool EnumWindows(P p, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  public struct RECT { public int L, T, R, B; }
  public static IntPtr Find(uint pid) { IntPtr r = IntPtr.Zero; EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); var c = new StringBuilder(64); GetClassName(h, c, 64); if (p == pid && IsWindowVisible(h) && c.ToString() == "via") { r = h; return false; } return true; }, IntPtr.Zero); return r; }
  // True when the window still has a border or is not exactly on its region.
  public static bool NeedsPlace(IntPtr h, int x, int y, int w, int hh) {
    int st = GetWindowLong(h, -16); RECT r; GetWindowRect(h, out r);
    return (st & (0x00C00000 | 0x00040000)) != 0 || r.L != x || r.T != y || (r.R - r.L) != w || (r.B - r.T) != hh; }
  public static void Place(IntPtr h, int x, int y, int w, int hh) {
    int st = GetWindowLong(h, -16); st &= ~(0x00C00000 | 0x00040000 | 0x00020000 | 0x00010000 | 0x00080000); // caption, thickframe, min/max box, sysmenu
    SetWindowLong(h, -16, st); SetWindowPos(h, IntPtr.Zero, x, y, w, hh, 0x4000 | 0x0020 | 0x0040 | 0x0004); } // ASYNCWINDOWPOS | FRAMECHANGED | SHOWWINDOW | NOZORDER
}
"@
[Win]::SetProcessDPIAware() | Out-Null
function Say($t) { Write-Host $t -ForegroundColor Cyan }

# ---------------------------------------------------------------- setup (once)
if ($Setup) {
    if (-not (Test-Path "$Source\re7.exe")) { throw "No re7.exe in $Source. Run coop-re7's Install.cmd first (or pass -Source)." }
    New-Item -ItemType Directory -Force $HookDir | Out-Null
    if (-not (Test-Path $HookDll)) {
        Say "Downloading Couchlink's input hook (pinned release, SHA-256 checked)..."
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('re7-split-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force $tmp | Out-Null
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $zipPath = Join-Path $tmp 'couchlink.zip'
        Invoke-WebRequest -UseBasicParsing -Uri $CouchlinkZip -OutFile $zipPath
        $got = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
        if ($got -ne $CouchlinkSha) { Remove-Item $tmp -Recurse -Force; throw "The Couchlink download failed its integrity check (got $got). Nothing was installed." }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            foreach ($want in @{ From = 'hook/x64/proxy/xinput1_3.dll'; To = 'xinput1_3.dll' }, @{ From = 'LICENSE'; To = 'LICENSE-Couchlink.txt' }, @{ From = 'THIRD_PARTY.md'; To = 'THIRD_PARTY-Couchlink.md' }) {
                $e = $zip.Entries | Where-Object { $_.FullName -like "*/$($want.From)" } | Select-Object -First 1
                if (-not $e) { throw "$($want.From) not found in the Couchlink release" }
                [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $HookDir $want.To), $true)
            }
        } finally { $zip.Dispose(); Remove-Item $tmp -Recurse -Force }
    }
    $self = Join-Path $Seats 'Start-RE7-SplitScreen.ps1'
    if ($PSCommandPath -ne $self) { Copy-Item $PSCommandPath $self -Force }
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) "$Title.lnk"))
    $lnk.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $lnk.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$self`" -Source `"$Source`" -Seats `"$Seats`""
    $lnk.WorkingDirectory = $Seats; $lnk.IconLocation = "$Source\re7.exe,0"; $lnk.Save()
    $done = "Ready. Start the game with '$Title' on your desktop.`n`nPlayer 1: controller 1, main screen. Player 2: controller 2, other screen."
    if ($NoDialog) { Say $done } else { [System.Windows.Forms.MessageBox]::Show($done, $Title) | Out-Null }
    exit 0
}

# ---------------------------------------------------------------- where each player plays (desktop pixels)
function Get-Regions {
    $main = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    if ($Layout -eq 'split') {
        $hh = [int]($main.Height / 2)
        return @(@{ X = $main.X; Y = $main.Y; W = $main.Width; H = $hh }, @{ X = $main.X; Y = $main.Y + $hh; W = $main.Width; H = $hh })
    }
    # The two biggest screens (a small virtual display, such as Couchlink's, is left out), main screen first.
    $two = @([System.Windows.Forms.Screen]::AllScreens | Sort-Object { - $_.Bounds.Width * $_.Bounds.Height } | Select-Object -First 2)
    if ($two.Count -lt 2) { throw 'Only one screen is connected: plug in a second one, or start with -Layout split.' }
    $two = @($two | Sort-Object { if ($_.Primary) { 0 } else { 1 } })
    return @($two | ForEach-Object { @{ X = $_.Bounds.X; Y = $_.Bounds.Y; W = $_.Bounds.Width; H = $_.Bounds.Height; Name = $_.DeviceName } })
}
$regions = Get-Regions
foreach ($n in 1, 2) { $r = $regions[$n - 1]; Say ("Player {0}: {1}x{2} at {3},{4} {5}" -f $n, $r.W, $r.H, $r.X, $r.Y, $r.Name) }

$procs = @()
if ($PlaceOnly) {
    foreach ($n in 1, 2) {
        $p = Get-Process re7 -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq (Join-Path $Seats "p$n\re7.exe") } | Select-Object -First 1
        if (-not $p) { throw "player $n's game is not running" }
        $procs += $p
    }
} else {
    if (-not (Test-Path "$Source\re7.exe")) { throw "No re7.exe in $Source. Run coop-re7's Install.cmd first (or pass -Source)." }
    if (-not (Test-Path $HookDll)) { throw "Couchlink's input hook is missing. Run 'Split screen setup.cmd' once." }
    if (-not (Get-Process steam -ErrorAction SilentlyContinue)) { throw 'Start Steam first.' }
    if (Get-Process re7 -ErrorAction SilentlyContinue) { throw 'RE7 is already running. Close it first.' }

    # ---- player folders: big read-only files are hardlinks (no extra disk), the rest are real copies
    foreach ($n in 1, 2) {
        $dir = Join-Path $Seats "p$n"
        if ($Rebuild -or -not (Test-Path "$dir\re7.exe")) {
            Say "Building player $n folder..."
            if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
            foreach ($f in Get-ChildItem $Source -Recurse -File) {
                $rel = $f.FullName.Substring($Source.Length + 1)
                if ($rel -match '(^|\\)(re2_framework_log\.txt|reframework_accessed_files\.txt|reframework_loose_files\.txt)$') { continue }
                if ($rel -match '^reframework\\data\\(coopnet_status|coopnet_(es|ev)_(in|out)|coopnet_in|coopnet_out|coop_.*_log)') { continue }
                $to = Join-Path $dir $rel
                New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
                if ($f.Length -gt 50MB) {
                    try { New-Item -ItemType HardLink -Path $to -Target $f.FullName | Out-Null }
                    catch { throw "Could not hardlink $rel. The player folders must be on the same NTFS drive as $Source (exFAT and FAT32 have no hardlinks)." }
                } else { Copy-Item $f.FullName $to }
            }
        }
        Copy-Item $HookDll (Join-Path $dir 'xinput1_3.dll') -Force
        $me = 27776 + $n; $peer = 27779 - $n
        [IO.File]::WriteAllText("$dir\reframework\data\coopnet_config.json", (@{ mode = 'udp'; bindHost = '127.0.0.1'; localPort = $me; peerHost = '127.0.0.1'; peerPort = $peer; sendHz = 30; peerSteamId = ''; steamChannel = 7 } | ConvertTo-Json))
        # Couchlink's hook: XInput pad N is this copy's pad 0; every real pad is hidden from DirectInput, Raw Input and
        # HID (RE7 also reads PlayStation pads directly, so one pad drove both copies without own_pads); fake focus;
        # every named mutex gets a per-copy name.
        [IO.File]::WriteAllText("$dir\couchlink-hook.json", ('{"cmd":"config","config":{"pad":' + $Pads[$n - 1] + ',"focus":true,"locks":["*"],"own_pads":[]},"options":{"xinput":true}}'))
        # Saving: player 1 only (the mod's "Allow saving" switch, read live from coop_settings.json).
        $sf = "$dir\reframework\data\coop_settings.json"; $s = $null
        try { $raw = [IO.File]::ReadAllText($sf); if ($raw.Trim()) { $s = $raw | ConvertFrom-Json } } catch { }
        if (-not $s) { $s = New-Object psobject }
        $s | Add-Member -Force -NotePropertyName allow_saving -NotePropertyValue ([bool]($n -eq 1 -and -not $NoSave))
        [IO.File]::WriteAllText($sf, ($s | ConvertTo-Json -Depth 10))
        # Windowed mode at the size of the player's region, so RE7 does not keep resizing its window back.
        $ini = "$dir\re7_config.ini"
        if (Test-Path $ini) {
            $r = $regions[$n - 1]
            $txt = [IO.File]::ReadAllText($ini)
            $txt = $txt -replace 'NormalWindowResolution=\([^)]*\)', ('NormalWindowResolution=({0}.000000,{1}.000000)' -f $r.W, $r.H) -replace 'FullScreenMode=true', 'FullScreenMode=false'
            [IO.File]::WriteAllText($ini, $txt)
        }
        Remove-Item "$dir\re2_framework_log.txt", "$dir\reframework\data\coopnet_status.txt" -ErrorAction SilentlyContinue
    }

    # ---- start player 1, then player 2 once player 1's mod runs
    foreach ($n in 1, 2) {
        $dir = Join-Path $Seats "p$n"
        $psi = New-Object System.Diagnostics.ProcessStartInfo "$dir\re7.exe"
        $psi.WorkingDirectory = $dir; $psi.UseShellExecute = $false
        $psi.EnvironmentVariables['SteamAppId'] = '418370'
        $psi.EnvironmentVariables['COUCHLINK_HOOK_CONFIG'] = "$dir\couchlink-hook.json"
        $p = [Diagnostics.Process]::Start($psi); $procs += $p
        Say "Player $n started (pid $($p.Id), controller $($Pads[$n - 1]))"
        # Touch nothing until the mod runs (its status file appears once REFramework has finished hooking the game).
        $status = "$dir\reframework\data\coopnet_status.txt"; $t = Get-Date
        while (-not (Test-Path $status)) {
            if ($p.HasExited) { throw "Player $n's game closed while starting." }
            if (((Get-Date) - $t).TotalSeconds -gt 240) { throw "Player $n's co-op mod has not started after 4 minutes." }
            Start-Sleep -Milliseconds 500
        }
        Say "Player $n is ready ($([int]((Get-Date) - $t).TotalSeconds) s)"
        Start-Sleep -Seconds 3
    }
}

function Place-All {
    foreach ($n in 1, 2) {
        if ($procs[$n - 1].HasExited) { continue }
        $h = [Win]::Find([uint32]$procs[$n - 1].Id); $r = $regions[$n - 1]
        if ($h -ne [IntPtr]::Zero -and -not [Win]::IsHungAppWindow($h) -and [Win]::NeedsPlace($h, $r.X, $r.Y, $r.W, $r.H)) { [Win]::Place($h, $r.X, $r.Y, $r.W, $r.H) }
    }
}
Place-All
Say 'Both players are up. Close both games to stop.'
# RE7 puts its border back when it reapplies its display settings (options menu, loading): keep both windows
# borderless on their region, checking every 2 s, until both games are closed.
while (-not ($procs[0].HasExited -and $procs[1].HasExited)) { Start-Sleep -Seconds 2; Place-All }
