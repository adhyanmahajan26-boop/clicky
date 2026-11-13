<#
Theo for Windows: install, update or remove, from a GitHub release. No administrator rights needed.

  irm https://github.com/<owner>/<repo>/releases/latest/download/install.ps1 | iex

or, with options:

  & ([scriptblock]::Create((irm .../install.ps1))) -Version 202611130300 -NoLaunch

Downloads the per-user installer (Theo-<build>-windows-x64-setup.exe), checks it against the release's SHA256SUMS, and runs
it silently. The installer and the app aren't code-signed yet, so SmartScreen may warn the first time Theo opens.
#>
param(
  [string]$Version = "",
  [string]$Dir = "",
  [string]$From = "",
  [string]$Sha256 = "",
  [switch]$NoLaunch,
  [switch]$Force,
  [switch]$Uninstall,
  [switch]$Purge,
  [switch]$Yes,
  [switch]$Help
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
# Windows PowerShell 5.1 on older Windows 10 may still offer only TLS 1.0/1.1, which GitHub refuses.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

function Main {
  $Repo = if ($env:THEO_RELEASES_REPO) { $env:THEO_RELEASES_REPO } else { "adhyanmahajan26-boop/claudia-releases" }
  $Api = if ($env:THEO_GITHUB_API) { $env:THEO_GITHUB_API.TrimEnd("/") } else { "https://api.github.com" }
  $DataDir = Join-Path $env:APPDATA "Theo-Desktop"

  if ($Help) {
    Write-Output @"
Theo for Windows installer

  -Version <build>   install this build (default: the latest release)
  -Dir <folder>      install here instead of the default per-user folder
  -From <file|url>   install this setup.exe instead of downloading; needs -Sha256
  -Sha256 <hex>      the checksum -From must match
  -NoLaunch          don't open Theo afterwards
  -Force             reinstall even if this build is already installed
  -Uninstall         remove Theo, keep its data
  -Purge             remove Theo and its data (asks first; -Yes skips the question)

Environment: THEO_RELEASES_REPO, THEO_INSTALL_DIR, THEO_GITHUB_TOKEN (falls back to GH_TOKEN, GITHUB_TOKEN, then gh auth token), THEO_GITHUB_API.
"@
    return
  }
  if ($env:THEO_INSTALL_DIR -and -not $Dir) { $Dir = $env:THEO_INSTALL_DIR }

  if ($Uninstall -or $Purge) {
    if ($Purge -and -not $Yes) {
      $answer = Read-Host "This deletes Theo and all its data in $DataDir (bots, chats, memory). Type yes to go on"
      if ($answer -ne "yes") { throw "Nothing was deleted." }
    }
    $entry = Get-UninstallEntry
    if (-not $entry) { Write-Output "Theo isn't installed." }
    elseif ($entry.UninstallString -match "(?i)msiexec") {
      # Installed from the .msi: its uninstall string is MsiExec.exe /X{product code}.
      $code = [regex]::Match($entry.UninstallString, "\{[0-9A-Fa-f-]+\}").Value
      $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList @("/x", $code, "/qn", "/norestart") -Wait -PassThru
      if ($proc.ExitCode -ne 0) { throw "Removing Theo failed (msiexec code $($proc.ExitCode)); it may need an administrator." }
    } else {
      $proc = Start-Process -FilePath (Get-UninstallCommand) -ArgumentList "/S" -Wait -PassThru
      if ($proc.ExitCode -ne 0) { throw "Removing Theo failed (code $($proc.ExitCode))." }
    }
    if ($Purge) { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $DataDir; Write-Output "Theo and its data are removed." }
    else { Write-Output "Theo is removed. Its data is still in $DataDir." }
    return
  }

  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("theo-install-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $tmp | Out-Null
  try {
    $setup = Join-Path $tmp "Theo-setup.exe"
    $build = "local"
    if ($From) {
      if (-not $Sha256) { throw "-From needs -Sha256" }
      if ($From -match "^https?://") { Invoke-WebRequest -UseBasicParsing -Uri $From -OutFile $setup } else { Copy-Item $From $setup }
      if ((Get-FileHash -Algorithm SHA256 $setup).Hash.ToLower() -ne $Sha256.ToLower()) { throw "Checksum mismatch: refusing to install $From" }
    } else {
      $headers = @{ "Accept" = "application/vnd.github+json"; "User-Agent" = "theo-installer" }
      $token = Get-Token
      if ($token) { $headers["Authorization"] = "Bearer $token" }
      $url = if ($Version) { "$Api/repos/$Repo/releases/tags/build-$($Version -replace '^build-','')" } else { "$Api/repos/$Repo/releases/latest" }
      $release = Invoke-RestMethod -Uri $url -Headers $headers
      $build = $release.tag_name -replace '^build-', ''
      $installed = Get-InstalledBuild
      if (-not $Force -and $installed -eq $build) { Write-Output "Theo $build is already installed (-Force reinstalls)."; return }
      $asset = $release.assets | Where-Object { $_.name -like "*-windows-x64-setup.exe" } | Select-Object -First 1
      $sums = $release.assets | Where-Object { $_.name -eq "SHA256SUMS" } | Select-Object -First 1
      if (-not $asset) { throw "Build $build has no Windows installer." }
      if (-not $sums) { throw "Build $build has no SHA256SUMS: refusing to install." }
      $headers["Accept"] = "application/octet-stream"
      Invoke-WebRequest -UseBasicParsing -Uri $asset.url -Headers $headers -OutFile $setup
      $sumsFile = Join-Path $tmp "SHA256SUMS"
      Invoke-WebRequest -UseBasicParsing -Uri $sums.url -Headers $headers -OutFile $sumsFile
      $line = Get-Content $sumsFile | Where-Object { $_ -match ("  " + [regex]::Escape($asset.name) + "$") } | Select-Object -First 1
      if (-not $line) { throw "SHA256SUMS doesn't list $($asset.name): refusing to install." }
      $expected = ($line -split "  ")[0].ToLower()
      if ((Get-FileHash -Algorithm SHA256 $setup).Hash.ToLower() -ne $expected) { throw "Checksum mismatch for $($asset.name): refusing to install." }
    }
    $args = @("/S")
    if ($Dir) { $args += "/D=$Dir" }
    $proc = Start-Process -FilePath $setup -ArgumentList $args -Wait -PassThru
    if ($proc.ExitCode -ne 0) { throw "The Theo installer stopped with code $($proc.ExitCode); nothing was changed. If Windows blocked it, run it again and allow it." }
    if (-not (Get-AppPath)) { throw "The Theo installer finished but Theo isn't installed: try again, or run the setup .exe from the release page." }
    $marker = Join-Path $DataDir "INSTALLED_BUILD"
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    Set-Content -Path $marker -Value $build
    Write-Output "Theo $build is installed."
    if (-not $NoLaunch) {
      $exe = Get-AppPath
      if ($exe) { Start-Process -FilePath $exe }
    }
  } finally {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp
  }
}

function Get-Token {
  foreach ($v in @($env:THEO_GITHUB_TOKEN, $env:GH_TOKEN, $env:GITHUB_TOKEN)) { if ($v) { return $v } }
  if (Get-Command gh -ErrorAction SilentlyContinue) { try { return (gh auth token 2>$null) } catch { } }
  return ""
}

function Get-UninstallEntry {
  $keys = @("HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*")
  Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq "Theo" } | Select-Object -First 1
}

function Get-UninstallCommand {
  $e = Get-UninstallEntry
  if ($e -and $e.UninstallString) { return ($e.UninstallString -replace '"', '') }
  return $null
}

function Get-AppPath {
  $e = Get-UninstallEntry
  if ($e -and $e.InstallLocation) {
    $p = Join-Path ($e.InstallLocation -replace '"', '') "theo-desktop.exe"
    if (Test-Path $p) { return $p }
  }
  return $null
}

function Get-InstalledBuild {
  $marker = Join-Path (Join-Path $env:APPDATA "Theo-Desktop") "INSTALLED_BUILD"
  if (Test-Path $marker) { return (Get-Content $marker -First 1) }
  return ""
}

Main
