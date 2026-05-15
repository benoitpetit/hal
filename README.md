# hal

<p align="center">
  <img src="logo.png" alt="HAL 9000" width="200" />
</p>

> *"I'm sorry Dave, I'm afraid I can't do that."*

Workflow-friendly CLI for **hal** API (OpenAI-compatible chat completions). Available in Bash and PowerShell.

```
hal/
├── src/              # Source scripts
│   ├── hal.sh        # Bash (Linux / macOS / WSL)
│   └── hal.ps1       # PowerShell (Windows)
├── install/          # Installers
│   ├── install.sh    # Bash installer
│   └── install.ps1   # PowerShell installer
├── Makefile          # Install / test / build
├── README.md         # This file
├── README_FR.md      # French version
├── CHANGELOG.md      # Release history
├── CONTRIBUTING.md   # Contribution guidelines
├── LICENSE           # MIT License
└── logo.png          # HAL 9000
```

---

## Deploy HAL

### One-liner install (Linux / macOS / WSL)

```bash
curl -sL https://raw.githubusercontent.com/benoitpetit/hal/main/src/hal.sh | sudo tee /usr/local/bin/hal > /dev/null && sudo chmod +x /usr/local/bin/hal
```

### One-liner install (Windows PowerShell)

```powershell
iwr -Uri https://raw.githubusercontent.com/benoitpetit/hal/main/src/hal.ps1 -OutFile hal.ps1
```

### Via make

```bash
make install
```

### Via installer script

```bash
chmod +x install/install.sh
sudo ./install.sh install
```

### Manually

```bash
chmod +x src/hal.sh
sudo cp src/hal.sh /usr/local/bin/hal
```

### Dependencies

- `curl`
- `python3` (Bash only — JSON handling)

```bash
make install-deps   # Debian/Ubuntu, macOS, Arch, Fedora
```

---

## Mission Parameters

Configure HAL via environment variables:

| Variable | Description | Default |
|----------|-------------|--------|
| `HAL_API_BASE` | API base URL | *(internal default)* |
| `HAL_API_KEY` | API key (if required) | *(none)* |
| `HAL_MODEL` | Default model | `gpt-4o` |
| `HAL_CACHE_ENABLED` | Enable local cache | `1` |
| `HAL_CACHE_TTL` | Cache expiration time (seconds, 0=disabled) | `0` |
| `HAL_MAX_RETRIES` | Retries on failure | `3` |
| `HAL_RETRY_DELAY` | Initial retry delay (sec) | `2` |
| `HAL_NETWORK_TIMEOUT` | Network timeout for requests (sec) | `60` |
| `HAL_CIRCUIT_FAILURE_THRESHOLD` | Failures before circuit opens | `5` |
| `HAL_CIRCUIT_RESET_TIMEOUT` | Seconds before circuit half-open | `30` |
| `HAL_PREPEND` | Text to prepend to message | *(none)* |
| `HAL_APPEND` | Text to append to message | *(none)* |
| `HAL_JSON_PATH` | JSON path for extraction | *(none)* |
| `HAL_BATCH_DELAY` | Delay between batch requests (sec) | `1` |
| `HAL_MAX_FILE_SIZE` | Maximum file size in bytes | `1048576` (1MB) |
| `XDG_CACHE_HOME` | XDG cache directory override | *(none, uses ~/.cache)* |
| `HAL_CONFIG` | External config file path | *(none, uses ~/.halrc)* |

> **Config file:** You can also use a config file at `~/.halrc` or the path specified in `$HAL_CONFIG`. The file supports `VAR=value` or `export VAR=value` syntax (one per line, comments with `#`).

---

## Brains Tested in Flight

The hal API does not expose a `/v1/models` endpoint. The models below were **validated one by one via real API calls** during development:

| Model | Description |
|-------|-------------|
| `gpt-4o` | GPT-4o (default) — fast and versatile |
| `gpt-4o-mini` | Lightweight and economical |
| `gpt-4-turbo` | GPT-4 Turbo |
| `gpt-4` | Classic GPT-4 |
| `o1` | Advanced reasoning |
| `o3-mini` | Lightweight reasoning |
| `claude-sonnet-4` | Claude Sonnet |
| `claude-opus-4` | Claude Opus (most powerful) |
| `gemini-1.5-pro` | Google Gemini 1.5 Pro |
| `fast` | Fast / lightweight model |
| `llama` | Meta Llama |

List available brains:

```bash
hal --list-models
```

Switch brains on the fly:

```bash
hal --chat "Code a quicksort in Rust" --model claude-opus-4
hal --chat "Quick summary" --model fast
```

---

## Talking to HAL

### Positional message (simplest)

```bash
hal "Explain special relativity"
```

### With explicit options

```bash
hal --chat "Hello" --output raw --quiet
```

### Pipe stdin (ideal for scripts)

```bash
echo "Summarize this" | hal --system "Be concise" --quiet | jq -r '.choices[0].message.content'
```

### With system prompt and model

```bash
hal --chat "Review this code" --system "You are a senior Go developer" --model gpt-4o
```

### Generation parameters

```bash
hal --chat "Write a poem about autumn" --temperature 0.9 --max-tokens 200
```

### Use a local proxy

```bash
hal --chat "ping" --api-base http://localhost:8080
```

---

## Sensory Data Analysis

### Attach a text file

```bash
hal --chat "Summarize this file" --file notes.md
hal --chat "Compare these two files" --file a.md --file b.md
```

Content is formatted exactly like captured requests from the web app:

```
--- filename ---
file content

user message
```

### Attach an image

```bash
hal --chat "Describe this image" --image photo.png
hal --chat "Compare these images" --image a.png --image b.png
```

Images are base64-encoded in OpenAI multimodal format.

### Mix text files + images

```bash
hal --chat "Review this code and tell me if the UI matches" \
  --file app.tsx --image screenshot.png
```

---

## CLI Options

```
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
```

**Short aliases:** `-c` (--chat), `-m` (--model), `-s` (--system), `-t` (--temperature), `-o` (--output), `-f` (--file), `-i` (--image)

> **Help note:** `--help` works everywhere. Even `hal --model --help` shows help instead of crashing.

---

## Onboard Memory

Responses are cached in `~/.cache/hal/` (or `$XDG_CACHE_HOME/hal/` if `XDG_CACHE_HOME` is set).

Unlike basic caching, the key is computed from the **content** of attached files and images (MD5 hash), not just their paths. Modify a file, the cache invalidates automatically.

**Cache TTL:** Set `HAL_CACHE_TTL` to enable automatic cache expiration in seconds (default: 0 = disabled/permanent).

Disable with `HAL_CACHE_ENABLED=0` or `--no-cache`.

---

## Automated Protocols

### Batch processing

Process multiple prompts from a file (one per line):

```bash
hal --batch prompts.txt
hal --batch prompts.txt --prepend "Be concise: " --append " (max 3 pts)"
hal --batch prompts.txt --batch-delay 2  # wait 2s between requests
```

### Extract specific JSON fields

Use `--json-path` with dot notation to extract specific fields:

```bash
hal --chat "Hello" --json-path "choices.0.message.content"
hal --chat "Summarize this" --file doc.md --json-path "usage.total_tokens"
```

### Combine prepend/append

```bash
hal --chat "Review this code" --prepend "You are a senior dev. " --append " Be concise."
```

### GitHub Actions

```yaml
- name: Ask hal
  run: |
    RESPONSE=$(./src/hal.sh --chat "Generate a changelog for this tag" --quiet | jq -r '.choices[0].message.content')
    echo "## Response from hal" >> $GITHUB_STEP_SUMMARY
    echo "$RESPONSE" >> $GITHUB_STEP_SUMMARY
```

### Pipeline scripting

```bash
#!/bin/bash
set -euo pipefail

DIFF=$(git diff HEAD~1)
REVIEW=$(echo "$DIFF" | hal --system "You are a senior dev. Be concise." --quiet)
echo "$REVIEW"
```

### Streaming responses

Stream tokens as they're generated (requires API SSE support):

```bash
# Stream to stdout (raw mode)
hal --chat "Write a poem" --stream --output raw --quiet

# With short aliases
hal -c "Explain this" -m gpt-4o -o raw --quiet
```

### Inspect payload without sending

```bash
# See what would be sent to the API
hal --chat "Test message" --dry-run
```

### Config file example

Create `~/.halrc`:
```bash
# ~/.halrc
HAL_MODEL=gpt-4o
HAL_API_KEY=your-api-key-here
HAL_PREPEND="You are a helpful assistant. "
HAL_CACHE_TTL=3600  # 1 hour cache
```

---

## When HAL Refuses

Two types of errors, two behaviors:

- **User errors** (missing argument, file not found, unknown option): clear message on **stderr**, exit code `1` or `2`
- **API errors** (HTTP, timeout, invalid response): format respected per `--output`:
  - `--output json` → `{"error": "..."}` on stdout
  - `--output raw` → `ERROR: ...` on stderr

---

## Self-Update

Update HAL directly from GitHub without reinstalling:

```bash
hal --update          # update only if a new version is available
hal --update-force    # force reinstallation of the latest version
```

PowerShell:

```powershell
.\hal.ps1 -Update
.\hal.ps1 -UpdateForce
```

---

## System Update

```bash
make build    # creates dist/hal.tar.gz
make test     # tests hal.sh and hal.ps1
make clean    # cleans dist/
```

---

## License

MIT — Dave, this conversation can serve no purpose anymore. Goodbye.
