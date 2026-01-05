//! The `ligi init` command implementation.

const std = @import("std");
const core = @import("../../core/mod.zig");
const paths = core.paths;
const fs = core.fs;
const config = core.config;
const global_index = core.global_index;

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

/// Initial content for art/README.md
pub const INITIAL_ART_README =
    \\# art/ (Ligi artifacts)
    \\
    \\This directory is created by `ligi init` for each repo and for the global
    \\`~/.ligi` store. It is the project's human/LLM artifact system.
    \\
    \\Contents:
    \\- `index/`    auto-maintained link + tag indexes
    \\- `template/` prompt/report templates
    \\- `config/`   Ligi config (e.g., `ligi.toml`)
    \\- `archive/`  soft-delete area for retired docs
    \\
    \\Docs:
    \\- `ligi_art.md` explains the art directory
    \\- `ligi_templates.md` explains templates
    \\
    \\Related directories:
    \\- [media](../media/README.md) - images and diagrams for markdown docs
    \\- [data](../data/README.md) - CSV/JSONL files for tables and visualizations
    \\
    \\Please treat `art/` as durable project context. Avoid deleting or moving files
    \\here unless explicitly requested; prefer `archive/` for cleanup. See
    \\`art/founding_idea.md` for design intent.
    \\
;

/// Initial content for art/ligi_art.md
pub const INITIAL_LIGI_ART_DOC =
    \\# Ligi Art Directory
    \\
    \\`art/` is the durable Ligi artifact store (repo) and `~/.ligi/art` (global). It
    \\holds human/LLM context and is meant to live in git.
    \\
    \\Core areas:
    \\- `index/` auto-maintained tag/link indexes
    \\- `template/` reusable templates
    \\- `config/` ligi config
    \\- `archive/` retired docs
    \\
    \\Guidelines:
    \\- Add notes, plans, logs, and other context here.
    \\- Avoid delete/move; archive instead.
    \\
;

/// Initial content for art/ligi_templates.md
pub const INITIAL_LIGI_TEMPLATES_DOC =
    \\# Ligi Templates
    \\
    \\A template is markdown with a top ` ```toml ` block (before any heading) that
    \\declares fields, then the body.
    \\
    \\Example fields:
    \\```toml
    \\name = "Alice"
    \\age = 30
    \\role = { type = "string" }
    \\```
    \\
    \\Usage:
    \\- `{{ name }}` substitutes values.
    \\- `!![label](path)` includes a file (path relative to template file). If the
    \\  included file has `# front`...`# Document` or `---` frontmatter, it is stripped.
    \\  Max include depth: 10.
    \\
    \\CLI: `ligi template fill [path]` (or `ligi t f`). `--clipboard` copies output.
    \\No path opens `fzf`.
    \\
;

/// Initial content for AGENTS.md
pub const INITIAL_AGENTS =
    \\# Ligi Agent Notes
    \\
    \\`art/` is the durable Ligi artifact store created by `ligi init`.
    \\
    \\Do not delete or move files under `art/` unless explicitly asked; archive instead
    \\(`art/archive/`). See `art/ligi_art.md` and `art/founding_idea.md`.
    \\
    \\Optional: run `scripts/install_git_hooks.sh` to block `art/` deletions.
    \\
;

/// Initial content for media/README.md
pub const INITIAL_MEDIA_README =
    \\# media/
    \\
    \\This directory holds media files (images, diagrams, etc.) referenced by markdown
    \\documents in this repository.
    \\
    \\Guidelines:
    \\- Use descriptive filenames (e.g., `architecture-overview.png`)
    \\- Prefer vector formats (SVG) when possible for diagrams
    \\- Reference files using relative paths from your markdown: `![alt](../media/image.png)`
    \\
;

/// Initial content for data/README.md
pub const INITIAL_DATA_README =
    \\# data/
    \\
    \\This directory holds structured data files (CSV, JSONL, etc.) that can be rendered
    \\into tables or visualizations in markdown documents.
    \\
    \\Guidelines:
    \\- Use descriptive filenames (e.g., `metrics-2024.csv`)
    \\- Include a header row in CSV files
    \\- Use JSONL for semi-structured or nested data
    \\
;

/// Result of init operation for reporting
pub const InitResult = struct {
    created_dirs: std.ArrayList([]const u8) = .empty,
    skipped_dirs: std.ArrayList([]const u8) = .empty,
    created_files: std.ArrayList([]const u8) = .empty,
    skipped_files: std.ArrayList([]const u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) InitResult {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *InitResult) void {
        for (self.created_dirs.items) |path| {
            self.allocator.free(path);
        }
        for (self.skipped_dirs.items) |path| {
            self.allocator.free(path);
        }
        for (self.created_files.items) |path| {
            self.allocator.free(path);
        }
        for (self.skipped_files.items) |path| {
            self.allocator.free(path);
        }
        self.created_dirs.deinit(self.allocator);
        self.skipped_dirs.deinit(self.allocator);
        self.created_files.deinit(self.allocator);
        self.skipped_files.deinit(self.allocator);
    }
};

/// Run the init command
pub fn run(
    allocator: std.mem.Allocator,
    global: bool,
    root_override: ?[]const u8,
    quiet: bool,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var result = InitResult.init(allocator);
    defer result.deinit();

    // Determine base path
    var base_path: []const u8 = undefined;
    var base_path_allocated = false;
    defer if (base_path_allocated) allocator.free(base_path);

    if (root_override) |r| {
        base_path = r;
    } else if (global) {
        switch (paths.getGlobalRoot(allocator)) {
            .ok => |p| {
                base_path = p;
                base_path_allocated = true;
            },
            .err => |e| {
                try e.write(stderr);
                return e.exitCode();
            },
        }
    } else {
        base_path = ".";
    }

    // Create main art directory
    const art_path = try paths.joinPath(allocator, &.{ base_path, "art" });
    defer allocator.free(art_path);

    try createDirTracked(allocator, art_path, &result);

    // Create special subdirectories
    for (paths.SPECIAL_DIRS) |special| {
        const dir_path = try paths.joinPath(allocator, &.{ art_path, special });
        defer allocator.free(dir_path);
        try createDirTracked(allocator, dir_path, &result);
    }

    // Create initial files
    // 1. Tag index in art/index/ligi_tags.md
    const tags_path = try paths.joinPath(allocator, &.{ art_path, "index", "ligi_tags.md" });
    defer allocator.free(tags_path);
    try createFileTracked(allocator, tags_path, INITIAL_TAGS_INDEX, &result);

    // 2. Art README in art/README.md
    const art_readme_path = try paths.joinPath(allocator, &.{ art_path, "README.md" });
    defer allocator.free(art_readme_path);
    try createFileTracked(allocator, art_readme_path, INITIAL_ART_README, &result);

    // 3. Art docs in art/
    const art_doc_path = try paths.joinPath(allocator, &.{ art_path, "ligi_art.md" });
    defer allocator.free(art_doc_path);
    try createFileTracked(allocator, art_doc_path, INITIAL_LIGI_ART_DOC, &result);

    const templates_doc_path = try paths.joinPath(allocator, &.{ art_path, "ligi_templates.md" });
    defer allocator.free(templates_doc_path);
    try createFileTracked(allocator, templates_doc_path, INITIAL_LIGI_TEMPLATES_DOC, &result);

    // 4. AGENTS.md in base path
    const agents_path = try paths.joinPath(allocator, &.{ base_path, "AGENTS.md" });
    defer allocator.free(agents_path);
    try createFileTracked(allocator, agents_path, INITIAL_AGENTS, &result);

    // 5. media/ directory and README
    const media_path = try paths.joinPath(allocator, &.{ base_path, "media" });
    defer allocator.free(media_path);
    try createDirTracked(allocator, media_path, &result);

    const media_readme_path = try paths.joinPath(allocator, &.{ media_path, "README.md" });
    defer allocator.free(media_readme_path);
    try createFileTracked(allocator, media_readme_path, INITIAL_MEDIA_README, &result);

    // 6. data/ directory and README
    const data_path = try paths.joinPath(allocator, &.{ base_path, "data" });
    defer allocator.free(data_path);
    try createDirTracked(allocator, data_path, &result);

    const data_readme_path = try paths.joinPath(allocator, &.{ data_path, "README.md" });
    defer allocator.free(data_readme_path);
    try createFileTracked(allocator, data_readme_path, INITIAL_DATA_README, &result);

    // 7. Config file
    var config_dir: []const u8 = undefined;
    var config_dir_allocated = false;
    defer if (config_dir_allocated) allocator.free(config_dir);

    if (global) {
        switch (paths.getGlobalConfigPath(allocator)) {
            .ok => |p| {
                config_dir = p;
                config_dir_allocated = true;
            },
            .err => |e| {
                try e.write(stderr);
                return e.exitCode();
            },
        }
    } else {
        config_dir = try paths.joinPath(allocator, &.{ art_path, "config" });
        config_dir_allocated = true;
    }

    // Ensure config dir exists
    try createDirTracked(allocator, config_dir, &result);

    const config_path = try paths.joinPath(allocator, &.{ config_dir, "ligi.toml" });
    defer allocator.free(config_path);
    try createFileTracked(allocator, config_path, config.DEFAULT_CONFIG_TOML, &result);

    // Register repo in global index (only for local init, not --global)
    if (!global) {
        switch (global_index.registerRepo(allocator, base_path)) {
            .ok => {},
            .err => |e| {
                // Non-fatal: warn but continue
                try stderr.writeAll("warning: failed to register repo in global index: ");
                try e.context.format("", .{}, stderr);
                try stderr.writeAll("\n");
            },
        }
    }

    // Print summary if not quiet
    if (!quiet) {
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

fn createDirTracked(allocator: std.mem.Allocator, path: []const u8, result: *InitResult) !void {
    const existed = fs.dirExists(path);
    switch (fs.ensureDirRecursive(path)) {
        .ok => {
            const path_copy = try allocator.dupe(u8, path);
            if (!existed) {
                try result.created_dirs.append(allocator, path_copy);
            } else {
                try result.skipped_dirs.append(allocator, path_copy);
            }
        },
        .err => |e| {
            std.debug.print("Warning: {s}\n", .{e.context.message});
        },
    }
}

fn createFileTracked(allocator: std.mem.Allocator, path: []const u8, content: []const u8, result: *InitResult) !void {
    switch (fs.writeFileIfNotExists(path, content)) {
        .ok => |created| {
            const path_copy = try allocator.dupe(u8, path);
            if (created) {
                try result.created_files.append(allocator, path_copy);
            } else {
                try result.skipped_files.append(allocator, path_copy);
            }
        },
        .err => |e| {
            std.debug.print("Warning: {s}\n", .{e.context.message});
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

test "INITIAL_TAGS_INDEX contains expected header" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_TAGS_INDEX, "# Ligi Tag Index") != null);
}

test "INITIAL_TAGS_INDEX contains Tags section" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_TAGS_INDEX, "## Tags") != null);
}

test "INITIAL_ART_README contains header" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_ART_README, "# art/ (Ligi artifacts)") != null);
}

test "INITIAL_LIGI_ART_DOC contains header" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_LIGI_ART_DOC, "# Ligi Art Directory") != null);
}

test "INITIAL_LIGI_TEMPLATES_DOC contains header" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_LIGI_TEMPLATES_DOC, "# Ligi Templates") != null);
}

test "INITIAL_AGENTS contains header" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_AGENTS, "# Ligi Agent Notes") != null);
}

test "INITIAL_MEDIA_README contains header" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_MEDIA_README, "# media/") != null);
}

test "INITIAL_DATA_README contains header" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_DATA_README, "# data/") != null);
}

test "INITIAL_ART_README links to media and data" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_ART_README, "[media](../media/README.md)") != null);
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_ART_README, "[data](../data/README.md)") != null);
}

test "InitResult init and deinit work correctly" {
    const allocator = std.testing.allocator;
    var result = InitResult.init(allocator);
    defer result.deinit();

    const path1 = try allocator.dupe(u8, "test/path1");
    const path2 = try allocator.dupe(u8, "test/path2");
    try result.created_dirs.append(allocator, path1);
    try result.created_files.append(allocator, path2);

    try std.testing.expectEqual(@as(usize, 1), result.created_dirs.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.created_files.items.len);
}
