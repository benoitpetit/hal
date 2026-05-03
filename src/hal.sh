#!/bin/bash
set -euo pipefail

#===============================================================================
# hal.sh — CLI for hal API (OpenAI-compatible chat completions)
# Requires: curl, python3
#===============================================================================

readonly VERSION="1.1.0"

# --- Configuration (env overrides defaults) ---
_API_BASE_ENC="00151849430a1f47111e5648491d09110514515d520d13424f5542530d0d42584040"
_API_BASE_KEY=$(printf '%s' 'aGFsOTAwMA==' | base64 -d 2>/dev/null || printf '%s' 'aGFsOTAwMA==' | base64 -D)
API_BASE="${HAL_API_BASE:-$(python3 -c 'import sys; k=sys.argv[1].encode(); d=bytes.fromhex(sys.argv[2]); print(bytes([d[i]^k[i%len(k)] for i in range(len(d))]).decode())' "$_API_BASE_KEY" "$_API_BASE_ENC")}"
API_BASE="${API_BASE%/}"  # trim trailing slash
API_KEY="${HAL_API_KEY:-}"
MODEL="${HAL_MODEL:-gpt-4o}"

CACHE_DIR="${HOME}/.cache/hal"
CACHE_ENABLED="${HAL_CACHE_ENABLED:-1}"
MAX_RETRIES="${HAL_MAX_RETRIES:-3}"
RETRY_DELAY="${HAL_RETRY_DELAY:-2}"
NETWORK_TIMEOUT="${HAL_NETWORK_TIMEOUT:-60}"  # Timeout réseau en secondes

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
PREPEND_TEXT=""
APPEND_TEXT=""
JSON_PATH=""
BATCH_DELAY=1

# --- Last HTTP response ---
__LAST_BODY=""
__LAST_CODE=""

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
  --temperature N     Sampling temperature (0–2)
  --max-tokens N      Max tokens to generate
  --api-base URL      API base URL (env: HAL_API_BASE)
  --api-key KEY       API key (env: HAL_API_KEY)
  --output json|raw   Output format (default: json)
  --file PATH         Attach a text file (repeatable)
  --image PATH        Attach an image file (repeatable)
  --batch FILE        Read prompts from file (one per line)
  --prepend TEXT      Insert text before message
  --append TEXT       Insert text after message
  --json-path PATH    Extract specific JSON field (dot notation)
  --batch-delay N     Delay in seconds between batch requests (default: 1)
  --list-models       Show available models
  --update            Update script to the latest version from GitHub
  --update-force      Force update even if already up to date
  --no-cache          Disable local cache
  --quiet             Suppress stderr logs
  -v, --version       Show version
  -h, --help          Show this help

Examples:
  hal.sh "Explain quantum computing"
  hal.sh --chat "Hello" --output raw --quiet
  echo "Summarize this" | hal.sh --system "Be concise" --quiet
  hal.sh --chat "Review" --file code.go --image screenshot.png
  hal.sh --batch prompts.txt --prepend "Be concise: " --append " (max 3 pts)"
  hal.sh --chat "Hello" --json-path "choices.0.message.content"
EOF
}

check_deps() {
    command -v curl >/dev/null || die "curl is required" 1
    command -v python3 >/dev/null || die "python3 is required" 1
    if [[ "$CACHE_ENABLED" -eq 1 ]]; then
        mkdir -p "$CACHE_DIR" 2>/dev/null || true
        chmod 700 "$CACHE_DIR" 2>/dev/null || true
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
    local files_hash="" images_hash=""
    for f in "${FILES[@]}"; do
        files_hash="${files_hash}$(md5sum "$f" | cut -d' ' -f1)"
    done
    for img in "${IMAGES[@]}"; do
        images_hash="${images_hash}$(md5sum "$img" | cut -d' ' -f1)"
    done
    echo -n "$msg|$SYSTEM|$MODEL|$TEMPERATURE|$MAX_TOKENS|$files_hash|$images_hash" | md5sum | cut -d' ' -f1
}

cache_path() {
    local key; key=$(cache_key "$1")
    echo "$CACHE_DIR/$key.json"
}

try_cache() {
    [[ "$CACHE_ENABLED" -eq 0 ]] && return 1
    local path; path=$(cache_path "$1")
    if [[ -f "$path" ]]; then
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
    mkdir -p "$CACHE_DIR"
    chmod 700 "$CACHE_DIR"
    printf '%s\n' "$body" > "$path"
    log "Cached: $path"
}

# --- Core logic ---
send() {
    local msg="$1"

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
            if [[ "$__LAST_CODE" == "502" && -n "$__LAST_BODY" ]]; then
                local api_err
                api_err=$(echo "$__LAST_BODY" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("error",""))' 2>/dev/null || true)
                [[ -n "$api_err" ]] && log "API error: $api_err"
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
            --chat)
                [[ $# -ge 2 ]] || die "Missing value for --chat"
                CHAT_MSG="$2"
                msg_set=1
                shift 2 ;;
            --model)
                [[ $# -ge 2 ]] || die "Missing value for --model. Use --list-models to see available models."
                MODEL="$2"
                shift 2 ;;
            --system)
                [[ $# -ge 2 ]] || die "Missing value for --system"
                SYSTEM="$2"
                shift 2 ;;
            --temperature)
                [[ $# -ge 2 ]] || die "Missing value for --temperature"
                [[ "$2" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "Invalid temperature: $2 (expected number 0–2)"
                TEMPERATURE="$2"
                shift 2 ;;
            --max-tokens)
                [[ $# -ge 2 ]] || die "Missing value for --max-tokens"
                [[ "$2" =~ ^[0-9]+$ ]] || die "Invalid max-tokens: $2 (expected positive integer)"
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
            --output)
                [[ $# -ge 2 ]] || die "Missing value for --output"
                OUTPUT="$2"
                [[ "$OUTPUT" == "json" || "$OUTPUT" == "raw" ]] || die "Invalid output: $OUTPUT (expected json or raw)"
                shift 2 ;;
            --file)
                [[ $# -ge 2 ]] || die "Missing value for --file"
                [[ -f "$2" ]] || die "File not found: $2"
                FILES+=("$2")
                shift 2 ;;
            --image)
                [[ $# -ge 2 ]] || die "Missing value for --image"
                [[ -f "$2" ]] || die "Image not found: $2"
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
        if [[ ! -t 0 ]]; then
            CHAT_MSG=$(cat)
        else
            usage
            exit 2
        fi
    fi

    CHAT_MSG=$(printf '%s\n' "$CHAT_MSG" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

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
