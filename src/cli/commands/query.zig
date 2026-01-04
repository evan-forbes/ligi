//! The `ligi query` command implementation.
//!
//! Query documents by tags. Supports:
//! - Single tag query: ligi q t <tag>
//! - AND queries: ligi q t tag1 & tag2
//! - OR queries: ligi q t tag1 | tag2
//! - Auto-indexing when index is stale

const std = @import("std");
const core = @import("../../core/mod.zig");
const tag_index = core.tag_index;
const config = core.config;
const fs = core.fs;
const paths = core.paths;
const clipboard = @import("../../template/clipboard.zig");

/// Output format for query results
pub const OutputFormat = enum {
    text,
    json,
};

/// Run the query command
pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
    quiet: bool,
) !u8 {
    // Check for subcommand
    if (args.len == 0) {
        try stderr.writeAll("error: missing subcommand\n");
        try stderr.writeAll("usage: ligi q t <tag> [& tag2] [| tag3] [-a] [-o text|json] [-c]\n");
        return 1;
    }

    const subcmd = args[0];

    // Handle tag query
    if (std.mem.eql(u8, subcmd, "t") or std.mem.eql(u8, subcmd, "tag")) {
        return runTagQuery(allocator, args[1..], stdout, stderr, quiet);
    }

    // Handle --help at query level
    if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        try stdout.writeAll("Usage: ligi q t <tag> [options]\n\n");
        try stdout.writeAll("Query documents by tags.\n\n");
        try stdout.writeAll("Examples:\n");
        try stdout.writeAll("  ligi q t project           Query single tag\n");
        try stdout.writeAll("  ligi q t project \\& done   Query intersection (AND)\n");
        try stdout.writeAll("  ligi q t project \\| todo   Query union (OR)\n\n");
        try stdout.writeAll("Options:\n");
        try stdout.writeAll("  -r, --root <path>     Repository root directory\n");
        try stdout.writeAll("  -a, --absolute        Output absolute paths\n");
        try stdout.writeAll("  -o, --output <fmt>    Output format: text or json\n");
        try stdout.writeAll("  -c, --clipboard       Copy output to clipboard\n");
        try stdout.writeAll("  --index <bool>        Enable/disable auto-indexing (default: true)\n");
        return 0;
    }

    try stderr.print("error: unknown subcommand '{s}'\n", .{subcmd});
    try stderr.writeAll("usage: ligi q t <tag> [options]\n");
    return 1;
}

/// Run a tag query
fn runTagQuery(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
    quiet: bool,
) !u8 {
    // Arena for all query allocations
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Parse options
    var root: ?[]const u8 = null;
    var absolute = false;
    var output_format: OutputFormat = .text;
    var copy_to_clipboard = false;
    var auto_index = true;

    // Collect tag expression tokens
    var tokens: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--root")) {
            i += 1;
            if (i >= args.len) {
                try stderr.writeAll("error: --root requires a value\n");
                return 1;
            }
            root = args[i];
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--absolute")) {
            absolute = true;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) {
                try stderr.writeAll("error: --output requires a value\n");
                return 1;
            }
            if (std.mem.eql(u8, args[i], "json")) {
                output_format = .json;
            } else if (std.mem.eql(u8, args[i], "text")) {
                output_format = .text;
            } else {
                try stderr.print("error: invalid output format '{s}'\n", .{args[i]});
                return 1;
            }
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--clipboard")) {
            copy_to_clipboard = true;
        } else if (std.mem.eql(u8, arg, "--index")) {
            i += 1;
            if (i >= args.len) {
                try stderr.writeAll("error: --index requires a value\n");
                return 1;
            }
            if (std.mem.eql(u8, args[i], "true")) {
                auto_index = true;
            } else if (std.mem.eql(u8, args[i], "false")) {
                auto_index = false;
            } else {
                try stderr.print("error: --index must be true or false, got '{s}'\n", .{args[i]});
                return 1;
            }
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stdout.writeAll("Usage: ligi q t <tag> [& tag2] [| tag3] [options]\n\n");
            try stdout.writeAll("Query documents by tags.\n\n");
            try stdout.writeAll("Options:\n");
            try stdout.writeAll("  -r, --root <path>     Repository root directory\n");
            try stdout.writeAll("  -a, --absolute        Output absolute paths\n");
            try stdout.writeAll("  -o, --output <fmt>    Output format: text or json\n");
            try stdout.writeAll("  -c, --clipboard       Copy output to clipboard\n");
            try stdout.writeAll("  --index <bool>        Enable/disable auto-indexing\n");
            return 0;
        } else {
            try tokens.append(arena_alloc, arg);
        }
    }

    if (tokens.items.len == 0) {
        try stderr.writeAll("error: no tag specified\n");
        try stderr.writeAll("usage: ligi q t <tag>\n");
        return 1;
    }

    // Resolve paths
    const root_path = root orelse ".";
    const art_path = try paths.getLocalArtPath(arena_alloc, root_path);

    // Check art directory exists
    if (!fs.dirExists(art_path)) {
        try stderr.print("error: art directory not found: {s}\n", .{art_path});
        return 1;
    }

    // Auto-index if needed
    if (auto_index) {
        const stale = try tag_index.isIndexStale(arena_alloc, art_path);
        if (stale) {
            // Run indexing
            const cfg = config.getDefaultConfig();
            var tag_map = try tag_index.collectTags(
                arena_alloc,
                art_path,
                null,
                cfg.index.follow_symlinks,
                cfg.index.ignore_patterns,
                stderr,
            );
            defer tag_map.deinit();

            _ = try tag_index.writeLocalIndexes(arena_alloc, art_path, &tag_map, stdout, quiet);

            // Try to update global index too
            tag_index.writeGlobalIndexes(arena_alloc, &tag_map, root_path, stdout, quiet) catch {};
        }
    }

    // Evaluate query expression
    var result_set = std.StringHashMap(void).init(arena_alloc);
    var first_tag = true;
    var current_op: enum { none, and_op, or_op } = .none;

    for (tokens.items) |token| {
        // Check for operators
        if (std.mem.eql(u8, token, "&")) {
            current_op = .and_op;
            continue;
        }
        if (std.mem.eql(u8, token, "|")) {
            current_op = .or_op;
            continue;
        }

        // It's a tag - load its files
        const tag_path = try std.fs.path.join(arena_alloc, &.{ art_path, "index", "tags", token });
        const tag_file = try std.fmt.allocPrint(arena_alloc, "{s}.md", .{tag_path});

        const files = tag_index.readTagIndex(arena_alloc, tag_file) catch |err| {
            if (err == error.FileNotFound) {
                // Tag not found - empty set
                if (first_tag) {
                    // First tag not found, result is empty
                    first_tag = false;
                    continue;
                }
                // For AND, empty intersection
                // For OR, just skip this tag
                if (current_op == .and_op) {
                    result_set.clearAndFree();
                }
                continue;
            }
            return err;
        };
        defer {
            for (files) |f| arena_alloc.free(f);
            arena_alloc.free(files);
        }

        if (first_tag) {
            // Initialize result set
            for (files) |f| {
                const key = try arena_alloc.dupe(u8, f);
                try result_set.put(key, {});
            }
            first_tag = false;
        } else {
            switch (current_op) {
                .and_op => {
                    // Intersect with current result
                    var new_files = std.StringHashMap(void).init(arena_alloc);
                    for (files) |f| {
                        try new_files.put(f, {});
                    }

                    var to_remove: std.ArrayList([]const u8) = .empty;
                    var it = result_set.keyIterator();
                    while (it.next()) |key| {
                        if (!new_files.contains(key.*)) {
                            try to_remove.append(arena_alloc, key.*);
                        }
                    }
                    for (to_remove.items) |key| {
                        _ = result_set.remove(key);
                    }
                },
                .or_op => {
                    // Union with current result
                    for (files) |f| {
                        if (!result_set.contains(f)) {
                            const key = try arena_alloc.dupe(u8, f);
                            try result_set.put(key, {});
                        }
                    }
                },
                .none => {
                    // No operator, treat as implicit AND
                    var new_files = std.StringHashMap(void).init(arena_alloc);
                    for (files) |f| {
                        try new_files.put(f, {});
                    }

                    var to_remove: std.ArrayList([]const u8) = .empty;
                    var it = result_set.keyIterator();
                    while (it.next()) |key| {
                        if (!new_files.contains(key.*)) {
                            try to_remove.append(arena_alloc, key.*);
                        }
                    }
                    for (to_remove.items) |key| {
                        _ = result_set.remove(key);
                    }
                },
            }
        }
        current_op = .none;
    }

    // Collect and sort results
    var result_list: std.ArrayList([]const u8) = .empty;
    var result_it = result_set.keyIterator();
    while (result_it.next()) |key| {
        try result_list.append(arena_alloc, key.*);
    }

    std.mem.sort([]const u8, result_list.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    // Convert to absolute paths if requested
    var output_paths: std.ArrayList([]const u8) = .empty;
    if (absolute) {
        const abs_root = std.fs.cwd().realpathAlloc(arena_alloc, root_path) catch root_path;
        for (result_list.items) |path| {
            const abs_path = try std.fs.path.join(arena_alloc, &.{ abs_root, path });
            try output_paths.append(arena_alloc, abs_path);
        }
    } else {
        for (result_list.items) |path| {
            try output_paths.append(arena_alloc, path);
        }
    }

    // Format output
    var output_buffer: std.ArrayList(u8) = .empty;
    const output_writer = output_buffer.writer(arena_alloc);

    switch (output_format) {
        .text => {
            for (output_paths.items) |path| {
                try output_writer.print("{s}\n", .{path});
            }
        },
        .json => {
            // Get first tag for JSON output
            const first_tag_name = for (tokens.items) |t| {
                if (!std.mem.eql(u8, t, "&") and !std.mem.eql(u8, t, "|")) {
                    break t;
                }
            } else "query";

            try output_writer.print("{{\"tag\":\"{s}\",\"results\":[", .{first_tag_name});
            for (output_paths.items, 0..) |path, idx| {
                if (idx > 0) try output_writer.writeAll(",");
                try output_writer.print("\"{s}\"", .{path});
            }
            try output_writer.writeAll("]}\n");
        },
    }

    const output = output_buffer.items;

    // Write to stdout
    try stdout.writeAll(output);

    // Copy to clipboard if requested
    if (copy_to_clipboard) {
        clipboard.copy(allocator, output) catch {
            try stderr.writeAll("warning: failed to copy to clipboard\n");
        };
    }

    return 0;
}

// ============================================================================
// Tests
// ============================================================================

test "query command module compiles" {
    _ = run;
    _ = runTagQuery;
}
