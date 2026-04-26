#!/usr/bin/env pwsh

param(
    [string]$Command = "install",
    [string]$Prefix = "/usr/local/bin"
)

$ErrorActionPreference = "Stop"
$Version = "1.0.0"

$InstallDir = if ($IsWindows -or $env:OS -like "Windows*") {
    if ($env:LOCALAPPDATA) { "$env:LOCALAPPDATA\hal" } else { "$env:USERPROFILE\hal" }
} elseif ($Prefix -and $Prefix.StartsWith("/")) {
    $Prefix
} else {
    "/usr/local/bin"
}

$CacheDir = if ($IsWindows -or $env:OS -like "Windows*") {
    "$env:USERPROFILE\.cache\hal"
} else {
    "$env:HOME/.cache/hal"
}

function Show-Usage {
    @"
hal installer (Windows PowerShell)

Usage: .\install.ps1 [command] [options]

Commands:
  install     Install hal (default)
  uninstall   Remove hal from system
  update      Update hal to latest version
  status      Show installation status

Options:
  -Prefix DIR    Installation directory (default: $InstallDir)

Examples:
  .\install.ps1 install
  .\install.ps1 uninstall
  .\install.ps1 status
"@
}

function Test-Dependencies {
    $missing = @()
    if (-not (Get-Command curl -ErrorAction SilentlyContinue)) { $missing += "curl" }
    if (-not (Get-Command python -ErrorAction SilentlyContinue) -and
        -not (Get-Command python3 -ErrorAction SilentlyContinue)) { $missing += "python3" }

    if ($missing.Count -gt 0) {
        Write-Error "Missing dependencies: $($missing -join ', ')"
        exit 1
    }
}

function Install-Hal {
    Test-Dependencies

    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $SrcDir = Join-Path (Split-Path -Parent $ScriptDir) "src"

    if (-not (Test-Path "$SrcDir\hal.ps1")) {
        Write-Error "hal.ps1 not found in $SrcDir"
        exit 1
    }

    Write-Host "Installing hal to $InstallDir\hal.ps1" -ForegroundColor Cyan

    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    Copy-Item "$SrcDir\hal.ps1" "$InstallDir\hal.ps1" -Force

    if (-not (Test-Path $CacheDir)) {
        New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    }
    if ($IsWindows -or $env:OS -like "Windows*") {
        (Get-Item $CacheDir).Attributes = "Hidden"
    }

    Write-Host "Created cache directory: $CacheDir" -ForegroundColor Green
    Write-Host "Done. Run 'hal.ps1 -Help' (or add $InstallDir to PATH)" -ForegroundColor Green
}

function Uninstall-Hal {
    $halPath = Join-Path $InstallDir "hal.ps1"
    if (Test-Path $halPath) {
        Remove-Item $halPath -Force
        Write-Host "Removed $halPath" -ForegroundColor Green
    } else {
        Write-Host "hal not found in $InstallDir" -ForegroundColor Yellow
    }

    if (Test-Path $CacheDir) {
        Remove-Item $CacheDir -Recurse -Force
        Write-Host "Removed cache: $CacheDir" -ForegroundColor Green
    }
}

function Update-Hal {
    Write-Host "Update check (version: $Version)" -ForegroundColor Cyan
    Write-Host "To update, pull latest and re-run: .\install.ps1 install" -ForegroundColor Yellow
}

function Show-Status {
    Write-Host "=== hal status ===" -ForegroundColor Cyan
    Write-Host "Version: $Version"
    Write-Host ""

    $halPath = Join-Path $InstallDir "hal.ps1"
    if (Test-Path $halPath) {
        Write-Host "Installed: $halPath" -ForegroundColor Green
    } else {
        Write-Host "Installed: No" -ForegroundColor Yellow
    }
    Write-Host ""

    if (Test-Path $CacheDir) {
        $cached = (Get-ChildItem $CacheDir -File -ErrorAction SilentlyContinue).Count
        Write-Host "Cache: $CacheDir ($cached cached responses)"
    } else {
        Write-Host "Cache: Not created" -ForegroundColor Yellow
    }
}

switch ($Command) {
    "install"   { Install-Hal }
    "uninstall" { Uninstall-Hal }
    "update"    { Update-Hal }
    "status"    { Show-Status }
    "help"      { Show-Usage }
    default     { Write-Error "Unknown command: $Command"; Show-Usage; exit 1 }
}
