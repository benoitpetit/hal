#!/bin/bash
set -euo pipefail

INSTALL_DIR="${DESTDIR:-/usr/local/bin}"
CACHE_DIR="${HOME}/.cache/hal"
VERSION="1.2.0"

usage() {
    cat <<EOF
hal installer (Linux/macOS/WSL)

Usage: install.sh [command] [options]

Commands:
  install     Install hal (default)
  uninstall   Remove hal from system
  update      Update hal to latest version
  status      Show installation status

Options:
  -p, --prefix DIR    Installation directory (default: /usr/local/bin)
  -h, --help          Show this help

Examples:
  sudo ./install.sh install
  sudo ./install.sh -p /opt/bin install
  sudo ./install.sh uninstall
  ./install.sh status
EOF
}

check_deps() {
    local missing=()
    for cmd in curl python3; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing dependencies: ${missing[*]}" >&2
        echo "Run: make install-deps" >&2
        exit 1
    fi
}

do_install() {
    check_deps

    local src_dir
    src_dir="$(cd "$(dirname "$0")/.." && pwd)/src"

    if [[ ! -f "$src_dir/hal.sh" ]]; then
        echo "ERROR: hal.sh not found in $src_dir" >&2
        exit 1
    fi

    echo "Installing hal to $INSTALL_DIR/hal"
    install -d "$INSTALL_DIR"
    install -m 755 "$src_dir/hal.sh" "$INSTALL_DIR/hal"

    mkdir -p "$CACHE_DIR"
    chmod 700 "$CACHE_DIR"

    echo "Creating cache directory: $CACHE_DIR"
    echo "Done. Run 'hal --help'"
}

do_uninstall() {
    if [[ -f "$INSTALL_DIR/hal" ]]; then
        rm -f "$INSTALL_DIR/hal"
        echo "Removed $INSTALL_DIR/hal"
    else
        echo "hal not found in $INSTALL_DIR"
    fi

    if [[ -d "$CACHE_DIR" ]]; then
        rm -rf "$CACHE_DIR"
        echo "Removed cache: $CACHE_DIR"
    fi
}

do_update() {
    echo "Update check (version: $VERSION)"
    echo "To update, pull latest and re-run: sudo ./install.sh install"
}

do_status() {
    echo "=== hal status ==="
    echo "Version: $VERSION"
    echo ""

    if command -v hal >/dev/null 2>&1; then
        local hal_path
        hal_path=$(command -v hal)
        echo "Installed: $hal_path"
        if hal --version >/dev/null 2>&1; then
            echo "Executable: OK"
        else
            echo "Executable: version check failed" >&2
        fi
    else
        echo "Installed: No"
    fi
    echo ""

    if [[ -d "$CACHE_DIR" ]]; then
        echo "Cache: $CACHE_DIR ($(ls "$CACHE_DIR" 2>/dev/null | wc -l) cached responses)"
    else
        echo "Cache: Not created"
    fi
}

# --- Argument parsing ---
CMD="install"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--prefix)
            [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; usage; exit 1; }
            INSTALL_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        install|uninstall|update|status)
            CMD="$1"
            shift
            ;;
        *)
            echo "Unknown option or command: $1" >&2
            usage
            exit 1
            ;;
    esac
done

case "$CMD" in
    install)
        do_install
        ;;
    uninstall)
        do_uninstall
        ;;
    update)
        do_update
        ;;
    status)
        do_status
        ;;
    *)
        echo "Unknown command: $CMD" >&2
        usage
        exit 1
        ;;
esac
