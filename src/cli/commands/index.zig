//! The `ligi index` command implementation (stub).

const std = @import("std");

/// Run the index command (not yet implemented)
pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
    quiet: bool,
) !u8 {
    _ = allocator;
    _ = args;
    _ = stdout;
    _ = quiet;
    try stderr.writeAll("error: 'index' command not yet implemented\n");
    return 1;
}
