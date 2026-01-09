//! The `ligi index` command implementation.
//!
//! Indexes tags in markdown files under art/ and creates:
//! - Local tag index: art/index/ligi_tags.md
//! - Per-tag indexes: art/index/tags/<tag>.md
//! - Global indexes: ~/.ligi/art/index/tags/<tag>.md

const std = @import("std");
const core = @import("../../core/mod.zig");
const tag_index = core.tag_index;
const config = core.config;
const fs = core.fs;
const paths = core.paths;
const global_index = core.global_index;

/// Run the index command
pub fn run(
    allocator: std.mem.Allocator,
    root: ?[]const u8,
    file: ?[]const u8,
    tags_arg: ?[]const u8,
    global: bool,
    no_local: bool,
    quiet: bool,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    // Arena for all indexing allocations
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Validate --tags requires --file
    if (tags_arg != null and file == null) {
        try stderr.writeAll("error: --tags requires --file\n");
        return 1;
    }

    if (global) {
        if (file != null) {
            try stderr.writeAll("error: --file is not compatible with --global\n");
            return 1;
        }
        if (tags_arg != null) {
            try stderr.writeAll("error: --tags is not compatible with --global\n");
            return 1;
        }
        if (root != null) {
            try stderr.writeAll("error: --root is not compatible with --global\n");
            return 1;
        }
        // Load global index
        var index = switch (global_index.loadGlobalIndex(arena_alloc)) {
            .ok => |i| i,
            .err => |e| {
                try e.write(stderr);
                return e.exitCode();
            },
        };
        defer index.deinit();

        const global_art = switch (paths.getGlobalArtPath(arena_alloc)) {
            .ok => |p| p,
            .err => |e| {
                try e.write(stderr);
                return e.exitCode();
            },
        };

        const cfg = config.getDefaultConfig();
        const ignore_patterns = cfg.index.ignore_patterns;
        const follow_symlinks = cfg.index.follow_symlinks;

        const stats = try tag_index.rebuildGlobalTagIndexesFromRepos(
            arena_alloc,
            index.repos.items,
            global_art,
            !no_local,
            follow_symlinks,
            ignore_patterns,
            stdout,
            stderr,
            quiet,
        );

        if (!quiet) {
            try stdout.print("repos processed: {d}\n", .{stats.repos_processed});
            try stdout.print("tags written: {d}\n", .{stats.tags_written});
            try stdout.print("files indexed: {d}\n", .{stats.files_indexed});
        }

        return 0;
    }

    // Resolve root directory
    const root_path = root orelse ".";

    // Build art path
    const art_path = try paths.getLocalArtPath(arena_alloc, root_path);

    // Check art directory exists
    if (!fs.dirExists(art_path)) {
        try stderr.print("error: art directory not found: {s}\n", .{art_path});
        return 1;
    }

    // Validate --file is under art/ if provided
    if (file) |f| {
        if (!std.mem.startsWith(u8, f, "art/") and !std.mem.startsWith(u8, f, "art\\")) {
            try stderr.print("error: file outside art directory: {s} (must be under {s})\n", .{ f, art_path });
            return 1;
        }
        // Check file exists
        const full_file_path = try std.fs.path.join(arena_alloc, &.{ root_path, f });
        if (!fs.fileExists(full_file_path)) {
            try stderr.print("error: file not found: {s}\n", .{full_file_path});
            return 1;
        }

        // If --tags is provided, insert tags into the file before indexing
        if (tags_arg) |tags_str| {
            const tags_added = insertTagsIntoFile(arena_alloc, full_file_path, tags_str, stdout, stderr, quiet) catch {
                // Error message already printed by insertTagsIntoFile
                return 1;
            };
            if (!quiet and tags_added > 0) {
                try stdout.print("added {d} tag(s) to {s}\n", .{ tags_added, f });
            }
        }
    }

    // Load config (use defaults if not found)
    const cfg = config.getDefaultConfig();
    const ignore_patterns = cfg.index.ignore_patterns;
    const follow_symlinks = cfg.index.follow_symlinks;

    if (no_local) {
        try stderr.writeAll("error: --no-local is only valid with --global\n");
        return 1;
    }

    // Collect tags
    var tag_map: tag_index.TagMap = undefined;
    if (file) |f| {
        tag_map = try tag_index.loadTagMapFromIndexes(arena_alloc, art_path, stderr);
        try tag_index.updateTagMapForFile(arena_alloc, &tag_map, art_path, f, stderr);
    } else {
        tag_map = try tag_index.collectTags(
            arena_alloc,
            art_path,
            null,
            follow_symlinks,
            ignore_patterns,
            stderr,
        );
    }
    defer tag_map.deinit();

    // Count files and tags
    var file_count: usize = 0;
    var tag_it = tag_map.map.iterator();
    while (tag_it.next()) |entry| {
        file_count += entry.value_ptr.items.len;
    }
    const tag_count = tag_map.map.count();

    // Write local indexes
    const local_result = try tag_index.writeLocalIndexes(arena_alloc, art_path, &tag_map, stdout, quiet);

    // Fill tag links in source files
    var tags_filled: usize = 0;
    if (file) |f| {
        // Fill only the specified file
        const file_in_art = if (std.mem.startsWith(u8, f, "art/"))
            f[4..]
        else if (std.mem.startsWith(u8, f, "art\\"))
            f[4..]
        else
            f;
        tags_filled = try tag_index.fillTagLinksInFile(arena_alloc, art_path, file_in_art, stdout, quiet);
    } else {
        // Fill all files
        tags_filled = try tag_index.fillAllTagLinks(arena_alloc, art_path, follow_symlinks, ignore_patterns, stdout, quiet);
    }

    // Write global indexes
    tag_index.writeGlobalIndexes(arena_alloc, &tag_map, root_path, stdout, quiet) catch |err| {
        // Warn but don't fail if global write fails
        try stderr.print("warning: failed to update global index: {s}\n", .{@errorName(err)});
    };

    // Print summary
    if (!quiet) {
        try stdout.print("indexed {d} files, found {d} unique tags\n", .{ file_count, tag_count });
        if (tags_filled > 0) {
            try stdout.print("filled {d} tag link(s) in source files\n", .{tags_filled});
        }
        if (local_result.created > 0 or local_result.updated > 0) {
            // Already printed by writeLocalIndexes
        }
    }

    return 0;
}

/// Insert tags into a file's frontmatter or at the top of the file.
/// Tags are added as [[t/tag_name]] format.
/// Returns the number of tags added.
fn insertTagsIntoFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    tags_str: []const u8,
    stdout: anytype,
    stderr: anytype,
    quiet: bool,
) !usize {
    _ = stdout;

    // Parse comma-separated tags
    var tags: std.ArrayList([]const u8) = .empty;
    defer tags.deinit(allocator);

    var it = std.mem.splitScalar(u8, tags_str, ',');
    while (it.next()) |tag_raw| {
        const tag = std.mem.trim(u8, tag_raw, " \t");
        if (tag.len > 0) {
            // Validate tag name
            const validation = tag_index.isValidTagName(tag);
            if (validation != .valid) {
                switch (validation) {
                    .empty => try stderr.print("error: empty tag name\n", .{}),
                    .too_long => try stderr.print("error: tag name too long: '{s}'\n", .{tag}),
                    .path_traversal => try stderr.print("error: path traversal in tag name: '{s}'\n", .{tag}),
                    .invalid_char => |c| try stderr.print("error: invalid character '{c}' in tag name '{s}' (allowed: A-Za-z0-9_-./)\n", .{ c, tag }),
                    .valid => unreachable,
                }
                return error.InvalidTagName;
            }
            try tags.append(allocator, tag);
        }
    }

    if (tags.items.len == 0) {
        return 0;
    }

    // Read existing file content
    const content = switch (fs.readFile(allocator, file_path)) {
        .ok => |c| c,
        .err => |e| {
            try stderr.print("error: failed to read file {s}: {s}\n", .{ file_path, e.context.message });
            return error.ReadError;
        },
    };
    defer allocator.free(content);

    // Check which tags already exist in the file
    var new_tags: std.ArrayList([]const u8) = .empty;
    defer new_tags.deinit(allocator);

    for (tags.items) |tag| {
        // Build the tag pattern to search for
        const tag_pattern = try std.fmt.allocPrint(allocator, "[[t/{s}]]", .{tag});
        defer allocator.free(tag_pattern);

        if (std.mem.indexOf(u8, content, tag_pattern) == null) {
            try new_tags.append(allocator, tag);
        } else if (!quiet) {
            // Tag already exists, skip silently unless verbose
        }
    }

    if (new_tags.items.len == 0) {
        return 0; // All tags already exist
    }

    // Build the tags line to insert
    var tags_line: std.ArrayList(u8) = .empty;
    defer tags_line.deinit(allocator);

    for (new_tags.items, 0..) |tag, i| {
        if (i > 0) {
            try tags_line.appendSlice(allocator, " ");
        }
        try tags_line.appendSlice(allocator, "[[t/");
        try tags_line.appendSlice(allocator, tag);
        try tags_line.appendSlice(allocator, "]]");
    }
    try tags_line.appendSlice(allocator, "\n");

    // Find where to insert the tags
    // Strategy: Insert after the first heading (# line) if present, otherwise at the top
    var insert_pos: usize = 0;
    var found_heading = false;

    // Look for first markdown heading
    var line_start: usize = 0;
    for (content, 0..) |c, i| {
        if (c == '\n' or i == content.len - 1) {
            const line_end = if (c == '\n') i else i + 1;
            const line = content[line_start..line_end];

            // Check if this line is a heading
            const trimmed = std.mem.trimLeft(u8, line, " \t");
            if (trimmed.len > 0 and trimmed[0] == '#') {
                // Found a heading, insert after this line
                insert_pos = if (c == '\n') i + 1 else line_end;
                found_heading = true;
                break;
            }

            line_start = i + 1;
        }
    }

    // If no heading found, insert at the very top
    if (!found_heading) {
        insert_pos = 0;
    }

    // Build new content
    var new_content: std.ArrayList(u8) = .empty;
    defer new_content.deinit(allocator);

    try new_content.appendSlice(allocator, content[0..insert_pos]);

    // Add a newline before tags if inserting after heading and there isn't one
    if (found_heading and insert_pos > 0 and content[insert_pos - 1] != '\n') {
        try new_content.appendSlice(allocator, "\n");
    }

    try new_content.appendSlice(allocator, tags_line.items);

    // Add a newline after tags if the next content doesn't start with one
    if (insert_pos < content.len and content[insert_pos] != '\n') {
        try new_content.appendSlice(allocator, "\n");
    }

    try new_content.appendSlice(allocator, content[insert_pos..]);

    // Write the new content back to the file
    switch (fs.writeFile(file_path, new_content.items)) {
        .ok => {},
        .err => |e| {
            try stderr.print("error: failed to write file {s}: {s}\n", .{ file_path, e.context.message });
            return error.WriteError;
        },
    }

    return new_tags.items.len;
}

// ============================================================================
// Tests
// ============================================================================

test "index command module compiles" {
    // Basic compilation test
    _ = run;
}
