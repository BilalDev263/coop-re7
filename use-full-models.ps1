# use-full-models.ps1: set up "Third Person Full Model Placeholders" (Nexus RE7 mod 86) for
# the co-op lobby only. Run it with "Use full models.cmd" after copying that mod's
# "natives" folder into your co-op game folder.
#
# The mod replaces the players' own body files, which also changes your first-person view
# (you see the inside of the character's head). This moves its model files (*.mesh.*,
# *.mdf2.*) to natives\stm\coop\..., a folder only the co-op lobby reads, so your own
# view stays normal and your friend's character uses the full models. Texture files stay
# where they are. It also switches on REFramework's Loose File Loader, which the game
# needs to read loose files at all. Run it again any time; it only moves what's left.

param(
    [string]$GameDir = ""
)

$ErrorActionPreference = "Stop"
function Ok($t) { Write-Host "  OK  $t" -ForegroundColor Green }
function Warn($t) { Write-Host "  !!  $t" -ForegroundColor Yellow }

if ($GameDir -eq "") {
    $docs = [Environment]::GetFolderPath("MyDocuments")
    $cands = @((Join-Path $env:SystemDrive "RE7-coop"), (Join-Path $docs "RE7-coop"))
    foreach ($c in $cands) { if (Test-Path (Join-Path $c "re7.exe")) { $GameDir = $c; break } }
}
if ($GameDir -eq "" -or -not (Test-Path (Join-Path $GameDir "re7.exe"))) {
    Write-Host "Couldn't find your co-op game folder. Run: powershell -File use-full-models.ps1 -GameDir <folder>" -ForegroundColor Red
    exit 1
}
Write-Host "Co-op folder: $GameDir"
if (Get-Process re7 -ErrorAction SilentlyContinue) {
    Write-Host "Close the game first, then run this again." -ForegroundColor Red
    exit 1
}

$stm = Join-Path $GameDir "natives\stm"
$moved = 0
foreach ($top in @("character", "ch8", "ch9")) {
    $src = Join-Path $stm $top
    if (-not (Test-Path $src)) { continue }
    Get-ChildItem $src -Recurse -File | Where-Object { $_.Name -match '\.(mesh|mdf2)\.\d+$' } | ForEach-Object {
        $rel = $_.FullName.Substring($stm.Length + 1)
        $dest = Join-Path (Join-Path $stm "coop") $rel
        New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
        Move-Item -Force $_.FullName $dest
        $moved++
    }
}
$have = Test-Path (Join-Path $stm "coop\character\player\pl2000\pl2001\pl2001.mesh.220128762")
if ($moved -gt 0) { Ok "moved $moved model files to natives\stm\coop" }
elseif ($have) { Ok "model files already set up" }
else { Warn "no model files found: copy the mod's 'natives' folder into $GameDir first"; exit 1 }

$cfg = Join-Path $GameDir "re2_fw_config.txt"
if (Test-Path $cfg) {
    $text = Get-Content $cfg -Raw
    if ($text -match 'LooseFileLoader_Enabled=false') {
        Set-Content -Path $cfg -Value ($text -replace 'LooseFileLoader_Enabled=false', 'LooseFileLoader_Enabled=true') -NoNewline -Encoding Ascii
        Ok "switched on REFramework's Loose File Loader"
    } elseif ($text -notmatch 'LooseFileLoader_Enabled=true') {
        Add-Content -Path $cfg -Value "LooseFileLoader_Enabled=true" -Encoding Ascii
        Ok "switched on REFramework's Loose File Loader"
    } else { Ok "Loose File Loader already on" }
} else {
    Set-Content -Path $cfg -Value "LooseFileLoader_Enabled=true" -Encoding Ascii
    Ok "switched on REFramework's Loose File Loader"
}
Write-Host ""
Write-Host "Done. Start RE7 Co-op; the Lobby should say 'Full character models: installed'." -ForegroundColor Cyan
