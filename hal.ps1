#!/usr/bin/env pwsh
#Requires -Version 7.0
#===============================================================================
# hal.ps1 — CLI for hal API (OpenAI-compatible chat completions)
#===============================================================================

$ErrorActionPreference = "Stop"

# --- Configuration (env overrides defaults) ---
$script:API_BASE = $env:HAL_API_BASE
if (-not $script:API_BASE) {
    $enc = "00151849430a1f47111e5648491d09110514515d520d13424f5542530d0d42584040"
    $k = [Convert]::FromBase64String('aGFsOTAwMA==')
    $bytes = for ($i = 0; $i -lt $enc.Length; $i += 2) { [Convert]::ToByte($enc.Substring($i, 2), 16) }
    $dec = for ($i = 0; $i -lt $bytes.Count; $i++) { $bytes[$i] -bxor $k[$i % $k.Length] }
    $script:API_BASE = [System.Text.Encoding]::UTF8.GetString($dec)
}
$script:API_KEY = $env:HAL_API_KEY
if (-not $script:API_KEY) { $script:API_KEY = "" }
$script:MODEL = $env:HAL_MODEL
if (-not $script:MODEL) { $script:MODEL = "gpt-4o" }

$script:CACHE_DIR = Join-Path $HOME ".cache" "hal"
if ($env:OS -like "Windows*" -or $env:USERPROFILE) {
    $script:CACHE_DIR = Join-Path $env:USERPROFILE ".cache" "hal"
}
$script:CACHE_ENABLED = if ($null -ne $env:HAL_CACHE_ENABLED) { [int]$env:HAL_CACHE_ENABLED } else { 1 }
$script:MAX_RETRIES = if ($null -ne $env:HAL_MAX_RETRIES) { [int]$env:HAL_MAX_RETRIES } else { 3 }
$script:RETRY_DELAY = if ($null -ne $env:HAL_RETRY_DELAY) { [int]$env:HAL_RETRY_DELAY } else { 2 }

# --- Runtime defaults ---
$script:QUIET = $false
$script:OUTPUT = "json"
$script:SYSTEM = ""
$script:TEMPERATURE = ""
$script:MAX_TOKENS = ""
$script:CHAT_MSG = ""
$script:FILES = @()
$script:IMAGES = @()

$script:__LAST_BODY = ""
$script:__LAST_CODE = ""

# --- Helpers ---
function Write-Log {
    param([string]$Message)
    if (-not $script:QUIET) {
        [Console]::Error.WriteLine($Message)
    }
}

# CLI/user errors: always plain text to stderr
function Die {
    param([string]$Message, [int]$Code = 1)
    [Console]::Error.WriteLine("ERROR: $Message")
    exit $Code
}

# API/runtime errors: respect --output format
function Fatal {
    param([string]$Message, [int]$Code = 1)
    if ($script:OUTPUT -eq "json") {
        @{ error = $Message } | ConvertTo-Json -Compress -Depth 10
    } else {
        [Console]::Error.WriteLine("ERROR: $Message")
    }
    exit $Code
}

function Show-Models {
    $models = @"
Available models (tested empirically):

  gpt-4o          GPT-4o (default) — fast and versatile
  gpt-4o-mini     Lightweight and economical
  gpt-4-turbo     GPT-4 Turbo
  gpt-4           Classic GPT-4
  o1              Advanced reasoning
  o3-mini         Lightweight reasoning
  claude-sonnet-4 Claude Sonnet
  claude-opus-4   Claude Opus (most powerful)
  gemini-1.5-pro  Google Gemini 1.5 Pro
  fast            Fast / lightweight model
  llama           Meta Llama

Set default:  $env:HAL_MODEL = "gpt-4o"
Per-request:  .\hal.ps1 -Chat "..." -Model claude-opus-4
"@
    [Console]::Error.WriteLine($models)
}

function Show-Usage {
    $usage = @"
Usage: hal.ps1 [OPTIONS] [MESSAGE]

CLI for hal API - OpenAI-compatible chat completions.
Stderr: logs. Stdout: response (JSON or raw).

Options:
  -Chat "MSG"          Message to send (required if no stdin/arg)
  -Model MODEL         Model name (default: gpt-4o)
  -System "PROMPT"     System prompt
  -Temperature N       Sampling temperature (0-2)
  -MaxTokens N         Max tokens to generate
  -ApiBase URL         API base URL (env: HAL_API_BASE)
  -ApiKey KEY          API key (env: HAL_API_KEY)
  -Output json|raw     Output format (default: json)
  -File PATH           Attach a text file (repeatable)
  -Image PATH          Attach an image file (repeatable)
  -ListModels          Show available models
  -NoCache             Disable local cache
  -Quiet               Suppress stderr logs
  -h, -Help            Show this help

Examples:
  .\hal.ps1 "Explain quantum computing"
  .\hal.ps1 -Chat "Hello" -Output raw -Quiet
  "Summarize this" | .\hal.ps1 -System "Be concise" -Quiet | ConvertFrom-Json
  .\hal.ps1 -Chat "Review" -File code.go -Image screenshot.png
"@
    [Console]::Error.WriteLine($usage)
}

function Test-Dependencies {
    try {
        $null = Get-Command curl -ErrorAction Stop
    } catch {
        Die "curl is required but not found" 1
    }
}

# --- JSON helpers ---
function Build-Payload {
    param([string]$Message)
    $messages = @()
    if ($script:SYSTEM) {
        $messages += @{ role = "system"; content = $script:SYSTEM }
    }

    if ($script:IMAGES.Count -gt 0) {
        $content = @()
        foreach ($f in $script:FILES) {
            $text = "--- $(Split-Path $f -Leaf) ---`n$([System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8))"
            $content += @{ type = "text"; text = $text }
        }
        $content += @{ type = "text"; text = $Message }
        foreach ($img in $script:IMAGES) {
            $ext = [System.IO.Path]::GetExtension($img).ToLower()
            $mime = switch ($ext) {
                ".jpg"  { "image/jpeg" }
                ".jpeg" { "image/jpeg" }
                ".gif"  { "image/gif" }
                ".webp" { "image/webp" }
                default { "image/png" }
            }
            $bytes = [System.IO.File]::ReadAllBytes($img)
            $b64 = [Convert]::ToBase64String($bytes)
            $content += @{ type = "image_url"; image_url = @{ url = "data:$mime;base64,$b64" } }
        }
        $messages += @{ role = "user"; content = $content }
    } else {
        $parts = @()
        foreach ($f in $script:FILES) {
            $parts += "--- $(Split-Path $f -Leaf) ---`n$([System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8))"
        }
        if ($parts.Count -gt 0) {
            $parts += $Message
            $messages += @{ role = "user"; content = ($parts -join "`n`n") }
        } else {
            $messages += @{ role = "user"; content = $Message }
        }
    }

    $payload = @{
        model = $script:MODEL
        messages = $messages
    }
    if ($script:TEMPERATURE -ne "") {
        $payload.temperature = [double]$script:TEMPERATURE
    }
    if ($script:MAX_TOKENS -ne "") {
        $payload.max_tokens = [int]$script:MAX_TOKENS
    }
    $payload | ConvertTo-Json -Compress -Depth 10
}

function Extract-Content {
    param([string]$Body)
    try {
        $data = $Body | ConvertFrom-Json -ErrorAction Stop
        $data.choices[0].message.content
    } catch {
        Fatal "Invalid response — $($_.Exception.Message)" 1
    }
}

# --- HTTP ---
function Invoke-HalRequest {
    param([string]$Url, [string]$Payload)
    $tmpFile = [System.IO.Path]::GetTempFileName()
    $curlArgs = @("-s", "-S", "-w", "%{http_code}", "-o", $tmpFile)
    $curlArgs += @("-X", "POST", "-H", "content-type: application/json")
    if ($script:API_KEY) {
        $curlArgs += @("-H", "authorization: Bearer $($script:API_KEY)")
    }
    $curlArgs += @("-d", $Payload, $Url)

    try {
        $script:__LAST_CODE = & curl @curlArgs
        $script:__LAST_BODY = Get-Content -Raw -Path $tmpFile -Encoding utf8
    } finally {
        Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue
    }
}

# --- Cache ---
function Get-CacheKey {
    param([string]$Message)
    $fileHashes = ($script:FILES | ForEach-Object { (Get-FileHash -Path $_ -Algorithm MD5).Hash }) -join ""
    $imageHashes = ($script:IMAGES | ForEach-Object { (Get-FileHash -Path $_ -Algorithm MD5).Hash }) -join ""
    $inputString = "$Message|$($script:SYSTEM)|$($script:MODEL)|$($script:TEMPERATURE)|$($script:MAX_TOKENS)|$fileHashes|$imageHashes"
    $inputBytes = [System.Text.Encoding]::UTF8.GetBytes($inputString)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $hashBytes = $md5.ComputeHash($inputBytes)
    [BitConverter]::ToString($hashBytes) -replace "-", ""
}

function Get-CachePath {
    param([string]$Message)
    $key = Get-CacheKey -Message $Message
    Join-Path $script:CACHE_DIR "$key.json"
}

function Test-Cache {
    param([string]$Message)
    if ($script:CACHE_ENABLED -ne 1) { return $false }
    $path = Get-CachePath -Message $Message
    if (Test-Path $path) {
        Write-Log "Cache hit: $path"
        $script:__LAST_BODY = Get-Content -Raw -Path $path -Encoding utf8
        $script:__LAST_CODE = "200"
        return $true
    }
    return $false
}

function Save-Cache {
    param([string]$Message, [string]$Body)
    if ($script:CACHE_ENABLED -ne 1) { return }
    $path = Get-CachePath -Message $Message
    New-Item -ItemType Directory -Path $script:CACHE_DIR -Force | Out-Null
    Set-Content -Path $path -Value $Body -Encoding utf8 -NoNewline
    Write-Log "Cached: $path"
}

# --- Core logic ---
function Send-Chat {
    param([string]$Message)
    $url = "$($script:API_BASE)/chat/completions"

    if (Test-Cache -Message $Message) {
        # cached
    } else {
        $payload = Build-Payload -Message $Message

        $attempt = 0
        while ($true) {
            $attempt++
            Write-Log "Request $attempt/$($script:MAX_RETRIES) → $url"

            Invoke-HalRequest -Url $url -Payload $payload

            if ($script:__LAST_CODE -match "^2\d{2}$") {
                break
            }

            Write-Log "HTTP $($script:__LAST_CODE)"
            if ($script:__LAST_CODE -eq "502" -and $script:__LAST_BODY) {
                try {
                    $errObj = $script:__LAST_BODY | ConvertFrom-Json -ErrorAction Stop
                    if ($errObj.error) {
                        Write-Log "API error: $($errObj.error)"
                    }
                } catch { }
            }

            if ($attempt -ge $script:MAX_RETRIES) {
                Fatal "Request failed after $script:MAX_RETRIES attempts (HTTP $($script:__LAST_CODE))" 3
            }
            Start-Sleep -Seconds $script:RETRY_DELAY
        }

        if ($script:__LAST_BODY) {
            Save-Cache -Message $Message -Body $script:__LAST_BODY
        }
    }

    if ($script:OUTPUT -eq "raw") {
        Extract-Content -Body $script:__LAST_BODY
    } else {
        $script:__LAST_BODY
    }
}

# --- Argument parsing ---
function Main {
    Test-Dependencies

    # -Help anywhere triggers usage
    foreach ($arg in $args) {
        if ($arg -in @("-h", "-Help", "--help")) {
            Show-Usage
            exit 0
        }
    }

    $msgSet = $false
    $i = 0
    $argsArray = $args

    while ($i -lt $argsArray.Length) {
        $arg = $argsArray[$i]
        switch ($arg) {
            { $_ -in "-Chat", "--chat" } {
                if ($i + 1 -ge $argsArray.Length) { Die "Missing value for -Chat" 2 }
                $script:CHAT_MSG = $argsArray[$i + 1]
                $msgSet = $true
                $i += 2
            }
            { $_ -in "-Model", "--model" } {
                if ($i + 1 -ge $argsArray.Length) { Die "Missing value for -Model. Use -ListModels to see available models." 2 }
                $script:MODEL = $argsArray[$i + 1]
                $i += 2
            }
            { $_ -in "-System", "--system" } {
                if ($i + 1 -ge $argsArray.Length) { Die "Missing value for -System" 2 }
                $script:SYSTEM = $argsArray[$i + 1]
                $i += 2
            }
            { $_ -in "-Temperature", "--temperature" } {
                if ($i + 1 -ge $argsArray.Length) { Die "Missing value for -Temperature" 2 }
                $script:TEMPERATURE = $argsArray[$i + 1]
                $i += 2
            }
            { $_ -in "-MaxTokens", "--max-tokens" } {
                if ($i + 1 -ge $argsArray.Length) { Die "Missing value for -MaxTokens" 2 }
                $script:MAX_TOKENS = $argsArray[$i + 1]
                $i += 2
            }
            { $_ -in "-ApiBase", "--api-base" } {
                if ($i + 1 -ge $argsArray.Length) { Die "Missing value for -ApiBase" 2 }
                $script:API_BASE = $argsArray[$i + 1]
                $i += 2
            }
            { $_ -in "-ApiKey", "--api-key" } {
                if ($i + 1 -ge $argsArray.Length) { Die "Missing value for -ApiKey" 2 }
                $script:API_KEY = $argsArray[$i + 1]
                $i += 2
            }
            { $_ -in "-File", "--file" } {
                if ($i + 1 -ge $argsArray.Length) { Die "Missing value for -File" 2 }
                $p = $argsArray[$i + 1]
                if (-not (Test-Path $p)) { Die "File not found: $p" 2 }
                $script:FILES += $p
                $i += 2
            }
            { $_ -in "-Image", "--image" } {
                if ($i + 1 -ge $argsArray.Length) { Die "Missing value for -Image" 2 }
                $p = $argsArray[$i + 1]
                if (-not (Test-Path $p)) { Die "Image not found: $p" 2 }
                $script:IMAGES += $p
                $i += 2
            }
            { $_ -in "-Output", "--output" } {
                if ($i + 1 -ge $argsArray.Length) { Die "Missing value for -Output" 2 }
                $script:OUTPUT = $argsArray[$i + 1]
                if ($script:OUTPUT -notin @("json", "raw")) {
                    Die "Invalid output: $($script:OUTPUT)" 2
                }
                $i += 2
            }
            { $_ -in "-ListModels", "--list-models" } {
                Show-Models
                exit 0
            }
            { $_ -in "-NoCache", "--no-cache" } {
                $script:CACHE_ENABLED = 0
                $i++
            }
            { $_ -in "-Quiet", "--quiet" } {
                $script:QUIET = $true
                $i++
            }
            { $_ -in "-h", "-Help", "--help" } {
                Show-Usage
                exit 0
            }
            default {
                if ($arg.StartsWith("-")) {
                    Die "Unknown option: $arg" 2
                } else {
                    $script:CHAT_MSG = $arg
                    $msgSet = $true
                    $i++
                }
            }
        }
    }

    if (-not $msgSet) {
        if (-not [Console]::IsInputRedirected) {
            Show-Usage
            exit 1
        }
        $script:CHAT_MSG = [Console]::In.ReadToEnd()
    }

    $script:CHAT_MSG = $script:CHAT_MSG.Trim()
    if ([string]::IsNullOrWhiteSpace($script:CHAT_MSG)) {
        Die "Message cannot be empty" 2
    }

    Send-Chat -Message $script:CHAT_MSG
}

Main @args
