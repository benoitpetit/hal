---
name: hal-cli
description: Use the hal CLI to interact with the hal API (OpenAI-compatible chat completions). Use when an agent needs to generate text, summarize files, analyze images, extract JSON fields, batch process prompts, or obtain LLM responses via a command-line interface. Triggers include "use hal", "hal", "generate with hal", "summarize with hal", "analyze image with hal", "batch process with hal", "extract JSON from hal", or any task requiring a chat completion API call through CLI.
---

# hal CLI

Use this skill to interact with the hal API directly from the command line. Supports batch processing, text prepend/append, and JSON field extraction (v1.1.0+).

## When to Use

Use `hal` for:

- Generating text, code, or LLM responses
- Summarizing text files
- Analyzing images (multimodal)
- Obtaining chat completions in JSON or raw format
- Listing available models
- **Batch processing** multiple prompts from a file
- **Extracting specific JSON fields** from responses
- **Prepending/appending text** to messages (templates)
- Any task requiring interaction with the hal/OpenAI-compatible API

Do not use `hal` when more specialized tools exist (for example, use direct `curl` to the API if complex parsing is required).

## Preconditions

### Check Installation

```bash
command -v hal
```

If `hal` is not installed, proceed with installation:

### Quick Install (Linux / macOS / WSL)

```bash
curl -sL https://raw.githubusercontent.com/benoitpetit/hal/main/src/hal.sh | sudo tee /usr/local/bin/hal > /dev/null && sudo chmod +x /usr/local/bin/hal
```

### Install via make (from the repo)

```bash
make install
```

### Install via install script

```bash
chmod +x install/install.sh
sudo ./install/install.sh install
```

### Manual Install

```bash
chmod +x src/hal.sh
sudo cp src/hal.sh /usr/local/bin/hal
```

### Dependencies

- `curl`
- `python3` (for the Bash script — JSON handling)

```bash
make install-deps   # Debian/Ubuntu, macOS, Arch, Fedora
```

### Configuration

Configure via environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `HAL_API_BASE` | API base URL | *(internal default)* |
| `HAL_API_KEY` | API key (if required) | *(none)* |
| `HAL_MODEL` | Default model | `gpt-4o` |
| `HAL_CACHE_ENABLED` | Enable local cache | `1` |
| `HAL_MAX_RETRIES` | Retries on failure | `3` |
| `HAL_RETRY_DELAY` | Initial retry delay (sec) | `2` |
| `HAL_NETWORK_TIMEOUT` | Network timeout for requests (sec) | `60` |
| `HAL_CIRCUIT_FAILURE_THRESHOLD` | Failures before circuit opens | `5` |
| `HAL_CIRCUIT_RESET_TIMEOUT` | Seconds before circuit half-open | `30` |

## Core Workflow

1. **Check that hal is installed**

```bash
command -v hal || make install
```

2. **Use hal for a task**

Simple message:
```bash
hal "Explain special relativity"
```

With explicit options:
```bash
hal --chat "Hello" --output raw --quiet
```

With pipe (ideal for scripts):
```bash
echo "Summarize this" | hal --system "Be concise" --quiet | jq -r '.choices[0].message.content'
```

3. **Attach files or images**

Text file:
```bash
hal --chat "Summarize this file" --file notes.md
```

Image:
```bash
hal --chat "Describe this image" --image photo.png
```

Mix files and images:
```bash
hal --chat "Review this code and tell me if the UI matches" --file app.tsx --image screenshot.png
```

4. **Switch models**

```bash
hal --chat "Code a quicksort in Rust" --model claude-opus-4
hal --list-models
```

5. **Batch processing (v1.1.0+)**

Process multiple prompts from a file (one per line):
```bash
hal --batch prompts.txt
hal --batch prompts.txt --batch-delay 2  # wait 2s between requests
```

6. **Prepend/Append text (v1.1.0+)**

Insert text before/after messages:
```bash
hal --chat "code review" --prepend "You are a senior dev. " --append " Be concise."
```

7. **Extract JSON fields (v1.1.0+)**

Extract specific fields using dot notation:
```bash
hal --chat "Hello" --json-path "choices.0.message.content"
hal --chat "Summarize" --file doc.md --json-path "usage.total_tokens"
```

## Command Surface

### Simple Messages

```bash
hal "Positional message"
hal --chat "Explicit message"
```

### Generation Options

```bash
hal --chat "Message" --system "You are a senior dev" --model gpt-4o --temperature 0.9 --max-tokens 200
```

### Files and Images

```bash
hal --chat "Analyze" --file document.md
hal --chat "Compare" --file a.md --file b.md
hal --chat "Describe" --image photo.png
hal --chat "Compare images" --image a.png --image b.png
hal --chat "Review" --file code.py --image screenshot.png
```

### Batch Processing (v1.1.0+)

```bash
hal --batch prompts.txt
hal --batch prompts.txt --batch-delay 2  # wait 2s between requests
hal --batch prompts.txt --prepend "Be concise: " --append " (max 3 pts)"
```

### Prepend/Append Text (v1.1.0+)

```bash
hal --chat "code review" --prepend "You are a senior dev. " --append " Be concise."
```

### JSON Field Extraction (v1.1.0+)

```bash
hal --chat "Hello" --json-path "choices.0.message.content"
hal --chat "Summarize" --file doc.md --json-path "usage.total_tokens"
```

### API Configuration

```bash
hal --chat "ping" --api-base http://localhost:8080
hal --chat "ping" --api-key my-secret-key
```

### Output Format

```bash
hal --chat "Hello" --output json    # Default
hal --chat "Hello" --output raw
hal --chat "Hello" --quiet          # Suppresses stderr
```

### Models

```bash
hal --list-models
hal --chat "Question" --model gpt-4o
hal --chat "Question" --model gpt-4o-mini
hal --chat "Question" --model claude-opus-4
hal --chat "Question" --model fast
```

### Update

```bash
hal --update        # Update only if a new version exists
hal --update-force  # Force reinstallation
```

### Version and Help

```bash
hal --version
hal --help
hal --model --help  # Help available at any level
```

## Complete Options Reference

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
--batch FILE        Read prompts from file (one per line) [v1.1.0+]
--prepend TEXT      Insert text before message [v1.1.0+]
--append TEXT       Insert text after message [v1.1.0+]
--json-path PATH    Extract specific JSON field (dot notation) [v1.1.0+]
--batch-delay N     Delay in seconds between batch requests (default: 1) [v1.1.0+]
--list-models       Show available models
--update            Update script from GitHub
--update-force      Force update even if already up to date
--no-cache          Disable local cache
--quiet             Suppress stderr logs
-v, --version       Show version
-h, --help          Help
```

## Cache

Responses are cached in `~/.cache/hal/`. The cache key is computed from the **content** of attached files and images (MD5 hash), not just their paths.

- Disable: `HAL_CACHE_ENABLED=0` or `--no-cache`

## Error Handling

- **User errors** (missing argument, file not found, unknown option): message on **stderr**, exit code `1` or `2`
- **API errors** (HTTP, timeout, invalid response):
  - `--output json` → `{"error": "..."}` on stdout
  - `--output raw` → `ERROR: ...` on stderr

## Agent Guidance

- Always check that `hal` is installed with `command -v hal` before use.
- Use `--quiet` in scripts for clean output.
- Use `--output raw` when only text content is needed.
- Use `| jq -r '.choices[0].message.content'` to parse JSON output.
- Prefer pipes (`echo "..." | hal`) for dynamic content.
- Use `--file` to analyze existing files rather than copy-pasting their content.
- Use `--image` for multimodal image analysis.
- **Use `--batch FILE` for processing multiple prompts (one per line in file).**
- **Use `--prepend/--append` to create reusable text templates.**
- **Use `--json-path` to extract specific fields (e.g., `usage.total_tokens`) without jq.**
- Update the Orca worktree comment (`orca worktree set --worktree active --comment ...`) after significant checkpoints involving hal.

## Complete Examples

### Generate Code

```bash
hal --chat "Write a Python function to calculate the Fibonacci sequence" --output raw --quiet
```

### Summarize a File

```bash
hal --chat "Summarize this document in 3 sentences" --file report.pdf.txt --output raw --quiet
```

### Analyze an Image

```bash
hal --chat "What objects do you see in this image?" --image screenshot.png --output raw --quiet
```

### Git Pipeline

```bash
DIFF=$(git diff HEAD~1)
REVIEW=$(echo "$DIFF" | hal --system "You are a senior dev. Be concise." --quiet)
echo "$REVIEW"
```

### Batch Processing (v1.1.0+)

```bash
# Process multiple prompts from a file
cat > /tmp/prompts.txt << 'EOF'
Summarize this file
Review the code
Generate tests
EOF
hal --batch /tmp/prompts.txt --batch-delay 2
```

### Extract JSON Fields (v1.1.0+)

```bash
# Get only the message content
hal --chat "Hello" --json-path "choices.0.message.content" --quiet

# Get token usage
hal --chat "Summarize this" --file doc.md --json-path "usage.total_tokens"
```

### Text Templates (v1.1.0+)

```bash
# Reusable prompt template
hal --chat "review this PR" --prepend "You are a senior dev. " --append " Be concise. Bullet points."
```

## Important Constraints

- Requires `curl` and `python3` (Bash).
- The hal API is OpenAI-compatible but does not expose `/v1/models`.
- The models listed in `--list-models` were manually validated.
- The cache is based on the content (MD5) of files/images, not on paths.
- **Batch mode** (`--batch`) reads one prompt per line; use `--batch-delay` to avoid rate limits.
- **JSON path** uses dot notation (e.g., `choices.0.message.content`); arrays use numeric indices.

## References

- `README.md` — English project documentation
- `README_FR.md` — French project documentation
- `src/hal.sh` — Bash source script
- `src/hal.ps1` — PowerShell source script
- `install/install.sh` — Bash install script
- `install/install.ps1` — PowerShell install script
- `Makefile` — Install / test / build commands
