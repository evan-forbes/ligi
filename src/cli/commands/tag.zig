//! The `ligi tag` (alias `t`) command implementation.
//!
//! Adds tags to files or all markdown files in a directory.
//!
//! Usage:
//!   ligi t <path> <tag>        Add tag to a file or all .md files in a directory
//!   ligi t <path> <tag1,tag2>  Add multiple tags (comma-separated)

const std = @import("std");
const core = @import("../../core/mod.zig");
const tag_index = core.tag_index;
const fs = core.fs;
const workspace = core.workspace;
const ligi_log = core.log;
const config = core.config;

pub fn run(
    allocator: std.mem.Allocator,
    path_arg: ?[]const u8,
    tags_arg: ?[]const u8,
    quiet: bool,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const path = path_arg orelse {
        try stderr.writeAll("error: tag requires a file or directory path\n");
        try stderr.writeAll("usage: ligi t <path> <tag>\n");
        return 1;
    };

    const tags_str = tags_arg orelse {
        try stderr.writeAll("error: tag requires a tag name\n");
        try stderr.writeAll("usage: ligi t <path> <tag>\n");
        return 1;
    };

    // Validate tags up front
    var tags: std.ArrayList([]const u8) = .empty;
    defer tags.deinit(arena_alloc);

    var it = std.mem.splitScalar(u8, tags_str, ',');
    while (it.next()) |tag_raw| {
        const tag = std.mem.trim(u8, tag_raw, " \t");
        if (tag.len == 0) continue;
        const validation = tag_index.isValidTagName(tag);
        if (validation != .valid) {
            switch (validation) {
                .empty => try stderr.print("error: empty tag name\n", .{}),
                .too_long => try stderr.print("error: tag name too long: '{s}'\n", .{tag}),
                .path_traversal => try stderr.print("error: path traversal in tag name: '{s}'\n", .{tag}),
                .invalid_char => |c| try stderr.print("error: invalid character '{c}' in tag name '{s}' (allowed: A-Za-z0-9_-./)\n", .{ c, tag }),
                .valid => unreachable,
            }
            return 1;
        }
        try tags.append(arena_alloc, tag);
    }

    if (tags.items.len == 0) {
        try stderr.writeAll("error: no valid tags provided\n");
        return 1;
    }

    // Determine if path is a file or directory
    const is_dir = fs.dirExists(path);
    const is_file = !is_dir and fs.fileExists(path);

    if (!is_dir and !is_file) {
        try stderr.print("error: path not found: {s}\n", .{path});
        return 1;
    }

    var total_files: usize = 0;
    var total_tags_added: usize = 0;

    if (is_file) {
        // Single file
        if (!std.mem.endsWith(u8, path, ".md")) {
            try stderr.print("error: not a markdown file: {s}\n", .{path});
            return 1;
        }
        const added = addTagsToFile(arena_alloc, path, tags.items, stdout, stderr, quiet) catch |err| {
            if (err != error.ReadError and err != error.WriteError and err != error.InvalidTagName) {
                try stderr.print("error: failed to tag {s}: {s}\n", .{ path, @errorName(err) });
            }
            return 1;
        };
        total_files = 1;
        total_tags_added = added;
    } else {
        // Directory: walk and tag all .md files
        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch {
            try stderr.print("error: cannot open directory: {s}\n", .{path});
            return 1;
        };
        defer dir.close();

        var walker = dir.walk(arena_alloc) catch {
            try stderr.print("error: cannot walk directory: {s}\n", .{path});
            return 1;
        };
        defer walker.deinit();

        while (walker.next() catch null) |entry| {
            if (entry.kind == .directory) continue;
            if (!std.mem.endsWith(u8, entry.path, ".md")) continue;

            // Build full path
            const full_path = try std.fs.path.join(arena_alloc, &.{ path, entry.path });

            const added = addTagsToFile(arena_alloc, full_path, tags.items, stdout, stderr, quiet) catch |err| {
                if (err != error.ReadError and err != error.WriteError and err != error.InvalidTagName) {
                    try stderr.print("warning: failed to tag {s}: {s}\n", .{ full_path, @errorName(err) });
                }
                continue;
            };
            total_files += 1;
            total_tags_added += added;
        }
    }

    if (!quiet) {
        if (total_tags_added == 0) {
            try stdout.print("no new tags added ({d} file(s) already tagged)\n", .{total_files});
        } else {
            try stdout.print("added {d} tag(s) across {d} file(s)\n", .{ total_tags_added, total_files });
        }
    }

    // Re-index to update tag indexes
    const art_path = workspace.resolveArtPath(arena_alloc, null, stderr) catch |err| {
        try stderr.print("warning: failed to resolve art path for re-indexing: {s}\n", .{@errorName(err)});
        return 0;
    } orelse {
        // No workspace found, skip re-indexing
        return 0;
    };

    if (total_tags_added > 0) {
        const cfg = config.getDefaultConfig();
        reindex(arena_alloc, art_path, cfg, stdout, stderr, quiet) catch {
            try stderr.writeAll("warning: re-indexing failed\n");
        };
    }

    return 0;
}

/// Add tags to a single file. Returns number of tags actually added.
fn addTagsToFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    tags: []const []const u8,
    stdout: anytype,
    stderr: anytype,
    quiet: bool,
) !usize {
    // Read existing content
    const content = switch (fs.readFile(allocator, file_path)) {
        .ok => |c| c,
        .err => |e| {
            try stderr.print("error: failed to read {s}: {s}\n", .{ file_path, e.context.message });
            return error.ReadError;
        },
    };
    defer allocator.free(content);

    // Check which tags already exist
    var new_tags: std.ArrayList([]const u8) = .empty;
    defer new_tags.deinit(allocator);

    for (tags) |tag| {
        const pattern = try std.fmt.allocPrint(allocator, "[[t/{s}]]", .{tag});
        defer allocator.free(pattern);

        if (std.mem.indexOf(u8, content, pattern) == null) {
            try new_tags.append(allocator, tag);
        }
    }

    if (new_tags.items.len == 0) return 0;

    // Build tags line
    var tags_line: std.ArrayList(u8) = .empty;
    defer tags_line.deinit(allocator);

    for (new_tags.items, 0..) |tag, i| {
        if (i > 0) try tags_line.appendSlice(allocator, " ");
        try tags_line.appendSlice(allocator, "[[t/");
        try tags_line.appendSlice(allocator, tag);
        try tags_line.appendSlice(allocator, "]]");
    }
    try tags_line.appendSlice(allocator, "\n");

    // Find insertion point: after first heading, or top of file
    var insert_pos: usize = 0;
    var found_heading = false;
    var line_start: usize = 0;

    for (content, 0..) |c, i| {
        if (c == '\n' or i == content.len - 1) {
            const line_end = if (c == '\n') i else i + 1;
            const line = content[line_start..line_end];
            const trimmed = std.mem.trimLeft(u8, line, " \t");
            if (trimmed.len > 0 and trimmed[0] == '#') {
                insert_pos = if (c == '\n') i + 1 else line_end;
                found_heading = true;
                break;
            }
            line_start = i + 1;
        }
    }

    if (!found_heading) insert_pos = 0;

    // Build new content
    var new_content: std.ArrayList(u8) = .empty;
    defer new_content.deinit(allocator);

    try new_content.appendSlice(allocator, content[0..insert_pos]);
    if (found_heading and insert_pos > 0 and content[insert_pos - 1] != '\n') {
        try new_content.appendSlice(allocator, "\n");
    }
    try new_content.appendSlice(allocator, tags_line.items);
    if (insert_pos < content.len and content[insert_pos] != '\n') {
        try new_content.appendSlice(allocator, "\n");
    }
    try new_content.appendSlice(allocator, content[insert_pos..]);

    // Write back
    switch (fs.writeFile(file_path, new_content.items)) {
        .ok => {},
        .err => |e| {
            try stderr.print("error: failed to write {s}: {s}\n", .{ file_path, e.context.message });
            return error.WriteError;
        },
    }

    if (!quiet) {
        try stdout.print("  {s}: +{d} tag(s)\n", .{ file_path, new_tags.items.len });
    }

    return new_tags.items.len;
}

/// Re-index after tagging to keep indexes up to date
fn reindex(
    allocator: std.mem.Allocator,
    art_path: []const u8,
    cfg: core.config.LigiConfig,
    stdout: anytype,
    stderr: anytype,
    quiet: bool,
) !void {
    var tag_map = try tag_index.collectTags(
        allocator,
        art_path,
        null,
        cfg.index.follow_symlinks,
        cfg.index.ignore_patterns,
        stderr,
    );
    defer tag_map.deinit();

    _ = try tag_index.writeLocalIndexes(allocator, art_path, &tag_map, stdout, true);
    _ = try tag_index.fillAllTagLinks(allocator, art_path, cfg.index.follow_symlinks, cfg.index.ignore_patterns, stdout, true);

    const ws_root = std.fs.path.dirname(art_path) orelse ".";
    tag_index.writeGlobalIndexes(allocator, &tag_map, ws_root, stdout, true) catch {};

    if (!quiet) {
        try stdout.writeAll("indexes updated\n");
    }
}

// ============================================================================
// Tests
// ============================================================================

test "tag command module compiles" {
    _ = run;
}
