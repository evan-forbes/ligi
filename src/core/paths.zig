//! Path resolution logic for ligi directories.

const std = @import("std");
const errors = @import("errors.zig");

/// Special directories that exist under art/
pub const SPECIAL_DIRS = [_][]const u8{ "index", "template", "config", "archive", "inbox" };

/// Get the global ligi root directory (~/.ligi)
pub fn getGlobalRoot(allocator: std.mem.Allocator) errors.Result([]const u8) {
    const home = std.posix.getenv("HOME") orelse {
        return .{ .err = errors.LigiError.filesystem(
            "$HOME environment variable not set",
            null,
        ) };
    };
    const path = std.fs.path.join(allocator, &.{ home, ".ligi" }) catch {
        return .{ .err = errors.LigiError.filesystem(
            "failed to join path",
            null,
        ) };
    };
    return .{ .ok = path };
}

/// Get the global art directory (~/.ligi/art)
pub fn getGlobalArtPath(allocator: std.mem.Allocator) errors.Result([]const u8) {
    const root = switch (getGlobalRoot(allocator)) {
        .ok => |r| r,
        .err => |e| return .{ .err = e },
    };
    defer allocator.free(root);

    const path = std.fs.path.join(allocator, &.{ root, "art" }) catch {
        return .{ .err = errors.LigiError.filesystem(
            "failed to join path",
            null,
        ) };
    };
    return .{ .ok = path };
}

/// Get the global config directory (~/.ligi/config)
pub fn getGlobalConfigPath(allocator: std.mem.Allocator) errors.Result([]const u8) {
    const root = switch (getGlobalRoot(allocator)) {
        .ok => |r| r,
        .err => |e| return .{ .err = e },
    };
    defer allocator.free(root);

    const path = std.fs.path.join(allocator, &.{ root, "config" }) catch {
        return .{ .err = errors.LigiError.filesystem(
            "failed to join path",
            null,
        ) };
    };
    return .{ .ok = path };
}

/// Get local art path relative to a root directory
pub fn getLocalArtPath(allocator: std.mem.Allocator, root: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ root, "art" });
}

/// Join multiple path segments
pub fn joinPath(allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    return std.fs.path.join(allocator, parts);
}

// ============================================================================
// Tests
// ============================================================================

test "getGlobalRoot returns ~/.ligi when HOME is set" {
    // This test uses the actual HOME environment variable
    const allocator = std.testing.allocator;
    const home = std.posix.getenv("HOME") orelse {
        // Skip test if HOME is not set
        return;
    };

    const result = getGlobalRoot(allocator);
    try std.testing.expect(result.isOk());

    const path = result.ok;
    defer allocator.free(path);

    const expected = try std.fs.path.join(allocator, &.{ home, ".ligi" });
    defer allocator.free(expected);

    try std.testing.expectEqualStrings(expected, path);
}

test "getGlobalArtPath returns ~/.ligi/art" {
    const allocator = std.testing.allocator;
    const home = std.posix.getenv("HOME") orelse return;

    const result = getGlobalArtPath(allocator);
    try std.testing.expect(result.isOk());

    const path = result.ok;
    defer allocator.free(path);

    const expected = try std.fs.path.join(allocator, &.{ home, ".ligi", "art" });
    defer allocator.free(expected);

    try std.testing.expectEqualStrings(expected, path);
}

test "getGlobalConfigPath returns ~/.ligi/config" {
    const allocator = std.testing.allocator;
    const home = std.posix.getenv("HOME") orelse return;

    const result = getGlobalConfigPath(allocator);
    try std.testing.expect(result.isOk());

    const path = result.ok;
    defer allocator.free(path);

    const expected = try std.fs.path.join(allocator, &.{ home, ".ligi", "config" });
    defer allocator.free(expected);

    try std.testing.expectEqualStrings(expected, path);
}

test "getLocalArtPath joins root with art/" {
    const allocator = std.testing.allocator;
    const path = try getLocalArtPath(allocator, "/some/project");
    defer allocator.free(path);

    try std.testing.expectEqualStrings("/some/project/art", path);
}

test "SPECIAL_DIRS contains correct directories" {
    try std.testing.expectEqual(@as(usize, 5), SPECIAL_DIRS.len);
    try std.testing.expectEqualStrings("index", SPECIAL_DIRS[0]);
    try std.testing.expectEqualStrings("template", SPECIAL_DIRS[1]);
    try std.testing.expectEqualStrings("config", SPECIAL_DIRS[2]);
    try std.testing.expectEqualStrings("archive", SPECIAL_DIRS[3]);
    try std.testing.expectEqualStrings("inbox", SPECIAL_DIRS[4]);
}

test "joinPath handles multiple segments" {
    const allocator = std.testing.allocator;
    const path = try joinPath(allocator, &.{ "/home", "user", ".ligi", "art" });
    defer allocator.free(path);

    try std.testing.expectEqualStrings("/home/user/.ligi/art", path);
}

test "joinPath handles single segment" {
    const allocator = std.testing.allocator;
    const path = try joinPath(allocator, &.{"single"});
    defer allocator.free(path);

    try std.testing.expectEqualStrings("single", path);
}
