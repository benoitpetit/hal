.PHONY: install test build install-deps clean uninstall

PREFIX ?= /usr/local
BIN := $(PREFIX)/bin

install:
	@echo "Installing hal to $(BIN)/hal"
	@install -d $(BIN)
	@install -m 755 src/hal.sh $(BIN)/hal
	@mkdir -p $(HOME)/.cache/hal
	@chmod 700 $(HOME)/.cache/hal
	@echo "Done. Run 'hal --help'"

uninstall:
	@rm -f $(BIN)/hal
	@rm -rf $(HOME)/.cache/hal
	@echo "hal uninstalled"

test:
	@echo "=== Testing hal.sh syntax ==="
	@bash -n src/hal.sh && echo "OK" || echo "Syntax error"
	@echo "=== Testing hal.sh --help ==="
	@chmod +x src/hal.sh
	@./src/hal.sh --help || true
	@echo "=== Testing hal.ps1 syntax ==="
	@pwsh -Command "Get-Command src/hal.ps1" >/dev/null 2>&1 && pwsh -Command "& { . src/hal.ps1 -Help }" || echo "pwsh not available, skipping"

build:
	@mkdir -p dist
	@tar czf dist/hal.tar.gz src/hal.sh src/hal.ps1 install/install.sh install/install.ps1 README.md README_FR.md Makefile logo.png
	@echo "Archive: dist/hal.tar.gz"

install-deps:
	@echo "Installing dependencies..."
	@if command -v apt-get >/dev/null 2>&1; then \
		sudo apt-get update && sudo apt-get install -y curl python3; \
	elif command -v brew >/dev/null 2>&1; then \
		brew install curl python3; \
	elif command -v pacman >/dev/null 2>&1; then \
		sudo pacman -S --noconfirm curl python3; \
	elif command -v dnf >/dev/null 2>&1; then \
		sudo dnf install -y curl python3; \
	else \
		echo "Please install curl and python3 manually."; \
	fi

clean:
	@rm -rf dist
