//! The `ligi v` command implementation.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const voice = @import("../../voice/mod.zig");
const models = @import("../../voice/models.zig");
const clipboard = @import("../../template/clipboard.zig");

pub fn run(
    allocator: std.mem.Allocator,
    timeout: ?[]const u8,
    model_size: ?[]const u8,
    model_path: ?[]const u8,
    allow_download: bool,
    use_clipboard: bool,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    if (!build_options.voice) {
        try stderr.writeAll("error: voice: not built with voice support (rebuild with -Dvoice=true)\n");
        return 1;
    }

    if (builtin.os.tag != .linux) {
        try stderr.writeAll("error: voice: unsupported platform (linux-only)\n");
        return 1;
    }

    const timeout_ms = parseDuration(timeout orelse "10m") catch {
        if (timeout) |value| {
            try stderr.print("error: voice: invalid timeout '{s}'\n", .{value});
        } else {
            try stderr.writeAll("error: voice: invalid timeout\n");
        }
        return 2;
    };

    const size_value = model_size orelse "base.en";
    const size = models.parseModelSize(size_value) orelse {
        try stderr.print("error: voice: invalid model size '{s}'\n", .{size_value});
        return 2;
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const outcome = voice.run(arena_alloc, .{
        .timeout_ms = timeout_ms,
        .model_path = model_path,
        .model_size = size,
        .allow_download = allow_download,
    }, stderr);

    switch (outcome) {
        .ok => |result| {
            try stdout.print("{s}\n", .{result.text});
            if (use_clipboard) {
                clipboard.copy(arena_alloc, result.text) catch {
                    try stderr.writeAll("warning: failed to copy to clipboard\n");
                };
            }
            return 0;
        },
        .err => |err| return renderError(err, stderr),
    }
}

fn renderError(err: voice.VoiceError, stderr: anytype) u8 {
    switch (err) {
        .model_missing => {
            _ = stderr.writeAll("error: voice: model not found and download disabled\n") catch {};
            return 3;
        },
        .download_failed => |detail| {
            _ = stderr.print("error: voice: failed to download model: {s}\n", .{detail}) catch {};
            return 3;
        },
        .audio_init_failed => |detail| {
            _ = stderr.print("error: voice: audio capture init failed: {s}\n", .{detail}) catch {};
            return 4;
        },
        .audio_capture_failed => |detail| {
            _ = stderr.print("error: voice: audio capture failed: {s}\n", .{detail}) catch {};
            return 4;
        },
        .transcription_failed => |detail| {
            _ = stderr.print("error: voice: transcription failed: {s}\n", .{detail}) catch {};
            return 5;
        },
        .canceled => {
            _ = stderr.writeAll("Canceled.\n") catch {};
            return 130;
        },
    }
}

fn parseDuration(input: []const u8) !u64 {
    if (input.len < 2) return error.InvalidDuration;

    const unit = input[input.len - 1];
    const digits = input[0 .. input.len - 1];
    const value = std.fmt.parseInt(u64, digits, 10) catch return error.InvalidDuration;
    if (value == 0) return error.InvalidDuration;

    const multiplier: u64 = switch (unit) {
        's' => 1_000,
        'm' => 60 * 1_000,
        'h' => 60 * 60 * 1_000,
        else => return error.InvalidDuration,
    };

    return std.math.mul(u64, value, multiplier) catch return error.InvalidDuration;
}

// ============================================================================
// Tests
// ============================================================================

test "parseDuration supports suffixes" {
    try std.testing.expectEqual(@as(u64, 10_000), try parseDuration("10s"));
    try std.testing.expectEqual(@as(u64, 600_000), try parseDuration("10m"));
    try std.testing.expectEqual(@as(u64, 3_600_000), try parseDuration("1h"));
}

test "parseDuration rejects invalid input" {
    // Too short
    try std.testing.expectError(error.InvalidDuration, parseDuration(""));
    try std.testing.expectError(error.InvalidDuration, parseDuration("m"));

    // No suffix
    try std.testing.expectError(error.InvalidDuration, parseDuration("10"));
    try std.testing.expectError(error.InvalidDuration, parseDuration("100"));

    // Invalid suffix
    try std.testing.expectError(error.InvalidDuration, parseDuration("10x"));
    try std.testing.expectError(error.InvalidDuration, parseDuration("10M"));

    // Zero duration
    try std.testing.expectError(error.InvalidDuration, parseDuration("0s"));
    try std.testing.expectError(error.InvalidDuration, parseDuration("0m"));
    try std.testing.expectError(error.InvalidDuration, parseDuration("0h"));

    // Non-numeric
    try std.testing.expectError(error.InvalidDuration, parseDuration("abcs"));
    try std.testing.expectError(error.InvalidDuration, parseDuration("-5m"));
}

test "parseDuration rejects overflow" {
    // This would overflow u64 when multiplied by 3_600_000
    try std.testing.expectError(error.InvalidDuration, parseDuration("99999999999999999h"));
}
