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
└── logo.png         # HAL 9000
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
| `HAL_MAX_RETRIES` | Retries on failure | `3` |
| `HAL_RETRY_DELAY` | Delay between retries (sec) | `2` |

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
--chat "MSG"        Message to send
--model MODEL       Model (default: gpt-4o)
--system "PROMPT"   System prompt
--temperature N     Temperature (0–2)
--max-tokens N      Max tokens
--api-base URL      API base URL
--api-key KEY       API key
--output json|raw   Output format (default: json)
--file PATH         Attach a text file (repeatable)
--image PATH        Attach an image (repeatable)
--list-models       Show available models
--no-cache          Disable local cache
--quiet             Suppress stderr logs
-h, --help          Help (available at any level)
```

> **Help note:** `--help` works everywhere. Even `hal --model --help` shows help instead of crashing.

---

## Onboard Memory

Responses are cached in `~/.cache/hal/`.

Unlike basic caching, the key is computed from the **content** of attached files and images (MD5 hash), not just their paths. Modify a file, the cache invalidates automatically.

Disable with `HAL_CACHE_ENABLED=0` or `--no-cache`.

---

## Automated Protocols

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

---

## When HAL Refuses

Two types of errors, two behaviors:

- **User errors** (missing argument, file not found, unknown option): clear message on **stderr**, exit code `1` or `2`
- **API errors** (HTTP, timeout, invalid response): format respected per `--output`:
  - `--output json` → `{"error": "..."}` on stdout
  - `--output raw` → `ERROR: ...` on stderr

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