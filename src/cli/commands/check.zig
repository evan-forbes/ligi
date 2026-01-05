//! The `ligi check` command implementation.
//!
//! Validates global index entries and reports broken paths.

const std = @import("std");
const core = @import("../../core/mod.zig");
const paths = core.paths;
const fs = core.fs;
const global_index = core.global_index;
const tag_index = core.tag_index;

/// Status of a repo check
pub const RepoStatus = enum {
    ok,
    broken,
    missing_art,

    pub fn toString(self: RepoStatus) []const u8 {
        return switch (self) {
            .ok => "OK",
            .broken => "BROKEN",
            .missing_art => "MISSING_ART",
        };
    }
};

/// Result of checking a single repo
pub const CheckResult = struct {
    path: []const u8,
    status: RepoStatus,
};

/// Summary of pruning actions
pub const PruneSummary = struct {
    pruned_repos: usize = 0,
    pruned_local_tag_entries: usize = 0,
    pruned_global_tag_entries: usize = 0,
    pruned_tags: usize = 0,
};

/// Run the check command
pub fn run(
    allocator: std.mem.Allocator,
    output_format: OutputFormat,
    root_filter: ?[]const u8,
    prune: bool,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    // Load global index
    var index = switch (global_index.loadGlobalIndex(allocator)) {
        .ok => |i| i,
        .err => |e| {
            try e.write(stderr);
            return e.exitCode();
        },
    };
    defer index.deinit();

    if (index.repos.items.len == 0 and root_filter == null and !prune) {
        if (output_format == .json) {
            try stdout.writeAll("{\"results\":[]}\n");
        } else {
            try stdout.writeAll("No repositories registered in global index.\n");
        }
        return 0;
    }

    // Check each repo
    var results: std.ArrayList(CheckResult) = .empty;
    defer results.deinit(allocator);

    var has_errors = false;
    var filter_path: ?[]const u8 = null;
    defer if (filter_path) |path| allocator.free(path);

    if (root_filter) |root| {
        const resolved = if (global_index.canonicalizePath(allocator, root)) |path|
            path
        else |_|
            try allocator.dupe(u8, root);
        filter_path = resolved;
        const status = checkRepo(filter_path.?);
        if (status != .ok) {
            has_errors = true;
        }
        try results.append(allocator, .{
            .path = filter_path.?,
            .status = status,
        });
    } else {
        for (index.repos.items) |repo_path| {
            const status = checkRepo(repo_path);
            if (status != .ok) {
                has_errors = true;
            }
            try results.append(allocator, .{
                .path = repo_path,
                .status = status,
            });
        }
    }

    // Output results
    var summary: ?PruneSummary = null;

    if (prune) {
        // Prune global index entries
        const pruned_repos = global_index.pruneIndexEntries(&index);
        if (pruned_repos > 0) {
            switch (global_index.saveGlobalIndex(allocator, &index)) {
                .ok => {},
                .err => |e| {
                    try e.write(stderr);
                    return e.exitCode();
                },
            }
        }

        var pruned_local_entries: usize = 0;
        var pruned_tags: usize = 0;

        if (root_filter) |root| {
            const repo_path = filter_path orelse root;
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            local_prune: {
                const art_path = std.fmt.bufPrint(&path_buf, "{s}/art", .{repo_path}) catch break :local_prune;
                if (fs.dirExists(art_path)) {
                    const local_result = try tag_index.pruneLocalTagIndexes(allocator, art_path, stderr);
                    pruned_local_entries += local_result.pruned_entries;
                    pruned_tags += local_result.pruned_tags;
                }
            }
        } else {
            for (index.repos.items) |repo_path| {
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const art_path = std.fmt.bufPrint(&path_buf, "{s}/art", .{repo_path}) catch {
                    continue;
                };
                if (fs.dirExists(art_path)) {
                    const local_result = try tag_index.pruneLocalTagIndexes(allocator, art_path, stderr);
                    pruned_local_entries += local_result.pruned_entries;
                    pruned_tags += local_result.pruned_tags;
                }
            }
        }

        const global_art = switch (paths.getGlobalArtPath(allocator)) {
            .ok => |p| p,
            .err => |e| {
                try e.write(stderr);
                return e.exitCode();
            },
        };
        defer allocator.free(global_art);

        const global_result = try tag_index.pruneGlobalTagIndexes(
            allocator,
            global_art,
            index.repos.items,
            stderr,
        );

        pruned_tags += global_result.pruned_tags;

        summary = .{
            .pruned_repos = pruned_repos,
            .pruned_local_tag_entries = pruned_local_entries,
            .pruned_global_tag_entries = global_result.pruned_entries,
            .pruned_tags = pruned_tags,
        };
    }

    switch (output_format) {
        .text => {
            try outputText(results.items, stdout);
            if (summary) |s| {
                try stdout.print("pruned repos: {d}\n", .{s.pruned_repos});
                try stdout.print("pruned local tag entries: {d}\n", .{s.pruned_local_tag_entries});
                try stdout.print("pruned global tag entries: {d}\n", .{s.pruned_global_tag_entries});
                try stdout.print("pruned tags: {d}\n", .{s.pruned_tags});
            }
        },
        .json => try outputJson(allocator, results.items, summary, stdout),
    }

    if (prune) {
        return 0;
    }
    return if (has_errors) 1 else 0;
}

/// Check a single repo's status
fn checkRepo(repo_path: []const u8) RepoStatus {
    // Check if repo root exists
    if (!fs.dirExists(repo_path)) {
        return .broken;
    }

    // Check if art/ directory exists
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const art_path = std.fmt.bufPrint(&path_buf, "{s}/art", .{repo_path}) catch {
        return .broken;
    };

    if (!fs.dirExists(art_path)) {
        return .missing_art;
    }

    return .ok;
}

/// Output format options
pub const OutputFormat = enum {
    text,
    json,
};

/// Output results as text
fn outputText(results: []const CheckResult, writer: anytype) !void {
    // Group by status for pretty output
    for (results) |result| {
        try writer.print("{s:<12} {s}\n", .{ result.status.toString(), result.path });
    }
}

/// Output results as JSON
fn outputJson(
    allocator: std.mem.Allocator,
    results: []const CheckResult,
    summary: ?PruneSummary,
    writer: anytype,
) !void {
    try writer.writeAll("{\"results\":[");

    for (results, 0..) |result, i| {
        if (i > 0) {
            try writer.writeAll(",");
        }

        // Escape the path for JSON
        var escaped: std.ArrayList(u8) = .empty;
        defer escaped.deinit(allocator);

        for (result.path) |c| {
            switch (c) {
                '"' => try escaped.appendSlice(allocator, "\\\""),
                '\\' => try escaped.appendSlice(allocator, "\\\\"),
                '\n' => try escaped.appendSlice(allocator, "\\n"),
                '\r' => try escaped.appendSlice(allocator, "\\r"),
                '\t' => try escaped.appendSlice(allocator, "\\t"),
                else => try escaped.append(allocator, c),
            }
        }

        try writer.print("{{\"path\":\"{s}\",\"status\":\"{s}\"}}", .{
            escaped.items,
            result.status.toString(),
        });
    }

    try writer.writeAll("]");
    if (summary) |s| {
        try writer.print(
            ",\"prune_summary\":{{\"pruned_repos\":{d},\"pruned_local_tag_entries\":{d},\"pruned_global_tag_entries\":{d},\"pruned_tags\":{d}}}",
            .{
                s.pruned_repos,
                s.pruned_local_tag_entries,
                s.pruned_global_tag_entries,
                s.pruned_tags,
            },
        );
    }
    try writer.writeAll("}\n");
}

// ============================================================================
// Tests
// ============================================================================

test "RepoStatus.toString returns correct strings" {
    try std.testing.expectEqualStrings("OK", RepoStatus.ok.toString());
    try std.testing.expectEqualStrings("BROKEN", RepoStatus.broken.toString());
    try std.testing.expectEqualStrings("MISSING_ART", RepoStatus.missing_art.toString());
}

test "checkRepo returns broken for non-existent path" {
    const status = checkRepo("/definitely/does/not/exist/abc123xyz");
    try std.testing.expectEqual(RepoStatus.broken, status);
}

test "outputText formats correctly" {
    const allocator = std.testing.allocator;
    _ = allocator;

    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    const results = [_]CheckResult{
        .{ .path = "/path/to/repo", .status = .ok },
        .{ .path = "/broken/repo", .status = .broken },
    };

    try outputText(&results, stream.writer());
    const output = stream.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "BROKEN") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "/path/to/repo") != null);
}

test "outputJson produces valid JSON structure" {
    const allocator = std.testing.allocator;

    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    const results = [_]CheckResult{
        .{ .path = "/path/to/repo", .status = .ok },
    };

    try outputJson(allocator, &results, null, stream.writer());
    const output = stream.getWritten();

    try std.testing.expect(std.mem.startsWith(u8, output, "{\"results\":["));
    try std.testing.expect(std.mem.indexOf(u8, output, "\"path\":\"/path/to/repo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"status\":\"OK\"") != null);
}

test "checkRepo returns ok for valid repo with art directory" {
    const allocator = std.testing.allocator;
    const fixtures = @import("../../testing/fixtures.zig");

    var tmp = try fixtures.TempDir.create(allocator);
    defer tmp.cleanup();

    // Create repo with art/
    try tmp.dir().makePath("repo/art");

    const repo_path = try std.fs.path.join(allocator, &.{ tmp.path, "repo" });
    defer allocator.free(repo_path);

    const status = checkRepo(repo_path);
    try std.testing.expectEqual(RepoStatus.ok, status);
}

test "checkRepo returns missing_art for repo without art directory" {
    const allocator = std.testing.allocator;
    const fixtures = @import("../../testing/fixtures.zig");

    var tmp = try fixtures.TempDir.create(allocator);
    defer tmp.cleanup();

    // Create repo without art/
    try tmp.dir().makePath("repo");

    const repo_path = try std.fs.path.join(allocator, &.{ tmp.path, "repo" });
    defer allocator.free(repo_path);

    const status = checkRepo(repo_path);
    try std.testing.expectEqual(RepoStatus.missing_art, status);
}

test "checkRepo returns broken for dangling symlink" {
    // This test documents the expected behavior: dangling symlinks are treated as broken
    const allocator = std.testing.allocator;
    const fixtures = @import("../../testing/fixtures.zig");

    var tmp = try fixtures.TempDir.create(allocator);
    defer tmp.cleanup();

    // Create a dangling symlink
    const symlink_path = try std.fs.path.join(allocator, &.{ tmp.path, "dangling_link" });
    defer allocator.free(symlink_path);

    // Try to create symlink pointing to non-existent target
    tmp.dir().symLink("/nonexistent/target", "dangling_link", .{}) catch |err| {
        // Skip test if symlinks not supported (e.g., some Windows configs)
        if (err == error.AccessDenied) return;
        return err;
    };

    const status = checkRepo(symlink_path);
    try std.testing.expectEqual(RepoStatus.broken, status);
}
