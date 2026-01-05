.PHONY: install

install:
	zig build install-local -Doptimize=ReleaseFast
