# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-04-26

### Added
- Initial release of `hal` CLI in Bash (`hal.sh`) and PowerShell (`hal.ps1`).
- OpenAI-compatible chat completions API support.
- Environment-based configuration (`HAL_API_BASE`, `HAL_API_KEY`, `HAL_MODEL`, etc.).
- Local response cache with content-based invalidation (MD5 of files/images).
- File and image attachments for multimodal prompts.
- Retry logic with configurable delay and max attempts.
- `--list-models` flag with empirically tested model list.
- `--version` flag.
- Image resizing for large attachments (PIL / System.Drawing).
- Installer scripts (`install.sh`, `install.ps1`) and Makefile targets.

### Security
- API base URL obfuscated via simple XOR encoding to avoid hardcoding plaintext URLs.
- Cache directory created with restrictive permissions (`chmod 700`).

## [1.1.0] - 2026-05-03

### Added
- `--batch FILE` : process multiple prompts from a file (one per line).
- `--prepend TEXT` : insert text before the message.
- `--append TEXT` : insert text after the message.
- `--json-path PATH` : extract a specific JSON field using dot notation.
- `--batch-delay N` : delay in seconds between batch requests (default: 1).

### Changed
- Refactored argument parsing for better portability and error handling.
- Improved cross-platform cache directory resolution (`XDG_CACHE_HOME`, Windows/Linux paths).
- Validated numeric inputs for `--temperature` and `--max-tokens`.
- Normalized `API_BASE` trailing slash to prevent malformed URLs.
- Removed unused temporary file (`tmpCodeFile`) from PowerShell implementation.
- Updated `Makefile` to exclude `jq` from dependency installation.
- Added `README_FR.md` to build archive.

### Fixed
- `install.sh` now correctly parses `-p` / `--prefix` option.
- `install.ps1` sets `Hidden` attribute only on Windows.
- PowerShell `Fatal` function now explicitly writes JSON to stdout.
- Bash `base64 -d` portability fix for macOS/BSD systems.

## [1.2.0] - 2025-01-XX

### Added
- **`--stream` flag (Bash)**: Real-time streaming of response tokens using SSE. Output is printed as it's generated.
- **`--dry-run` flag (Bash)**: Build and print the API payload without sending the request. Useful for debugging.
- **Cache TTL support (Bash)**: `HAL_CACHE_TTL` environment variable allows setting cache expiration time in seconds (0 = disabled).
- **XDG cache directory support (Bash)**: Respects `$XDG_CACHE_HOME` environment variable for cache location.
- **External config file support (Bash)**: Loads configuration from `~/.halrc` or `$HAL_CONFIG` file (supports `VAR=value` and `export VAR=value` syntax).
- **Short aliases**: `-c` (--chat), `-m` (--model), `-s` (--system), `-t` (--temperature), `-o` (--output), `-f` (--file), `-i` (--image).
- **File size limit**: Default maximum file size of 1MB for `--file` and `--image` attachments (configurable via `HAL_MAX_FILE_SIZE`).

### Changed
- **Version synchronization**: All scripts (hal.sh, hal.ps1, install.sh) now report version 1.2.0.
- **Improved input validation**: Temperature must be between 0 and 2; max-tokens limited to 100000.
- **Enhanced error handling**: Specific error messages for HTTP 401 (auth), 404 (endpoint), 429 (rate limit).
- **Better dependency checking**: Validates python3 version >= 3.6.
- **Cache key generation**: More portable (supports both `md5sum` and `md5` commands).
- **Environment variables**: Added support for `HAL_PREPEND`, `HAL_APPEND`, `HAL_JSON_PATH`, `HAL_BATCH_DELAY`, `HAL_MAX_FILE_SIZE`.
- **Error messages**: stdin empty now produces "stdin is empty" instead of "Message cannot be empty".

### Fixed
- **Version consistency**: install.sh version now matches hal.sh and hal.ps1.
- **Cache TTL in Bash**: Previously missing, now implemented with proper age checking.
- **Config loading in Bash**: Previously missing, now supports external config files like PowerShell version.

## [Unreleased]

### Added
- **`--dry-run` flag (PowerShell)**: Build and print the API payload without sending the request.
- **Cache TTL support (PowerShell)**: `HAL_CACHE_TTL` environment variable for cache expiration (seconds, 0 = disabled).
- **`install.ps1` — PATH auto-add**: Automatically adds installation directory to user PATH on Windows.
- **ShellCheck + PSScriptAnalyzer**: Added linter integration to `make test`.
- **`install.sh`/`install.ps1` — real `--update` commands**: Now download latest version from GitHub instead of being stubs.

### Changed
- **`cache_key()` portable (Bash)**: Replaced `md5sum`/`md5` system commands with pure `python3` hashlib for cross-platform consistency.
- **Cache TTL portable (Bash)**: Replaced `stat`/`find`-based age check with `python3 os.path.getmtime`.
- **Config parsing (Bash)**: Replaced `sed`-based quote stripping with native Bash parameter expansion.
- **Version sync**: `hal.ps1` bumped to 1.2.0, `install.ps1` bumped to 1.2.0.

### Fixed
- **Streaming subshell bug (Bash)**: `stream_send()` used a pipe → `while read` loop, causing `full_response` to be set in a subshell and lost. Now uses a temp file to preserve variable scope.`
