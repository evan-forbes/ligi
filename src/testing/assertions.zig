//! Custom test assertions.

const std = @import("std");

/// Assert that a directory exists
pub fn assertDirExists(dir: std.fs.Dir, path: []const u8) !void {
    var d = dir.openDir(path, .{}) catch |err| {
        std.debug.print("Expected directory to exist: {s}, got error: {}\n", .{ path, err });
        return error.DirectoryNotFound;
    };
    d.close();
}

/// Assert that a file exists
pub fn assertFileExists(dir: std.fs.Dir, path: []const u8) !void {
    const file = dir.openFile(path, .{}) catch |err| {
        std.debug.print("Expected file to exist: {s}, got error: {}\n", .{ path, err });
        return error.FileNotFound;
    };
    file.close();
}

/// Assert that a file contains expected content
pub fn assertFileContains(allocator: std.mem.Allocator, dir: std.fs.Dir, path: []const u8, expected: []const u8) !void {
    const file = try dir.openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    if (std.mem.indexOf(u8, content, expected) == null) {
        std.debug.print("File {s} does not contain: {s}\n", .{ path, expected });
        return error.ContentNotFound;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "assertDirExists passes for existing directory" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("test_subdir");
    try assertDirExists(tmp_dir.dir, "test_subdir");
}

test "assertFileExists passes for existing file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("test_file.txt", .{});
    file.close();

    try assertFileExists(tmp_dir.dir, "test_file.txt");
}

test "assertFileContains passes when content exists" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("test.txt", .{});
    try file.writeAll("hello world");
    file.close();

    try assertFileContains(allocator, tmp_dir.dir, "test.txt", "hello");
    try assertFileContains(allocator, tmp_dir.dir, "test.txt", "world");
}
