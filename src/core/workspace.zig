//! Workspace detection and context building for the three-tier hierarchy.
//!
//! Workspaces form a hierarchy: global (~/.ligi) -> org -> repo
//! This module handles detecting the current workspace type and building
//! the full context including template resolution paths.

const std = @import("std");
const config = @import("config.zig");
const errors = @import("errors.zig");
const fs = @import("fs.zig");
const paths = @import("paths.zig");

pub const WorkspaceType = config.WorkspaceType;

/// Maximum depth to search for parent workspaces (prevents infinite loops)
const MAX_SEARCH_DEPTH = 10;

/// Resolved workspace context (computed at runtime)
pub const WorkspaceContext = struct {
    /// Current workspace root (where art/ lives)
    root: []const u8,

    /// Workspace type
    type: WorkspaceType,

    /// Workspace name (dirname or configured)
    name: []const u8,

    /// Parent org root path (null if global or no org found)
    org_root: ?[]const u8,

    /// Parent org name (null if global or no org found)
    org_name: ?[]const u8,

    /// Repo name when running from inside a registered repo under an org
    repo_name: ?[]const u8,

    /// Global root path (~/.ligi)
    global_root: ?[]const u8,

    /// Resolved template search paths (in priority order: repo -> org -> global)
    template_paths: []const []const u8,

    /// Resolved index search paths
    index_paths: []const []const u8,

    /// Auto-tag configuration
    auto_tags_enabled: bool,

    /// Allocator used for this context
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WorkspaceContext) void {
        self.allocator.free(self.root);
        self.allocator.free(self.name);
        if (self.org_root) |p| self.allocator.free(p);
        if (self.org_name) |n| self.allocator.free(n);
        if (self.repo_name) |n| self.allocator.free(n);
        if (self.global_root) |p| self.allocator.free(p);
        for (self.template_paths) |p| self.allocator.free(p);
        self.allocator.free(self.template_paths);
        for (self.index_paths) |p| self.allocator.free(p);
        self.allocator.free(self.index_paths);
    }
};

/// Result of workspace detection
pub const DetectResult = union(enum) {
    ok: WorkspaceContext,
    err: errors.LigiError,

    pub fn isOk(self: DetectResult) bool {
        return self == .ok;
    }
};

/// Detect the workspace context starting from a given path.
/// Walks up the directory tree to find art/ directories and determine the hierarchy.
pub fn detectWorkspace(allocator: std.mem.Allocator, start_path: []const u8) DetectResult {
    // First, find the nearest art/ directory (current workspace)
    const workspace_root = findNearestArtParent(allocator, start_path) orelse {
        return .{ .err = errors.LigiError.filesystem(
            "no art/ directory found (run 'ligi init' first)",
            null,
        ) };
    };
    defer allocator.free(workspace_root);

    return buildContext(allocator, workspace_root);
}

/// Build a workspace context from a known workspace root.
pub fn buildContext(allocator: std.mem.Allocator, workspace_root: []const u8) DetectResult {
    // Read workspace type from config (default to repo for legacy configs)
    const workspace_type = readWorkspaceType(allocator, workspace_root) orelse .repo;

    // Get workspace name (from config or directory name)
    const workspace_name = readWorkspaceName(allocator, workspace_root) orelse
        getDirectoryName(allocator, workspace_root) orelse {
        return .{ .err = errors.LigiError.filesystem(
            "failed to determine workspace name",
            null,
        ) };
    };

    // Find parent org (if we're a repo)
    var org_root: ?[]const u8 = null;
    var org_name: ?[]const u8 = null;
    if (workspace_type == .repo) {
        if (findOrgRoot(allocator, workspace_root)) |org_path| {
            org_root = org_path;
            org_name = readWorkspaceName(allocator, org_path) orelse
                getDirectoryName(allocator, org_path);
        }
    }

    // Find global root
    const global_root = switch (paths.getGlobalRoot(allocator)) {
        .ok => |p| blk: {
            // Check if global actually exists
            const global_art = std.fs.path.join(allocator, &.{ p, "art" }) catch {
                allocator.free(p);
                break :blk null;
            };
            defer allocator.free(global_art);
            if (fs.dirExists(global_art)) {
                break :blk p;
            }
            allocator.free(p);
            break :blk null;
        },
        .err => null,
    };

    // Build template paths (repo -> org -> global)
    var template_paths_list: std.ArrayList([]const u8) = .empty;

    // Add current workspace template path
    const local_template = std.fs.path.join(allocator, &.{ workspace_root, "art", "template" }) catch {
        return .{ .err = errors.LigiError.filesystem("failed to build template path", null) };
    };
    template_paths_list.append(allocator, local_template) catch {
        allocator.free(local_template);
        return .{ .err = errors.LigiError.filesystem("failed to build template paths", null) };
    };

    // Add org template path if present
    if (org_root) |org| {
        const org_template = std.fs.path.join(allocator, &.{ org, "art", "template" }) catch {
            // Clean up and return error
            for (template_paths_list.items) |p| allocator.free(p);
            template_paths_list.deinit(allocator);
            return .{ .err = errors.LigiError.filesystem("failed to build template path", null) };
        };
        template_paths_list.append(allocator, org_template) catch {
            allocator.free(org_template);
            for (template_paths_list.items) |p| allocator.free(p);
            template_paths_list.deinit(allocator);
            return .{ .err = errors.LigiError.filesystem("failed to build template paths", null) };
        };
    }

    // Add global template path if present
    if (global_root) |global| {
        const global_template = std.fs.path.join(allocator, &.{ global, "art", "template" }) catch {
            for (template_paths_list.items) |p| allocator.free(p);
            template_paths_list.deinit(allocator);
            return .{ .err = errors.LigiError.filesystem("failed to build template path", null) };
        };
        template_paths_list.append(allocator, global_template) catch {
            allocator.free(global_template);
            for (template_paths_list.items) |p| allocator.free(p);
            template_paths_list.deinit(allocator);
            return .{ .err = errors.LigiError.filesystem("failed to build template paths", null) };
        };
    }

    // Build index paths (similar structure)
    var index_paths_list: std.ArrayList([]const u8) = .empty;
    const local_index = std.fs.path.join(allocator, &.{ workspace_root, "art", "index" }) catch {
        for (template_paths_list.items) |p| allocator.free(p);
        template_paths_list.deinit(allocator);
        return .{ .err = errors.LigiError.filesystem("failed to build index path", null) };
    };
    index_paths_list.append(allocator, local_index) catch {
        allocator.free(local_index);
        for (template_paths_list.items) |p| allocator.free(p);
        template_paths_list.deinit(allocator);
        return .{ .err = errors.LigiError.filesystem("failed to build index paths", null) };
    };

    // Duplicate workspace_root for the context
    const owned_root = allocator.dupe(u8, workspace_root) catch {
        for (template_paths_list.items) |p| allocator.free(p);
        template_paths_list.deinit(allocator);
        for (index_paths_list.items) |p| allocator.free(p);
        index_paths_list.deinit(allocator);
        return .{ .err = errors.LigiError.filesystem("allocation failed", null) };
    };

    return .{ .ok = .{
        .root = owned_root,
        .type = workspace_type,
        .name = workspace_name,
        .org_root = org_root,
        .org_name = org_name,
        .repo_name = null,
        .global_root = global_root,
        .template_paths = template_paths_list.toOwnedSlice(allocator) catch {
            allocator.free(owned_root);
            allocator.free(workspace_name);
            if (org_root) |p| allocator.free(p);
            if (org_name) |n| allocator.free(n);
            if (global_root) |p| allocator.free(p);
            for (template_paths_list.items) |p| allocator.free(p);
            template_paths_list.deinit(allocator);
            for (index_paths_list.items) |p| allocator.free(p);
            index_paths_list.deinit(allocator);
            return .{ .err = errors.LigiError.filesystem("allocation failed", null) };
        },
        .index_paths = index_paths_list.toOwnedSlice(allocator) catch {
            allocator.free(owned_root);
            allocator.free(workspace_name);
            if (org_root) |p| allocator.free(p);
            if (org_name) |n| allocator.free(n);
            if (global_root) |p| allocator.free(p);
            for (index_paths_list.items) |p| allocator.free(p);
            index_paths_list.deinit(allocator);
            return .{ .err = errors.LigiError.filesystem("allocation failed", null) };
        },
        .auto_tags_enabled = true, // Default, could read from config
        .allocator = allocator,
    } };
}

/// Find the nearest parent directory containing an art/ subdirectory.
fn findNearestArtParent(allocator: std.mem.Allocator, start_path: []const u8) ?[]const u8 {
    var current = allocator.dupe(u8, start_path) catch return null;
    var depth: usize = 0;

    while (depth < MAX_SEARCH_DEPTH) {
        // Check if current/art exists
        const art_path = std.fs.path.join(allocator, &.{ current, "art" }) catch {
            allocator.free(current);
            return null;
        };
        defer allocator.free(art_path);

        if (fs.dirExists(art_path)) {
            return current;
        }

        // Move to parent directory
        const parent = std.fs.path.dirname(current);
        if (parent == null or std.mem.eql(u8, parent.?, current)) {
            // Reached filesystem root
            allocator.free(current);
            return null;
        }

        const new_current = allocator.dupe(u8, parent.?) catch {
            allocator.free(current);
            return null;
        };
        allocator.free(current);
        current = new_current;
        depth += 1;
    }

    allocator.free(current);
    return null;
}

/// Find the parent org root by walking up from a repo root.
fn findOrgRoot(allocator: std.mem.Allocator, repo_root: []const u8) ?[]const u8 {
    // Start from parent of repo_root
    const parent = std.fs.path.dirname(repo_root) orelse return null;
    if (std.mem.eql(u8, parent, repo_root)) return null;

    var current = allocator.dupe(u8, parent) catch return null;
    var depth: usize = 0;

    while (depth < MAX_SEARCH_DEPTH) {
        // Check if current/art exists and is an org
        const art_path = std.fs.path.join(allocator, &.{ current, "art" }) catch {
            allocator.free(current);
            return null;
        };
        defer allocator.free(art_path);

        if (fs.dirExists(art_path)) {
            // Check if this is an org workspace
            const ws_type = readWorkspaceType(allocator, current);
            if (ws_type == .org) {
                return current;
            }
        }

        // Move to parent directory
        const next_parent = std.fs.path.dirname(current);
        if (next_parent == null or std.mem.eql(u8, next_parent.?, current)) {
            // Reached filesystem root
            allocator.free(current);
            return null;
        }

        const new_current = allocator.dupe(u8, next_parent.?) catch {
            allocator.free(current);
            return null;
        };
        allocator.free(current);
        current = new_current;
        depth += 1;
    }

    allocator.free(current);
    return null;
}

/// Read workspace type from config file.
fn readWorkspaceType(allocator: std.mem.Allocator, workspace_root: []const u8) ?WorkspaceType {
    const config_path = std.fs.path.join(allocator, &.{ workspace_root, "art", "config", "ligi.toml" }) catch return null;
    defer allocator.free(config_path);

    const content = switch (fs.readFile(allocator, config_path)) {
        .ok => |c| c,
        .err => return null,
    };
    defer allocator.free(content);

    // Simple TOML parsing - look for type = "..."
    return parseTomlWorkspaceType(content);
}

/// Read workspace name from config file.
fn readWorkspaceName(allocator: std.mem.Allocator, workspace_root: []const u8) ?[]const u8 {
    const config_path = std.fs.path.join(allocator, &.{ workspace_root, "art", "config", "ligi.toml" }) catch return null;
    defer allocator.free(config_path);

    const content = switch (fs.readFile(allocator, config_path)) {
        .ok => |c| c,
        .err => return null,
    };
    defer allocator.free(content);

    // Simple TOML parsing - look for name = "..."
    return parseTomlName(allocator, content);
}

/// Get the directory name from a path.
fn getDirectoryName(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const basename = std.fs.path.basename(path);
    if (basename.len == 0) return null;
    return allocator.dupe(u8, basename) catch null;
}

/// Parse workspace type from TOML content.
fn parseTomlWorkspaceType(content: []const u8) ?WorkspaceType {
    // Look for 'type = "global"', 'type = "org"', or 'type = "repo"'
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "type")) {
            // Find the value
            if (std.mem.indexOf(u8, trimmed, "\"global\"")) |_| return .global;
            if (std.mem.indexOf(u8, trimmed, "\"org\"")) |_| return .org;
            if (std.mem.indexOf(u8, trimmed, "\"repo\"")) |_| return .repo;
        }
    }
    return null;
}

/// Parse workspace name from TOML content.
fn parseTomlName(allocator: std.mem.Allocator, content: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "name")) {
            // Find the value between quotes
            if (std.mem.indexOf(u8, trimmed, "\"")) |start| {
                const rest = trimmed[start + 1 ..];
                if (std.mem.indexOf(u8, rest, "\"")) |end| {
                    return allocator.dupe(u8, rest[0..end]) catch null;
                }
            }
        }
    }
    return null;
}

/// Resolve the art/ path for the current context.
/// Uses explicit root if provided, otherwise detects workspace.
/// Returns null (and prints error) if no workspace found.
pub fn resolveArtPath(
    allocator: std.mem.Allocator,
    root_override: ?[]const u8,
    stderr: anytype,
) !?[]const u8 {
    if (root_override) |root| {
        return try paths.getLocalArtPath(allocator, root);
    }

    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const ws = detectWorkspace(allocator, cwd);
    if (ws != .ok) {
        try stderr.writeAll("error: no art/ directory found (run 'ligi init' first)\n");
        return null;
    }
    var ctx = ws.ok;
    defer ctx.deinit();

    return try std.fs.path.join(allocator, &.{ ctx.root, "art" });
}

/// Determine which repo the user is in, given an org root and the current working directory.
/// Returns the repo directory name (e.g., "repo1") if cwd is inside a registered repo, null otherwise.
pub fn detectRepoContext(allocator: std.mem.Allocator, org_root: []const u8, cwd: []const u8) ?[]const u8 {
    // Get registered repos
    const repos = getOrgRepos(allocator, org_root) catch return null;
    defer {
        for (repos) |r| allocator.free(r);
        allocator.free(repos);
    }

    for (repos) |repo_path| {
        // Check if cwd starts with repo_path
        if (std.mem.startsWith(u8, cwd, repo_path)) {
            // Ensure it's a proper prefix (exact match or followed by /)
            if (cwd.len == repo_path.len or cwd[repo_path.len] == '/') {
                return allocator.dupe(u8, std.fs.path.basename(repo_path)) catch null;
            }
        }
    }

    return null;
}

/// Get the list of registered repos from an org workspace.
/// Returns absolute paths to the repo directories.
pub fn getOrgRepos(allocator: std.mem.Allocator, org_root: []const u8) ![][]const u8 {
    const config_path = try std.fs.path.join(allocator, &.{ org_root, "art", "config", "ligi.toml" });
    defer allocator.free(config_path);

    const content = switch (fs.readFile(allocator, config_path)) {
        .ok => |c| c,
        .err => return error.ConfigNotFound,
    };
    defer allocator.free(content);

    // Parse repos array from TOML
    var repos: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (repos.items) |r| allocator.free(r);
        repos.deinit(allocator);
    }

    // Find repos = [...] line
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "repos")) {
            // Parse the array - find [ and ]
            const bracket_start = std.mem.indexOf(u8, trimmed, "[") orelse continue;
            const bracket_end = std.mem.indexOf(u8, trimmed, "]") orelse continue;
            const array_content = trimmed[bracket_start + 1 .. bracket_end];

            // Parse quoted strings
            var in_quote = false;
            var quote_start: usize = 0;
            for (array_content, 0..) |c, i| {
                if (c == '"' and !in_quote) {
                    in_quote = true;
                    quote_start = i + 1;
                } else if (c == '"' and in_quote) {
                    in_quote = false;
                    const repo_name = array_content[quote_start..i];
                    // Convert relative path to absolute
                    const abs_path = try std.fs.path.join(allocator, &.{ org_root, repo_name });
                    try repos.append(allocator, abs_path);
                }
            }
            break;
        }
    }

    return repos.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "parseTomlWorkspaceType parses global" {
    const content = "type = \"global\"\n";
    try std.testing.expectEqual(WorkspaceType.global, parseTomlWorkspaceType(content).?);
}

test "parseTomlWorkspaceType parses org" {
    const content = "[workspace]\ntype = \"org\"\n";
    try std.testing.expectEqual(WorkspaceType.org, parseTomlWorkspaceType(content).?);
}

test "parseTomlWorkspaceType parses repo" {
    const content = "type = \"repo\"";
    try std.testing.expectEqual(WorkspaceType.repo, parseTomlWorkspaceType(content).?);
}

test "parseTomlWorkspaceType returns null for missing type" {
    const content = "[workspace]\nname = \"test\"\n";
    try std.testing.expect(parseTomlWorkspaceType(content) == null);
}

test "parseTomlName extracts name" {
    const allocator = std.testing.allocator;
    const content = "name = \"my-workspace\"\n";
    const name = parseTomlName(allocator, content);
    try std.testing.expect(name != null);
    defer allocator.free(name.?);
    try std.testing.expectEqualStrings("my-workspace", name.?);
}

test "parseTomlName returns null for missing name" {
    const allocator = std.testing.allocator;
    const content = "type = \"repo\"\n";
    try std.testing.expect(parseTomlName(allocator, content) == null);
}

test "getDirectoryName extracts basename" {
    const allocator = std.testing.allocator;
    const name = getDirectoryName(allocator, "/home/user/myproject");
    try std.testing.expect(name != null);
    defer allocator.free(name.?);
    try std.testing.expectEqualStrings("myproject", name.?);
}

test "WorkspaceType enum values" {
    try std.testing.expectEqual(WorkspaceType.global, WorkspaceType.global);
    try std.testing.expectEqual(WorkspaceType.org, WorkspaceType.org);
    try std.testing.expectEqual(WorkspaceType.repo, WorkspaceType.repo);
}

test "detectRepoContext returns repo name when cwd is inside a registered repo" {
    const allocator = std.testing.allocator;

    // Create a temp dir structure: org/art/config/ligi.toml with repos = ["repo1"]
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create org structure
    try tmp_dir.dir.makePath("art/config");
    try tmp_dir.dir.makePath("repo1/src");

    // Get real path of tmp dir
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Write org config with repo1
    const config_content = try std.fmt.allocPrint(allocator, "type = \"org\"\nname = \"test-org\"\nrepos = [\"{s}/repo1\"]\n", .{tmp_path});
    defer allocator.free(config_content);

    const config_path = try std.fs.path.join(allocator, &.{ tmp_path, "art", "config", "ligi.toml" });
    defer allocator.free(config_path);

    const config_file = try std.fs.cwd().createFile(config_path, .{});
    defer config_file.close();
    try config_file.writeAll(config_content);

    // Test: cwd inside repo1
    const repo1_cwd = try std.fs.path.join(allocator, &.{ tmp_path, "repo1", "src" });
    defer allocator.free(repo1_cwd);

    const repo_name = detectRepoContext(allocator, tmp_path, repo1_cwd);
    try std.testing.expect(repo_name != null);
    defer allocator.free(repo_name.?);
    try std.testing.expectEqualStrings("repo1", repo_name.?);
}

test "detectRepoContext returns null when cwd is at org level" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makePath("art/config");

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Write config with no repos
    const config_path = try std.fs.path.join(allocator, &.{ tmp_path, "art", "config", "ligi.toml" });
    defer allocator.free(config_path);

    const config_file = try std.fs.cwd().createFile(config_path, .{});
    defer config_file.close();
    try config_file.writeAll("type = \"org\"\nname = \"test-org\"\nrepos = []\n");

    const result = detectRepoContext(allocator, tmp_path, tmp_path);
    try std.testing.expect(result == null);
}
