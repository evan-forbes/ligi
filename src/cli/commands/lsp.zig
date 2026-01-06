//! LSP command: starts a stdio LSP server for completions.

const std = @import("std");
const lsp = @import("../../lsp/mod.zig");

pub fn run(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var server = lsp.server.Server.init(allocator);
    defer server.deinit();

    const stdin_reader = std.fs.File.stdin().deprecatedReader();

    server.run(stdin_reader, stdout, stderr) catch |err| {
        try stderr.print("error: failed to start lsp: {}\n", .{err});
        return 1;
    };

    return 0;
}
