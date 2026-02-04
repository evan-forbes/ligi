//! TOML configuration parsing and management.

const std = @import("std");
const errors = @import("errors.zig");
const fs = @import("fs.zig");

/// Workspace type in the three-tier hierarchy
pub const WorkspaceType = enum {
    /// Global workspace at ~/.ligi
    global,
    /// Organization workspace containing multiple repos
    org,
    /// Individual repository workspace
    repo,

    pub fn toString(self: WorkspaceType) []const u8 {
        return switch (self) {
            .global => "global",
            .org => "org",
            .repo => "repo",
        };
    }

    pub fn fromString(s: []const u8) ?WorkspaceType {
        if (std.mem.eql(u8, s, "global")) return .global;
        if (std.mem.eql(u8, s, "org")) return .org;
        if (std.mem.eql(u8, s, "repo")) return .repo;
        return null;
    }
};

/// Ligi configuration structure
pub const LigiConfig = struct {
    /// Config file format version
    version: []const u8 = "0.2.0",

    /// Workspace configuration
    workspace: WorkspaceConfig = .{},

    /// Index settings
    index: IndexConfig = .{},

    /// Query settings
    query: QueryConfig = .{},

    /// Auto-tagging settings
    auto_tags: AutoTagsConfig = .{},

    pub const WorkspaceConfig = struct {
        /// Workspace type: global, org, or repo
        type: WorkspaceType = .repo,

        /// For org: registered repositories (relative paths)
        /// Stored as comma-separated string in TOML, parsed to slice
        repos: []const []const u8 = &.{},

        /// For repo: explicit org root (auto-detected if null)
        org_root: ?[]const u8 = null,

        /// Display name for this workspace (derived from dirname if null)
        name: ?[]const u8 = null,
    };

    pub const AutoTagsConfig = struct {
        /// Whether to auto-add context tags
        enabled: bool = true,

        /// Tag templates (supports {{org}}, {{repo}} placeholders)
        tags: []const []const u8 = &.{ "{{org}}", "{{repo}}" },
    };

    pub const IndexConfig = struct {
        /// File patterns to ignore when indexing
        ignore_patterns: []const []const u8 = &.{ "*.tmp", "*.bak" },
        /// Whether to follow symlinks
        follow_symlinks: bool = false,
    };

    pub const QueryConfig = struct {
        /// Default output format
        default_format: OutputFormat = .text,
        /// Whether to use colors in output
        colors: bool = true,
    };

    pub const OutputFormat = enum { text, json };
};

/// Get default config
pub fn getDefaultConfig() LigiConfig {
    return .{};
}

/// Default TOML content for new config files (repo workspace)
pub const DEFAULT_CONFIG_TOML =
    \\# Ligi Configuration
    \\# See https://github.com/evan-forbes/ligi for documentation
    \\
    \\version = "0.2.0"
    \\
    \\[workspace]
    \\# Workspace type: "global", "org", or "repo"
    \\type = "repo"
    \\# Display name (defaults to directory name if not set)
    \\# name = "my-repo"
    \\# Explicit org root path (auto-detected if not set)
    \\# org_root = "../"
    \\
    \\[index]
    \\# Patterns to ignore when indexing (glob syntax)
    \\ignore_patterns = ["*.tmp", "*.bak"]
    \\# Whether to follow symbolic links
    \\follow_symlinks = false
    \\
    \\[query]
    \\# Default output format: "text" or "json"
    \\default_format = "text"
    \\# Enable colored output
    \\colors = true
    \\
    \\[auto_tags]
    \\# Whether to automatically add context tags when creating documents
    \\enabled = true
    \\# Tag templates ({{org}} and {{repo}} are replaced with workspace names)
    \\tags = ["{{org}}", "{{repo}}"]
    \\
;

/// Generate TOML config for a specific workspace type
pub fn generateConfigToml(allocator: std.mem.Allocator, workspace_type: WorkspaceType, name: ?[]const u8, repos: []const []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    try result.appendSlice(allocator, "# Ligi Configuration\n");
    try result.appendSlice(allocator, "# See https://github.com/evan-forbes/ligi for documentation\n\n");
    try result.appendSlice(allocator, "version = \"0.2.0\"\n\n");

    try result.appendSlice(allocator, "[workspace]\n");
    try result.appendSlice(allocator, "type = \"");
    try result.appendSlice(allocator, workspace_type.toString());
    try result.appendSlice(allocator, "\"\n");

    if (name) |n| {
        try result.appendSlice(allocator, "name = \"");
        try result.appendSlice(allocator, n);
        try result.appendSlice(allocator, "\"\n");
    }

    if (workspace_type == .org and repos.len > 0) {
        try result.appendSlice(allocator, "repos = [");
        for (repos, 0..) |repo, i| {
            if (i > 0) try result.appendSlice(allocator, ", ");
            try result.appendSlice(allocator, "\"");
            try result.appendSlice(allocator, repo);
            try result.appendSlice(allocator, "\"");
        }
        try result.appendSlice(allocator, "]\n");
    }

    try result.appendSlice(allocator, "\n[index]\n");
    try result.appendSlice(allocator, "ignore_patterns = [\"*.tmp\", \"*.bak\"]\n");
    try result.appendSlice(allocator, "follow_symlinks = false\n");

    try result.appendSlice(allocator, "\n[query]\n");
    try result.appendSlice(allocator, "default_format = \"text\"\n");
    try result.appendSlice(allocator, "colors = true\n");

    try result.appendSlice(allocator, "\n[auto_tags]\n");
    try result.appendSlice(allocator, "enabled = true\n");
    try result.appendSlice(allocator, "tags = [\"{{org}}\", \"{{repo}}\"]\n");

    return result.toOwnedSlice(allocator);
}

/// Add a repo to an org's config file
pub fn addRepoToOrgConfig(allocator: std.mem.Allocator, config_path: []const u8, repo_name: []const u8) !void {
    // Read existing config
    const content = switch (fs.readFile(allocator, config_path)) {
        .ok => |c| c,
        .err => return error.ReadError,
    };
    defer allocator.free(content);

    // Check if repo already exists in the repos list
    // Simple string search - look for the repo name in quotes
    var search_pattern: std.ArrayList(u8) = .empty;
    defer search_pattern.deinit(allocator);
    try search_pattern.appendSlice(allocator, "\"");
    try search_pattern.appendSlice(allocator, repo_name);
    try search_pattern.appendSlice(allocator, "\"");

    if (std.mem.indexOf(u8, content, search_pattern.items) != null) {
        // Repo already registered
        return;
    }

    // Find the repos line and add to it, or add a new repos line
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    var found_repos = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "repos")) {
            // Found existing repos line
            found_repos = true;
            // Find the closing bracket
            if (std.mem.indexOf(u8, line, "]")) |bracket_pos| {
                // Check if empty array
                const before_bracket = std.mem.trim(u8, line[0..bracket_pos], " \t");
                if (std.mem.endsWith(u8, before_bracket, "[")) {
                    // Empty array: repos = []
                    try result.appendSlice(allocator, line[0..bracket_pos]);
                    try result.appendSlice(allocator, "\"");
                    try result.appendSlice(allocator, repo_name);
                    try result.appendSlice(allocator, "\"]");
                } else {
                    // Non-empty array: add to end
                    try result.appendSlice(allocator, line[0..bracket_pos]);
                    try result.appendSlice(allocator, ", \"");
                    try result.appendSlice(allocator, repo_name);
                    try result.appendSlice(allocator, "\"]");
                }
                try result.append(allocator, '\n');
            } else {
                // Malformed line, just keep it
                try result.appendSlice(allocator, line);
                try result.append(allocator, '\n');
            }
        } else {
            try result.appendSlice(allocator, line);
            try result.append(allocator, '\n');
        }
    }

    // If we didn't find a repos line, add one after [workspace]
    if (!found_repos) {
        var final_result: std.ArrayList(u8) = .empty;
        defer final_result.deinit(allocator);
        var final_lines = std.mem.splitScalar(u8, result.items, '\n');
        while (final_lines.next()) |line| {
            try final_result.appendSlice(allocator, line);
            try final_result.append(allocator, '\n');
            if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), "[workspace]")) {
                // Skip to after type line
            } else if (std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " \t"), "type")) {
                try final_result.appendSlice(allocator, "repos = [\"");
                try final_result.appendSlice(allocator, repo_name);
                try final_result.appendSlice(allocator, "\"]\n");
            }
        }
        // Remove trailing newline that was added
        if (final_result.items.len > 0 and final_result.items[final_result.items.len - 1] == '\n') {
            _ = final_result.pop();
        }
        switch (fs.writeFile(config_path, final_result.items)) {
            .ok => {},
            .err => return error.WriteError,
        }
        return;
    }

    // Remove trailing newline that was added
    if (result.items.len > 0 and result.items[result.items.len - 1] == '\n') {
        _ = result.pop();
    }

    switch (fs.writeFile(config_path, result.items)) {
        .ok => {},
        .err => return error.WriteError,
    }
}

// ============================================================================
// Tests
// ============================================================================

test "getDefaultConfig returns LigiConfig with defaults" {
    const config = getDefaultConfig();
    try std.testing.expectEqualStrings("0.2.0", config.version);
    try std.testing.expect(!config.index.follow_symlinks);
    try std.testing.expect(config.query.colors);
    try std.testing.expectEqual(LigiConfig.OutputFormat.text, config.query.default_format);
    try std.testing.expectEqual(WorkspaceType.repo, config.workspace.type);
    try std.testing.expect(config.auto_tags.enabled);
}

test "DEFAULT_CONFIG_TOML contains version" {
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_CONFIG_TOML, "version = \"0.2.0\"") != null);
}

test "DEFAULT_CONFIG_TOML contains index section" {
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_CONFIG_TOML, "[index]") != null);
}

test "DEFAULT_CONFIG_TOML contains query section" {
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_CONFIG_TOML, "[query]") != null);
}

test "DEFAULT_CONFIG_TOML contains workspace section" {
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_CONFIG_TOML, "[workspace]") != null);
}

test "DEFAULT_CONFIG_TOML contains auto_tags section" {
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_CONFIG_TOML, "[auto_tags]") != null);
}

test "WorkspaceType toString and fromString" {
    try std.testing.expectEqualStrings("global", WorkspaceType.global.toString());
    try std.testing.expectEqualStrings("org", WorkspaceType.org.toString());
    try std.testing.expectEqualStrings("repo", WorkspaceType.repo.toString());

    try std.testing.expectEqual(WorkspaceType.global, WorkspaceType.fromString("global").?);
    try std.testing.expectEqual(WorkspaceType.org, WorkspaceType.fromString("org").?);
    try std.testing.expectEqual(WorkspaceType.repo, WorkspaceType.fromString("repo").?);
    try std.testing.expect(WorkspaceType.fromString("invalid") == null);
}

test "generateConfigToml creates valid config for repo" {
    const allocator = std.testing.allocator;
    const toml = try generateConfigToml(allocator, .repo, null, &.{});
    defer allocator.free(toml);

    try std.testing.expect(std.mem.indexOf(u8, toml, "type = \"repo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, toml, "[workspace]") != null);
}

test "generateConfigToml creates valid config for org with repos" {
    const allocator = std.testing.allocator;
    const repos = [_][]const u8{ "repo-a", "repo-b" };
    const toml = try generateConfigToml(allocator, .org, "my-org", &repos);
    defer allocator.free(toml);

    try std.testing.expect(std.mem.indexOf(u8, toml, "type = \"org\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, toml, "name = \"my-org\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, toml, "\"repo-a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, toml, "\"repo-b\"") != null);
}
