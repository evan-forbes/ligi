[[t/DONE]]

# Ligi Templating Migration Plan

## Executive Summary

This document is the step‑by‑step implementation plan to migrate the existing `sablono` template CLI (located at `/home/evan/src/evan-forbes/hack/sablono/src/`) into this repo as a first‑class `template` module, and to expose it via the `ligi t f` CLI workflow. It is written so a junior engineer can follow it end‑to‑end, including required tests and validation.

---

## Part 1: Decisions (Finalized)

| # | Decision | Choice |
|---|----------|--------|
| 1 | New module name | `template` |
| 2 | CLI entry | `ligi t` (alias for `template`) |
| 3 | Fill subcommand | `ligi t f` (alias for `fill`) |
| 4 | Missing path behavior | Start `fzf` search from `$HOME` |
| 5 | If `fzf` missing | Fail with actionable error (install or provide path) |
| 6 | Output | Always stdout; optional clipboard with `-c`/`--clipboard` |
| 7 | Template format | TOML frontmatter in ` ```toml ` block before first heading |
| 8 | Include syntax | `!![Label](./path.md)` with recursion limit 10 |

---

## Part 2: Target UX

### 2.1 Command Overview

- `ligi t f [path] [-c|--clipboard]`

### 2.2 Example Interaction

```
$ ligi t f art/template/prompt.md
filling template art/template/prompt.md with:
> foo (default "42"):
$ 69
```

stdout result:
```
this prompt has 69 as a value
```

### 2.3 Missing Path Behavior (Fuzzy Search)

- If `path` is omitted:
  - Run `fzf` to select a file under `$HOME` (suggested: `find "$HOME" -type f -name "*.md" | fzf`).
  - If `fzf` is not installed, exit with:
    - `error: fzf is not installed; install fzf or provide a template path`
  - If user cancels `fzf`, exit with a clean error (no stack traces).

---

## Part 3: Module Migration (Sablono -> Template)

### 3.1 Files to Copy

From `/home/evan/src/evan-forbes/hack/sablono/src/`:
- `parser.zig`
- `engine.zig`
- `prompter.zig`
- `toml.zig` (internal dependency used by parser, not re-exported)
- `clipboard.zig`
- `root.zig`

**Do NOT copy:** `main.zig` or `build.zig` from sablono - we use ligi's build pipeline.

### 3.2 Destination Layout

Create `src/template/` in this repo:
```
src/
  template/
    mod.zig        # new module root (renamed from sablono/root.zig)
    parser.zig
    engine.zig
    prompter.zig
    toml.zig
    clipboard.zig
```

### 3.3 Required Renames + Import Fixes

- Rename `root.zig` -> `mod.zig` (to match ligi conventions).
- Replace all `@import("sablono")` with relative imports:
  - `@import("parser.zig")`, `@import("engine.zig")`, etc.
- Update all comments / names from `sablono` -> `template`.
- In `mod.zig`, re-export the public API:

```zig
pub const parser = @import("parser.zig");
pub const prompter = @import("prompter.zig");
pub const engine = @import("engine.zig");
pub const clipboard = @import("clipboard.zig");
// toml.zig is internal to parser, no need to re-export

test {
    _ = parser;
    _ = prompter;
    _ = engine;
    _ = clipboard;
}
```

---

## Part 4: Build Integration

### 4.1 `build.zig` Updates

The template module lives inside the ligi source tree, so it does NOT need a separate module definition in build.zig. It will be imported via relative paths from within the codebase.

**No changes needed to build.zig** - the module is accessed via `@import("template/mod.zig")` from within the src tree.

### 4.2 `src/root.zig` Updates

Add the template module re-export and tests:

```zig
// Add with other module re-exports (around line 7):
pub const template = @import("template/mod.zig");

// Add to the test block (around line 31):
test {
    // ... existing tests ...

    // Template tests
    _ = @import("template/mod.zig");
}
```

### 4.3 `src/cli/commands/mod.zig` Updates

Add the template command export:

```zig
pub const template = @import("template.zig");
```

---

## Part 5: CLI Integration (`ligi t f`)

### 5.1 Command Registry Changes

In `src/cli/registry.zig`:

**Step 1:** Add command definition to `COMMANDS` array (around line 79):

```zig
.{
    .canonical = "template",
    .names = &.{ "template", "t" },
    .description = "Fill a template from TOML frontmatter",
    .long_description =
    \\Fill templates with interactive prompts.
    \\
    \\Subcommands:
    \\  fill, f    Fill a template interactively
    \\
    \\Usage: ligi t f [path] [-c|--clipboard]
    \\
    \\If path is omitted, fzf is launched to select a template.
    ,
},
```

**Step 2:** Add clap params definition (after `CheckParams`, around line 153):

```zig
/// Template command options
const TemplateParams = clap.parseParamsComptime(
    \\-h, --help         Show this help message
    \\-c, --clipboard    Copy output to clipboard
    \\<str>...
    \\
);
```

**Step 3:** Add dispatch in `run()` function (around line 231):

```zig
} else if (std.mem.eql(u8, cmd.canonical, "template")) {
    return runTemplateCommand(allocator, remaining_args, stdout, stderr);
}
```

**Step 4:** Add handler function (after `runCheckCommand`):

```zig
/// Run the template command with subcommand parsing
fn runTemplateCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    // Check for subcommand
    if (args.len == 0) {
        try stderr.writeAll("error: missing subcommand\n");
        try stderr.writeAll("usage: ligi t <fill|f> [path] [-c|--clipboard]\n");
        return 1;
    }

    const subcmd = args[0];
    const subcmd_args = args[1..];

    // Handle fill subcommand
    if (std.mem.eql(u8, subcmd, "fill") or std.mem.eql(u8, subcmd, "f")) {
        return runTemplateFillCommand(allocator, subcmd_args, stdout, stderr);
    }

    // Handle --help at template level
    if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        const registry = buildRegistry();
        if (registry.findCommand("template")) |cmd| {
            try registry.printCommandHelp(cmd, stdout);
        }
        return 0;
    }

    try stderr.print("error: unknown subcommand '{s}'\n", .{subcmd});
    try stderr.writeAll("usage: ligi t <fill|f> [path] [-c|--clipboard]\n");
    return 1;
}

/// Run the template fill subcommand
fn runTemplateFillCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var diag: clap.Diagnostic = .{};
    var iter = clap.args.SliceIterator{ .args = args };

    var res = clap.parseEx(clap.Help, &TemplateParams, clap.parsers.default, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.report(stderr, err);
        return 1;
    };
    defer res.deinit();

    // Handle --help for fill
    if (res.args.help != 0) {
        try stdout.writeAll("Usage: ligi t f [path] [-c|--clipboard]\n\n");
        try stdout.writeAll("Fill a template interactively.\n\n");
        try stdout.writeAll("Arguments:\n");
        try stdout.writeAll("  [path]         Path to template file (launches fzf if omitted)\n\n");
        try stdout.writeAll("Options:\n");
        try stdout.writeAll("  -c, --clipboard  Copy output to clipboard\n");
        try stdout.writeAll("  -h, --help       Show this help\n");
        return 0;
    }

    const template_cmd = @import("commands/template.zig");
    const positionals = res.positionals[0];
    const path: ?[]const u8 = if (positionals.len > 0) positionals[0] else null;

    return template_cmd.runFill(
        allocator,
        path,
        res.args.clipboard != 0,
        stdout,
        stderr,
    );
}
```

### 5.2 New Command File

Create `src/cli/commands/template.zig`:

```zig
//! Template fill command implementation.

const std = @import("std");
const template = @import("../../template/mod.zig");

/// Run the fill workflow
pub fn runFill(
    allocator: std.mem.Allocator,
    path_arg: ?[]const u8,
    clipboard: bool,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    // Resolve template path (launches fzf if null)
    const template_path = path_arg orelse {
        return resolveFzf(allocator, stdout, stderr);
    };

    // Read template file
    const cwd = std.fs.cwd();
    const abs_path = cwd.realpathAlloc(allocator, template_path) catch |err| {
        try stderr.print("error: cannot resolve path '{s}': {}\n", .{ template_path, err });
        return 1;
    };
    defer allocator.free(abs_path);

    const content = std.fs.cwd().readFileAlloc(allocator, abs_path, 1024 * 1024) catch |err| {
        try stderr.print("error: cannot read '{s}': {}\n", .{ abs_path, err });
        return 1;
    };
    defer allocator.free(content);

    // Parse -> Prompt -> Render
    // ... (call template module functions)

    // Output
    try stdout.writeAll(result);

    if (clipboard) {
        template.clipboard.copy(result) catch |err| {
            try stderr.print("error: clipboard copy failed: {}\n", .{err});
            return 1;
        };
    }

    return 0;
}

/// Launch fzf to select a template, then continue with fill
fn resolveFzf(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    // See Part 5.4 for implementation
    _ = allocator;
    _ = stdout;
    _ = stderr;
    return 1;
}
```

### 5.3 Prompt Output Formatting

Update `src/template/prompter.zig` prompt formatting to match:
- `filling template <path> with:` printed once before prompts
- Each field prompt is formatted like:
  - `> foo (default "42"):` (with default)
  - `> foo:` (no default)

### 5.4 fzf Integration (Interactive File Selection)

When path is omitted, launch fzf **interactively** so the user can pick a file, then continue with that selection:

```zig
fn resolveFzf(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    // Spawn fzf with stdin/stdout connected to terminal for interactive use
    // fzf will search from $HOME for .md files
    const home = std.posix.getenv("HOME") orelse {
        try stderr.writeAll("error: HOME not set\n");
        return 1;
    };

    var child = std.process.Child.init(
        &.{ "sh", "-c", "find \"$HOME\" -type f -name '*.md' 2>/dev/null | fzf" },
        allocator,
    );

    // Inherit stdin/stderr so fzf is interactive
    child.stdin_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    // Capture stdout to get selected file
    child.stdout_behavior = .Pipe;

    child.spawn() catch |err| {
        if (err == error.FileNotFound) {
            try stderr.writeAll("error: fzf is not installed; install fzf or provide a template path\n");
            return 1;
        }
        try stderr.print("error: failed to spawn fzf: {}\n", .{err});
        return 1;
    };

    // Read selected path from fzf stdout
    const selected = child.stdout.?.reader().readUntilDelimiterAlloc(
        allocator,
        '\n',
        4096,
    ) catch |err| {
        _ = child.wait() catch {};
        if (err == error.EndOfStream) {
            // User cancelled fzf (Ctrl+C or Esc)
            try stderr.writeAll("error: no template selected\n");
            return 1;
        }
        try stderr.print("error: failed to read fzf output: {}\n", .{err});
        return 1;
    };
    defer allocator.free(selected);

    const result = child.wait() catch |err| {
        try stderr.print("error: fzf failed: {}\n", .{err});
        return 1;
    };

    if (result.Exited != 0) {
        try stderr.writeAll("error: no template selected\n");
        return 1;
    }

    // Now run fill with the selected path
    return runFillWithPath(allocator, selected, false, stdout, stderr);
}
```

**Key points:**
- `stdin_behavior = .Inherit` - fzf reads from terminal (user can type/navigate)
- `stderr_behavior = .Inherit` - fzf UI renders to terminal
- `stdout_behavior = .Pipe` - we capture the selected file path
- User experience: fzf opens, user picks file, then `ligi t f` continues with that file

---

## Part 6: Fill Flow (Implementation Detail)

### 6.1 Resolve Template Path

- If path provided: resolve it to absolute using `cwd.realpathAlloc`.
- If missing path: launch fzf interactively (see Part 5.4)

### 6.2 Parse + Prompt + Render

1. Read template file contents
2. `template.parser.parse(content)` → returns frontmatter fields + document body
3. `template.prompter.prompt(fields, stdin, stdout)` → returns filled values
4. `template.engine.process(body, values)` → returns rendered output

### 6.3 Output & Clipboard

- Always print filled template to stdout
- If `-c/--clipboard`:
  - call `template.clipboard.copy(...)`
  - if it fails, return error and non‑zero exit

### 6.4 Error Handling

Use consistent error messages matching existing ligi patterns:

| Scenario | Error Message |
|----------|---------------|
| Template file not found | `error: cannot resolve path '<path>': FileNotFound` |
| No ` ```toml ` block found | `error: template missing frontmatter (no toml block found)` |
| TOML block appears after a heading | `error: frontmatter must appear before the first heading` |
| Invalid TOML in frontmatter | `error: invalid frontmatter: <toml error>` |
| Include file not found | `error: include not found: '<path>'` |
| Recursion limit exceeded | `error: include recursion limit (10) exceeded` |
| Invalid int input | `error: expected integer for '<field>'` |
| Clipboard tool missing | `error: clipboard copy failed: no clipboard tool found (install xclip or xsel)` |

All errors should:
- Print to stderr
- Return exit code 1
- NOT print stack traces

---

## Part 7: Documentation to Add

Create a new doc file `art/template/README.md` with:
- Command synopsis + examples
- Frontmatter syntax
- Variables (`{{ key }}`)
- Includes (`!![Label](./path.md)`)
- `fzf` fallback behavior + error message
- Clipboard flag

### 7.1 Template Locations

Templates can live in:
- **Local repo:** `./art/template/` - project-specific templates
- **Global:** `~/.ligi/art/template/` - personal templates available everywhere

When using fzf (no path provided), it searches `$HOME` for all `.md` files, so both locations are searchable.

---

## Part 8: Testing Checklist

### 8.1 Unit Tests (Required)

- `src/template/parser.zig`:
  - Parses valid frontmatter and fields
  - Rejects missing `# front` or `# Document`
  - Validates type `string`/`int`
- `src/template/engine.zig`:
  - Substitution for known vars
  - Leaves unknown vars intact
  - Include expansion works for nested files
  - Recursion limit triggers error
- `src/template/prompter.zig`:
  - Default values are used on empty input
  - Int validation rejects non‑numbers
  - Prompt formatting matches `> name (default "x"):`
- `src/template/clipboard.zig`:
  - Smoke test: function returns error if no clipboard tool

### 8.2 Integration Tests (Required)

- CLI routing:
  - `ligi t --help` prints correct usage
  - `ligi t f --help` prints correct usage
- Template fill flow (mocked IO):
  - Given a test template, ensure output matches expected
  - Verify prompt lines appear in order
- `fzf` missing behavior:
  - Simulate `FileNotFound` spawn and assert error message

### 8.3 Test Fixtures

Create these test fixtures for smoke tests:

**`art/template/prompt.md`** (basic template):

    ```toml
    name = { type = "string", default = "World" }
    count = { type = "int", default = 42 }
    ```

    # Hello Template

    Hello, {{ name }}!

    You have {{ count }} items.

**`art/template/with_include.md`** (tests include syntax):

    ```toml
    title = { type = "string" }
    ```

    # {{ title }}

    !![Common Footer](./footer.md)

**`art/template/footer.md`** (included file):
```markdown
---
Generated by ligi template
```

### 8.4 Smoke Tests (Manual)

Run these manually after integration:

1) `zig build test`

2) Basic fill
```
zig build run -- t f art/template/prompt.md
```

3) Clipboard flag
```
zig build run -- t f art/template/prompt.md -c
```

4) Missing path + fzf
```
zig build run -- t f
```
- Confirm that `fzf` opens
- Confirm canceling exits gracefully
- If `fzf` is missing, confirm the correct error message

---

## Part 9: Step‑By‑Step Task Checklist

### 9.1 Migration Tasks

- [ ] Create `src/template/` directory
- [ ] Copy sablono source files into `src/template/` (see Part 3.1 for file list)
- [ ] Rename `root.zig` -> `mod.zig`
- [ ] Update imports and identifiers from `sablono` -> `template`
- [ ] Update `mod.zig` to re‑export parser/engine/prompter/clipboard (NOT toml - it's internal)

### 9.2 Build/Integration Tasks

- [ ] Re‑export `template` in `src/root.zig`
- [ ] Add `template` test import to `src/root.zig` test block
- [ ] Export `template` command in `src/cli/commands/mod.zig`

### 9.3 CLI Tasks

- [ ] Add `CommandDef` for `template` to `COMMANDS` array in `src/cli/registry.zig`
- [ ] Add `TemplateParams` clap definition in `src/cli/registry.zig`
- [ ] Add `runTemplateCommand` handler in `src/cli/registry.zig`
- [ ] Add `runTemplateFillCommand` handler in `src/cli/registry.zig`
- [ ] Add dispatch case for `"template"` in `run()` function
- [ ] Create `src/cli/commands/template.zig` with `runFill()` and `resolveFzf()`

### 9.4 UX Tasks

- [ ] Implement `fzf` fallback when path omitted
- [ ] Implement error message when `fzf` missing
- [ ] Match prompt formatting to spec
- [ ] Implement `-c/--clipboard` flag

### 9.5 Docs Tasks

- [ ] Add templating docs in `art/template/README.md` (or preferred path)
- [ ] Include examples and flags

### 9.6 Test & Fixture Tasks

- [ ] Create `art/template/prompt.md` test fixture
- [ ] Create `art/template/with_include.md` test fixture
- [ ] Create `art/template/footer.md` test fixture
- [ ] Verify existing sablono unit tests pass after migration
- [ ] Add CLI routing tests (`ligi t --help`, `ligi t f --help`)
- [ ] Run smoke tests listed in 8.4

---

## Part 10: Verification Checklist

After implementation, verify:

- [ ] `zig build test` passes
- [ ] `ligi --help` shows `template, t` command
- [ ] `ligi t --help` shows subcommand info
- [ ] `ligi t f --help` shows fill usage
- [ ] `ligi t f art/template/prompt.md` prompts and outputs correctly
- [ ] `ligi t f art/template/prompt.md -c` copies to clipboard
- [ ] `ligi t f` (no path) launches fzf interactively
- [ ] `ligi t f` with fzf not installed shows helpful error
- [ ] Error messages go to stderr, not stdout
- [ ] Exit code is 0 on success, 1 on error

---

## Notes & Guardrails

- Do not bring in `/home/evan/src/evan-forbes/hack/sablono/build.zig` or its `src/main.zig`.
- Always use the existing `ligi` build pipeline.
- All new code should follow existing style (no non‑ASCII unless present).
- Clipboard is optional, output to stdout is the default behavior.
- The template module does NOT need changes to `build.zig` - it's accessed via relative imports.
- Follow the existing error message patterns: `error: <message>` to stderr, return exit code 1.
- When in doubt, look at how `init` and `check` commands are structured for patterns to follow.

