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

/// Run the index command
pub fn run(
    allocator: std.mem.Allocator,
    root: ?[]const u8,
    file: ?[]const u8,
    quiet: bool,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    // Arena for all indexing allocations
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

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
    }

    // Load config (use defaults if not found)
    const cfg = config.getDefaultConfig();
    const ignore_patterns = cfg.index.ignore_patterns;
    const follow_symlinks = cfg.index.follow_symlinks;

    // Collect tags
    var tag_map = try tag_index.collectTags(
        arena_alloc,
        art_path,
        file,
        follow_symlinks,
        ignore_patterns,
        stderr,
    );
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

    // Write global indexes
    tag_index.writeGlobalIndexes(arena_alloc, &tag_map, root_path, stdout, quiet) catch |err| {
        // Warn but don't fail if global write fails
        try stderr.print("warning: failed to update global index: {s}\n", .{@errorName(err)});
    };

    // Print summary
    if (!quiet) {
        try stdout.print("indexed {d} files, found {d} unique tags\n", .{ file_count, tag_count });
        if (local_result.created > 0 or local_result.updated > 0) {
            // Already printed by writeLocalIndexes
        }
    }

    return 0;
}

// ============================================================================
// Tests
// ============================================================================

test "index command module compiles" {
    // Basic compilation test
    _ = run;
}
