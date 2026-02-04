//! Path resolution logic for ligi directories.

const std = @import("std");
const errors = @import("errors.zig");

/// Special directories that exist under art/
pub const SPECIAL_DIRS = [_][]const u8{ "index", "template", "config", "archive", "inbox", "calendar", "notes", "plan" };

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

/// Find a template by name, searching through the provided paths in order.
/// Returns the full path to the template if found, null otherwise.
pub fn findTemplate(allocator: std.mem.Allocator, template_paths: []const []const u8, template_name: []const u8) ?[]const u8 {
    for (template_paths) |template_dir| {
        const full_path = std.fs.path.join(allocator, &.{ template_dir, template_name }) catch continue;

        // Check if file exists
        if (fileExists(full_path)) {
            return full_path;
        }
        allocator.free(full_path);
    }
    return null;
}

/// Check if a file exists (helper function)
fn fileExists(path: []const u8) bool {
    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}

/// Result of template resolution
pub const TemplateResolution = struct {
    /// Full path to the template file
    path: []const u8,
    /// Which level the template came from
    source: TemplateSource,
};

pub const TemplateSource = enum {
    repo,
    org,
    global,
    builtin,
};

/// Find a template and return information about where it came from.
/// template_paths should be in order: [repo, org, global]
pub fn findTemplateWithSource(
    allocator: std.mem.Allocator,
    template_paths: []const []const u8,
    template_name: []const u8,
) ?TemplateResolution {
    for (template_paths, 0..) |template_dir, i| {
        const full_path = std.fs.path.join(allocator, &.{ template_dir, template_name }) catch continue;

        if (fileExists(full_path)) {
            const source: TemplateSource = switch (i) {
                0 => .repo,
                1 => .org,
                2 => .global,
                else => .global,
            };
            return .{
                .path = full_path,
                .source = source,
            };
        }
        allocator.free(full_path);
    }
    return null;
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
    try std.testing.expectEqual(@as(usize, 8), SPECIAL_DIRS.len);
    try std.testing.expectEqualStrings("index", SPECIAL_DIRS[0]);
    try std.testing.expectEqualStrings("template", SPECIAL_DIRS[1]);
    try std.testing.expectEqualStrings("config", SPECIAL_DIRS[2]);
    try std.testing.expectEqualStrings("archive", SPECIAL_DIRS[3]);
    try std.testing.expectEqualStrings("inbox", SPECIAL_DIRS[4]);
    try std.testing.expectEqualStrings("calendar", SPECIAL_DIRS[5]);
    try std.testing.expectEqualStrings("notes", SPECIAL_DIRS[6]);
    try std.testing.expectEqualStrings("plan", SPECIAL_DIRS[7]);
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
