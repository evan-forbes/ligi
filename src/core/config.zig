//! TOML configuration parsing and management.

const std = @import("std");
const errors = @import("errors.zig");
const fs = @import("fs.zig");

/// Ligi configuration structure
pub const LigiConfig = struct {
    /// Config file format version
    version: []const u8 = "0.1.0",

    /// Index settings
    index: IndexConfig = .{},

    /// Query settings
    query: QueryConfig = .{},

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

/// Default TOML content for new config files
pub const DEFAULT_CONFIG_TOML =
    \\# Ligi Configuration
    \\# See https://github.com/evan-forbes/ligi for documentation
    \\
    \\version = "0.1.0"
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
;

// ============================================================================
// Tests
// ============================================================================

test "getDefaultConfig returns LigiConfig with defaults" {
    const config = getDefaultConfig();
    try std.testing.expectEqualStrings("0.1.0", config.version);
    try std.testing.expect(!config.index.follow_symlinks);
    try std.testing.expect(config.query.colors);
    try std.testing.expectEqual(LigiConfig.OutputFormat.text, config.query.default_format);
}

test "DEFAULT_CONFIG_TOML contains version" {
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_CONFIG_TOML, "version = \"0.1.0\"") != null);
}

test "DEFAULT_CONFIG_TOML contains index section" {
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_CONFIG_TOML, "[index]") != null);
}

test "DEFAULT_CONFIG_TOML contains query section" {
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_CONFIG_TOML, "[query]") != null);
}
