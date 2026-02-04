//! Structured JSONL logging for ligi operations.
//!
//! Appends JSON lines to `art/.ligi_log.jsonl` for audit and debugging.
//! Each entry records a command invocation with timing and result metadata.

const std = @import("std");
const fs = @import("fs.zig");

pub const LogEntry = struct {
    timestamp: i64,
    command: []const u8,
    action: []const u8,
    detail: ?[]const u8 = null,
    count: ?usize = null,
    duration_ms: ?i64 = null,
};

/// Append a structured log entry to art/.ligi_log.jsonl.
/// Errors are silently ignored (logging should never block operations).
pub fn log(allocator: std.mem.Allocator, art_path: []const u8, entry: LogEntry) void {
    const log_path = std.fs.path.join(allocator, &.{ art_path, ".ligi_log.jsonl" }) catch return;
    defer allocator.free(log_path);

    // Build JSON line
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    writer.print("{{\"ts\":{d},\"cmd\":\"{s}\",\"act\":\"{s}\"", .{
        entry.timestamp,
        entry.command,
        entry.action,
    }) catch return;

    if (entry.detail) |d| {
        writer.print(",\"detail\":\"{s}\"", .{d}) catch return;
    }
    if (entry.count) |c| {
        writer.print(",\"count\":{d}", .{c}) catch return;
    }
    if (entry.duration_ms) |ms| {
        writer.print(",\"ms\":{d}", .{ms}) catch return;
    }
    writer.writeAll("}\n") catch return;

    // Append to log file
    const file = std.fs.cwd().openFile(log_path, .{ .mode = .write_only }) catch |err| {
        if (err == error.FileNotFound) {
            // Create the file
            const new_file = std.fs.cwd().createFile(log_path, .{}) catch return;
            defer new_file.close();
            new_file.writeAll(buf.items) catch return;
            return;
        }
        return;
    };
    defer file.close();
    file.seekFromEnd(0) catch return;
    file.writeAll(buf.items) catch return;
}

/// Get current unix timestamp in seconds.
pub fn now() i64 {
    return std.time.timestamp();
}

// ============================================================================
// Tests
// ============================================================================

test "log entry format" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    log(allocator, tmp_path, .{
        .timestamp = 1706918400,
        .command = "index",
        .action = "complete",
        .count = 42,
        .duration_ms = 150,
    });

    const log_path = try std.fs.path.join(allocator, &.{ tmp_path, ".ligi_log.jsonl" });
    defer allocator.free(log_path);

    const content = try std.fs.cwd().readFileAlloc(allocator, log_path, 4096);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "\"cmd\":\"index\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"count\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"ms\":150") != null);
}

test "log handles missing directory gracefully" {
    const allocator = std.testing.allocator;

    // Should not crash when path doesn't exist
    log(allocator, "/nonexistent/path", .{
        .timestamp = 0,
        .command = "test",
        .action = "noop",
    });
}
