.PHONY: install voice

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
