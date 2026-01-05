//! Path safety utilities for the serve module.
//!
//! Provides path normalization and validation to prevent directory traversal
//! attacks and ensure all served files are within the allowed root directory.

const std = @import("std");

/// Errors that can occur during path validation
pub const PathError = error{
    /// Path contains directory traversal attempt (..)
    TraversalAttempt,
    /// Path is absolute (starts with / or drive letter)
    AbsolutePath,
    /// Path contains null bytes
    NullByte,
    /// Path is empty
    EmptyPath,
    /// Path escapes root directory after normalization
    EscapesRoot,
};

/// Allowed file extensions for serving
pub const AllowedExtension = enum {
    markdown,
    image,

    pub fn fromPath(path: []const u8) ?AllowedExtension {
        const ext = std.fs.path.extension(path);
        if (ext.len == 0) return null;

        // Markdown files
        if (std.mem.eql(u8, ext, ".md") or std.mem.eql(u8, ext, ".markdown")) {
            return .markdown;
        }

        // Image files
        if (std.mem.eql(u8, ext, ".png") or
            std.mem.eql(u8, ext, ".jpg") or
            std.mem.eql(u8, ext, ".jpeg") or
            std.mem.eql(u8, ext, ".gif") or
            std.mem.eql(u8, ext, ".svg") or
            std.mem.eql(u8, ext, ".webp"))
        {
            return .image;
        }

        return null;
    }
};

/// Validates and normalizes a relative path for safe serving.
///
/// Returns the normalized path if valid, or an error if the path
/// is unsafe (contains traversal, is absolute, etc.).
pub fn validatePath(path: []const u8) PathError![]const u8 {
    if (path.len == 0) {
        return PathError.EmptyPath;
    }

    // Check for null bytes
    if (std.mem.indexOfScalar(u8, path, 0) != null) {
        return PathError.NullByte;
    }

    // Check for absolute paths
    if (path[0] == '/' or path[0] == '\\') {
        return PathError.AbsolutePath;
    }

    // Check for Windows drive letters (e.g., C:)
    if (path.len >= 2 and path[1] == ':') {
        return PathError.AbsolutePath;
    }

    // Check each component for traversal
    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |component| {
        // Also check for backslash-separated paths
        var inner = std.mem.splitScalar(u8, component, '\\');
        while (inner.next()) |inner_component| {
            if (std.mem.eql(u8, inner_component, "..")) {
                return PathError.TraversalAttempt;
            }
        }
    }

    return path;
}

/// Joins the root directory with a relative path safely.
/// Returns null if the path would escape the root or is invalid.
pub fn joinSafePath(
    allocator: std.mem.Allocator,
    root: []const u8,
    relative: []const u8,
) ?[]const u8 {
    // Validate the relative path first
    const validated = validatePath(relative) catch return null;

    // Join the paths
    const joined = std.fs.path.join(allocator, &.{ root, validated }) catch return null;

    return joined;
}

/// Checks if a path has an allowed extension for serving
pub fn hasAllowedExtension(path: []const u8) bool {
    return AllowedExtension.fromPath(path) != null;
}

/// Checks if a directory should be skipped during listing
pub fn shouldSkipDir(name: []const u8) bool {
    // Skip hidden directories
    if (name.len > 0 and name[0] == '.') {
        return true;
    }

    // Skip common build/cache directories
    const skip_list = [_][]const u8{
        "node_modules",
        "zig-cache",
        "zig-out",
        "__pycache__",
        "target",
        "build",
        "dist",
    };

    for (skip_list) |skip| {
        if (std.mem.eql(u8, name, skip)) {
            return true;
        }
    }

    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "validatePath accepts simple paths" {
    const result = try validatePath("file.md");
    try std.testing.expectEqualStrings("file.md", result);
}

test "validatePath accepts nested paths" {
    const result = try validatePath("dir/subdir/file.md");
    try std.testing.expectEqualStrings("dir/subdir/file.md", result);
}

test "validatePath rejects traversal" {
    try std.testing.expectError(PathError.TraversalAttempt, validatePath("../file.md"));
    try std.testing.expectError(PathError.TraversalAttempt, validatePath("dir/../file.md"));
    try std.testing.expectError(PathError.TraversalAttempt, validatePath("dir/.."));
}

test "validatePath rejects absolute paths" {
    try std.testing.expectError(PathError.AbsolutePath, validatePath("/etc/passwd"));
    try std.testing.expectError(PathError.AbsolutePath, validatePath("\\Windows\\System32"));
}

test "validatePath rejects Windows drive paths" {
    try std.testing.expectError(PathError.AbsolutePath, validatePath("C:\\Windows"));
    try std.testing.expectError(PathError.AbsolutePath, validatePath("D:file.md"));
}

test "validatePath rejects empty paths" {
    try std.testing.expectError(PathError.EmptyPath, validatePath(""));
}

test "validatePath rejects null bytes" {
    try std.testing.expectError(PathError.NullByte, validatePath("file\x00.md"));
}

test "hasAllowedExtension works for markdown" {
    try std.testing.expect(hasAllowedExtension("file.md"));
    try std.testing.expect(hasAllowedExtension("file.markdown"));
    try std.testing.expect(hasAllowedExtension("dir/file.md"));
}

test "hasAllowedExtension works for images" {
    try std.testing.expect(hasAllowedExtension("image.png"));
    try std.testing.expect(hasAllowedExtension("image.jpg"));
    try std.testing.expect(hasAllowedExtension("image.jpeg"));
    try std.testing.expect(hasAllowedExtension("image.gif"));
    try std.testing.expect(hasAllowedExtension("image.svg"));
    try std.testing.expect(hasAllowedExtension("image.webp"));
}

test "hasAllowedExtension rejects other extensions" {
    try std.testing.expect(!hasAllowedExtension("file.txt"));
    try std.testing.expect(!hasAllowedExtension("file.js"));
    try std.testing.expect(!hasAllowedExtension("file.html"));
    try std.testing.expect(!hasAllowedExtension("file"));
}

test "shouldSkipDir skips hidden directories" {
    try std.testing.expect(shouldSkipDir(".git"));
    try std.testing.expect(shouldSkipDir(".hidden"));
}

test "shouldSkipDir skips common build directories" {
    try std.testing.expect(shouldSkipDir("node_modules"));
    try std.testing.expect(shouldSkipDir("zig-cache"));
    try std.testing.expect(shouldSkipDir("zig-out"));
}

test "shouldSkipDir allows normal directories" {
    try std.testing.expect(!shouldSkipDir("docs"));
    try std.testing.expect(!shouldSkipDir("src"));
    try std.testing.expect(!shouldSkipDir("art"));
}

test "AllowedExtension.fromPath returns correct types" {
    try std.testing.expectEqual(AllowedExtension.markdown, AllowedExtension.fromPath("file.md").?);
    try std.testing.expectEqual(AllowedExtension.image, AllowedExtension.fromPath("file.png").?);
    try std.testing.expect(AllowedExtension.fromPath("file.txt") == null);
}
