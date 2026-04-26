# Contributing to HAL

Thank you for your interest in improving HAL! This document provides guidelines for contributing to the project.

## Getting Started

1. Fork the repository on GitHub.
2. Clone your fork locally.
3. Create a new branch for your feature or bug fix.

## Development Setup

### Requirements

- `bash` >= 4.0
- `curl`
- `python3` (for Bash script JSON handling)
- `pwsh` >= 7.0 (for PowerShell testing)

### Running Tests

```bash
make test
```

This validates shell syntax and runs `--help` on both scripts.

### Building the Archive

```bash
make build
```

Produces `dist/hal.tar.gz` containing all release files.

## Code Style

- **Bash**: Use `set -euo pipefail`, lowercase function names, UPPERCASE globals.
- **PowerShell**: Use `$ErrorActionPreference = "Stop"`, PascalCase functions, `$script:` scope for globals.
- Keep both scripts functionally identical where possible.
- Write clear, concise commit messages in English.

## Submitting Changes

1. Ensure your changes are well-tested (`make test` passes).
2. Update `CHANGELOG.md` under the `[Unreleased]` section.
3. If adding new CLI options, update both `README.md` and `README_FR.md`.
4. Open a Pull Request with a clear description of the problem and solution.

## Reporting Issues

When reporting bugs, please include:

- Operating system and version
- Shell version (`bash --version` or `$PSVersionTable`)
- Steps to reproduce
- Expected vs. actual behavior
- Any relevant error messages or logs

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
