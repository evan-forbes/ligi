//! CLI module for ligi.

pub const registry = @import("registry.zig");
pub const help = @import("help.zig");
pub const commands = @import("commands/mod.zig");

pub const CommandRegistry = registry.CommandRegistry;
pub const buildRegistry = registry.buildRegistry;
pub const run = registry.run;
pub const VERSION = registry.VERSION;
