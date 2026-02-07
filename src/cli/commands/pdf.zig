//! `ligi pdf` command implementation.

const std = @import("std");
const pdf = @import("../../pdf/mod.zig");

pub fn run(
    allocator: std.mem.Allocator,
    input_path: ?[]const u8,
    output_path: ?[]const u8,
    recursive: bool,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const input = input_path orelse {
        try stderr.writeAll("error: pdf: missing input markdown file\n");
        return 1;
    };

    return pdf.run(allocator, .{
        .input_path = input,
        .output_path = output_path,
        .recursive = recursive,
    }, stdout, stderr);
}

test "run returns error when input is missing" {
    const allocator = std.testing.allocator;
    var stderr_buf: [256]u8 = undefined;
    var stderr_stream = std.io.fixedBufferStream(&stderr_buf);

    const code = try run(
        allocator,
        null,
        null,
        false,
        stderr_stream.writer(),
        stderr_stream.writer(),
    );
    try std.testing.expectEqual(@as(u8, 1), code);
}
