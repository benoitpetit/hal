#!/usr/bin/env pwsh
#Requires -Version 7.0
#===============================================================================
# hal.ps1 — CLI for hal API (OpenAI-compatible chat completions)
#===============================================================================

$ErrorActionPreference = "Stop"

$script:VERSION = "1.1.0"

# --- Configuration (env overrides defaults) ---
$script:API_BASE = $env:HAL_API_BASE
if (-not $script:API_BASE) {
    $enc = "00151849430a1f47111e5648491d09110514515d520d13424f5542530d0d42584040"
    $k = [Convert]::FromBase64String('aGFsOTAwMA==')
    $bytes = for ($i = 0; $i -lt $enc.Length; $i += 2) { [Convert]::ToByte($enc.Substring($i, 2), 16) }
    $dec = for ($i = 0; $i -lt $bytes.Count; $i++) { $bytes[$i] -bxor $k[$i % $k.Length] }
    $script:API_BASE = [System.Text.Encoding]::UTF8.GetString($dec)
}
$script:API_BASE = $script:API_BASE.TrimEnd('/')
$script:API_KEY = $env:HAL_API_KEY
if (-not $script:API_KEY) { $script:API_KEY = "" }
$script:MODEL = $env:HAL_MODEL
if (-not $script:MODEL) { $script:MODEL = "gpt-4o" }

# Cache dir: prefer XDG_CACHE_HOME, then platform-specific
if ($env:XDG_CACHE_HOME) {
    $script:CACHE_DIR = Join-Path $env:XDG_CACHE_HOME "hal"
} elseif ($IsWindows -or $env:OS -like "Windows*") {
    $script:CACHE_DIR = Join-Path $env:USERPROFILE ".cache" "hal"
} else {
    $script:CACHE_DIR = Join-Path $HOME ".cache" "hal"
}
$script:CACHE_ENABLED = if ($null -ne $env:HAL_CACHE_ENABLED) { [int]$env:HAL_CACHE_ENABLED } else { 1 }
$script:MAX_RETRIES = if ($null -ne $env:HAL_MAX_RETRIES) { [int]$env:HAL_MAX_RETRIES } else { 3 }
$script:RETRY_DELAY = if ($null -ne $env:HAL_RETRY_DELAY) { [int]$env:HAL_RETRY_DELAY } else { 2 }
$script:NETWORK_TIMEOUT = if ($null -ne $env:HAL_NETWORK_TIMEOUT) { [int]$env:HAL_NETWORK_TIMEOUT } else { 60 }

# --- Circuit breaker ---
$script:CIRCUIT_FAILURE_THRESHOLD = if ($null -ne $env:HAL_CIRCUIT_FAILURE_THRESHOLD) { [int]$env:HAL_CIRCUIT_FAILURE_THRESHOLD } else { 5 }
$script:CIRCUIT_RESET_TIMEOUT = if ($null -ne $env:HAL_CIRCUIT_RESET_TIMEOUT) { [int]$env:HAL_CIRCUIT_RESET_TIMEOUT } else { 30 }
$script:CIRCUIT_STATE = "closed"  # closed, open, half-open
$script:CIRCUIT_FAILURES = 0

# --- Runtime defaults ---
$script:QUIET = $false
$script:OUTPUT = "json"
$script:SYSTEM = ""
$script:TEMPERATURE = ""
$script:MAX_TOKENS = ""
$script:CHAT_MSG = ""
$script:FILES = @()
$script:IMAGES = @()
$script:BATCH_FILE = ""
$script:PREPEND_TEXT = ""
$script:APPEND_TEXT = ""
$script:JSON_PATH = ""
$script:BATCH_DELAY = 1

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
        [Console]::Out.WriteLine((@{ error = $Message } | ConvertTo-Json -Compress -Depth 10))
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

Set default:  `$env:HAL_MODEL = `"gpt-4o`"
Per-request:  `.\hal.ps1 -Chat `"...`" -Model claude-opus-4`
"@
    [Console]::Error.WriteLine($models)
}

function Update-Script {
    param([switch]$Force)
    $scriptUrl = "https://raw.githubusercontent.com/benoitpetit/hal/main/src/hal.ps1"
    $tmpFile = [System.IO.Path]::GetTempFileName()

    Write-Log "Checking for updates..."
    try {
        Invoke-WebRequest -Uri $scriptUrl -OutFile $tmpFile -ErrorAction Stop
    } catch {
        Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue
        Die "Failed to download latest version: $($_.Exception.Message)" 1
    }

    $currentPath = $PSCommandPath
    if (-not $currentPath) {
        Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue
        Die "Cannot determine script path. Please update manually." 1
    }

    if (-not $Force) {
        $localHash = (Get-FileHash -Path $currentPath -Algorithm SHA256).Hash
        $remoteHash = (Get-FileHash -Path $tmpFile -Algorithm SHA256).Hash
        if ($localHash -eq $remoteHash) {
            Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue
            Write-Log "Already up to date (version $script:VERSION)"
            exit 0
        }
    }

    try {
        Copy-Item -Path $tmpFile -Destination $currentPath -Force -ErrorAction Stop
    } catch {
        Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue
        Die "Cannot write to $currentPath. Run as administrator or check permissions: $($_.Exception.Message)" 1
    } finally {
        Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue
    }

    $newVersion = (Select-String -Path $currentPath -Pattern '\$script:VERSION = "(.*)"').Matches.Groups[1].Value
    Write-Log "Updated successfully to version $newVersion"
    exit 0
}

function Show-Usage {
    $usage = @"
hal $script:VERSION

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
  -Image PATH          Attach an image (repeatable)
  -Batch FILE          Read prompts from file (one per line)
  -Prepend TEXT        Insert text before message
  -Append TEXT         Insert text after message
  -JsonPath PATH       Extract specific JSON field (dot notation)
  -BatchDelay N        Delay in seconds between batch requests (default: 1)
  -ListModels          Show available models
  -Update              Update script to the latest version from GitHub
  -UpdateForce         Force update even if already up to date
  -NoCache             Disable local cache
  -Quiet               Suppress stderr logs
  -Version             Show version
  -h, -Help            Show this help

Examples:
  .\hal.ps1 "Explain quantum computing"
  .\hal.ps1 -Chat "Hello" -Output raw -Quiet
  "Summarize this" | .\hal.ps1 -System "Be concise" -Quiet | ConvertFrom-Json
  .\hal.ps1 -Chat "Review" -File code.go -Image screenshot.png
  .\hal.ps1 -Batch prompts.txt -Prepend "Be concise: " -Append " (max 3 pts)"
  .\hal.ps1 -Chat "Hello" -JsonPath "choices.0.message.content"
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
function Resize-ImageIfNeeded {
    param([string]$ImagePath)
    $MAX_SIZE = 512
    $bytes = [System.IO.File]::ReadAllBytes($ImagePath)
    if ($bytes.Length -le 500 * 1024) {
        return $bytes
    }
    try {
        Add-Type -AssemblyName System.Drawing
        $memStream = [System.IO.MemoryStream]::new($bytes)
        $image = [System.Drawing.Image]::FromStream($memStream)
        if ($image.Width -gt $MAX_SIZE -or $image.Height -gt $MAX_SIZE) {
            $ratio = [Math]::Min($MAX_SIZE / $image.Width, $MAX_SIZE / $image.Height)
            $newWidth = [int]($image.Width * $ratio)
            $newHeight = [int]($image.Height * $ratio)
            $thumbnail = [System.Drawing.Bitmap]::new($newWidth, $newHeight)
            $graphics = [System.Drawing.Graphics]::FromImage($thumbnail)
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.DrawImage($image, 0, 0, $newWidth, $newHeight)
            $outStream = [System.IO.MemoryStream]::new()
            $thumbnail.Save($outStream, $image.RawFormat)
            $graphics.Dispose()
            $thumbnail.Dispose()
            $image.Dispose()
            $memStream.Dispose()
            return $outStream.ToArray()
        }
        $image.Dispose()
        $memStream.Dispose()
    } catch {
        # Fallback: return original bytes if resizing fails
    }
    return $bytes
}

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
            $bytes = Resize-ImageIfNeeded -ImagePath $img
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

# --- Circuit breaker ---
function Open-Circuit {
    $script:CIRCUIT_STATE = "open"
    $script:CIRCUIT_FAILURES = 0
    Write-Log "Circuit breaker OPEN (too many failures)"
}

function Record-CircuitFailure {
    $script:CIRCUIT_FAILURES++
    if ($script:CIRCUIT_STATE -eq "closed" -and $script:CIRCUIT_FAILURES -ge $script:CIRCUIT_FAILURE_THRESHOLD) {
        Open-Circuit
    }
}

function Record-CircuitSuccess {
    if ($script:CIRCUIT_STATE -ne "closed") {
        $script:CIRCUIT_STATE = "closed"
        $script:CIRCUIT_FAILURES = 0
        Write-Log "Circuit breaker CLOSED (recovered)"
    }
}

function Test-Circuit {
    if ($script:CIRCUIT_STATE -eq "open") {
        Write-Log "Circuit breaker OPEN - retry after $($script:CIRCUIT_RESET_TIMEOUT)s"
        Start-Sleep -Seconds $script:CIRCUIT_RESET_TIMEOUT
        $script:CIRCUIT_STATE = "half-open"
    }
}

# --- HTTP ---
function Invoke-HalRequest {
    param([string]$Url, [string]$Payload)
    $tmpDir = [System.IO.Path]::GetTempPath()
    $tmpPayloadFile = [System.IO.Path]::Combine($tmpDir, [System.Guid]::NewGuid().ToString() + ".json")
    $tmpBodyFile = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tmpPayloadFile, $Payload, [System.Text.Encoding]::UTF8)

    $curlArgs = @("-s", "-S", "-w", "%{http_code}", "-o", $tmpBodyFile, "--max-time", $script:NETWORK_TIMEOUT)
    $curlArgs += @("-X", "POST", "-H", "content-type: application/json")
    if ($script:API_KEY) {
        $curlArgs += @("-H", "authorization: Bearer $($script:API_KEY)")
    }
    $curlArgs += @("--data-binary", "@$tmpPayloadFile", $Url)

    try {
        $script:__LAST_CODE = & curl @curlArgs
        $script:__LAST_BODY = Get-Content -Raw -Path $tmpBodyFile -Encoding utf8
    } finally {
        Remove-Item -Path $tmpPayloadFile -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $tmpBodyFile -Force -ErrorAction SilentlyContinue
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

    # Apply prepend/append
    if ($script:PREPEND_TEXT) { $Message = $script:PREPEND_TEXT + $Message }
    if ($script:APPEND_TEXT) { $Message = $Message + $script:APPEND_TEXT }

    if ([string]::IsNullOrWhiteSpace($script:API_BASE)) {
        Die "API base URL is required. Set HAL_API_BASE or use -ApiBase." 2
    }
    if ([string]::IsNullOrWhiteSpace($script:MODEL)) {
        Die "Model is required. Set HAL_MODEL or use -Model." 2
    }

    $url = "$($script:API_BASE)/chat/completions"

    if (Test-Cache -Message $Message) {
        # cached
    } else {
        $payload = Build-Payload -Message $Message

        Test-Circuit

        $attempt = 0
        $retryDelay = $script:RETRY_DELAY
        while ($true) {
            $attempt++
            Write-Log "Request $attempt/$($script:MAX_RETRIES)"

            Invoke-HalRequest -Url $url -Payload $payload

            if ($script:__LAST_CODE -match "^2\d{2}$") {
                Record-CircuitSuccess
                break
            }

            Record-CircuitFailure
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
            Write-Log "Retry in ${retryDelay}s..."
            Start-Sleep -Seconds $retryDelay
            $retryDelay = $retryDelay * 2  # Exponential backoff
        }

        if ($script:__LAST_BODY) {
            Save-Cache -Message $Message -Body $script:__LAST_BODY
        }
    }

    if ($script:OUTPUT -eq "raw") {
        $result = Extract-Content -Body $script:__LAST_BODY
        if ($script:JSON_PATH) {
            try {
                $obj = $result | ConvertFrom-Json -ErrorAction Stop
                $parts = $script:JSON_PATH.Split('.')
                foreach ($p in $parts) {
                    if ($p -match '^\d+$') { $obj = $obj[[int]$p] }
                    else { $obj = $obj.$p }
                }
                if ($obj -is [string]) { $obj } else { $obj | ConvertTo-Json -Depth 10 -Compress }
            } catch { $result }
        } else { $result }
    } else {
        if ($script:JSON_PATH) {
            try {
                $obj = $script:__LAST_BODY | ConvertFrom-Json -ErrorAction Stop
                $parts = $script:JSON_PATH.Split('.')
                foreach ($p in $parts) {
                    if ($p -match '^\d+$') { $obj = $obj[[int]$p] }
                    else { $obj = $obj.$p }
                }
                if ($obj -is [string]) { $obj } else { $obj | ConvertTo-Json -Depth 10 -Compress }
            } catch { $script:__LAST_BODY }
        } else {
            $script:__LAST_BODY
        }
    }
}

# --- Batch processing ---
function Send-Batch {
    param([string]$File)
    Get-Content $File | ForEach-Object {
        $line = $_.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { return }
        Write-Log "Batch: $line"
        Send-Chat -Message $line
        Start-Sleep -Seconds $script:BATCH_DELAY
    }
}

# --- Argument parsing ---
function Main {
    Test-Dependencies

    # -Help / -Version anywhere triggers early
    foreach ($arg in $args) {
        if ($arg -in @("-h", "-Help", "--help")) {
            Show-Usage
            exit 0
        }
        if ($arg -in @("-Version", "--version")) {
            [Console]::Error.WriteLine("hal $script:VERSION")
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
                if ($argsArray[$i + 1] -notmatch '^\d+(\.\d+)?$') { Die "Invalid temperature: $($argsArray[$i + 1]) (expected number 0–2)" 2 }
                $script:TEMPERATURE = $argsArray[$i + 1]
                $i += 2
            }
            { $_ -in "-MaxTokens", "--max-tokens" } {
                if ($i + 1 -ge $argsArray.Length) { Die "Missing value for -MaxTokens" 2 }
                if ($argsArray[$i + 1] -notmatch '^\d+$') { Die "Invalid max-tokens: $($argsArray[$i + 1]) (expected positive integer)" 2 }
                $script:MAX_TOKENS = $argsArray[$i + 1]
                $i += 2
            }
            { $_ -in "-ApiBase", "--api-base" } {
                if ($i + 1 -ge $argsArray.Length) { Die "Missing value for -ApiBase" 2 }
                $script:API_BASE = $argsArray[$i + 1].TrimEnd('/')
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
            { $_ -in "-Batch", "--batch" } {
                if ($i + 1 -ge $argsArray.Length) { Die "Missing value for -Batch" 2 }
                $p = $argsArray[$i + 1]
                if (-not (Test-Path $p)) { Die "Batch file not found: $p" 2 }
                $script:BATCH_FILE = $p
                $i += 2
            }
            { $_ -in "-Prepend", "--prepend" } {
                if ($i + 1 -ge $argsArray.Length) { Die "Missing value for -Prepend" 2 }
                $script:PREPEND_TEXT = $argsArray[$i + 1]
                $i += 2
            }
            { $_ -in "-Append", "--append" } {
                if ($i + 1 -ge $argsArray.Length) { Die "Missing value for -Append" 2 }
                $script:APPEND_TEXT = $argsArray[$i + 1]
                $i += 2
            }
            { $_ -in "-JsonPath", "--json-path" } {
                if ($i + 1 -ge $argsArray.Length) { Die "Missing value for -JsonPath" 2 }
                $script:JSON_PATH = $argsArray[$i + 1]
                $i += 2
            }
            { $_ -in "-BatchDelay", "--batch-delay" } {
                if ($i + 1 -ge $argsArray.Length) { Die "Missing value for -BatchDelay" 2 }
                if ($argsArray[$i + 1] -notmatch '^\d+$') { Die "Invalid batch-delay: $($argsArray[$i + 1]) (expected positive integer)" 2 }
                $script:BATCH_DELAY = [int]$argsArray[$i + 1]
                $i += 2
            }
            { $_ -in "-Output", "--output" } {
                if ($i + 1 -ge $argsArray.Length) { Die "Missing value for -Output" 2 }
                $script:OUTPUT = $argsArray[$i + 1]
                if ($script:OUTPUT -notin @("json", "raw")) {
                    Die "Invalid output: $($script:OUTPUT) (expected json or raw)" 2
                }
                $i += 2
            }
            { $_ -in "-ListModels", "--list-models" } {
                Show-Models
                exit 0
            }
            { $_ -in "-Update", "--update" } {
                Update-Script
            }
            { $_ -in "-UpdateForce", "--update-force" } {
                Update-Script -Force
            }
            { $_ -in "-NoCache", "--no-cache" } {
                $script:CACHE_ENABLED = 0
                $i++
            }
            { $_ -in "-Quiet", "--quiet" } {
                $script:QUIET = $true
                $i++
            }
            { $_ -in "-Version", "--version" } {
                [Console]::Error.WriteLine("hal $script:VERSION")
                exit 0
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

    if ($script:BATCH_FILE) {
        if (-not [string]::IsNullOrWhiteSpace($script:CHAT_MSG)) {
            Die "Cannot use -Batch with a message argument" 2
        }
        Send-Batch -File $script:BATCH_FILE
    } else {
        if ([string]::IsNullOrWhiteSpace($script:CHAT_MSG)) {
            Die "Message cannot be empty" 2
        }
        Send-Chat -Message $script:CHAT_MSG
    }
}

Main @args
