//! Help text formatting utilities.

const std = @import("std");

/// Format a usage line
pub fn formatUsage(writer: anytype, command: []const u8, synopsis: []const u8) !void {
    try writer.print("Usage: ligi {s} {s}\n", .{ command, synopsis });
}

/// Format a section with title and content
pub fn formatSection(writer: anytype, title: []const u8, content: []const u8) !void {
    try writer.print("\n{s}:\n{s}\n", .{ title, content });
}

/// Format a flag with short and long forms
pub fn formatFlag(writer: anytype, short: ?u8, long: []const u8, desc: []const u8) !void {
    if (short) |s| {
        try writer.print("  -{c}, --{s:<12} {s}\n", .{ s, long, desc });
    } else {
        try writer.print("      --{s:<12} {s}\n", .{ long, desc });
    }
}

// ============================================================================
// Tests
// ============================================================================

test "formatUsage produces correct format" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try formatUsage(stream.writer(), "init", "[options]");
    try std.testing.expectEqualStrings("Usage: ligi init [options]\n", stream.getWritten());
}

test "formatSection includes title and content" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try formatSection(stream.writer(), "Options", "  -h  help");
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Options:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-h  help") != null);
}

test "formatFlag handles short and long forms" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try formatFlag(stream.writer(), 'h', "help", "Show help");
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "-h") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--help") != null);
}

test "formatFlag handles long form only" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try formatFlag(stream.writer(), null, "verbose", "Be verbose");
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "--verbose") != null);
}
