//! Ligi library root - re-exports public API.

const std = @import("std");

// Re-export core modules
pub const core = @import("core/mod.zig");
pub const cli = @import("cli/mod.zig");

// Re-export commonly used types
pub const ErrorCategory = core.ErrorCategory;
pub const ErrorContext = core.ErrorContext;
pub const LigiError = core.LigiError;
pub const Result = core.Result;
pub const LigiConfig = core.LigiConfig;

pub const CommandRegistry = cli.CommandRegistry;
pub const VERSION = cli.VERSION;

// Utility functions
pub const paths = core.paths;
pub const fs = core.fs;
pub const config = core.config;

// Run CLI
pub const run = cli.run;

// ============================================================================
// Tests - import all test modules
// ============================================================================

test {
    // Core tests
    _ = @import("core/errors.zig");
    _ = @import("core/paths.zig");
    _ = @import("core/fs.zig");
    _ = @import("core/config.zig");

    // CLI tests
    _ = @import("cli/registry.zig");
    _ = @import("cli/help.zig");
    _ = @import("cli/commands/init.zig");
}
