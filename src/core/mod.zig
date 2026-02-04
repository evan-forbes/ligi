//! Core module for ligi - contains foundational types and utilities.

pub const errors = @import("errors.zig");
pub const paths = @import("paths.zig");
pub const fs = @import("fs.zig");
pub const config = @import("config.zig");
pub const global_index = @import("global_index.zig");
pub const tag_index = @import("tag_index.zig");
pub const workspace = @import("workspace.zig");
pub const templates = @import("templates.zig");
pub const log = @import("log.zig");

// Re-export commonly used types
pub const ErrorCategory = errors.ErrorCategory;
pub const ErrorContext = errors.ErrorContext;
pub const LigiError = errors.LigiError;
pub const Result = errors.Result;

pub const LigiConfig = config.LigiConfig;
pub const WorkspaceType = config.WorkspaceType;
pub const SPECIAL_DIRS = paths.SPECIAL_DIRS;
pub const GlobalIndex = global_index.GlobalIndex;
pub const WorkspaceContext = workspace.WorkspaceContext;
pub const getBuiltinTemplate = templates.getBuiltinTemplate;
