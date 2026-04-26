.PHONY: install test build install-deps clean

PREFIX ?= /usr/local
BIN := $(PREFIX)/bin

install:
	@echo "Installing hal.sh to $(BIN)/hal"
	@install -d $(BIN)
	@install -m 755 hal.sh $(BIN)/hal
	@echo "Done. Run 'hal --help'"

test:
	@echo "=== Testing hal.sh ==="
	@chmod +x hal.sh
	@./hal.sh --help || true
	@echo "=== Testing hal.ps1 ==="
	@pwsh -Command "./hal.ps1 --help" || true

build:
	@mkdir -p dist
	@tar czf dist/hal.tar.gz hal.sh hal.ps1 README.md Makefile
	@echo "Archive: dist/hal.tar.gz"

install-deps:
	@echo "Installing dependencies..."
	@if command -v apt-get >/dev/null 2>&1; then \
		sudo apt-get update && sudo apt-get install -y curl python3 jq; \
	elif command -v brew >/dev/null 2>&1; then \
		brew install curl python3 jq; \
	elif command -v pacman >/dev/null 2>&1; then \
		sudo pacman -S --noconfirm curl python3 jq; \
	elif command -v dnf >/dev/null 2>&1; then \
		sudo dnf install -y curl python3 jq; \
	else \
		echo "Please install curl, python3 and jq manually."; \
	fi

clean:
	@rm -rf dist
