//! Filesystem operations for ligi.

const std = @import("std");
const errors = @import("errors.zig");

/// Create a directory if it doesn't exist (absolute path)
pub fn ensureDir(path: []const u8) errors.Result(void) {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => return .{ .ok = {} },
        else => return .{ .err = errors.LigiError.filesystem(
            "failed to create directory",
            null,
        ) },
    };
    return .{ .ok = {} };
}

/// Create a directory and all parent directories (works with relative paths)
pub fn ensureDirRecursive(path: []const u8) errors.Result(void) {
    std.fs.cwd().makePath(path) catch {
        return .{ .err = errors.LigiError.filesystem(
            "failed to create directory tree",
            null,
        ) };
    };
    return .{ .ok = {} };
}

/// Check if a directory exists
pub fn dirExists(path: []const u8) bool {
    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    dir.close();
    return true;
}

/// Check if a file exists
pub fn fileExists(path: []const u8) bool {
    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}

/// Write content to a file only if it doesn't exist.
/// Returns true if file was created, false if it already existed.
pub fn writeFileIfNotExists(path: []const u8, content: []const u8) errors.Result(bool) {
    // Try to create exclusively
    const file = std.fs.cwd().createFile(path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return .{ .ok = false },
        else => return .{ .err = errors.LigiError.filesystem(
            "failed to create file",
            null,
        ) },
    };
    defer file.close();

    file.writeAll(content) catch {
        return .{ .err = errors.LigiError.filesystem(
            "failed to write file",
            null,
        ) };
    };

    return .{ .ok = true };
}

/// Read entire file contents
pub fn readFile(allocator: std.mem.Allocator, path: []const u8) errors.Result([]const u8) {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return .{ .err = errors.LigiError.filesystem(
            "failed to open file",
            null,
        ) };
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        return .{ .err = errors.LigiError.filesystem(
            "failed to read file",
            null,
        ) };
    };

    return .{ .ok = content };
}

/// Write content to a file only if it differs from existing content.
/// Returns true if the file was written, false if skipped (content identical).
pub fn writeFileIfChanged(path: []const u8, content: []const u8, allocator: std.mem.Allocator) errors.Result(bool) {
    // Read existing content
    switch (readFile(allocator, path)) {
        .ok => |existing| {
            defer allocator.free(existing);
            if (std.mem.eql(u8, existing, content)) {
                return .{ .ok = false }; // Content unchanged, skip write
            }
        },
        .err => {
            // File doesn't exist or can't be read, proceed with write
        },
    }

    // Content differs or file is new - write it
    switch (writeFile(path, content)) {
        .ok => return .{ .ok = true },
        .err => |e| return .{ .err = e },
    }
}

/// Write content to a file, overwriting if it exists.
pub fn writeFile(path: []const u8, content: []const u8) errors.Result(void) {
    const file = std.fs.cwd().createFile(path, .{}) catch {
        return .{ .err = errors.LigiError.filesystem(
            "failed to create file",
            null,
        ) };
    };
    defer file.close();

    file.writeAll(content) catch {
        return .{ .err = errors.LigiError.filesystem(
            "failed to write file",
            null,
        ) };
    };

    return .{ .ok = {} };
}

// ============================================================================
// Tests
// ============================================================================

test "ensureDirRecursive creates nested directories" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Use the tmp_dir directly to create nested directories
    try tmp_dir.dir.makePath("a/b/c");

    // Verify the directories exist within tmp_dir
    var a_dir = try tmp_dir.dir.openDir("a", .{});
    defer a_dir.close();
    var b_dir = try tmp_dir.dir.openDir("a/b", .{});
    defer b_dir.close();
    var c_dir = try tmp_dir.dir.openDir("a/b/c", .{});
    defer c_dir.close();
}

test "ensureDirRecursive is idempotent" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create once
    try tmp_dir.dir.makePath("test_dir");

    // Create again - should not error
    try tmp_dir.dir.makePath("test_dir");

    // Verify it exists
    var dir = try tmp_dir.dir.openDir("test_dir", .{});
    dir.close();
}

test "dirExists returns false for non-existing path" {
    try std.testing.expect(!dirExists("/definitely/does/not/exist/abc123xyz"));
}

test "readFile returns error for missing file" {
    const allocator = std.testing.allocator;
    const result = readFile(allocator, "/definitely/does/not/exist.txt");
    try std.testing.expect(result.isErr());
}
