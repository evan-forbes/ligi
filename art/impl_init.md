[[t/DONE]]

# Ligi `init` Command Implementation Plan

## Executive Summary

This document provides an unambiguous implementation plan for the `ligi init` command—the foundational command that creates the directory structure and configuration files needed for ligi to operate both globally (`~/.ligi/`) and locally (per-repo `art/`).

---

## Part 1: Decisions (Finalized)

| # | Decision | Choice |
|---|----------|--------|
| 1 | CLI Library | zig-clap + custom wrapper for ergonomic command definition |
| 2 | Alias Strategy | Multiple enum variants mapping to same handler via abstraction layer |
| 3 | Config Format | TOML (using `tomlz` library) |
| 4 | Global Config Location | `~/.ligi/config/` (resolved via `$HOME`) |
| 5 | Error Handling | Full context chain with structured error types |
| 6 | Init Idempotency | Skip existing, create missing (safe, scriptable) |

---

## Part 2: Architecture

### 2.1 Directory Structure Created by `ligi init`

**Global** (`ligi init --global` or first-time setup):
```
~/.ligi/
├── config/
│   └── ligi.toml        # Global configuration
└── art/
    ├── index/
    │   └── ligi_tags.md  # Global tag index
    ├── template/
    └── archive/
```

**Local** (per-repo, `ligi init`):
```
./art/
├── index/
│   └── ligi_tags.md      # Local tag index
├── template/
├── config/               # Local overrides (optional)
└── archive/
```

### 2.2 Module Structure

```
src/
├── main.zig                    # Entry point
├── root.zig                    # Library root (re-exports public API)
│
├── cli/
│   ├── mod.zig                 # CLI module root
│   ├── registry.zig            # CommandRegistry abstraction (wrapper over clap)
│   ├── help.zig                # Help text generation
│   └── commands/
│       ├── mod.zig             # Command dispatch table
│       ├── init.zig            # `ligi init` implementation
│       ├── index.zig           # `ligi index` (stub for future)
│       ├── query.zig           # `ligi query` (stub for future)
│       └── archive.zig         # `ligi archive` (stub for future)
│
├── core/
│   ├── mod.zig                 # Core module root
│   ├── errors.zig              # Error types with context chain
│   ├── paths.zig               # Path resolution logic
│   ├── fs.zig                  # Filesystem operations
│   └── config.zig              # TOML config parsing/writing
│
└── testing/
    ├── mod.zig                 # Test utilities module root
    ├── fixtures.zig            # Temp dir scaffolding
    └── assertions.zig          # Custom test assertions
```

### 2.3 Dependency Graph

```
main.zig
└── cli/registry.zig
    └── cli/commands/mod.zig
        └── cli/commands/init.zig
            ├── core/paths.zig
            ├── core/fs.zig
            └── core/config.zig
                └── core/errors.zig (used by all)
```

### 2.4 External Dependencies

| Package | Purpose | Install |
|---------|---------|---------|
| `zig-clap` | Argument parsing | `zig fetch --save git+https://github.com/Hejsil/zig-clap` |
| `tomlz` | TOML parsing/serialization | `zig fetch --save git+https://github.com/mattyhall/tomlz` |

---

## Part 3: Core Abstractions

### 3.1 CommandRegistry: Clap Wrapper for Ergonomic Commands

The `CommandRegistry` provides a declarative way to define commands with:
- Multiple names (canonical + aliases) mapping to same handler
- Automatic help generation
- Type-safe flag definitions
- Subcommand routing

```zig
// src/cli/registry.zig

const std = @import("std");
const clap = @import("clap");

/// A command handler function signature
pub const HandlerFn = *const fn (
    allocator: std.mem.Allocator,
    args: anytype,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
) anyerror!u8;

/// Command definition with metadata
pub const CommandDef = struct {
    /// Canonical name (used in help, documentation)
    canonical: []const u8,
    /// All names that invoke this command (including canonical)
    names: []const []const u8,
    /// Short description for help listing
    description: []const u8,
    /// Long description for command-specific help
    long_description: ?[]const u8 = null,
    /// Clap parameter specification string
    params_spec: []const u8,
    /// Handler function
    handler: HandlerFn,
};

/// Registry of all commands
pub const CommandRegistry = struct {
    commands: []const CommandDef,
    global_params_spec: []const u8,
    version: []const u8,

    const Self = @This();

    /// Find command by any of its names (canonical or alias)
    pub fn findCommand(self: Self, name: []const u8) ?*const CommandDef {
        for (self.commands) |*cmd| {
            for (cmd.names) |cmd_name| {
                if (std.mem.eql(u8, name, cmd_name)) {
                    return cmd;
                }
            }
        }
        return null;
    }

    /// Generate main help text
    pub fn printHelp(self: Self, writer: anytype) !void {
        try writer.print("ligi v{s} - Human and LLM readable project management\n\n", .{self.version});
        try writer.writeAll("Usage: ligi [options] <command> [command-options]\n\n");
        try writer.writeAll("Commands:\n");
        for (self.commands) |cmd| {
            // Format: "  init, i          Initialize ligi in current directory"
            var names_buf: [64]u8 = undefined;
            var names_len: usize = 0;
            for (cmd.names, 0..) |name, idx| {
                if (idx > 0) {
                    names_buf[names_len] = ',';
                    names_buf[names_len + 1] = ' ';
                    names_len += 2;
                }
                @memcpy(names_buf[names_len..][0..name.len], name);
                names_len += name.len;
            }
            try writer.print("  {s:<16} {s}\n", .{ names_buf[0..names_len], cmd.description });
        }
        try writer.writeAll("\nOptions:\n");
        try writer.writeAll("  -h, --help       Show this help message\n");
        try writer.writeAll("  -v, --version    Show version\n");
        try writer.writeAll("  -q, --quiet      Suppress non-error output\n");
    }

    /// Generate command-specific help
    pub fn printCommandHelp(self: Self, cmd: *const CommandDef, writer: anytype) !void {
        _ = self;
        try writer.print("Usage: ligi {s} [options]\n\n", .{cmd.canonical});
        if (cmd.long_description) |desc| {
            try writer.print("{s}\n\n", .{desc});
        } else {
            try writer.print("{s}\n\n", .{cmd.description});
        }
        try writer.writeAll("Options:\n");
        // Parse params_spec and print formatted help
        // (Implementation detail: iterate clap params)
    }

    /// Parse and dispatch command
    pub fn parseAndDispatch(
        self: Self,
        allocator: std.mem.Allocator,
        args: []const []const u8,
        stdout: std.io.AnyWriter,
        stderr: std.io.AnyWriter,
    ) !u8 {
        // 1. Parse global flags first (--help, --version, --quiet)
        // 2. Extract command name from positional
        // 3. Look up command via findCommand
        // 4. Parse command-specific flags
        // 5. Call handler
        // Implementation follows clap's terminating_positional pattern
        _ = args;
        _ = allocator;
        _ = stdout;
        _ = stderr;
        return 0;
    }
};

/// Build the ligi command registry
pub fn buildRegistry() CommandRegistry {
    return .{
        .version = "0.1.0",
        .global_params_spec =
        \\-h, --help     Show help
        \\-v, --version  Show version
        \\-q, --quiet    Suppress non-error output
        \\<command>
        ,
        .commands = &.{
            .{
                .canonical = "init",
                .names = &.{ "init" },
                .description = "Initialize ligi in current directory or globally",
                .long_description =
                \\Initialize ligi directory structure.
                \\
                \\Creates art/ directory with index/, template/, config/, and archive/
                \\subdirectories. Also creates initial ligi_tags.md index file.
                \\
                \\Use --global to initialize ~/.ligi/ for global artifacts.
                ,
                .params_spec =
                \\-g, --global       Initialize global ~/.ligi instead of local ./art
                \\-r, --root <path>  Override target directory
                \\-h, --help         Show this help
                ,
                .handler = @import("commands/init.zig").execute,
            },
            .{
                .canonical = "index",
                .names = &.{ "index", "i" },
                .description = "Index tags and links in documents",
                .params_spec =
                \\-r, --root <path>  Root directory (default: .)
                \\-f, --file <path>  Specific file to index
                \\-h, --help         Show this help
                ,
                .handler = @import("commands/index.zig").execute,
            },
            .{
                .canonical = "query",
                .names = &.{ "query", "q" },
                .description = "Query documents by tags or links",
                .params_spec =
                \\-a, --absolute     Output absolute paths
                \\-o, --output <fmt> Output format (text, json)
                \\-c, --clipboard    Copy output to clipboard
                \\<query>...
                ,
                .handler = @import("commands/query.zig").execute,
            },
            .{
                .canonical = "archive",
                .names = &.{ "archive", "a" },
                .description = "Move document to archive",
                .params_spec =
                \\<file>             File to archive
                \\-h, --help         Show this help
                ,
                .handler = @import("commands/archive.zig").execute,
            },
        },
    };
}
```

**Key Design Points**:
1. Commands are defined declaratively with all metadata in one place
2. Aliases are just additional entries in the `names` array
3. Help is auto-generated from the registry
4. Adding a new command = adding one struct literal
5. The registry wraps clap's `terminating_positional` pattern internally

**Unit Tests for CommandRegistry**:
- `test "findCommand returns command for canonical name"`
- `test "findCommand returns command for alias"`
- `test "findCommand returns null for unknown command"`
- `test "printHelp lists all commands with aliases"`
- `test "printCommandHelp shows long description"`

### 3.2 Error Context Chain

Errors carry full context for debugging:

```zig
// src/core/errors.zig

const std = @import("std");

/// Error categories for exit codes
pub const ErrorCategory = enum(u8) {
    success = 0,
    usage = 1,        // Bad arguments
    filesystem = 2,   // File/dir operations failed
    config = 3,       // Config parse/write failed
    internal = 127,   // Bug in ligi
};

/// A link in the error context chain
pub const ErrorContext = struct {
    message: []const u8,
    source: ?*const ErrorContext = null,

    pub fn format(
        self: ErrorContext,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.writeAll(self.message);
        if (self.source) |src| {
            try writer.writeAll(": ");
            try src.format("", .{}, writer);
        }
    }
};

/// Rich error with category and context chain
pub const LigiError = struct {
    category: ErrorCategory,
    context: ErrorContext,

    const Self = @This();

    pub fn filesystem(message: []const u8, cause: ?*const ErrorContext) Self {
        return .{
            .category = .filesystem,
            .context = .{ .message = message, .source = cause },
        };
    }

    pub fn config(message: []const u8, cause: ?*const ErrorContext) Self {
        return .{
            .category = .config,
            .context = .{ .message = message, .source = cause },
        };
    }

    pub fn usage(message: []const u8) Self {
        return .{
            .category = .usage,
            .context = .{ .message = message },
        };
    }

    /// Format full error chain for display
    pub fn format(self: Self, writer: anytype) !void {
        try writer.writeAll("error: ");
        try self.context.format("", .{}, writer);
        try writer.writeAll("\n");
    }

    pub fn exitCode(self: Self) u8 {
        return @intFromEnum(self.category);
    }
};

/// Result type for operations that can fail with context
pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: LigiError,

        const Self = @This();

        pub fn unwrap(self: Self) !T {
            return switch (self) {
                .ok => |v| v,
                .err => error.LigiError,
            };
        }

        pub fn mapErr(self: Self, message: []const u8) Self {
            return switch (self) {
                .ok => self,
                .err => |e| .{ .err = .{
                    .category = e.category,
                    .context = .{ .message = message, .source = &e.context },
                } },
            };
        }
    };
}
```

**Usage Example**:
```zig
fn createArtDir(path: []const u8) Result(void) {
    std.fs.makeDirAbsolute(path) catch |err| {
        return .{ .err = LigiError.filesystem(
            "failed to create art directory",
            &.{ .message = @errorName(err) },
        ) };
    };
    return .{ .ok = {} };
}

// Caller can add context:
const result = createArtDir("/foo/art").mapErr("while initializing ligi");
```

**Output Example**:
```
error: while initializing ligi: failed to create art directory: AccessDenied
```

**Unit Tests for Errors**:
- `test "ErrorContext formats single message"`
- `test "ErrorContext formats chain of messages"`
- `test "LigiError.filesystem sets correct category"`
- `test "Result.mapErr wraps error with additional context"`
- `test "exitCode returns correct value for each category"`

### 3.3 TOML Configuration

```zig
// src/core/config.zig

const std = @import("std");
const tomlz = @import("tomlz");
const errors = @import("errors.zig");

/// Ligi configuration structure
pub const LigiConfig = struct {
    /// Config file format version
    version: []const u8 = "0.1.0",

    /// Index settings
    index: IndexConfig = .{},

    /// Query settings
    query: QueryConfig = .{},

    pub const IndexConfig = struct {
        /// File patterns to ignore when indexing
        ignore_patterns: []const []const u8 = &.{ "*.tmp", "*.bak" },
        /// Whether to follow symlinks
        follow_symlinks: bool = false,
    };

    pub const QueryConfig = struct {
        /// Default output format
        default_format: OutputFormat = .text,
        /// Whether to use colors in output
        colors: bool = true,
    };

    pub const OutputFormat = enum { text, json };
};

/// Load config from TOML file
pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) errors.Result(LigiConfig) {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        return .{ .err = errors.LigiError.config(
            "failed to open config file",
            &.{ .message = @errorName(err) },
        ) };
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        return .{ .err = errors.LigiError.config(
            "failed to read config file",
            &.{ .message = @errorName(err) },
        ) };
    };
    defer allocator.free(content);

    const config = tomlz.decode(LigiConfig, allocator, content) catch |err| {
        return .{ .err = errors.LigiError.config(
            "failed to parse TOML",
            &.{ .message = @errorName(err) },
        ) };
    };

    return .{ .ok = config };
}

/// Save config to TOML file
pub fn saveConfig(
    allocator: std.mem.Allocator,
    path: []const u8,
    config: LigiConfig,
) errors.Result(void) {
    const file = std.fs.createFileAbsolute(path, .{}) catch |err| {
        return .{ .err = errors.LigiError.config(
            "failed to create config file",
            &.{ .message = @errorName(err) },
        ) };
    };
    defer file.close();

    tomlz.serialize(allocator, file.writer(), config) catch |err| {
        return .{ .err = errors.LigiError.config(
            "failed to write TOML",
            &.{ .message = @errorName(err) },
        ) };
    };

    return .{ .ok = {} };
}

/// Get default config
pub fn getDefaultConfig() LigiConfig {
    return .{};
}

/// Default TOML content for new config files
pub const DEFAULT_CONFIG_TOML =
    \\# Ligi Configuration
    \\# See https://github.com/evan-forbes/ligi for documentation
    \\
    \\version = "0.1.0"
    \\
    \\[index]
    \\# Patterns to ignore when indexing (glob syntax)
    \\ignore_patterns = ["*.tmp", "*.bak"]
    \\# Whether to follow symbolic links
    \\follow_symlinks = false
    \\
    \\[query]
    \\# Default output format: "text" or "json"
    \\default_format = "text"
    \\# Enable colored output
    \\colors = true
    \\
;
```

**Unit Tests for Config**:
- `test "loadConfig parses valid TOML"`
- `test "loadConfig returns error for invalid TOML"`
- `test "loadConfig returns error for missing file"`
- `test "saveConfig creates valid TOML file"`
- `test "round-trip load/save preserves values"`
- `test "DEFAULT_CONFIG_TOML parses without error"`
- `test "getDefaultConfig returns sensible defaults"`

---

## Part 4: Implementation Phases

### Phase 1: Project Setup & Dependencies

#### Step 1.1: Add dependencies

```bash
# Add zig-clap
zig fetch --save git+https://github.com/Hejsil/zig-clap

# Add tomlz
zig fetch --save git+https://github.com/mattyhall/tomlz
```

**Verification**: `build.zig.zon` contains both dependencies.

#### Step 1.2: Update build.zig

```zig
// In build.zig, within the build function:

const clap_dep = b.dependency("clap", .{
    .target = target,
    .optimize = optimize,
});

const tomlz_dep = b.dependency("tomlz", .{
    .target = target,
    .optimize = optimize,
});

// Add to executable's root module imports:
.imports = &.{
    .{ .name = "ligi", .module = mod },
    .{ .name = "clap", .module = clap_dep.module("clap") },
    .{ .name = "tomlz", .module = tomlz_dep.module("tomlz") },
},
```

**Verification**: Can `@import("clap")` and `@import("tomlz")` without error.

#### Step 1.3: Create module directory structure

```bash
mkdir -p src/cli/commands src/core src/testing
touch src/cli/mod.zig src/cli/registry.zig src/cli/help.zig
touch src/cli/commands/mod.zig src/cli/commands/init.zig
touch src/cli/commands/index.zig src/cli/commands/query.zig src/cli/commands/archive.zig
touch src/core/mod.zig src/core/errors.zig src/core/paths.zig src/core/fs.zig src/core/config.zig
touch src/testing/mod.zig src/testing/fixtures.zig src/testing/assertions.zig
```

**Verification**: `zig build` succeeds with empty module files.

---

### Phase 2: Core Infrastructure

#### Step 2.1: Implement `core/errors.zig`

**Implementation**: Full error context chain as specified in Part 3.2.

**Functions**:
| Function | Signature | Purpose |
|----------|-----------|---------|
| `ErrorContext.format` | `(self, fmt, options, writer) !void` | Format error with chain |
| `LigiError.filesystem` | `(message, cause) LigiError` | Create filesystem error |
| `LigiError.config` | `(message, cause) LigiError` | Create config error |
| `LigiError.usage` | `(message) LigiError` | Create usage error |
| `LigiError.format` | `(self, writer) !void` | Format for display |
| `LigiError.exitCode` | `(self) u8` | Get exit code |
| `Result.mapErr` | `(self, message) Result` | Wrap error with context |

**Unit Tests** (8 tests):
```zig
test "ErrorContext formats single message" {
    const ctx = ErrorContext{ .message = "something failed" };
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try ctx.format("", .{}, stream.writer());
    try std.testing.expectEqualStrings("something failed", stream.getWritten());
}

test "ErrorContext formats chain of two messages" { ... }
test "ErrorContext formats chain of three messages" { ... }
test "LigiError.filesystem sets category to filesystem" { ... }
test "LigiError.config sets category to config" { ... }
test "LigiError.usage sets category to usage" { ... }
test "exitCode returns correct value for each category" { ... }
test "Result.mapErr wraps error with additional context" { ... }
```

#### Step 2.2: Implement `core/paths.zig`

**Functions**:
| Function | Signature | Purpose |
|----------|-----------|---------|
| `getGlobalRoot` | `(allocator) ![]const u8` | Returns `$HOME/.ligi` |
| `getGlobalArtPath` | `(allocator) ![]const u8` | Returns `$HOME/.ligi/art` |
| `getGlobalConfigPath` | `(allocator) ![]const u8` | Returns `$HOME/.ligi/config` |
| `getLocalArtPath` | `(allocator, root) ![]const u8` | Returns `{root}/art` |
| `getSpecialDirs` | `() [4][]const u8` | Returns `["index", "template", "config", "archive"]` |
| `joinPath` | `(allocator, parts) ![]const u8` | Joins path segments |

**Implementation**:
```zig
// src/core/paths.zig

const std = @import("std");
const errors = @import("errors.zig");

pub const SPECIAL_DIRS = [_][]const u8{ "index", "template", "config", "archive" };

pub fn getGlobalRoot(allocator: std.mem.Allocator) errors.Result([]const u8) {
    const home = std.posix.getenv("HOME") orelse {
        return .{ .err = errors.LigiError.filesystem(
            "$HOME environment variable not set",
            null,
        ) };
    };
    return .{ .ok = try std.fs.path.join(allocator, &.{ home, ".ligi" }) };
}

pub fn getGlobalArtPath(allocator: std.mem.Allocator) errors.Result([]const u8) {
    const root = switch (getGlobalRoot(allocator)) {
        .ok => |r| r,
        .err => |e| return .{ .err = e },
    };
    return .{ .ok = try std.fs.path.join(allocator, &.{ root, "art" }) };
}

pub fn getGlobalConfigPath(allocator: std.mem.Allocator) errors.Result([]const u8) {
    const root = switch (getGlobalRoot(allocator)) {
        .ok => |r| r,
        .err => |e| return .{ .err = e },
    };
    return .{ .ok = try std.fs.path.join(allocator, &.{ root, "config" }) };
}

pub fn getLocalArtPath(allocator: std.mem.Allocator, root: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ root, "art" });
}

pub fn joinPath(allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    return std.fs.path.join(allocator, parts);
}
```

**Unit Tests** (7 tests):
```zig
test "getGlobalRoot returns ~/.ligi when HOME is set" { ... }
test "getGlobalRoot returns error when HOME is unset" { ... }
test "getGlobalArtPath returns ~/.ligi/art" { ... }
test "getGlobalConfigPath returns ~/.ligi/config" { ... }
test "getLocalArtPath joins root with art/" { ... }
test "SPECIAL_DIRS contains correct four directories" { ... }
test "joinPath handles multiple segments" { ... }
```

#### Step 2.3: Implement `core/fs.zig`

**Functions**:
| Function | Signature | Purpose |
|----------|-----------|---------|
| `ensureDir` | `(path) Result(void)` | Create dir if not exists |
| `ensureDirRecursive` | `(path) Result(void)` | Create dir and parents |
| `dirExists` | `(path) bool` | Check if directory exists |
| `fileExists` | `(path) bool` | Check if file exists |
| `writeFileIfNotExists` | `(path, content) Result(bool)` | Write file, return true if created |
| `readFile` | `(allocator, path) Result([]const u8)` | Read file contents |

**Implementation**:
```zig
// src/core/fs.zig

const std = @import("std");
const errors = @import("errors.zig");

pub fn ensureDir(path: []const u8) errors.Result(void) {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => return .{ .ok = {} },
        else => return .{ .err = errors.LigiError.filesystem(
            "failed to create directory",
            &.{ .message = path },
        ) },
    };
    return .{ .ok = {} };
}

pub fn ensureDirRecursive(path: []const u8) errors.Result(void) {
    std.fs.makePath(std.fs.cwd(), path) catch |err| {
        return .{ .err = errors.LigiError.filesystem(
            "failed to create directory tree",
            &.{ .message = @errorName(err) },
        ) };
    };
    return .{ .ok = {} };
}

pub fn dirExists(path: []const u8) bool {
    const stat = std.fs.cwd().statFile(path) catch return false;
    return stat.kind == .directory;
}

pub fn fileExists(path: []const u8) bool {
    const stat = std.fs.cwd().statFile(path) catch return false;
    return stat.kind == .file;
}

pub fn writeFileIfNotExists(path: []const u8, content: []const u8) errors.Result(bool) {
    const file = std.fs.createFileAbsolute(path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return .{ .ok = false },
        else => return .{ .err = errors.LigiError.filesystem(
            "failed to create file",
            &.{ .message = path },
        ) },
    };
    defer file.close();

    file.writeAll(content) catch |err| {
        return .{ .err = errors.LigiError.filesystem(
            "failed to write file",
            &.{ .message = @errorName(err) },
        ) };
    };

    return .{ .ok = true };
}

pub fn readFile(allocator: std.mem.Allocator, path: []const u8) errors.Result([]const u8) {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        return .{ .err = errors.LigiError.filesystem(
            "failed to open file",
            &.{ .message = @errorName(err) },
        ) };
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch |err| {
        return .{ .err = errors.LigiError.filesystem(
            "failed to read file",
            &.{ .message = @errorName(err) },
        ) };
    };

    return .{ .ok = content };
}
```

**Unit Tests** (10 tests):
```zig
test "ensureDir creates directory that doesn't exist" { ... }
test "ensureDir is idempotent for existing directory" { ... }
test "ensureDirRecursive creates nested directories" { ... }
test "dirExists returns true for existing directory" { ... }
test "dirExists returns false for non-existing path" { ... }
test "dirExists returns false for file" { ... }
test "fileExists returns true for existing file" { ... }
test "fileExists returns false for directory" { ... }
test "writeFileIfNotExists creates new file and returns true" { ... }
test "writeFileIfNotExists does not overwrite and returns false" { ... }
```

#### Step 2.4: Implement `core/config.zig`

**Implementation**: As specified in Part 3.3.

**Unit Tests** (7 tests):
```zig
test "loadConfig parses valid TOML" { ... }
test "loadConfig returns error for malformed TOML" { ... }
test "loadConfig returns error for missing file" { ... }
test "saveConfig writes valid TOML" { ... }
test "round-trip load/save preserves all values" { ... }
test "DEFAULT_CONFIG_TOML parses without error" { ... }
test "getDefaultConfig returns LigiConfig with defaults" { ... }
```

---

### Phase 3: CLI Infrastructure

#### Step 3.1: Implement `cli/registry.zig`

**Implementation**: CommandRegistry as specified in Part 3.1.

**Unit Tests** (6 tests):
```zig
test "findCommand returns command for canonical name" { ... }
test "findCommand returns same command for alias" { ... }
test "findCommand returns null for unknown command" { ... }
test "printHelp includes all commands" { ... }
test "printHelp shows aliases in parentheses" { ... }
test "printCommandHelp shows params specification" { ... }
```

#### Step 3.2: Implement `cli/help.zig`

Utility functions for consistent help formatting.

```zig
// src/cli/help.zig

const std = @import("std");

pub fn formatUsage(writer: anytype, command: []const u8, synopsis: []const u8) !void {
    try writer.print("Usage: ligi {s} {s}\n", .{ command, synopsis });
}

pub fn formatSection(writer: anytype, title: []const u8, content: []const u8) !void {
    try writer.print("\n{s}:\n{s}\n", .{ title, content });
}

pub fn formatFlag(writer: anytype, short: ?u8, long: []const u8, desc: []const u8) !void {
    if (short) |s| {
        try writer.print("  -{c}, --{s:<12} {s}\n", .{ s, long, desc });
    } else {
        try writer.print("      --{s:<12} {s}\n", .{ long, desc });
    }
}
```

**Unit Tests** (3 tests):
```zig
test "formatUsage produces correct format" { ... }
test "formatSection includes title and content" { ... }
test "formatFlag handles short and long forms" { ... }
```

---

### Phase 4: Init Command

#### Step 4.1: Implement `cli/commands/init.zig`

```zig
// src/cli/commands/init.zig

const std = @import("std");
const paths = @import("../../core/paths.zig");
const fs = @import("../../core/fs.zig");
const config = @import("../../core/config.zig");
const errors = @import("../../core/errors.zig");

pub const InitOptions = struct {
    /// Initialize global ~/.ligi instead of local ./art
    global: bool = false,
    /// Override target directory
    root: ?[]const u8 = null,
    /// Suppress non-error output
    quiet: bool = false,
};

pub const InitResult = struct {
    /// Directories that were created
    created_dirs: std.ArrayList([]const u8),
    /// Directories that already existed (skipped)
    skipped_dirs: std.ArrayList([]const u8),
    /// Files that were created
    created_files: std.ArrayList([]const u8),
    /// Files that already existed (skipped)
    skipped_files: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) InitResult {
        return .{
            .created_dirs = std.ArrayList([]const u8).init(allocator),
            .skipped_dirs = std.ArrayList([]const u8).init(allocator),
            .created_files = std.ArrayList([]const u8).init(allocator),
            .skipped_files = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *InitResult) void {
        self.created_dirs.deinit();
        self.skipped_dirs.deinit();
        self.created_files.deinit();
        self.skipped_files.deinit();
    }
};

/// Initial content for ligi_tags.md
pub const INITIAL_TAGS_INDEX =
    \\# Ligi Tag Index
    \\
    \\This file is auto-maintained by ligi. Each tag links to its index file.
    \\
    \\## Tags
    \\
    \\(No tags indexed yet)
    \\
;

/// Execute the init command
pub fn execute(
    allocator: std.mem.Allocator,
    args: anytype,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
) anyerror!u8 {
    _ = stderr;

    const options = InitOptions{
        .global = args.args.global,
        .root = args.args.root,
        .quiet = args.args.quiet orelse false,
    };

    var result = InitResult.init(allocator);
    defer result.deinit();

    // Determine base path
    const base_path = if (options.root) |r|
        r
    else if (options.global)
        switch (paths.getGlobalRoot(allocator)) {
            .ok => |p| p,
            .err => |e| {
                try e.format(stderr);
                return e.exitCode();
            },
        }
    else
        ".";

    // Create main art directory
    const art_path = try paths.joinPath(allocator, &.{ base_path, "art" });
    try createDirTracked(art_path, &result);

    // Create special subdirectories
    for (paths.SPECIAL_DIRS) |special| {
        const dir_path = try paths.joinPath(allocator, &.{ art_path, special });
        try createDirTracked(dir_path, &result);
    }

    // Create initial files
    // 1. Tag index in art/index/ligi_tags.md
    const tags_path = try paths.joinPath(allocator, &.{ art_path, "index", "ligi_tags.md" });
    try createFileTracked(tags_path, INITIAL_TAGS_INDEX, &result);

    // 2. Config file
    const config_dir = if (options.global)
        switch (paths.getGlobalConfigPath(allocator)) {
            .ok => |p| p,
            .err => |e| {
                try e.format(stderr);
                return e.exitCode();
            },
        }
    else
        try paths.joinPath(allocator, &.{ art_path, "config" });

    try createDirTracked(config_dir, &result);

    const config_path = try paths.joinPath(allocator, &.{ config_dir, "ligi.toml" });
    try createFileTracked(config_path, config.DEFAULT_CONFIG_TOML, &result);

    // Print summary if not quiet
    if (!options.quiet) {
        if (result.created_dirs.items.len > 0 or result.created_files.items.len > 0) {
            try stdout.print("Initialized ligi in {s}\n", .{base_path});
            for (result.created_dirs.items) |dir| {
                try stdout.print("  created: {s}/\n", .{dir});
            }
            for (result.created_files.items) |file| {
                try stdout.print("  created: {s}\n", .{file});
            }
        } else {
            try stdout.print("ligi already initialized in {s}\n", .{base_path});
        }
    }

    return 0;
}

fn createDirTracked(path: []const u8, result: *InitResult) !void {
    switch (fs.ensureDirRecursive(path)) {
        .ok => {
            if (!fs.dirExists(path)) {
                try result.created_dirs.append(path);
            } else {
                try result.skipped_dirs.append(path);
            }
        },
        .err => |e| return e,
    }
}

fn createFileTracked(path: []const u8, content: []const u8, result: *InitResult) !void {
    switch (fs.writeFileIfNotExists(path, content)) {
        .ok => |created| {
            if (created) {
                try result.created_files.append(path);
            } else {
                try result.skipped_files.append(path);
            }
        },
        .err => |e| return e,
    }
}
```

**Unit Tests** (10 tests):
```zig
test "execute creates art directory in fresh location" { ... }
test "execute creates all four special subdirectories" { ... }
test "execute creates ligi_tags.md in art/index/" { ... }
test "execute creates ligi.toml config file" { ... }
test "execute with global=true creates ~/.ligi/art" { ... }
test "execute with global=true puts config in ~/.ligi/config" { ... }
test "execute with root override uses specified path" { ... }
test "execute is idempotent - skips existing dirs" { ... }
test "execute is idempotent - skips existing files" { ... }
test "execute with quiet=true produces no stdout output" { ... }
```

#### Step 4.2: Implement stub commands

Create minimal stubs for future commands:

```zig
// src/cli/commands/index.zig
pub fn execute(allocator: std.mem.Allocator, args: anytype, stdout: anytype, stderr: anytype) anyerror!u8 {
    _ = allocator;
    _ = args;
    try stderr.writeAll("error: 'index' command not yet implemented\n");
    _ = stdout;
    return 1;
}

// Similar for query.zig and archive.zig
```

---

### Phase 5: Main Entry Point & Integration

#### Step 5.1: Implement `cli/commands/mod.zig`

```zig
// src/cli/commands/mod.zig

pub const init = @import("init.zig");
pub const index = @import("index.zig");
pub const query = @import("query.zig");
pub const archive = @import("archive.zig");
```

#### Step 5.2: Implement `cli/mod.zig`

```zig
// src/cli/mod.zig

pub const registry = @import("registry.zig");
pub const help = @import("help.zig");
pub const commands = @import("commands/mod.zig");

pub const CommandRegistry = registry.CommandRegistry;
pub const buildRegistry = registry.buildRegistry;
```

#### Step 5.3: Implement `main.zig`

```zig
// src/main.zig

const std = @import("std");
const cli = @import("cli/mod.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer().any();
    const stderr = std.io.getStdErr().writer().any();

    const reg = cli.buildRegistry();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.next();

    // Collect remaining args
    var arg_list = std.ArrayList([]const u8).init(allocator);
    defer arg_list.deinit();
    while (args.next()) |arg| {
        try arg_list.append(arg);
    }

    const exit_code = try reg.parseAndDispatch(
        allocator,
        arg_list.items,
        stdout,
        stderr,
    );

    std.process.exit(exit_code);
}
```

---

### Phase 6: Integration Tests

#### Step 6.1: Implement test fixtures

```zig
// src/testing/fixtures.zig

const std = @import("std");

pub const TempDir = struct {
    path: []const u8,
    dir: std.fs.Dir,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator) !TempDir {
        const path = try std.fs.cwd().makeTempPath(allocator, "ligi-test-", .{});
        const dir = try std.fs.openDirAbsolute(path, .{});
        return .{ .path = path, .dir = dir, .allocator = allocator };
    }

    pub fn cleanup(self: *TempDir) void {
        self.dir.close();
        std.fs.deleteTreeAbsolute(self.path) catch {};
        self.allocator.free(self.path);
    }
};

pub fn runLigi(allocator: std.mem.Allocator, args: []const []const u8) !struct {
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
} {
    var child = std.ChildProcess.init(
        &[_][]const u8{"./zig-out/bin/ligi"} ++ args,
        allocator,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);

    const term = try child.wait();
    const exit_code: u8 = switch (term) {
        .Exited => |code| code,
        else => 255,
    };

    return .{ .exit_code = exit_code, .stdout = stdout, .stderr = stderr };
}
```

#### Step 6.2: Implement assertions

```zig
// src/testing/assertions.zig

const std = @import("std");

pub fn assertDirExists(path: []const u8) !void {
    const stat = std.fs.cwd().statFile(path) catch |err| {
        std.debug.print("Expected directory to exist: {s}\n", .{path});
        return err;
    };
    try std.testing.expect(stat.kind == .directory);
}

pub fn assertFileExists(path: []const u8) !void {
    const stat = std.fs.cwd().statFile(path) catch |err| {
        std.debug.print("Expected file to exist: {s}\n", .{path});
        return err;
    };
    try std.testing.expect(stat.kind == .file);
}

pub fn assertFileContains(allocator: std.mem.Allocator, path: []const u8, expected: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, expected) != null);
}
```

#### Step 6.3: Integration test cases

```zig
// tests/integration/init_test.zig

const std = @import("std");
const fixtures = @import("../../src/testing/fixtures.zig");
const assertions = @import("../../src/testing/assertions.zig");

test "ligi init creates complete directory structure" {
    const allocator = std.testing.allocator;
    var tmp = try fixtures.TempDir.create(allocator);
    defer tmp.cleanup();

    const result = try fixtures.runLigi(allocator, &.{ "init", "--root", tmp.path });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // Verify all directories
    try assertions.assertDirExists(try std.fs.path.join(allocator, &.{ tmp.path, "art" }));
    try assertions.assertDirExists(try std.fs.path.join(allocator, &.{ tmp.path, "art", "index" }));
    try assertions.assertDirExists(try std.fs.path.join(allocator, &.{ tmp.path, "art", "template" }));
    try assertions.assertDirExists(try std.fs.path.join(allocator, &.{ tmp.path, "art", "config" }));
    try assertions.assertDirExists(try std.fs.path.join(allocator, &.{ tmp.path, "art", "archive" }));
}

test "ligi init creates ligi_tags.md" {
    // ...
}

test "ligi init creates ligi.toml config" {
    // ...
}

test "ligi init is idempotent" {
    // Run twice, verify no error, same result
}

test "ligi init --quiet produces no output" {
    // ...
}

test "ligi i shows not implemented error" {
    // Verify alias works and stub responds
}

test "ligi --help shows all commands" {
    // ...
}

test "ligi init --help shows init help" {
    // ...
}

test "ligi --version shows version" {
    // ...
}

test "ligi nonexistent shows error" {
    // ...
}
```

---

## Part 5: Testing Summary

### Unit Test Count by Module

| Module | Tests |
|--------|-------|
| `core/errors.zig` | 8 |
| `core/paths.zig` | 7 |
| `core/fs.zig` | 10 |
| `core/config.zig` | 7 |
| `cli/registry.zig` | 6 |
| `cli/help.zig` | 3 |
| `cli/commands/init.zig` | 10 |
| **Total Unit Tests** | **51** |

### Integration Test Count

| Category | Tests |
|----------|-------|
| Init happy path | 3 |
| Init idempotency | 1 |
| Init options | 2 |
| Alias resolution | 2 |
| Help output | 3 |
| Error handling | 2 |
| **Total Integration Tests** | **13** |

### Test Commands

```bash
# Run all unit tests
zig build test

# Run integration tests (requires build first)
zig build && zig build test-integration

# Run specific test file
zig test src/core/errors.zig

# Run with verbose output
zig build test -- --verbose
```

---

## Part 6: Implementation Checklist

### Phase 1: Setup
- [ ] 1.1 Add zig-clap dependency
- [ ] 1.2 Add tomlz dependency
- [ ] 1.3 Update build.zig with module imports
- [ ] 1.4 Create directory structure
- [ ] 1.5 Verify `zig build` succeeds

### Phase 2: Core Infrastructure
- [ ] 2.1 `core/errors.zig` + 8 tests passing
- [ ] 2.2 `core/paths.zig` + 7 tests passing
- [ ] 2.3 `core/fs.zig` + 10 tests passing
- [ ] 2.4 `core/config.zig` + 7 tests passing

### Phase 3: CLI Infrastructure
- [ ] 3.1 `cli/registry.zig` + 6 tests passing
- [ ] 3.2 `cli/help.zig` + 3 tests passing

### Phase 4: Init Command
- [ ] 4.1 `cli/commands/init.zig` + 10 tests passing
- [ ] 4.2 Stub commands (index, query, archive)

### Phase 5: Main Entry Point
- [ ] 5.1 `cli/commands/mod.zig`
- [ ] 5.2 `cli/mod.zig`
- [ ] 5.3 `main.zig`
- [ ] 5.4 Manual smoke test: `zig build run -- init`

### Phase 6: Integration Tests
- [ ] 6.1 `testing/fixtures.zig`
- [ ] 6.2 `testing/assertions.zig`
- [ ] 6.3 Integration test suite (13 tests passing)

---

## Part 7: File Contents Reference

### `art/index/ligi_tags.md` (initial)

```markdown
# Ligi Tag Index

This file is auto-maintained by ligi. Each tag links to its index file.

## Tags

(No tags indexed yet)
```

### `~/.ligi/config/ligi.toml` or `art/config/ligi.toml` (initial)

```toml
# Ligi Configuration
# See https://github.com/evan-forbes/ligi for documentation

version = "0.1.0"

[index]
# Patterns to ignore when indexing (glob syntax)
ignore_patterns = ["*.tmp", "*.bak"]
# Whether to follow symbolic links
follow_symlinks = false

[query]
# Default output format: "text" or "json"
default_format = "text"
# Enable colored output
colors = true
```

---

## Part 8: Future Considerations (Out of Scope)

Documented for awareness but **not** part of this implementation:

1. **`ligi index` command** - Markdown parser for `[[t/tag]]` syntax
2. **`ligi query` command** - Tag index reading, ripgrep integration
3. **`ligi archive` command** - Link rewriting logic
4. **Git integration** - Auto-commit after operations
5. **Watch mode** - File watcher for auto-indexing
6. **Template expansion** - Variable substitution
7. **Config inheritance** - Local config extending global

---

## Appendix A: Estimated Complexity

| Module | Lines (code) | Lines (tests) |
|--------|--------------|---------------|
| `core/errors.zig` | 80 | 60 |
| `core/paths.zig` | 50 | 50 |
| `core/fs.zig` | 100 | 80 |
| `core/config.zig` | 80 | 60 |
| `cli/registry.zig` | 200 | 80 |
| `cli/help.zig` | 40 | 30 |
| `cli/commands/init.zig` | 150 | 100 |
| `cli/commands/stubs` | 30 | 0 |
| `cli/mod.zig` | 10 | 0 |
| `main.zig` | 50 | 0 |
| `testing/*` | 100 | 0 |
| **Total** | **~890** | **~460** |

**Grand Total**: ~1350 lines for a complete, well-tested `init` implementation with extensible CLI framework.
