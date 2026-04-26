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

## [Unreleased]

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
