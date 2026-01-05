//! Serve command: starts a local HTTP server for markdown rendering.
//!
//! Renders markdown files with GitHub Flavored Markdown and Mermaid diagrams.
//! All assets are embedded - no CDN dependencies required.

const std = @import("std");
const serve = @import("../../serve/mod.zig");
const core = @import("../../core/mod.zig");

/// Configuration for the serve command
pub const ServeConfig = struct {
    root: []const u8,
    host: []const u8,
    port: u16,
    open_browser: bool,
    enable_index: bool,
};

/// Run the serve command
pub fn run(
    allocator: std.mem.Allocator,
    root_override: ?[]const u8,
    host_override: ?[]const u8,
    port_override: ?u16,
    open_browser: bool,
    no_index: bool,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    // Determine the root directory
    const root = blk: {
        if (root_override) |r| {
            break :blk r;
        }
        // Default to ./art if it exists, otherwise current directory
        if (core.fs.dirExists("art")) {
            break :blk "art";
        }
        break :blk ".";
    };

    // Verify root exists
    if (!core.fs.dirExists(root)) {
        try stderr.print("error: directory '{s}' does not exist\n", .{root});
        return 1;
    }

    const config = ServeConfig{
        .root = root,
        .host = host_override orelse "127.0.0.1",
        .port = port_override orelse 8777,
        .open_browser = open_browser,
        .enable_index = !no_index,
    };

    try stdout.print("Serving markdown from: {s}\n", .{config.root});
    try stdout.print("Server: http://{s}:{d}\n", .{ config.host, config.port });
    try stdout.writeAll("Press Ctrl+C to stop\n\n");

    // Start the server (blocks until interrupted)
    serve.startServer(allocator, config, stdout, stderr) catch |err| {
        try stderr.print("error: server failed: {}\n", .{err});
        return 1;
    };

    return 0;
}
