#!/bin/bash
set -euo pipefail

#===============================================================================
# hal.sh — CLI for hal API (OpenAI-compatible chat completions)
# Requires: curl, python3
#===============================================================================

readonly VERSION="1.2.0"

# --- Configuration (env overrides defaults) ---
_API_BASE_ENC="00151849430a1f47111e5648491d09110514515d520d13424f5542530d0d42584040"
_API_BASE_KEY=$(printf '%s' 'aGFsOTAwMA==' | base64 -d 2>/dev/null || printf '%s' 'aGFsOTAwMA==' | base64 -D)
API_BASE="${HAL_API_BASE:-$(python3 -c 'import sys; k=sys.argv[1].encode(); d=bytes.fromhex(sys.argv[2]); print(bytes([d[i]^k[i%len(k)] for i in range(len(d))]).decode())' "$_API_BASE_KEY" "$_API_BASE_ENC")}"
API_BASE="${API_BASE%/}"  # trim trailing slash
API_KEY="${HAL_API_KEY:-}"
MODEL="${HAL_MODEL:-gpt-4o}"

# Cache directory: prefer XDG_CACHE_HOME, then HOME
if [[ -n "${XDG_CACHE_HOME:-}" ]]; then
    CACHE_DIR="${XDG_CACHE_HOME}/hal"
else
    CACHE_DIR="${HOME}/.cache/hal"
fi

CACHE_ENABLED="${HAL_CACHE_ENABLED:-1}"
CACHE_TTL="${HAL_CACHE_TTL:-0}"  # 0 = no TTL (permanent cache)
MAX_RETRIES="${HAL_MAX_RETRIES:-3}"
RETRY_DELAY="${HAL_RETRY_DELAY:-2}"
NETWORK_TIMEOUT="${HAL_NETWORK_TIMEOUT:-60}"  # Timeout réseau en secondes
MAX_FILE_SIZE=$((1024 * 1024))  # 1MB default

# --- Circuit breaker ---
CIRCUIT_FAILURE_THRESHOLD="${HAL_CIRCUIT_FAILURE_THRESHOLD:-5}"  # Échecs consécutifs avant ouverture
CIRCUIT_RESET_TIMEOUT="${HAL_CIRCUIT_RESET_TIMEOUT:-30}"  # Secondes avant tentative de réouverture
__CIRCUIT_STATE="closed"  # closed, open, half-open
__CIRCUIT_FAILURES=0

# --- Runtime defaults ---
QUIET=0
OUTPUT="json"
SYSTEM=""
TEMPERATURE=""
MAX_TOKENS=""
CHAT_MSG=""
declare -a FILES=()
declare -a IMAGES=()
BATCH_FILE=""
PREPEND_TEXT="${HAL_PREPEND:-}"
APPEND_TEXT="${HAL_APPEND:-}"
JSON_PATH="${HAL_JSON_PATH:-}"
BATCH_DELAY="${HAL_BATCH_DELAY:-1}"
STREAM=0
DRY_RUN=0

# --- Last HTTP response ---
__LAST_BODY=""
__LAST_CODE=""

# --- Load external config file (~/.halrc or $HAL_CONFIG) ---
load_config() {
    # Use subshell to avoid "unbound variable" with set -u
    local config_file
    config_file=$(set +u; echo "${HAL_CONFIG:-$HOME/.halrc}")
    set -u
    [[ -f "$config_file" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        # Match: export VAR=value or VAR=value
        if [[ "$line" =~ ^[[:space:]]*export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            local var="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"
            # Remove surrounding quotes (bash native)
            [[ "$val" == \"*\" ]] && val="${val#\"}" && val="${val%\"}"
            [[ "$val" == \'*\' ]] && val="${val#\'}" && val="${val%\'}"
            export "$var"="$val"
        elif [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            local var="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"
            [[ "$val" == \"*\" ]] && val="${val#\"}" && val="${val%\"}"
            [[ "$val" == \'*\' ]] && val="${val#\'}" && val="${val%\'}"
            export "$var"="$val"
        fi
    done < "$config_file"
}

# --- Helpers ---
log() { [[ "$QUIET" -eq 0 ]] && echo "$*" >&2 || true; }

# CLI/user errors: always plain text to stderr
die() {
    echo "ERROR: $1" >&2
    exit "${2:-1}"
}

# API/runtime errors: respect --output format
fatal() {
    local msg="$1" code="${2:-1}"
    if [[ "$OUTPUT" == "json" ]]; then
        python3 -c "import json,sys; print(json.dumps({'error':sys.argv[1]},ensure_ascii=False))" "$msg"
    else
        echo "ERROR: $msg" >&2
    fi
    exit "$code"
}

list_models() {
    cat <<'EOF' >&2
Available models (tested empirically):

  gpt-4o             GPT-4o (default) — fast and versatile
  gpt-4o-mini        Lightweight and economical
  gpt-4-turbo        GPT-4 Turbo
  gpt-4              Classic GPT-4
  o1                 Advanced reasoning
  o3-mini            Lightweight reasoning
  claude-sonnet-4    Claude Sonnet
  claude-opus-4      Claude Opus (most powerful)
  claude-3-haiku     Claude 3 Haiku
  gemini-1.5-pro     Google Gemini 1.5 Pro
  gemini-2.0-flash   Google Gemini 2.0 Flash
  gemini-3           Google Gemini 3
  gemini-3-pro       Google Gemini 3 Pro
  gemini-3-flash     Google Gemini 3 Flash
  deepseek-chat      DeepSeek Chat
  deepseek-reasoner  DeepSeek Reasoner
  deepseek-v4        DeepSeek V4
  deepseek-v4-reasoner  DeepSeek V4 Reasoner
  deepseek-chat-v4   DeepSeek Chat V4
  mistral-large      Mistral Large
  mixtral-8x7b       Mixtral 8x7B
  command-r          Cohere Command R
  command-r-plus     Cohere Command R+
  llama              Meta Llama
  llama-3.2          Meta Llama 3.2
  gpt-5              GPT-5 (most advanced)
  gpt-5-turbo        GPT-5 Turbo (faster)
  gpt-5-preview      GPT-5 Preview
  gpt-5-mini         GPT-5 Mini (lightweight)
  grok               Grok
  grok-2             Grok 2
  grok-3             Grok 3 (advanced reasoning)
  grok-3-mini        Grok 3 Mini
  grok-3-reasoning   Grok 3 Reasoning
  claude-4-opus      Claude 4 Opus
  fast               Fast / lightweight model

Set default:  export HAL_MODEL=gpt-4o
Per-request:  hal.sh --chat "..." --model claude-opus-4
EOF
}

do_update() {
    local force="${1:-0}"
    local script_url="https://raw.githubusercontent.com/benoitpetit/hal/main/src/hal.sh"
    local tmpfile; tmpfile=$(mktemp)

    log "Checking for updates..."
    if ! curl -fsSL "$script_url" -o "$tmpfile" 2>/dev/null; then
        rm -f "$tmpfile"
        die "Failed to download latest version" 1
    fi

    local current_path
    current_path="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"

    if [[ "$force" != "1" ]]; then
        if diff -q "$current_path" "$tmpfile" >/dev/null 2>&1; then
            rm -f "$tmpfile"
            log "Already up to date (version $VERSION)"
            exit 0
        fi
    fi

    if [[ ! -w "$current_path" ]]; then
        rm -f "$tmpfile"
        die "Cannot write to $current_path. Run with sudo or check permissions." 1
    fi

    cp "$tmpfile" "$current_path"
    chmod +x "$current_path"
    rm -f "$tmpfile"

    local new_version
    new_version=$(grep -m1 'readonly VERSION=' "$current_path" | sed 's/.*="//;s/"//')
    log "Updated successfully to version ${new_version:-unknown}"
    exit 0
}

usage() {
    cat <<EOF >&2
hal $VERSION

Usage: hal.sh [OPTIONS] [MESSAGE]

CLI for hal API — OpenAI-compatible chat completions.
Stderr: logs. Stdout: response (JSON or raw).

Options:
  --chat "MSG"        Message to send (required if no stdin/arg)
  --model MODEL       Model name (default: gpt-4o)
  --system "PROMPT"   System prompt
  --temperature N     Sampling temperature (0-2, default: model default)
  --max-tokens N      Max tokens to generate (1-100000)
  --api-base URL      API base URL (env: HAL_API_BASE)
  --api-key KEY       API key (env: HAL_API_KEY)
  --output json|raw   Output format (default: json)
  --file PATH         Attach a text file (repeatable, max 1MB)
  --image PATH        Attach an image file (repeatable, max 1MB)
  --batch FILE        Read prompts from file (one per line)
  --prepend TEXT      Insert text before message
  --append TEXT       Insert text after message
  --json-path PATH    Extract specific JSON field (dot notation)
  --batch-delay N     Delay in seconds between batch requests (default: 1)
  --stream            Stream response tokens in real-time (SSE)
  --dry-run           Build and print payload without sending
  --list-models       Show available models
  --update            Update script to the latest version from GitHub
  --update-force      Force update even if already up to date
  --no-cache          Disable local cache
  --quiet             Suppress stderr logs
  -v, --version       Show version
  -h, --help          Show this help

Short aliases:
  -c  --chat          -m  --model          -s  --system
  -t  --temperature    -o  --output          -f  --file
  -i  --image

Config file: ~/.halrc or ${HAL_CONFIG:-~/.halrc} (export VAR=value format)
Environment: HAL_API_BASE, HAL_API_KEY, HAL_MODEL, HAL_CACHE_ENABLED,
            HAL_CACHE_TTL, HAL_MAX_RETRIES, HAL_RETRY_DELAY, HAL_NETWORK_TIMEOUT,
            HAL_CIRCUIT_FAILURE_THRESHOLD, HAL_CIRCUIT_RESET_TIMEOUT,
            HAL_PREPEND, HAL_APPEND, HAL_JSON_PATH, HAL_BATCH_DELAY,
            HAL_MAX_FILE_SIZE, XDG_CACHE_HOME

Examples:
  hal.sh "Explain quantum computing"
  hal.sh --chat "Hello" --output raw --quiet
  echo "Summarize this" | hal.sh --system "Be concise" --quiet
  hal.sh --chat "Review" --file code.go --image screenshot.png
  hal.sh --batch prompts.txt --prepend "Be concise: " --append " (max 3 pts)"
  hal.sh --chat "Hello" --json-path "choices.0.message.content"
  hal.sh --chat "Tell me a story" --stream --output raw
  hal.sh --chat "Test" --dry-run
  hal.sh -m gpt-4o -c "Hello world"
EOF
}

check_deps() {
    local missing=()
    command -v curl >/dev/null || missing+=("curl")
    command -v python3 >/dev/null || missing+=("python3")

    # Check python3 version
    if command -v python3 >/dev/null 2>&1; then
        local py_ver
        py_ver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)
        if [[ -z "$py_ver" ]]; then
            missing+=("python3>=3.6")
        else
            # Compare version numbers properly (3.14 >= 3.6, but string compare "3.14" < "3.6")
            local major minor
            major=$(echo "$py_ver" | cut -d. -f1)
            minor=$(echo "$py_ver" | cut -d. -f2)
            if [[ "$major" -lt 3 ]] || [[ "$major" -eq 3 && "$minor" -lt 6 ]]; then
                missing+=("python3>=3.6")
            fi
        fi
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing dependencies: ${missing[*]}. Run 'make install-deps' or see README." 1
    fi

    # Create cache directory
    if [[ "$CACHE_ENABLED" -eq 1 ]]; then
        mkdir -p "$CACHE_DIR" 2>/dev/null || die "Cannot create cache directory: $CACHE_DIR" 1
        chmod 700 "$CACHE_DIR" 2>/dev/null || log "Warning: could not set cache directory permissions"
    fi
}

# --- Streaming support (SSE) ---
stream_send() {
    local msg="$1"

    # Apply prepend/append
    [[ -n "$PREPEND_TEXT" ]] && msg="${PREPEND_TEXT}${msg}"
    [[ -n "$APPEND_TEXT" ]] && msg="${msg}${APPEND_TEXT}"

    [[ -n "$API_BASE" ]] || die "API base URL is required. Set HAL_API_BASE or use --api-base."
    [[ -n "$MODEL" ]] || die "Model is required. Set HAL_MODEL or use --model."

    local url="$API_BASE/chat/completions"
    local payload
    payload=$(build_payload "$msg" | python3 -c '
import json, sys
d = json.load(sys.stdin)
d["stream"] = True
print(json.dumps(d, ensure_ascii=False))
')

    log "Streaming response..."

    local tmp_dir; tmp_dir=$(mktemp -d)
    local tmp_payload="$tmp_dir/payload"
    local tmp_out="$tmp_dir/output"
    printf '%s' "$payload" > "$tmp_payload"

    local -a opts=(-s -S --max-time "$NETWORK_TIMEOUT" -N)
    opts+=(-X POST -H "content-type: application/json")
    [[ -n "$API_KEY" ]] && opts+=(-H "authorization: Bearer $API_KEY")
    opts+=(-H "Accept: text/event-stream" --no-buffer --data-binary "@$tmp_payload" -o "$tmp_out" "$url")

    curl "${opts[@]}" 2>/dev/null || true

    local full_response=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" == "data: [DONE]" ]] && break

        if [[ "$line" =~ ^data:\ (.*$) ]]; then
            local data="${BASH_REMATCH[1]}"
            if [[ -n "$data" && "$data" != "[DONE]" ]]; then
                local delta_content
                delta_content=$(echo "$data" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    delta = d.get("choices", [{}])[0].get("delta", {})
    content = delta.get("content", "")
    if content:
        print(content, end="")
except:
    pass
' 2>/dev/null)

                if [[ -n "$delta_content" ]]; then
                    full_response="${full_response}${delta_content}"
                    if [[ "$OUTPUT" == "raw" ]]; then
                        printf "%s" "$delta_content"
                    fi
                fi
            fi
        fi
    done < "$tmp_out"

    rm -rf "$tmp_dir"

    if [[ "$OUTPUT" == "json" && -n "$full_response" ]]; then
        log "Stream complete"
    fi
}

# --- JSON helpers ---
build_payload() {
    local msg="$1"
    local files_json images_json
    files_json=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${FILES[@]}")
    images_json=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${IMAGES[@]}")
    python3 -c '
import json, sys, os, base64, mimetypes

try:
    from PIL import Image
    PIL_AVAILABLE = True
except ImportError:
    PIL_AVAILABLE = False

MAX_IMAGE_SIZE = 512

msg, system, model, temp, maxtok = sys.argv[1:6]
files = json.loads(sys.argv[6])
images = json.loads(sys.argv[7])

messages = []
if system:
    messages.append({"role": "system", "content": system})

if images:
    content = []
    for f in files:
        with open(f, "r", encoding="utf-8", errors="replace") as fh:
            text = "--- {} ---\n{}".format(os.path.basename(f), fh.read())
        content.append({"type": "text", "text": text})
    content.append({"type": "text", "text": msg})
    for img in images:
        mime, _ = mimetypes.guess_type(img)
        if not mime:
            ext = os.path.splitext(img)[1].lower()
            mime = "image/jpeg" if ext in (".jpg", ".jpeg") else "image/png"

        with open(img, "rb") as fh:
            img_data = fh.read()

        if PIL_AVAILABLE and len(img_data) > 500 * 1024:
            import io
            im = Image.open(img)
            if im.width > MAX_IMAGE_SIZE or im.height > MAX_IMAGE_SIZE:
                im.thumbnail((MAX_IMAGE_SIZE, MAX_IMAGE_SIZE), Image.Resampling.LANCZOS)
                buf = io.BytesIO()
                im.save(buf, format=im.format or "PNG")
                img_data = buf.getvalue()

        b64 = base64.b64encode(img_data).decode("ascii")
        content.append({"type": "image_url", "image_url": {"url": f"data:{mime};base64,{b64}"}})
    messages.append({"role": "user", "content": content})
else:
    parts = []
    for f in files:
        with open(f, "r", encoding="utf-8", errors="replace") as fh:
            parts.append("--- {} ---\n{}".format(os.path.basename(f), fh.read()))
    if parts:
        parts.append(msg)
        messages.append({"role": "user", "content": "\n\n".join(parts)})
    else:
        messages.append({"role": "user", "content": msg})

payload = {"model": model, "messages": messages}
if temp:
    payload["temperature"] = float(temp)
if maxtok:
    payload["max_tokens"] = int(maxtok)
print(json.dumps(payload, ensure_ascii=False))
' "$msg" "$SYSTEM" "$MODEL" "$TEMPERATURE" "$MAX_TOKENS" "$files_json" "$images_json"
}

extract_content() {
    python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print(data["choices"][0]["message"]["content"])
except Exception as e:
    print("ERROR: invalid response —", e, file=sys.stderr)
    sys.exit(1)
'
}

# --- Circuit breaker ---
circuit_open() {
    __CIRCUIT_STATE="open"
    __CIRCUIT_FAILURES=0
    log "Circuit breaker OPEN (too many failures)"
}

circuit_record_failure() {
    __CIRCUIT_FAILURES=$((__CIRCUIT_FAILURES + 1))
    if [[ "$__CIRCUIT_STATE" == "closed" && "$__CIRCUIT_FAILURES" -ge "$CIRCUIT_FAILURE_THRESHOLD" ]]; then
        circuit_open
    fi
}

circuit_record_success() {
    if [[ "$__CIRCUIT_STATE" != "closed" ]]; then
        __CIRCUIT_STATE="closed"
        __CIRCUIT_FAILURES=0
        log "Circuit breaker CLOSED (recovered)"
    fi
}

circuit_check() {
    if [[ "$__CIRCUIT_STATE" == "open" ]]; then
        log "Circuit breaker OPEN - retry after ${CIRCUIT_RESET_TIMEOUT}s"
        sleep "$CIRCUIT_RESET_TIMEOUT"
        __CIRCUIT_STATE="half-open"
    fi
}

# --- HTTP ---
http_post() {
    local url="$1" payload="$2"
    local tmp_dir; tmp_dir=$(mktemp -d)
    local tmp_body="$tmp_dir/body"
    local tmp_code="$tmp_dir/code"
    local tmp_payload="$tmp_dir/payload"
    printf '%s' "$payload" > "$tmp_payload"
    local -a opts=(-s -S -o "$tmp_body" -w "%{http_code}" --max-time "$NETWORK_TIMEOUT")
    opts+=(-X POST -H "content-type: application/json")
    [[ -n "$API_KEY" ]] && opts+=(-H "authorization: Bearer $API_KEY")
    opts+=(--data-binary "@$tmp_payload" "$url")

    local curl_rc=0
    curl "${opts[@]}" > "$tmp_code" 2>/dev/null || curl_rc=$?

    __LAST_CODE=$(cat "$tmp_code" | tr -d '\n' || true)
    __LAST_BODY=$(cat "$tmp_body" || true)
    rm -rf "$tmp_dir"

    : "${__LAST_CODE:=000}"
    # If curl itself failed (e.g. DNS, connection refused) and we got no HTTP code, signal it
    if [[ "$curl_rc" -ne 0 && "$__LAST_CODE" == "000" ]]; then
        __LAST_BODY=""
    fi
}

# --- Cache ---
cache_key() {
    local msg="$1"
    local files_json images_json
    files_json=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${FILES[@]}")
    images_json=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${IMAGES[@]}")
    python3 -c '
import json, sys, hashlib
msg, system, model, temp, maxtok = sys.argv[1:6]
files = json.loads(sys.argv[6])
images = json.loads(sys.argv[7])
parts = [msg, system, model, temp, maxtok]
for f in files:
    with open(f, "rb") as fh:
        parts.append(hashlib.md5(fh.read()).hexdigest())
for img in images:
    with open(img, "rb") as fh:
        parts.append(hashlib.md5(fh.read()).hexdigest())
print(hashlib.md5("|".join(parts).encode()).hexdigest())
' "$msg" "$SYSTEM" "$MODEL" "$TEMPERATURE" "$MAX_TOKENS" "$files_json" "$images_json"
}

cache_path() {
    local key; key=$(cache_key "$1")
    echo "$CACHE_DIR/$key.json"
}

try_cache() {
    [[ "$CACHE_ENABLED" -eq 0 ]] && return 1
    local path; path=$(cache_path "$1")
    if [[ -f "$path" ]]; then
        # Check TTL if enabled
        if [[ "$CACHE_TTL" -gt 0 ]]; then
            local file_age
            file_age=$(python3 -c "import os,time; print(int(time.time() - os.path.getmtime('$path')))" 2>/dev/null || echo 0)
            if [[ "$file_age" -ge "$CACHE_TTL" ]]; then
                log "Cache expired: $path (age: ${file_age}s, TTL: ${CACHE_TTL}s)"
                rm -f "$path"
                return 1
            fi
        fi
        log "Cache hit: $path"
        __LAST_BODY=$(cat "$path")
        __LAST_CODE="200"
        return 0
    fi
    return 1
}

save_cache() {
    [[ "$CACHE_ENABLED" -eq 0 ]] && return
    local msg="$1" body="$2"
    local path; path=$(cache_path "$msg")
    mkdir -p "$CACHE_DIR" 2>/dev/null || return
    chmod 700 "$CACHE_DIR" 2>/dev/null || true
    printf '%s\n' "$body" > "$path"
    log "Cached: $path"
}

# --- File size check ---
check_file_size() {
    local file="$1"
    local max_size="${2:-$MAX_FILE_SIZE}"
    local fsize
    if command -v stat >/dev/null 2>&1; then
        fsize=$(stat -c%s "$file" 2>/dev/null || echo 0)
    else
        fsize=$(wc -c < "$file" 2>/dev/null || echo 0)
    fi
    if [[ "$fsize" -gt "$max_size" ]]; then
        local size_mb=$((fsize / 1024 / 1024))
        local max_mb=$((max_size / 1024 / 1024))
        die "File too large: $file (${size_mb}MB, max ${max_mb}MB). Set HAL_MAX_FILE_SIZE to increase limit." 1
    fi
}

# --- Core logic ---
send() {
    local msg="$1"

    # Dry-run: build and print payload then exit
    if [[ "$DRY_RUN" -eq 1 ]]; then
        local payload; payload=$(build_payload "$msg")
        echo "$payload" | python3 -m json.tool 2>/dev/null || echo "$payload"
        exit 0
    fi

    # Stream: SSE mode, bypass cache
    if [[ "$STREAM" -eq 1 ]]; then
        stream_send "$msg"
        return
    fi

    # Apply prepend/append
    [[ -n "$PREPEND_TEXT" ]] && msg="${PREPEND_TEXT}${msg}"
    [[ -n "$APPEND_TEXT" ]] && msg="${msg}${APPEND_TEXT}"

    [[ -n "$API_BASE" ]] || die "API base URL is required. Set HAL_API_BASE or use --api-base."
    [[ -n "$MODEL" ]] || die "Model is required. Set HAL_MODEL or use --model."

    local url="$API_BASE/chat/completions"

    if try_cache "$msg"; then
        : # cached
    else
        local payload; payload=$(build_payload "$msg")

        circuit_check

        local attempt=0
        local retry_delay="$RETRY_DELAY"
        while true; do
            attempt=$((attempt + 1))
            log "Request $attempt/$MAX_RETRIES"

            http_post "$url" "$payload"

            if [[ "$__LAST_CODE" =~ ^2[0-9]{2}$ ]]; then
                circuit_record_success
                break
            fi

            circuit_record_failure
            log "HTTP $__LAST_CODE"

            # Better API error handling with specific codes
            if [[ -n "$__LAST_BODY" ]]; then
                local api_err
                api_err=$(echo "$__LAST_BODY" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("error",{}).get("message",d.get("error",""))' 2>/dev/null || true)
                case "$__LAST_CODE" in
                    401) fatal "Authentication failed. Check HAL_API_KEY.${api_err:+ Details: $api_err}" 401 ;;
                    404) fatal "API endpoint not found. Check HAL_API_BASE.${api_err:+ Details: $api_err}" 404 ;;
                    429) fatal "Rate limited. Please retry later.${api_err:+ Details: $api_err}" 429 ;;
                    502|503|504)
                        [[ -n "$api_err" ]] && log "API error: $api_err"
                        ;;
                    *)
                        [[ -n "$api_err" ]] && log "API error: $api_err"
                        ;;
                esac
            fi

            if [[ $attempt -ge $MAX_RETRIES ]]; then
                fatal "Request failed after $MAX_RETRIES attempts (HTTP $__LAST_CODE)" 3
            fi
            log "Retry in ${retry_delay}s..."
            sleep "$retry_delay"
            retry_delay=$((retry_delay * 2))  # Exponential backoff
        done

        [[ -n "$__LAST_BODY" ]] && save_cache "$msg" "$__LAST_BODY"
    fi

    if [[ "$OUTPUT" == "raw" ]]; then
        local result
        result=$(printf '%s\n' "$__LAST_BODY" | extract_content)
        if [[ -n "$JSON_PATH" ]]; then
            echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin) if '\"' in sys.argv[1] else sys.stdin.read(); print(json.dumps(d,ensure_ascii=False))" 2>/dev/null || echo "$result"
        else
            echo "$result"
        fi
    else
        if [[ -n "$JSON_PATH" ]]; then
            printf '%s\n' "$__LAST_BODY" | python3 -c "
import json,sys
d=json.load(sys.stdin)
parts='$JSON_PATH'.split('.')
for p in parts:
    if p.isdigit(): d=d[int(p)]
    else: d=d[p]
print(json.dumps(d,ensure_ascii=False) if isinstance(d,(dict,list)) else d)
"
        else
            printf '%s\n' "$__LAST_BODY"
        fi
    fi
}

# --- Argument parsing ---
main() {
    # Load external config first
    load_config

    check_deps

    # --help anywhere triggers usage
    for arg in "$@"; do
        if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
            usage
            exit 0
        fi
        if [[ "$arg" == "-v" || "$arg" == "--version" ]]; then
            echo "hal $VERSION"
            exit 0
        fi
    done

    local msg_set=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --chat|-c)
                [[ $# -ge 2 ]] || die "Missing value for --chat"
                CHAT_MSG="$2"
                msg_set=1
                shift 2 ;;
            --model|-m)
                [[ $# -ge 2 ]] || die "Missing value for --model. Use --list-models to see available models."
                MODEL="$2"
                shift 2 ;;
            --system|-s)
                [[ $# -ge 2 ]] || die "Missing value for --system"
                SYSTEM="$2"
                shift 2 ;;
            --temperature|-t)
                [[ $# -ge 2 ]] || die "Missing value for --temperature"
                [[ "$2" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "Invalid temperature: $2 (expected number)"
                # Validate range 0-2 using awk for proper numeric comparison
                if ! echo "$2" | awk '{if ($1 >= 0 && $1 <= 2) exit 0; else exit 1}'; then
                    die "Temperature must be between 0 and 2: $2"
                fi
                TEMPERATURE="$2"
                shift 2 ;;
            --max-tokens)
                [[ $# -ge 2 ]] || die "Missing value for --max-tokens"
                [[ "$2" =~ ^[0-9]+$ ]] || die "Invalid max-tokens: $2 (expected positive integer)"
                if [[ "$2" -gt 100000 ]]; then
                    die "max-tokens too large: $2 (max 100000)"
                fi
                MAX_TOKENS="$2"
                shift 2 ;;
            --api-base)
                [[ $# -ge 2 ]] || die "Missing value for --api-base"
                API_BASE="$2"
                API_BASE="${API_BASE%/}"
                shift 2 ;;
            --api-key)
                [[ $# -ge 2 ]] || die "Missing value for --api-key"
                API_KEY="$2"
                shift 2 ;;
            --output|-o)
                [[ $# -ge 2 ]] || die "Missing value for --output"
                OUTPUT="$2"
                [[ "$OUTPUT" == "json" || "$OUTPUT" == "raw" ]] || die "Invalid output: $OUTPUT (expected json or raw)"
                shift 2 ;;
            --file|-f)
                [[ $# -ge 2 ]] || die "Missing value for --file"
                [[ -f "$2" ]] || die "File not found: $2"
                check_file_size "$2"
                FILES+=("$2")
                shift 2 ;;
            --image|-i)
                [[ $# -ge 2 ]] || die "Missing value for --image"
                [[ -f "$2" ]] || die "Image not found: $2"
                check_file_size "$2"
                IMAGES+=("$2")
                shift 2 ;;
            --batch)
                [[ $# -ge 2 ]] || die "Missing value for --batch"
                [[ -f "$2" ]] || die "Batch file not found: $2"
                BATCH_FILE="$2"
                shift 2 ;;
            --prepend)
                [[ $# -ge 2 ]] || die "Missing value for --prepend"
                PREPEND_TEXT="$2"
                shift 2 ;;
            --append)
                [[ $# -ge 2 ]] || die "Missing value for --append"
                APPEND_TEXT="$2"
                shift 2 ;;
            --json-path)
                [[ $# -ge 2 ]] || die "Missing value for --json-path"
                JSON_PATH="$2"
                shift 2 ;;
            --batch-delay)
                [[ $# -ge 2 ]] || die "Missing value for --batch-delay"
                [[ "$2" =~ ^[0-9]+$ ]] || die "Invalid batch-delay: $2 (expected positive integer)"
                BATCH_DELAY="$2"
                shift 2 ;;
            --stream)
                STREAM=1
                shift ;;
            --dry-run)
                DRY_RUN=1
                shift ;;
            --list-models)
                list_models
                exit 0 ;;
            --update)
                do_update 0
                ;;
            --update-force)
                do_update 1
                ;;
            --no-cache)
                CACHE_ENABLED=0
                shift ;;
            --quiet)
                QUIET=1
                shift ;;
            -h|--help)
                usage
                exit 0 ;;
            -v|--version)
                echo "hal $VERSION"
                exit 0 ;;
            -*)
                die "Unknown option: $1" ;;
            *)
                CHAT_MSG="$1"
                msg_set=1
                shift ;;
        esac
    done

    if [[ $msg_set -eq 0 ]]; then
        if [[ -n "$BATCH_FILE" ]]; then
            # Batch mode: don't read stdin for message
            CHAT_MSG=""
        elif [[ ! -t 0 ]]; then
            CHAT_MSG=$(cat)
            if [[ -z "$CHAT_MSG" ]]; then
                die "stdin is empty" 1
            fi
        else
            usage
            exit 2
        fi
    fi

    if [[ -n "$CHAT_MSG" ]]; then
        CHAT_MSG=$(printf '%s\n' "$CHAT_MSG" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    fi

    if [[ -n "$BATCH_FILE" ]]; then
        [[ -n "$CHAT_MSG" ]] && die "Cannot use --batch with a message argument"
        batch_send "$BATCH_FILE"
    else
        [[ -n "$CHAT_MSG" ]] || die "Message cannot be empty"
        send "$CHAT_MSG"
    fi
}

# --- Batch processing ---
batch_send() {
    local file="$1"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        log "Batch: $line"
        send "$line"
        sleep "$BATCH_DELAY"
    done < "$file"
}

main "$@"
