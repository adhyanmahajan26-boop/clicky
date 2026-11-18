# Vello for Windows: a guided check for a tester on their own PC.
#
# It asks a few yes/no questions, checks what it can by itself, and writes everything into one zip
# on the Desktop (Theo-test-results-<date>.zip). If the tester pasted the results code they were given
# (once; it's kept for this Windows user only, encrypted), it also sends the results back by itself to a
# private GitHub repo; otherwise the tester sends the zip.
# The results never hold the Windows user name (it is replaced with <user>) and no keys or chats.
#
# It keeps itself and Vello up to date: it first swaps itself for the newest Theo-Test.ps1 published in the
# releases repo (crossplatform/install/releases-repo, written into the copy a release carries), installs the
# newest build when Vello isn't installed, and has the tester update an older Vello with its own Update button.
#
# Run it from RUN-TEST.cmd (double-click), or:
#   powershell -NoProfile -ExecutionPolicy Bypass -File Theo-Test.ps1
# -Unattended answers every question with its default and skips the hands-on steps (for CI): it doesn't
# update itself or send anything. -NoSelfUpdate and -NoSend switch those off for a person too.
# Works on Windows PowerShell 5.1 (built into Windows 10 and 11).

param(
  [switch]$Unattended,
  [switch]$NoSelfUpdate,
  [switch]$NoSend,
  [string]$Installer = "",
  [string]$OutDir = ""
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
$ScriptVersion = "3"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataFolder = Join-Path $env:APPDATA "Theo-Desktop"
$ExeName = "theo-desktop.exe"
# Where this copy was published (a release's copy has it filled in; the repo's copy reads releases-repo beside it).
$PublishedReleasesRepo = ""
# The results code, kept apart from Vello's own data so uninstalling Vello doesn't forget it.
$TesterFolder = Join-Path $env:LOCALAPPDATA "Vello-Tester"
$ResultsCodeFile = Join-Path $TesterFolder "results-code.dat"
# Windows PowerShell 5.1 may still offer only old TLS, which GitHub refuses.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

# ------------------------------------------------------------------ releases (updates for this script and Vello)

function Get-ReleasesRepo {
  $repo = $env:THEO_RELEASES_REPO
  if (-not $repo) { $repo = $PublishedReleasesRepo }
  if (-not $repo) {
    foreach ($file in @((Join-Path $Here "releases-repo"), (Join-Path $Here "..\install\releases-repo"))) {
      if (Test-Path $file) { $repo = (Get-Content $file -Raw).Trim(); break }
    }
  }
  if ($repo -and $repo -match '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { return $repo }
  return $null
}

# The newest published build-<number> release that carries an asset ending in $suffix and a SHA256SUMS, or $null.
function Get-NewestRelease([string]$suffix) {
  $repo = Get-ReleasesRepo
  if (-not $repo) { return $null }
  try {
    $list = Invoke-RestMethod -UseBasicParsing -TimeoutSec 30 -Uri "https://api.github.com/repos/$repo/releases?per_page=30" -Headers @{ Accept = "application/vnd.github+json" }
  } catch { return $null }
  $best = $null
  foreach ($release in $list) {
    if ($release.draft -or $release.prerelease) { continue }
    if ($release.tag_name -notmatch '^build-(\d+)$') { continue }
    $build = [int64]$Matches[1]
    $asset = $release.assets | Where-Object { $_.name.ToLower().EndsWith($suffix.ToLower()) } | Select-Object -First 1
    $sums = $release.assets | Where-Object { $_.name -eq "SHA256SUMS" } | Select-Object -First 1
    if (-not $asset -or -not $sums) { continue }
    if ($best -and $best.build -ge $build) { continue }
    $best = [pscustomobject]@{ build = $build; tag = $release.tag_name; name = $asset.name; url = $asset.browser_download_url; sums = $sums.browser_download_url }
  }
  return $best
}

# Downloads a release's asset into $folder and checks it against the release's SHA256SUMS (also saved there). The file's
# path, or $null (a file that doesn't match is deleted).
function Get-CheckedAsset($release, [string]$folder) {
  try {
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $file = Join-Path $folder (Split-Path -Leaf $release.name)
    $sumsFile = Join-Path $folder "SHA256SUMS"
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 900 -Uri $release.url -OutFile $file
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri $release.sums -OutFile $sumsFile
    $expected = Get-Content $sumsFile | Where-Object { $_ -match ("\s\*?" + [regex]::Escape($release.name) + "$") } | ForEach-Object { ($_ -split "\s+")[0].ToLower() } | Select-Object -First 1
    $actual = (Get-FileHash -Algorithm SHA256 -Path $file).Hash.ToLower()
    if ($expected -and $expected -eq $actual) { return $file }
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
  } catch { }
  return $null
}

# This script, swapped for the newest published copy when that one is different, then run again. Quietly carries on with
# this copy when there's no network or nothing newer.
if (-not $Unattended -and -not $NoSelfUpdate -and $PSCommandPath) {
  $newest = Get-NewestRelease "Theo-Test.ps1"
  if ($newest) {
    $fresh = Get-CheckedAsset $newest (Join-Path $env:TEMP ("Vello-tester-" + [guid]::NewGuid().ToString("N")))
    if ($fresh -and (Get-FileHash -Algorithm SHA256 -Path $fresh).Hash -ne (Get-FileHash -Algorithm SHA256 -Path $PSCommandPath).Hash) {
      try {
        Copy-Item -LiteralPath $fresh -Destination $PSCommandPath -Force
        Write-Host "The tester check was updated to the one for build $($newest.build). Starting it..." -ForegroundColor Cyan
        $again = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $PSCommandPath, "-NoSelfUpdate")
        if ($NoSend) { $again += "-NoSend" }
        if ($Installer) { $again += @("-Installer", $Installer) }
        if ($OutDir) { $again += @("-OutDir", $OutDir) }
        & powershell.exe @again
        exit $LASTEXITCODE
      } catch {
        Write-Host "Couldn't update the tester check ($_); carrying on with this one." -ForegroundColor Yellow
      }
    }
  }
}

$Stamp = Get-Date -Format "yyyyMMdd-HHmm"
if (-not $OutDir) {
  $desktop = [Environment]::GetFolderPath("Desktop")
  if (-not $desktop -or -not (Test-Path $desktop)) { $desktop = $env:USERPROFILE }
  $OutDir = Join-Path $desktop "Theo-test-results-$Stamp"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$ShotsDir = Join-Path $OutDir "screenshots"
New-Item -ItemType Directory -Force -Path $ShotsDir | Out-Null

$Results = New-Object System.Collections.ArrayList
$Facts = [ordered]@{}
$Notes = New-Object System.Collections.ArrayList

# ------------------------------------------------------------------ helpers

function Hide-Private([string]$text) {
  if (-not $text) { return $text }
  $t = $text
  foreach ($p in @($env:USERPROFILE, $env:USERNAME)) {
    if ($p -and $p.Length -ge 3) { $t = $t -replace [regex]::Escape($p), "<user>" }
  }
  return $t
}

function Say([string]$text, [string]$color = "Gray") { Write-Host $text -ForegroundColor $color }

function Title([string]$text) {
  Write-Host ""
  Write-Host ("== " + $text + " ") -ForegroundColor Cyan
}

# pass | fail | skip | info. "fail" is for things that are wrong, not for "the tester said no to an optional step".
function Record([string]$step, [string]$result, [string]$detail = "") {
  $detail = Hide-Private $detail
  [void]$Results.Add([ordered]@{ step = $step; result = $result; detail = $detail })
  $color = @{ pass = "Green"; fail = "Red"; skip = "DarkGray"; info = "Gray" }[$result]
  if (-not $color) { $color = "Gray" }
  $line = "  [" + $result.ToUpper() + "] " + $step
  if ($detail) { $line += "  (" + $detail + ")" }
  Write-Host $line -ForegroundColor $color
}

function Ask-YesNo([string]$question, [bool]$default = $true) {
  if ($Unattended) { return $default }
  $hint = "y/n"
  if ($default) { $hint = "Y/n" } else { $hint = "y/N" }
  while ($true) {
    $a = Read-Host ("  " + $question + " [" + $hint + "]")
    if (-not $a) { return $default }
    $a = $a.Trim().ToLower()
    if ($a -in @("y", "yes")) { return $true }
    if ($a -in @("n", "no")) { return $false }
    Write-Host "  Please type y or n." -ForegroundColor Yellow
  }
}

function Ask-Text([string]$question) {
  if ($Unattended) { return "" }
  $a = Read-Host ("  " + $question + " (press Enter to skip)")
  return (Hide-Private $a)
}

function Wait-Enter([string]$what) {
  if ($Unattended) { return }
  Write-Host ""
  Write-Host ("  >> " + $what) -ForegroundColor Yellow
  [void](Read-Host "  Press Enter when you're done")
}

# Vello's engine answers JSON files dropped in its control-inbox folder (the same way its own tests drive it).
function Send-Theo($command, [int]$timeoutSeconds = 10) {
  $inbox = Join-Path $DataFolder "control-inbox"
  $outbox = Join-Path $DataFolder "control-outbox"
  if (-not (Test-Path $inbox)) { return $null }
  $id = [guid]::NewGuid().ToString("N")
  $tmp = Join-Path $inbox ($id + ".tmp")
  $final = Join-Path $inbox ($id + ".json")
  $reply = Join-Path $outbox ($id + ".json")
  try {
    [IO.File]::WriteAllText($tmp, ($command | ConvertTo-Json -Compress -Depth 6), (New-Object Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $final -Force
  } catch { return $null }
  $deadline = (Get-Date).AddSeconds($timeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-Path $reply) {
      try {
        $text = [IO.File]::ReadAllText($reply)
        Remove-Item -LiteralPath $reply -Force -ErrorAction SilentlyContinue
        return ($text | ConvertFrom-Json)
      } catch { }
    }
    Start-Sleep -Milliseconds 100
  }
  Remove-Item -LiteralPath $final -Force -ErrorAction SilentlyContinue
  return $null
}

function Get-TheoProcesses { return @(Get-Process -Name "theo-desktop" -ErrorAction SilentlyContinue) }

function Wait-TheoAnswers([int]$seconds) {
  $start = Get-Date
  while (((Get-Date) - $start).TotalSeconds -lt $seconds) {
    if ((Get-TheoProcesses).Count -gt 0) {
      $p = Send-Theo @{ cmd = "ping" } 2
      if ($p -and $p.ok) { return [math]::Round(((Get-Date) - $start).TotalSeconds, 1) }
    }
    Start-Sleep -Milliseconds 500
  }
  return $null
}

function Wait-TheoGone([int]$seconds) {
  $start = Get-Date
  while (((Get-Date) - $start).TotalSeconds -lt $seconds) {
    if ((Get-TheoProcesses).Count -eq 0) { return $true }
    Start-Sleep -Milliseconds 500
  }
  return $false
}

function Get-UninstallEntry {
  $keys = @("HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*")
  foreach ($k in $keys) {
    $e = Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq "Theo" } | Select-Object -First 1
    if ($e) { return $e }
  }
  return $null
}

function Get-TheoExe {
  $e = Get-UninstallEntry
  $candidates = @()
  if ($e -and $e.InstallLocation) { $candidates += (Join-Path ($e.InstallLocation.Trim('"')) $ExeName) }
  if ($e -and $e.DisplayIcon) { $candidates += ($e.DisplayIcon.Trim('"') -replace ',\d+$', '') }
  $candidates += (Join-Path $env:LOCALAPPDATA "Theo\$ExeName")
  $candidates += (Join-Path $env:ProgramFiles "Theo\$ExeName")
  foreach ($c in $candidates) { if ($c -and (Test-Path $c) -and $c.ToLower().EndsWith($ExeName)) { return $c } }
  return $null
}

function Get-StartMenuShortcut {
  $roots = @((Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"),
             (Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs"))
  foreach ($r in $roots) {
    if (Test-Path $r) {
      $l = Get-ChildItem -Path $r -Filter "Theo*.lnk" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($l) { return $l.FullName }
    }
  }
  return $null
}

function Open-Theo {
  $lnk = Get-StartMenuShortcut
  if ($lnk) { Start-Process -FilePath $lnk; return "Start menu shortcut" }
  $exe = Get-TheoExe
  if ($exe) { Start-Process -FilePath $exe; return "theo-desktop.exe" }
  return $null
}

function Get-BotCount {
  $s = Send-Theo @{ cmd = "botsState" } 10
  if ($s -and $s.ok -and $s.result -and $s.result.bots) { return @($s.result.bots).Count }
  if ($s -and $s.ok) { return 0 }
  return $null
}

# A picture of Vello's window only (brought to the front first), never the whole screen.
Add-Type -ErrorAction SilentlyContinue -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class TheoWin {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
try { [void][TheoWin]::SetProcessDPIAware() } catch { }

function Get-TheoWindow {
  foreach ($p in (Get-TheoProcesses)) {
    $p.Refresh()
    if ($p.MainWindowHandle -ne [IntPtr]::Zero -and [TheoWin]::IsWindowVisible($p.MainWindowHandle)) { return $p.MainWindowHandle }
  }
  return [IntPtr]::Zero
}

function Save-TheoShot([string]$name) {
  try {
    $h = Get-TheoWindow
    if ($h -eq [IntPtr]::Zero) { return $null }
    [void][TheoWin]::ShowWindow($h, 9)
    [void][TheoWin]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds 700
    $r = New-Object TheoWin+RECT
    [void][TheoWin]::GetWindowRect($h, [ref]$r)
    $w = $r.Right - $r.Left; $ht = $r.Bottom - $r.Top
    if ($w -lt 50 -or $ht -lt 50) { return $null }
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap $w, $ht
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
    $file = Join-Path $ShotsDir ($name + ".png")
    $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    return $file
  } catch { return $null }
}

function Test-Command([string]$name) {
  $c = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { return $true }
  return $false
}

# ------------------------------------------------------------------ sending the results back

# The results code is "<owner>/<repo> <token>": a private GitHub repo for results and a token that can only write to it
# (crossplatform/tester/HOW-TO-TEST.txt says how to make one). It's kept encrypted for this Windows user (DPAPI).
function Split-ResultsCode([string]$code) {
  if ($code -match '^\s*([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)[\s:]+([A-Za-z0-9_]{20,255})\s*$') {
    return [pscustomobject]@{ repo = $Matches[1]; token = $Matches[2] }
  }
  return $null
}

function Read-ResultsCode {
  if (-not (Test-Path $ResultsCodeFile)) { return $null }
  try {
    $secure = ConvertTo-SecureString (Get-Content $ResultsCodeFile -Raw).Trim()
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    return (Split-ResultsCode $plain)
  } catch { return $null }
}

function Save-ResultsCode([string]$code) {
  try {
    New-Item -ItemType Directory -Force -Path $TesterFolder | Out-Null
    $secure = ConvertTo-SecureString $code -AsPlainText -Force
    Set-Content -Path $ResultsCodeFile -Value (ConvertFrom-SecureString $secure)
  } catch { }
}

# One file into the results repo through GitHub's contents API. "ok", or what went wrong (never the token).
function Send-ResultsFile($code, [string]$file, [string]$path, [string]$message) {
  $body = @{ message = $message; content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($file)) } | ConvertTo-Json -Compress
  $headers = @{ Authorization = ("Bearer " + $code.token); Accept = "application/vnd.github+json"; "X-GitHub-Api-Version" = "2022-11-28" }
  try {
    [void](Invoke-RestMethod -UseBasicParsing -TimeoutSec 300 -Method Put -Uri ("https://api.github.com/repos/" + $code.repo + "/contents/" + $path) -Headers $headers -Body $body -ContentType "application/json")
    return "ok"
  } catch {
    $status = 0
    try { $status = [int]$_.Exception.Response.StatusCode } catch { }
    if ($status -in @(401, 403, 404)) { return "refused" }
    if ($status) { return "GitHub answered $status" }
    return "no connection to GitHub"
  }
}

# Asks first, then sends RESULTS.txt and the zip to reports/<date>-<id>/ in the results repo. $true when both went.
function Send-Results([string]$zip, [string]$summary, [int]$passed, [int]$failed) {
  $code = Read-ResultsCode
  if (-not $code) {
    Write-Host ""
    Say "  If the person who asked you to test gave you a results code, paste it here and the results will be sent back"
    Say "  by themselves, this time and every time after (it's kept on this PC for your Windows user only)."
    $typed = Read-Host "  Results code (press Enter to skip and send the zip yourself)"
    if (-not $typed) { return $false }
    $code = Split-ResultsCode $typed
    if (-not $code) { Say "  That doesn't look like a results code (it's a repo name, a space, then a long token). Send the zip instead." "Yellow"; return $false }
    Save-ResultsCode ($code.repo + " " + $code.token)
  }
  if (-not (Ask-YesNo ("Send these results to " + $code.repo + " now? (the same zip you can open on your Desktop)") $true)) { return $false }
  $zipBytes = (Get-Item $zip).Length
  if ($zipBytes -gt 45MB) { Say "  The zip is too big to send this way ($([math]::Round($zipBytes / 1MB)) MB). Please send it by hand." "Yellow"; return $false }
  $folder = "reports/" + $Stamp + "-" + [guid]::NewGuid().ToString("N").Substring(0, 6)
  $title = "Tester results " + $Stamp + ": " + $passed + " passed, " + $failed + " failed"
  Say "  Sending..."
  $first = Send-ResultsFile $code $summary ($folder + "/RESULTS.txt") $title
  $second = "skipped"
  if ($first -eq "ok") { $second = Send-ResultsFile $code $zip ($folder + "/" + (Split-Path -Leaf $zip)) $title }
  if ($first -eq "ok" -and $second -eq "ok") { return $true }
  if ($first -eq "refused" -or $second -eq "refused") {
    Remove-Item -LiteralPath $ResultsCodeFile -Force -ErrorAction SilentlyContinue
    Say "  GitHub refused the results code (it may have expired), so it was forgotten. Send the zip by hand, and ask for a new code." "Yellow"
  } else {
    Say ("  Couldn't send the results (" + $(if ($first -ne "ok") { $first } else { $second }) + "). Please send the zip by hand.") "Yellow"
  }
  return $false
}

# ------------------------------------------------------------------ start

Clear-Host
Say "Vello for Windows - tester check" "Cyan"
Say "This takes about 15 minutes. It asks a few questions and checks Vello by itself."
Say "At the end it makes one zip on your Desktop. If you were given a results code, it can send the zip back by itself"
Say "(it asks first); otherwise you send the zip."
Say "The zip has no passwords, keys or chats, and your Windows user name is replaced with <user>."
Say "You can stop at any time with Ctrl+C."

$Facts["script_version"] = $ScriptVersion
$Facts["started"] = (Get-Date).ToString("s")
$Facts["unattended"] = [bool]$Unattended

# ------------------------------------------------------------------ 1. this PC

Title "1. About this PC"
try {
  $cv = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
  $product = $cv.ProductName
  # Windows 11 still says "Windows 10" in ProductName; the build number tells them apart.
  if ([int]$cv.CurrentBuild -ge 22000) { $product = $product -replace "Windows 10", "Windows 11" }
  $Facts["windows"] = "$product $($cv.DisplayVersion) build $($cv.CurrentBuild).$($cv.UBR)"
} catch { $Facts["windows"] = [Environment]::OSVersion.VersionString }
$Facts["cpu_arch"] = $env:PROCESSOR_ARCHITECTURE
if ($env:PROCESSOR_ARCHITEW6432) { $Facts["cpu_arch"] = $env:PROCESSOR_ARCHITEW6432 }
try { $Facts["ram_gb"] = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1) } catch { }
try { $Facts["language"] = (Get-Culture).Name } catch { }
$Facts["user_name_has_space"] = ($env:USERNAME -match " ")
$Facts["user_name_has_non_english_letters"] = ($env:USERNAME -match "[^\x00-\x7F]")
$Facts["user_folder_has_space_or_non_english"] = ($env:USERPROFILE -match "[ ]|[^\x00-\x7F]")
try {
  $dpi = (Get-ItemProperty "HKCU:\Control Panel\Desktop\WindowMetrics" -ErrorAction Stop).AppliedDPI
  if ($dpi) { $Facts["display_scale_percent"] = [math]::Round($dpi / 96 * 100) }
} catch { }
try {
  $light = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -ErrorAction Stop).AppsUseLightTheme
  if ($light -eq 0) { $Facts["apps_theme"] = "dark" } else { $Facts["apps_theme"] = "light" }
} catch { }
$wv = $null
foreach ($k in @("HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
                 "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
                 "HKCU:\Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}")) {
  try { $v = (Get-ItemProperty $k -ErrorAction Stop).pv; if ($v -and $v -ne "0.0.0.0") { $wv = $v; break } } catch { }
}
if ($wv) { $Facts["webview2"] = $wv } else { $Facts["webview2"] = "not found before install (the installer downloads it)" }
foreach ($tool in @("git", "gh", "node", "npm", "python", "claude", "opencode", "codex", "gemini", "cursor-agent", "grok")) {
  $Facts["has_" + ($tool -replace "-", "_")] = (Test-Command $tool)
}
try {
  $mp = Get-MpComputerStatus -ErrorAction Stop
  $Facts["defender_realtime"] = [bool]$mp.RealTimeProtectionEnabled
} catch { $Facts["defender_realtime"] = "unknown" }
foreach ($k in $Facts.Keys) { Say ("  " + $k + ": " + (Hide-Private ([string]$Facts[$k]))) }
if ($Facts["cpu_arch"] -eq "ARM64") { [void]$Notes.Add("This is a Windows on ARM PC; Vello is x64 and runs under emulation.") }

# ------------------------------------------------------------------ 2. installing

Title "2. Installing Vello"
if (-not $Installer) {
  $found = Get-ChildItem -Path $Here -Filter "*-windows-x64-setup.exe" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $found) { $found = Get-ChildItem -Path $Here -Filter "*setup*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 }
  if ($found) { $Installer = $found.FullName }
}
# The tester ran an installer from this kit by hand (so the SmartScreen questions make sense), or not.
$installerBesideScript = [bool]$Installer
# Nothing installed and no installer here: the newest build from the releases page, checked against its SHA256SUMS.
if (-not $Installer -and -not (Get-UninstallEntry)) {
  $newestSetup = Get-NewestRelease "-windows-x64-setup.exe"
  if ($newestSetup) {
    Say "  Downloading Vello build $($newestSetup.build)..."
    $Installer = Get-CheckedAsset $newestSetup (Join-Path $env:TEMP "Vello-tester-setup")
    if ($Installer) { Record "Downloaded the newest build ($($newestSetup.build)) and it matches its checksum" "pass" }
    else { Record "Downloaded the newest build" "fail" "the download failed or didn't match SHA256SUMS" }
  } else { Record "Found a build to install on the releases page" "fail" ("couldn't read the releases of " + (Get-ReleasesRepo)) }
}
if ($Installer -and (Test-Path $Installer)) {
  $Facts["installer"] = (Split-Path -Leaf $Installer)
  $hash = (Get-FileHash -Algorithm SHA256 -Path $Installer).Hash.ToLower()
  $sums = Join-Path (Split-Path -Parent $Installer) "SHA256SUMS"
  if (Test-Path $sums) {
    $expected = Get-Content $sums | Where-Object { $_ -match ("\s\*?" + [regex]::Escape((Split-Path -Leaf $Installer)) + "$") } | ForEach-Object { ($_ -split "\s+")[0].ToLower() } | Select-Object -First 1
    if ($expected -eq $hash) { Record "Installer matches its checksum (SHA256SUMS)" "pass" }
    elseif ($expected) { Record "Installer matches its checksum (SHA256SUMS)" "fail" "got $hash, expected $expected" }
    else { Record "Installer matches its checksum (SHA256SUMS)" "skip" "SHA256SUMS has no line for it" }
  } else { Record "Installer checksum" "info" $hash }
}

$entry = Get-UninstallEntry
$alreadyInstalled = [bool]$entry
if ($alreadyInstalled) {
  Say "  Vello is installed already (version $($entry.DisplayVersion))."
  if (-not $Unattended -and $installerBesideScript) {
    $smart = Ask-YesNo "When you double-clicked the installer, did Windows show a blue 'Windows protected your PC' box?" $true
    if ($smart) {
      $ok = Ask-YesNo "Did 'More info' then 'Run anyway' let it install?" $true
      if ($ok) { Record "SmartScreen: More info, Run anyway works" "pass" } else { Record "SmartScreen: More info, Run anyway works" "fail" (Ask-Text "What happened instead?") }
    } else { Record "SmartScreen warning shown" "info" "no warning on this PC" }
    $other = Ask-YesNo "Did anything else odd happen while installing (antivirus, error, admin prompt)?" $false
    if ($other) { Record "Install went smoothly" "fail" (Ask-Text "What happened?") } else { Record "Install went smoothly" "pass" }
  }
} elseif ($Installer -and (Test-Path $Installer)) {
  Say "  Vello isn't installed yet. Installing it now for this Windows user (no admin needed)..."
  $p = Start-Process -FilePath $Installer -ArgumentList "/S" -PassThru -Wait
  Start-Sleep -Seconds 2
  $entry = Get-UninstallEntry
  if ($entry) { Record "Silent per-user install" "pass" ("exit code " + $p.ExitCode) } else { Record "Silent per-user install" "fail" ("exit code " + $p.ExitCode + ", no Vello in Apps") }
  [void]$Notes.Add("The script installed Vello itself, so the SmartScreen warning wasn't tried by hand.")
} else {
  Record "Vello installed" "fail" "not installed, and no installer next to this script"
}

if ($entry) {
  $Facts["theo_version"] = $entry.DisplayVersion
  if ($entry.PSPath -match "HKEY_CURRENT_USER") { $Facts["installed_for"] = "this user" } else { $Facts["installed_for"] = "all users" }
}
$exe = Get-TheoExe
if ($exe) { Record "theo-desktop.exe is in place" "pass" $exe } else { Record "theo-desktop.exe is in place" "fail" "not found (antivirus may have removed it)" }
if ($exe) {
  $hub = Get-ChildItem -Path (Split-Path -Parent $exe) -Filter "theo-connectors*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($hub) { Record "Connector helper is next to the app" "pass" $hub.Name } else { Record "Connector helper is next to the app" "fail" "theo-connectors.exe missing" }
}
if (Get-StartMenuShortcut) { Record "Start menu shortcut" "pass" } else { Record "Start menu shortcut" "fail" "no Vello in the Start menu" }
try {
  $threats = @(Get-MpThreatDetection -ErrorAction Stop | Where-Object { ($_.Resources -join " ") -match "(?i)theo" })
  if ($threats.Count -gt 0) { Record "Windows Defender left Vello alone" "fail" ("Defender flagged: " + (($threats | ForEach-Object { $_.Resources -join " " }) -join "; ")) }
  else { Record "Windows Defender left Vello alone" "pass" }
} catch { Record "Windows Defender left Vello alone" "skip" "couldn't read Defender's history without admin" }

# ------------------------------------------------------------------ 3. first open

Title "3. Opening Vello"
if ((Get-TheoProcesses).Count -eq 0) {
  $how = Open-Theo
  if ($how) { Say "  Opened Vello from the $how." } else { Say "  Couldn't find Vello to open." "Yellow" }
}
$secs = Wait-TheoAnswers 90
if ($null -ne $secs) { Record "Vello starts and its engine answers" "pass" "$secs s" }
else { Record "Vello starts and its engine answers" "fail" ("processes: " + (Get-TheoProcesses).Count) }

# Vello's own updater: an older build is updated the way the tester will from now on, with the Update button, so the rest of
# the check runs on the newest build (and the updater itself gets tested every time).
$updates = Send-Theo @{ cmd = "updates"; action = "check" } 60
if ($updates -and $updates.ok) {
  $Facts["build_at_start"] = $updates.result.build
  $Facts["updates_from"] = $updates.result.repo
  $waiting = $updates.result.available
  if ($waiting -and $waiting.build -and -not $Unattended) {
    Say "  Vello build $($updates.result.build) is open, and build $($waiting.build) is out."
    Wait-Enter "In Vello, click 'Update' at the bottom of the sidebar (or Settings, Updates). Vello closes, updates and opens again by itself. Wait until it's back"
    $updatedTo = $null
    $deadline = (Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $deadline) {
      $now = Send-Theo @{ cmd = "updates"; action = "state" } 5
      if ($now -and $now.ok -and [int64]$now.result.build -ge [int64]$waiting.build) { $updatedTo = $now.result.build; break }
      Start-Sleep -Seconds 2
    }
    if ($updatedTo) { Record "Vello updated itself with its Update button" "pass" ("build " + $updates.result.build + " to " + $updatedTo) }
    else {
      $now = Send-Theo @{ cmd = "updates"; action = "state" } 10
      $why = "still build " + $updates.result.build
      if ($now -and $now.ok -and $now.result.message) { $why += ": " + $now.result.message }
      Record "Vello updated itself with its Update button" "fail" $why
      if ((Get-TheoProcesses).Count -eq 0) { [void](Open-Theo); [void](Wait-TheoAnswers 90) }
    }
  } elseif ($waiting -and $waiting.build) {
    Record "Vello is the newest build" "info" ("build " + $updates.result.build + "; " + $waiting.build + " is out")
  } elseif ($updates.result.state -eq "upToDate") {
    Record "Vello is the newest build" "pass" ("build " + $updates.result.build)
  } elseif ($Unattended) {
    # CI installs a build from a branch, whose releases page may have nothing for it yet: worth seeing, not a failure.
    Record "Vello could check for updates" "info" ([string]$updates.result.message)
  } else {
    Record "Vello could check for updates" "fail" ([string]$updates.result.message)
  }
  $after = Send-Theo @{ cmd = "updates"; action = "state" } 10
  if ($after -and $after.ok) { $Facts["build"] = $after.result.build }
} else { Record "Vello could check for updates" "skip" "no answer from Vello" }

$status = Send-Theo @{ cmd = "status" } 10
if ($status -and $status.ok) { $Facts["engine"] = "Vello " + $status.result.version + " " + $status.result.os + "/" + $status.result.arch }
$doctor = Send-Theo @{ cmd = "doctor" } 60
if ($doctor -and $doctor.ok) {
  [IO.File]::WriteAllText((Join-Path $OutDir "health-check.txt"), (Hide-Private ([string]$doctor.result.text)))
  $bad = @($doctor.result.findings | Where-Object { $_.level -in @("error", "fail", "failed") })
  Record "Theo's own health check ran" "pass" ("" + @($doctor.result.findings).Count + " findings, " + $bad.Count + " errors (see health-check.txt)")
} else { Record "Theo's own health check ran" "skip" "no answer" }

Start-Sleep -Seconds 3
$shot = Save-TheoShot "1-first-open"
if ($shot) { Record "Theo's window is on screen" "pass" } else { Record "Theo's window is on screen" "info" "couldn't find its window to take a picture" }

if (-not $Unattended) {
  $seen = Ask-YesNo "Can you see Vello's window (it starts with a short setup)?" $true
  if ($seen) { Record "Tester sees the window" "pass" } else { Record "Tester sees the window" "fail" (Ask-Text "What do you see instead?") }
  $looks = Ask-YesNo "Does it look right: sharp text, nothing cut off or overlapping?" $true
  if ($looks) { Record "Window looks right" "pass" } else { Record "Window looks right" "fail" (Ask-Text "What looks wrong?") }
}

# ------------------------------------------------------------------ 4. setup and a first bot

Title "4. Setup and your first bot"
$botsBefore = Get-BotCount
if (-not $Unattended) {
  Say "  In Vello, go through the setup:"
  Say "   - Welcome: type any name."
  Say "   - 'Pick a brain': you don't need one for this test. If you have an OpenAI or Anthropic API key,"
  Say "     or Gemini CLI / Codex / OpenCode signed in, you can use it. Otherwise press 'Skip for now'."
  Say "   - 'Pick products': turn on all three (Vello, Pointer Assistant and Dictation) so you can try them later."
  Say "   - 'Your first bot': pick any job and look, then press 'Make ...'."
  Say "   - Click around: the bot's chat, Bots, Connectors, Settings. Send the bot a message like 'hi'."
  Wait-Enter "Go through setup and make a bot in Vello now."
  $hadBrain = Ask-YesNo "Did you give Vello a brain (an API key or a signed-in agent)?" $false
  $Facts["tester_used_a_brain"] = $hadBrain
  if ($hadBrain) {
    $Facts["brain_used"] = Ask-Text "Which one (for example 'OpenAI key' or 'Gemini CLI')?"
    $answered = Ask-YesNo "Did your bot answer your message?" $true
    if ($answered) { Record "Bot answers with the tester's brain" "pass" } else { Record "Bot answers with the tester's brain" "fail" (Ask-Text "What did the chat show?") }
  } else {
    $card = Ask-YesNo "With no brain, did the chat explain clearly what to do (a card saying to add a brain)?" $true
    if ($card) { Record "No brain: the chat says what to do" "pass" } else { Record "No brain: the chat says what to do" "fail" (Ask-Text "What did it show?") }
  }
  $confusing = Ask-Text "Anything confusing or broken in setup or while clicking around?"
  if ($confusing) { Record "Setup and pages" "info" $confusing }
}
$botsAfter = Get-BotCount
if ($null -ne $botsAfter) {
  if ($Unattended) { Record "Bots list readable" "pass" "$botsAfter bots" }
  elseif ($null -ne $botsBefore -and $botsAfter -gt $botsBefore) { Record "A bot was made" "pass" "$botsBefore bots before setup, $botsAfter after" }
  elseif ($null -eq $botsBefore -and $botsAfter -gt 0) { Record "A bot was made" "pass" "$botsAfter bots" }
  else { Record "A bot was made" "info" "no new bot ($botsAfter bots); the tester may have skipped that step" }
} else { Record "Bots list readable" "fail" "no answer from Vello" }
[void](Save-TheoShot "2-after-setup")

# ------------------------------------------------------------------ 5. tray, closing and opening again

Title "5. Closing the window, the tray, and opening again"
if (-not $Unattended) {
  Wait-Enter "Close Vello's window with the X in its top-right corner."
  Start-Sleep -Seconds 2
  if ((Get-TheoProcesses).Count -gt 0) { Record "Closing the window keeps Vello running in the tray" "pass" }
  else { Record "Closing the window keeps Vello running in the tray" "fail" "Vello quit when its window closed" }
  $tray = Ask-YesNo "Is Vello's icon in the tray (bottom-right, maybe behind the ^ arrow)?" $true
  if ($tray) {
    Record "Tray icon shows" "pass"
    $menu = Ask-YesNo "Right-click it: does the menu have 'Open Vello' and 'Quit Vello'?" $true
    if ($menu) { Record "Tray menu has Open Vello and Quit Vello" "pass" } else { Record "Tray menu has Open Vello and Quit Vello" "fail" (Ask-Text "What does it show?") }
  } else { Record "Tray icon shows" "fail" }
}
# Opening Vello while it runs should bring the same window back, not start a second Vello.
$before = (Get-TheoProcesses).Count
[void](Open-Theo)
Start-Sleep -Seconds 6
$after = (Get-TheoProcesses).Count
if ($before -ge 1 -and $after -eq $before) { Record "Opening it again doesn't start a second Vello" "pass" }
elseif ($before -ge 1) { Record "Opening it again doesn't start a second Vello" "fail" "$before before, $after after" }
if (-not $Unattended) {
  $back = Ask-YesNo "Did Vello's window come back?" $true
  if ($back) { Record "Window comes back from the Start menu" "pass" } else { Record "Window comes back from the Start menu" "fail" }
}

# ------------------------------------------------------------------ 6. quit, open again, everything kept

Title "6. Quit and open again"
if (-not $Unattended) {
  Wait-Enter "Right-click Vello's tray icon and choose 'Quit Vello'."
  if (Wait-TheoGone 20) { Record "Quit Vello leaves nothing running" "pass" }
  else { Record "Quit Vello leaves nothing running" "fail" "still running 20 s later" }
}
if ((Get-TheoProcesses).Count -gt 0) {
  [void](Send-Theo @{ cmd = "quit" } 10)
  if (-not (Wait-TheoGone 20)) { Get-TheoProcesses | Stop-Process -Force -ErrorAction SilentlyContinue }
}
[void](Open-Theo)
$secs = Wait-TheoAnswers 90
if ($null -ne $secs) { Record "Opens again after quitting" "pass" "$secs s" } else { Record "Opens again after quitting" "fail" }
$botsReopened = Get-BotCount
if ($null -ne $botsAfter -and $null -ne $botsReopened) {
  if ($botsReopened -eq $botsAfter) { Record "Bots are kept after quitting" "pass" "$botsReopened bots" }
  else { Record "Bots are kept after quitting" "fail" "$botsAfter before, $botsReopened after" }
}
Start-Sleep -Seconds 3
[void](Save-TheoShot "3-reopened")
if (-not $Unattended) {
  if ($hadBrain) {
    $noSetup = Ask-YesNo "Did it open straight to your bots, without the setup again?" $true
    if ($noSetup) { Record "Setup isn't shown again" "pass" } else { Record "Setup isn't shown again" "fail" }
  } else {
    # With no brain at all, Setup comes back on purpose (as on the Mac) and should say why.
    $why = Ask-YesNo "With no brain, setup may come back. Did Vello open either to your bots or to setup's brain step saying it needs one?" $true
    if ($why) { Record "Reopens sensibly with no brain" "pass" } else { Record "Reopens sensibly with no brain" "fail" (Ask-Text "What did it show?") }
  }
}

# ------------------------------------------------------------------ 7. new in this build

Title "7. New in this build"
foreach ($probe in @(@{ name = "Products answer"; cmd = @{ cmd = "products" } }, @{ name = "Updates answer"; cmd = @{ cmd = "updates" } })) {
  $r = Send-Theo $probe.cmd 15
  if ($r -and $r.ok) { Record $probe.name "pass" } elseif ($r) { Record $probe.name "info" ($r.error) } else { Record $probe.name "fail" "no answer from Vello" }
}
if (-not $Unattended) {
  Say "  A few quick looks at what's new. Answer n to anything you can't find, and say what you saw."
  function Check-New([string]$step, [string]$howTo, [string]$question) {
    Say ""
    Say "  $howTo"
    if (Ask-YesNo $question $true) { Record $step "pass" } else { Record $step "fail" (Ask-Text "What happened instead?") }
  }
  Check-New "Teams in the sidebar" "Look at the sidebar on the left: bots are grouped into teams, a manager first (with a crown), then 'Other bots', then 'New category'." "Is the sidebar grouped like that?"
  Check-New "Bot settings: edit and delete" "Open a bot you made, open its settings, change its description and save. Then make a spare bot and delete it." "Did the change stick, and did the spare bot go away (after asking first)?"
  Check-New "New group chat" "Make a group chat with two bots in it (look for New group in the sidebar)." "Could you make it, and does it show in the sidebar?"
  Check-New "New routine" "Open Routines, press New routine, pick a bot, choose 'Every day' at any time, and add it." "Is the routine in the list with its next time?"
  Check-New "Updates in Settings" "Open Settings, then Updates, and press 'Check for updates'." "Did it say something clear (up to date, a new build, or why it couldn't check)?"
  if (Ask-YesNo "Try Dictation? (needs a microphone; no brain needed)" $true) {
    Check-New "Dictation types into another app" "Open Notepad, click in it, hold Ctrl + Windows key, say 'hello from Vello', then let go." "Did your words appear in Notepad (a small pill showed while you talked)?"
  } else { Record "Dictation" "skip" }
  if ($hadBrain -and (Ask-YesNo "Try Pointer Assistant? (needs a microphone and the brain you gave Vello)" $true)) {
    Check-New "Pointer Assistant answers about the screen" "Hold Ctrl + Alt, ask 'what's on my screen?', then let go." "Did Pointer Assistant answer out loud and on screen near the pointer (the orange spark)?"
    Check-New "Pointer Assistant points at things" "Hold Ctrl + Alt and ask 'where is the Start button?'." "Did the spark fly to it?"
  } else { Record "Clicky" "skip" "needs a brain and a microphone" }
}
[void](Save-TheoShot "4-new-features")

# ------------------------------------------------------------------ 8. optional extras

Title "8. Extras (optional)"
if (-not $Unattended) {
  if (Ask-YesNo "Try a notification? (needs a brain; skip if you have none)" $false) {
    Wait-Enter "Ask a bot to do something that needs your answer (e.g. 'ask me which colour I like'), then close Vello's window and wait."
    $toast = Ask-YesNo "Did a Windows notification from Vello appear?" $true
    if ($toast) { Record "Notification appears" "pass" } else { Record "Notification appears" "fail" }
  } else { Record "Notification" "skip" }
  $scale = Ask-YesNo "Want to check display scaling? (Settings > Display > Scale 150%, look at Vello, then set it back)" $false
  if ($scale) {
    $ok = Ask-YesNo "Did Vello look right at the other scale?" $true
    if ($ok) { Record "Looks right at another display scale" "pass" } else { Record "Looks right at another display scale" "fail" (Ask-Text "What looked wrong?") }
  } else { Record "Display scaling" "skip" }
}

# ------------------------------------------------------------------ 9. uninstall

Title "9. Uninstall (optional)"
$doUninstall = $Unattended
if (-not $Unattended) {
  Say "  This checks that Vello removes itself cleanly. It keeps Vello's data folder, so reinstalling brings your bots back."
  $doUninstall = Ask-YesNo "Uninstall Vello now?" $true
}
if ($doUninstall) {
  if ((Get-TheoProcesses).Count -gt 0) {
    [void](Send-Theo @{ cmd = "quit" } 10)
    if (-not (Wait-TheoGone 20)) { Get-TheoProcesses | Stop-Process -Force -ErrorAction SilentlyContinue }
  }
  $e = Get-UninstallEntry
  if ($e -and $e.UninstallString -match "(?i)msiexec") {
    $code = [regex]::Match($e.UninstallString, "\{[0-9A-Fa-f-]+\}").Value
    $p = Start-Process msiexec.exe -ArgumentList "/x", $code, "/qn" -Wait -PassThru
  } elseif ($e) {
    $cmd = ($e.UninstallString -replace '"', '')
    $p = Start-Process -FilePath $cmd -ArgumentList "/S" -Wait -PassThru
  }
  # The uninstaller copies itself and returns early; give it time to finish.
  $start = Get-Date
  while ((Get-UninstallEntry) -and ((Get-Date) - $start).TotalSeconds -lt 60) { Start-Sleep -Seconds 1 }
  if (-not (Get-UninstallEntry)) { Record "Uninstall removes Vello from Apps" "pass" } else { Record "Uninstall removes Vello from Apps" "fail" }
  Start-Sleep -Seconds 2
  if (-not (Get-StartMenuShortcut)) { Record "Uninstall removes the Start menu shortcut" "pass" } else { Record "Uninstall removes the Start menu shortcut" "fail" }
  $run = $null
  try { $run = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -ErrorAction Stop).PSObject.Properties | Where-Object { $_.Name -match "(?i)theo" } } catch { }
  if (-not $run) { Record "Uninstall removes the open-at-sign-in entry" "pass" } else { Record "Uninstall removes the open-at-sign-in entry" "fail" }
  if (Test-Path $DataFolder) { Record "Uninstall keeps Vello's data (bots, chats)" "pass" } else { Record "Uninstall keeps Vello's data (bots, chats)" "info" "data folder gone" }
} else { Record "Uninstall" "skip" }

# ------------------------------------------------------------------ results

Title "Writing the results"
$logs = Join-Path $DataFolder "Logs"
if (Test-Path $logs) {
  $logOut = Join-Path $OutDir "theo-logs"
  New-Item -ItemType Directory -Force -Path $logOut | Out-Null
  Get-ChildItem -Path $logs -File -ErrorAction SilentlyContinue | ForEach-Object {
    try {
      $t = [IO.File]::ReadAllText($_.FullName)
      if ($t.Length -gt 20000) { $t = $t.Substring($t.Length - 20000) }
      [IO.File]::WriteAllText((Join-Path $logOut $_.Name), (Hide-Private $t))
    } catch { }
  }
}
$final = ""
if (-not $Unattended) { $final = Ask-Text "Last one: anything else you noticed, good or bad?" }

$passed = @($Results | Where-Object { $_.result -eq "pass" }).Count
$failed = @($Results | Where-Object { $_.result -eq "fail" }).Count
$skipped = @($Results | Where-Object { $_.result -eq "skip" }).Count
$Facts["finished"] = (Get-Date).ToString("s")

$lines = New-Object System.Collections.ArrayList
[void]$lines.Add("Vello for Windows - tester results")
[void]$lines.Add("$passed passed, $failed failed, $skipped skipped")
[void]$lines.Add("")
[void]$lines.Add("This PC")
foreach ($k in $Facts.Keys) { [void]$lines.Add("  " + $k + ": " + (Hide-Private ([string]$Facts[$k]))) }
[void]$lines.Add("")
[void]$lines.Add("Steps")
foreach ($r in $Results) {
  $l = "  [" + $r.result.ToUpper() + "] " + $r.step
  if ($r.detail) { $l += "  -- " + $r.detail }
  [void]$lines.Add($l)
}
if ($Notes.Count -gt 0) { [void]$lines.Add(""); [void]$lines.Add("Notes"); foreach ($n in $Notes) { [void]$lines.Add("  " + $n) } }
if ($final) { [void]$lines.Add(""); [void]$lines.Add("Tester's last words: " + $final) }
$summary = Join-Path $OutDir "RESULTS.txt"
[IO.File]::WriteAllText($summary, ($lines -join "`r`n"))
$json = [ordered]@{ facts = $Facts; steps = $Results; notes = $Notes; last_words = $final }
[IO.File]::WriteAllText((Join-Path $OutDir "results.json"), (Hide-Private ($json | ConvertTo-Json -Depth 6)))

$zip = $OutDir + ".zip"
try {
  if (Test-Path $zip) { Remove-Item $zip -Force }
  Compress-Archive -Path (Join-Path $OutDir "*") -DestinationPath $zip -Force
} catch { $zip = $null }

Write-Host ""
Say "Done: $passed passed, $failed failed, $skipped skipped." "Cyan"
$sent = $false
if ($zip -and (Test-Path $zip) -and -not $Unattended -and -not $NoSend) {
  $sent = Send-Results $zip $summary $passed $failed
}
if ($sent) {
  Say "The results were sent back, so there's nothing to send by hand. A copy is on your Desktop:" "Green"
  Say ("  " + $zip) "Green"
} elseif ($zip -and (Test-Path $zip)) {
  Say "Please send this file back:" "Green"
  Say ("  " + $zip) "Green"
  if (-not $Unattended) { Start-Process explorer.exe -ArgumentList ("/select,`"" + $zip + "`"") }
} else {
  Say "Please zip and send back this folder:" "Yellow"
  Say ("  " + $OutDir) "Yellow"
}
if (-not $Unattended) { [void](Read-Host "Press Enter to close") }
if ($failed -gt 0) { exit 1 } else { exit 0 }
