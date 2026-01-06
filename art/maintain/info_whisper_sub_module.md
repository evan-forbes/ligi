# whisper.cpp Git Submodule

## Overview

The `vendor/whisper.cpp` directory is a git submodule pointing to the [whisper.cpp](https://github.com/ggml-org/whisper.cpp) repository. This C/C++ library provides speech-to-text functionality using OpenAI's Whisper models.

## Why a Submodule?

whisper.cpp is vendored as source code that gets compiled directly into ligi (when the `voice` feature is enabled). We use a git submodule rather than copying the code directly because:

1. **Version tracking** - The submodule pins to a specific commit, making it clear which version we're using
2. **Easy updates** - Can pull upstream changes without manual copy/paste
3. **Smaller repo** - The submodule reference is just a commit hash, not the full source tree
4. **Attribution** - Maintains clear connection to the upstream project

Current version: **v1.8.2** (commit `4979e04f5dcaccb36057e059bbaed8a2f5288315`)

## For Users: Cloning the Repository

When cloning ligi, you need to also fetch the submodule:

```bash
# Option 1: Clone with submodules in one command
git clone --recursive https://github.com/evan-forbes/ligi

# Option 2: Clone first, then init submodules
git clone https://github.com/evan-forbes/ligi
cd ligi
git submodule update --init
```

If you forget to init the submodule, the build will fail with:
```
voice enabled but vendor/whisper.cpp is missing
```

## For Maintainers: Updating whisper.cpp

To update to a newer version of whisper.cpp:

```bash
# Enter the submodule directory
cd vendor/whisper.cpp

# Fetch latest from upstream
git fetch origin

# Checkout the desired version (tag or commit)
git checkout v1.9.0  # or whatever version

# Go back to repo root
cd ../..

# Stage the submodule update
git add vendor/whisper.cpp

# Commit the update
git commit -m "chore: update whisper.cpp to v1.9.0"
```

### Testing After Update

After updating whisper.cpp, ensure:

1. The build still works: `zig build -Dvoice=true`
2. Voice features still function correctly
3. No new compiler warnings from whisper.cpp sources

### Checking Current Version

```bash
# See which commit the submodule is at
git submodule status

# Or check inside the submodule
cd vendor/whisper.cpp && git describe --tags
```

## For Maintainers: Making Local Modifications

If you need to patch whisper.cpp locally (not recommended unless necessary):

1. Make changes inside `vendor/whisper.cpp`
2. The submodule will show as "modified" in git status
3. You can commit these changes, but they won't be pushed to upstream whisper.cpp
4. Consider whether the change should be contributed upstream instead

**Warning**: Local modifications will be lost when updating to a new upstream version. If you must make local changes, document them clearly and consider forking whisper.cpp instead.

## Build Integration

The whisper.cpp source files are compiled directly by Zig's build system. See `build.zig` lines 105-188 for the integration details. Key points:

- Requires `-Dvoice=true` build flag to enable
- Compiles both C and C++ sources from whisper.cpp
- Architecture-specific optimizations for x86 and ARM
- Links against pthread and c++ standard library

## Troubleshooting

### "vendor/whisper.cpp is missing"
Run `git submodule update --init`

### Submodule shows as modified but you didn't change anything
This can happen if file permissions changed. Run:
```bash
cd vendor/whisper.cpp
git checkout .
```

### Build errors after updating whisper.cpp
The whisper.cpp API may have changed. Check:
- `src/voice/whisper.zig` for the Zig bindings
- whisper.cpp changelog for breaking changes
