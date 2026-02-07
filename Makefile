.PHONY: install voice pdf-check pdf-deps pdf-smoke

LIGI_BIN := $(HOME)/.local/bin/ligi

install:
	@if [ -f "$(LIGI_BIN)" ]; then \
		PID=$$(fuser "$(LIGI_BIN)" 2>/dev/null); \
		if [ -n "$$PID" ]; then \
			echo "error: $(LIGI_BIN) is in use by PID $$PID"; \
			echo "  kill $$PID"; \
			exit 1; \
		fi; \
	fi
	zig build install-local -Doptimize=ReleaseFast

voice:
	@if [ -f "$(LIGI_BIN)" ]; then \
		PID=$$(fuser "$(LIGI_BIN)" 2>/dev/null); \
		if [ -n "$$PID" ]; then \
			echo "error: $(LIGI_BIN) is in use by PID $$PID"; \
			echo "  kill $$PID"; \
			exit 1; \
		fi; \
	fi
	zig build install-local -Dvoice=true -Doptimize=ReleaseFast -Dvulkan=true

pdf-check:
	@if command -v chromium >/dev/null 2>&1; then \
		echo "chromium found"; \
	elif command -v chromium-browser >/dev/null 2>&1; then \
		echo "chromium-browser found"; \
	elif command -v google-chrome >/dev/null 2>&1; then \
		echo "google-chrome found"; \
	elif command -v google-chrome-stable >/dev/null 2>&1; then \
		echo "google-chrome-stable found"; \
	elif command -v chrome >/dev/null 2>&1; then \
		echo "chrome found"; \
	else \
		echo "Chromium/Chrome not found"; \
		echo "Run: make pdf-deps"; \
		exit 1; \
	fi

pdf-deps:
	@bash scripts/install_chromium_headless.sh

pdf-smoke:
	@zig build -Doptimize=ReleaseSafe
	@./zig-out/bin/ligi pdf README.md -o /tmp/ligi-pdf-smoke.pdf
	@ls -lh /tmp/ligi-pdf-smoke.pdf
