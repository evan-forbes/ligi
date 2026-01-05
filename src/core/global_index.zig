//! Global index management for tracking all ligi-initialized repositories.
//!
//! The global index lives at ~/.ligi/art/index/ligi_global_index.md and stores
//! absolute paths to all repos initialized with ligi.

const std = @import("std");
const errors = @import("errors.zig");
const paths = @import("paths.zig");
const fs = @import("fs.zig");

/// Initial content for a new global index file
pub const INITIAL_GLOBAL_INDEX =
    \\# Ligi Global Index
    \\
    \\This file is auto-maintained by ligi. It tracks all repositories initialized with ligi.
    \\
    \\## Repositories
    \\
    \\## Notes
    \\
    \\(Freeform, not parsed by ligi)
    \\
;

/// Parsed global index data
pub const GlobalIndex = struct {
    /// List of absolute repo root paths
    repos: std.ArrayList([]const u8) = .empty,
    /// Content of the Notes section (preserved verbatim)
    notes_content: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GlobalIndex {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GlobalIndex) void {
        for (self.repos.items) |path| {
            self.allocator.free(path);
        }
        self.repos.deinit(self.allocator);
        if (self.notes_content) |notes| {
            self.allocator.free(notes);
        }
    }

    /// Check if a repo path is already in the index
    pub fn contains(self: *const GlobalIndex, path: []const u8) bool {
        for (self.repos.items) |existing| {
            if (std.mem.eql(u8, existing, path)) {
                return true;
            }
        }
        return false;
    }

    /// Add a repo path if not already present
    pub fn addRepo(self: *GlobalIndex, path: []const u8) !bool {
        if (self.contains(path)) {
            return false;
        }
        const path_copy = try self.allocator.dupe(u8, path);
        try self.repos.append(self.allocator, path_copy);
        return true;
    }

    /// Render the index to markdown format
    pub fn render(self: *const GlobalIndex, allocator: std.mem.Allocator) ![]const u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        const writer = output.writer(allocator);

        // Header
        try writer.writeAll("# Ligi Global Index\n\n");
        try writer.writeAll("This file is auto-maintained by ligi. It tracks all repositories initialized with ligi.\n\n");
        try writer.writeAll("## Repositories\n\n");

        // Sort paths lexicographically
        const sorted_repos = try allocator.alloc([]const u8, self.repos.items.len);
        defer allocator.free(sorted_repos);
        @memcpy(sorted_repos, self.repos.items);
        std.mem.sort([]const u8, sorted_repos, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        // Write sorted repo list
        for (sorted_repos) |path| {
            try writer.print("- {s}\n", .{path});
        }

        // Notes section
        try writer.writeAll("\n## Notes\n\n");
        if (self.notes_content) |notes| {
            try writer.writeAll(notes);
        } else {
            try writer.writeAll("(Freeform, not parsed by ligi)\n");
        }

        return output.toOwnedSlice(allocator);
    }
};

/// Remove broken repo entries from a GlobalIndex in-place.
/// Returns the number of entries removed.
pub fn pruneIndexEntries(index: *GlobalIndex) usize {
    var pruned: usize = 0;
    var idx: usize = 0;

    while (idx < index.repos.items.len) {
        const repo_path = index.repos.items[idx];
        if (!fs.dirExists(repo_path)) {
            index.allocator.free(repo_path);
            _ = index.repos.orderedRemove(idx);
            pruned += 1;
            continue;
        }

        const art_path = std.fs.path.join(index.allocator, &.{ repo_path, "art" }) catch {
            index.allocator.free(repo_path);
            _ = index.repos.orderedRemove(idx);
            pruned += 1;
            continue;
        };
        defer index.allocator.free(art_path);

        if (!fs.dirExists(art_path)) {
            index.allocator.free(repo_path);
            _ = index.repos.orderedRemove(idx);
            pruned += 1;
            continue;
        }

        idx += 1;
    }

    return pruned;
}

/// Parse a global index file from its content
pub fn parseGlobalIndex(allocator: std.mem.Allocator, content: []const u8) !GlobalIndex {
    var index = GlobalIndex.init(allocator);
    errdefer index.deinit();

    var in_repos_section = false;
    var notes_start: ?usize = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_start: usize = 0;

    while (lines.next()) |line| {
        defer line_start += line.len + 1; // +1 for newline

        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Check for section headers
        if (std.mem.startsWith(u8, trimmed, "## Repositories")) {
            in_repos_section = true;
            continue;
        } else if (std.mem.startsWith(u8, trimmed, "## Notes")) {
            in_repos_section = false;
            // Capture everything after "## Notes\n"
            notes_start = line_start + line.len + 1;
            continue;
        } else if (std.mem.startsWith(u8, trimmed, "## ") or std.mem.startsWith(u8, trimmed, "# ")) {
            in_repos_section = false;
            continue;
        }

        // Parse repo paths in the Repositories section
        if (in_repos_section) {
            if (std.mem.startsWith(u8, trimmed, "- ")) {
                const path = std.mem.trim(u8, trimmed[2..], " \t");
                if (path.len > 0) {
                    const path_copy = try allocator.dupe(u8, path);
                    try index.repos.append(allocator, path_copy);
                }
            }
        }
    }

    // Capture notes content
    if (notes_start) |start| {
        if (start < content.len) {
            const notes = std.mem.trim(u8, content[start..], " \t\r\n");
            if (notes.len > 0) {
                index.notes_content = try allocator.dupe(u8, notes);
            }
        }
    }

    return index;
}

/// Get the path to the global index file
pub fn getGlobalIndexPath(allocator: std.mem.Allocator) errors.Result([]const u8) {
    const art_path = switch (paths.getGlobalArtPath(allocator)) {
        .ok => |p| p,
        .err => |e| return .{ .err = e },
    };
    defer allocator.free(art_path);

    const path = std.fs.path.join(allocator, &.{ art_path, "index", "ligi_global_index.md" }) catch {
        return .{ .err = errors.LigiError.filesystem(
            "failed to join path",
            null,
        ) };
    };
    return .{ .ok = path };
}

/// Load the global index from disk, creating it if it doesn't exist
pub fn loadGlobalIndex(allocator: std.mem.Allocator) errors.Result(GlobalIndex) {
    const index_path = switch (getGlobalIndexPath(allocator)) {
        .ok => |p| p,
        .err => |e| return .{ .err = e },
    };
    defer allocator.free(index_path);

    // Try to read existing file
    const content = switch (fs.readFile(allocator, index_path)) {
        .ok => |c| c,
        .err => {
            // File doesn't exist, return empty index
            return .{ .ok = GlobalIndex.init(allocator) };
        },
    };
    defer allocator.free(content);

    const index = parseGlobalIndex(allocator, content) catch {
        return .{ .err = errors.LigiError.config(
            "failed to parse global index",
            null,
        ) };
    };

    return .{ .ok = index };
}

/// Save the global index to disk
pub fn saveGlobalIndex(allocator: std.mem.Allocator, index: *const GlobalIndex) errors.Result(void) {
    const index_path = switch (getGlobalIndexPath(allocator)) {
        .ok => |p| p,
        .err => |e| return .{ .err = e },
    };
    defer allocator.free(index_path);

    // Ensure directory exists
    const index_dir = std.fs.path.dirname(index_path) orelse {
        return .{ .err = errors.LigiError.filesystem(
            "invalid index path",
            null,
        ) };
    };
    switch (fs.ensureDirRecursive(index_dir)) {
        .ok => {},
        .err => |e| return .{ .err = e },
    }

    // Render content
    const content = index.render(allocator) catch {
        return .{ .err = errors.LigiError.filesystem(
            "failed to render global index",
            null,
        ) };
    };
    defer allocator.free(content);

    // Write file (overwrite if exists)
    const file = std.fs.cwd().createFile(index_path, .{}) catch {
        return .{ .err = errors.LigiError.filesystem(
            "failed to create global index file",
            null,
        ) };
    };
    defer file.close();

    file.writeAll(content) catch {
        return .{ .err = errors.LigiError.filesystem(
            "failed to write global index file",
            null,
        ) };
    };

    return .{ .ok = {} };
}

/// Canonicalize a path: resolve `.`/`..` and follow symlinks
pub fn canonicalizePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    // First resolve to absolute path
    const abs_path = if (std.fs.path.isAbsolute(path))
        try allocator.dupe(u8, path)
    else blk: {
        const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch |err| {
            return err;
        };
        defer allocator.free(cwd);
        break :blk try std.fs.path.join(allocator, &.{ cwd, path });
    };
    defer allocator.free(abs_path);

    // Try to resolve to real path (follows symlinks)
    const real_path = std.fs.cwd().realpathAlloc(allocator, abs_path) catch {
        // If realpath fails (e.g., dangling symlink), use the absolute path
        return try allocator.dupe(u8, abs_path);
    };

    return real_path;
}

/// Add a repo to the global index
pub fn registerRepo(allocator: std.mem.Allocator, repo_path: []const u8) errors.Result(bool) {
    // Canonicalize the path
    const canonical_path = canonicalizePath(allocator, repo_path) catch {
        return .{ .err = errors.LigiError.filesystem(
            "failed to canonicalize path",
            null,
        ) };
    };
    defer allocator.free(canonical_path);

    // Load existing index
    var index = switch (loadGlobalIndex(allocator)) {
        .ok => |i| i,
        .err => |e| return .{ .err = e },
    };
    defer index.deinit();

    // Add repo if not present
    const added = index.addRepo(canonical_path) catch {
        return .{ .err = errors.LigiError.filesystem(
            "failed to add repo to index",
            null,
        ) };
    };

    if (added) {
        // Save updated index
        switch (saveGlobalIndex(allocator, &index)) {
            .ok => {},
            .err => |e| return .{ .err = e },
        }
    }

    return .{ .ok = added };
}

// ============================================================================
// Tests
// ============================================================================

test "INITIAL_GLOBAL_INDEX contains expected sections" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_GLOBAL_INDEX, "# Ligi Global Index") != null);
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_GLOBAL_INDEX, "## Repositories") != null);
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_GLOBAL_INDEX, "## Notes") != null);
}

test "GlobalIndex init and deinit work correctly" {
    const allocator = std.testing.allocator;
    var index = GlobalIndex.init(allocator);
    defer index.deinit();

    try std.testing.expectEqual(@as(usize, 0), index.repos.items.len);
}

test "GlobalIndex addRepo adds new path" {
    const allocator = std.testing.allocator;
    var index = GlobalIndex.init(allocator);
    defer index.deinit();

    const added = try index.addRepo("/test/repo");
    try std.testing.expect(added);
    try std.testing.expectEqual(@as(usize, 1), index.repos.items.len);
}

test "pruneIndexEntries removes missing repos or art dirs" {
    const allocator = std.testing.allocator;
    const fixtures = @import("../testing/fixtures.zig");

    var tmp = try fixtures.TempDir.create(allocator);
    defer tmp.cleanup();

    var dir = tmp.dir();
    try dir.makePath("repo_ok/art");
    try dir.makePath("repo_no_art");

    const repo_ok = try std.fs.path.join(allocator, &.{ tmp.path, "repo_ok" });
    defer allocator.free(repo_ok);
    const repo_no_art = try std.fs.path.join(allocator, &.{ tmp.path, "repo_no_art" });
    defer allocator.free(repo_no_art);
    const repo_missing = try std.fs.path.join(allocator, &.{ tmp.path, "repo_missing" });
    defer allocator.free(repo_missing);

    var index = GlobalIndex.init(allocator);
    defer index.deinit();

    _ = try index.addRepo(repo_ok);
    _ = try index.addRepo(repo_no_art);
    _ = try index.addRepo(repo_missing);

    const pruned = pruneIndexEntries(&index);
    try std.testing.expectEqual(@as(usize, 2), pruned);
    try std.testing.expectEqual(@as(usize, 1), index.repos.items.len);
    try std.testing.expectEqualStrings(repo_ok, index.repos.items[0]);
}

test "GlobalIndex addRepo is idempotent" {
    const allocator = std.testing.allocator;
    var index = GlobalIndex.init(allocator);
    defer index.deinit();

    const added1 = try index.addRepo("/test/repo");
    const added2 = try index.addRepo("/test/repo");

    try std.testing.expect(added1);
    try std.testing.expect(!added2);
    try std.testing.expectEqual(@as(usize, 1), index.repos.items.len);
}

test "GlobalIndex contains works correctly" {
    const allocator = std.testing.allocator;
    var index = GlobalIndex.init(allocator);
    defer index.deinit();

    _ = try index.addRepo("/test/repo");

    try std.testing.expect(index.contains("/test/repo"));
    try std.testing.expect(!index.contains("/other/repo"));
}

test "parseGlobalIndex parses repos correctly" {
    const allocator = std.testing.allocator;

    const content =
        \\# Ligi Global Index
        \\
        \\## Repositories
        \\
        \\- /home/user/project1
        \\- /home/user/project2
        \\
        \\## Notes
        \\
        \\Some notes here
    ;

    var index = try parseGlobalIndex(allocator, content);
    defer index.deinit();

    try std.testing.expectEqual(@as(usize, 2), index.repos.items.len);
    try std.testing.expectEqualStrings("/home/user/project1", index.repos.items[0]);
    try std.testing.expectEqualStrings("/home/user/project2", index.repos.items[1]);
}

test "parseGlobalIndex preserves notes content" {
    const allocator = std.testing.allocator;

    const content =
        \\# Ligi Global Index
        \\
        \\## Repositories
        \\
        \\- /test/repo
        \\
        \\## Notes
        \\
        \\Custom notes here
        \\With multiple lines
    ;

    var index = try parseGlobalIndex(allocator, content);
    defer index.deinit();

    try std.testing.expect(index.notes_content != null);
    try std.testing.expect(std.mem.indexOf(u8, index.notes_content.?, "Custom notes here") != null);
}

test "parseGlobalIndex handles empty repos section" {
    const allocator = std.testing.allocator;

    const content =
        \\# Ligi Global Index
        \\
        \\## Repositories
        \\
        \\## Notes
        \\
        \\Notes only
    ;

    var index = try parseGlobalIndex(allocator, content);
    defer index.deinit();

    try std.testing.expectEqual(@as(usize, 0), index.repos.items.len);
}

test "GlobalIndex render produces valid markdown" {
    const allocator = std.testing.allocator;
    var index = GlobalIndex.init(allocator);
    defer index.deinit();

    _ = try index.addRepo("/zz/repo");
    _ = try index.addRepo("/aa/repo");

    const output = try index.render(allocator);
    defer allocator.free(output);

    // Check structure
    try std.testing.expect(std.mem.indexOf(u8, output, "# Ligi Global Index") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "## Repositories") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "## Notes") != null);

    // Check repos are sorted
    const aa_pos = std.mem.indexOf(u8, output, "/aa/repo").?;
    const zz_pos = std.mem.indexOf(u8, output, "/zz/repo").?;
    try std.testing.expect(aa_pos < zz_pos);
}

test "canonicalizePath resolves relative paths" {
    const allocator = std.testing.allocator;

    // "." should resolve to cwd
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const result = try canonicalizePath(allocator, ".");
    defer allocator.free(result);

    try std.testing.expectEqualStrings(cwd, result);
}

test "pruneIndexEntries removes dangling symlinks" {
    // Dangling symlinks are treated as broken (path does not resolve)
    const allocator = std.testing.allocator;
    const fixtures = @import("../testing/fixtures.zig");

    var tmp = try fixtures.TempDir.create(allocator);
    defer tmp.cleanup();

    var dir = tmp.dir();
    try dir.makePath("repo_ok/art");

    // Create a dangling symlink as a "repo"
    dir.symLink("/nonexistent/target", "dangling_repo", .{}) catch |err| {
        // Skip test if symlinks not supported
        if (err == error.AccessDenied) return;
        return err;
    };

    const repo_ok = try std.fs.path.join(allocator, &.{ tmp.path, "repo_ok" });
    defer allocator.free(repo_ok);
    const dangling = try std.fs.path.join(allocator, &.{ tmp.path, "dangling_repo" });
    defer allocator.free(dangling);

    var index = GlobalIndex.init(allocator);
    defer index.deinit();

    _ = try index.addRepo(repo_ok);
    _ = try index.addRepo(dangling);

    const pruned = pruneIndexEntries(&index);
    try std.testing.expectEqual(@as(usize, 1), pruned);
    try std.testing.expectEqual(@as(usize, 1), index.repos.items.len);
    try std.testing.expectEqualStrings(repo_ok, index.repos.items[0]);
}
