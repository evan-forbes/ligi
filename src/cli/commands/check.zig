//! The `ligi check` command implementation.
//!
//! Validates global index entries and reports broken paths.

const std = @import("std");
const core = @import("../../core/mod.zig");
const paths = core.paths;
const fs = core.fs;
const global_index = core.global_index;

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

/// Run the check command
pub fn run(
    allocator: std.mem.Allocator,
    output_format: OutputFormat,
    root_filter: ?[]const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    _ = root_filter; // TODO: implement root filtering

    // Load global index
    var index = switch (global_index.loadGlobalIndex(allocator)) {
        .ok => |i| i,
        .err => |e| {
            try e.write(stderr);
            return e.exitCode();
        },
    };
    defer index.deinit();

    if (index.repos.items.len == 0) {
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

    // Output results
    switch (output_format) {
        .text => try outputText(results.items, stdout),
        .json => try outputJson(allocator, results.items, stdout),
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
fn outputJson(allocator: std.mem.Allocator, results: []const CheckResult, writer: anytype) !void {
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

    try writer.writeAll("]}\n");
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

    try outputJson(allocator, &results, stream.writer());
    const output = stream.getWritten();

    try std.testing.expect(std.mem.startsWith(u8, output, "{\"results\":["));
    try std.testing.expect(std.mem.indexOf(u8, output, "\"path\":\"/path/to/repo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"status\":\"OK\"") != null);
}
