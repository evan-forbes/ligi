.PHONY: install voice

install:
	zig build install-local -Doptimize=ReleaseFast

voice:
	zig build install-local -Dvoice=true -Doptimize=ReleaseFast -Dvulkan=true
