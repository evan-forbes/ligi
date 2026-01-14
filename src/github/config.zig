//! GitHub configuration loading.
//! Loads token from GITHUB_TOKEN env var or art/config/github.toml.

const std = @import("std");
const errors = @import("../core/errors.zig");
const fs = @import("../core/fs.zig");
const paths = @import("../core/paths.zig");
const toml = @import("../template/toml.zig");

/// Configuration for GitHub API access
pub const GithubConfig = struct {
    /// GitHub personal access token (from config or env)
    token: ?[]const u8,
    /// API base URL (default: https://api.github.com)
    api_base: []const u8 = "https://api.github.com",
    /// Whether token was loaded from env (don't free)
    token_from_env: bool = false,
};

/// Load GitHub configuration.
/// Priority: GITHUB_TOKEN env var > art/config/github.toml
///
/// Returns config with null token if no token found (not an error).
pub fn loadConfig(allocator: std.mem.Allocator, art_path: []const u8) errors.Result(GithubConfig) {
    // 1. Check environment variable first (takes precedence)
    if (std.posix.getenv("GITHUB_TOKEN")) |token| {
        return .{ .ok = .{
            .token = token,
            .api_base = "https://api.github.com",
            .token_from_env = true,
        } };
    }

    // 2. Try config file
    const config_path = paths.joinPath(allocator, &.{ art_path, "config", "github.toml" }) catch {
        return .{ .err = errors.LigiError.filesystem("failed to build config path", null) };
    };
    defer allocator.free(config_path);

    // Check if file exists - if not, return null token (not an error)
    if (!fs.fileExists(config_path)) {
        return .{ .ok = .{
            .token = null,
            .api_base = "https://api.github.com",
            .token_from_env = false,
        } };
    }

    // 3. Check permissions (warn if world-readable)
    // Note: We don't print warning here since we don't have access to stderr.
    // The caller should check permissions if needed.

    // 4. Parse TOML - NOTE: token MUST be quoted in TOML file
    const content = switch (fs.readFile(allocator, config_path)) {
        .ok => |c| c,
        .err => |e| return .{ .err = e },
    };
    defer allocator.free(content);

    var toml_data = toml.parse(allocator, content) catch {
        return .{ .err = errors.LigiError.config("failed to parse github.toml", null) };
    };
    defer {
        var it = toml_data.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        toml_data.deinit();
    }

    // Extract token if present
    const token: ?[]const u8 = if (toml_data.get("token")) |v| switch (v) {
        .string => |s| allocator.dupe(u8, s) catch null,
        else => null,
    } else null;

    return .{ .ok = .{
        .token = token,
        .api_base = "https://api.github.com",
        .token_from_env = false,
    } };
}

/// Free config resources if they were allocated
pub fn freeConfig(allocator: std.mem.Allocator, config: *GithubConfig) void {
    if (!config.token_from_env) {
        if (config.token) |t| {
            allocator.free(t);
        }
    }
    config.token = null;
}

/// Check if file is world-readable (Unix only)
fn isWorldReadable(path: []const u8) bool {
    const stat = std.fs.cwd().statFile(path) catch return false;
    // Check if "others" have read permission (mode & 0o004)
    return (stat.mode & 0o004) != 0;
}

// ============================================================================
// Tests
// ============================================================================

test "loadConfig returns null token when no config exists" {
    const allocator = std.testing.allocator;

    // Use a non-existent path
    const result = loadConfig(allocator, "/nonexistent/path/art");
    try std.testing.expect(result.isOk());

    var config = result.ok;
    defer freeConfig(allocator, &config);

    try std.testing.expect(config.token == null);
    try std.testing.expectEqualStrings("https://api.github.com", config.api_base);
}
