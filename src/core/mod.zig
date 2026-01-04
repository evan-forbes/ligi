//! Core module for ligi - contains foundational types and utilities.

pub const errors = @import("errors.zig");
pub const paths = @import("paths.zig");
pub const fs = @import("fs.zig");
pub const config = @import("config.zig");

// Re-export commonly used types
pub const ErrorCategory = errors.ErrorCategory;
pub const ErrorContext = errors.ErrorContext;
pub const LigiError = errors.LigiError;
pub const Result = errors.Result;

pub const LigiConfig = config.LigiConfig;
pub const SPECIAL_DIRS = paths.SPECIAL_DIRS;
