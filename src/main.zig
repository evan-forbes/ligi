//! Ligi CLI entry point.

const std = @import("std");
const cli = @import("cli/mod.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Zig 0.15+ uses buffered I/O
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    // Collect arguments (skip program name)
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Zig 0.15 ArrayList uses .empty and passes allocator to methods
    var arg_list: std.ArrayList([]const u8) = .empty;
    defer arg_list.deinit(allocator);

    // Skip program name
    _ = args.next();

    while (args.next()) |arg| {
        try arg_list.append(allocator, arg);
    }

    const exit_code = try cli.run(allocator, arg_list.items, stdout, stderr);

    // Flush output
    try stdout.flush();
    try stderr.flush();

    if (exit_code != 0) {
        std.process.exit(exit_code);
    }
}

test "main module compiles" {
    _ = cli;
}
