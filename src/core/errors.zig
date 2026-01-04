//! Error types with context chain for rich error reporting.

const std = @import("std");

/// Error categories for exit codes
pub const ErrorCategory = enum(u8) {
    success = 0,
    usage = 1, // Bad arguments
    filesystem = 2, // File/dir operations failed
    config = 3, // Config parse/write failed
    internal = 127, // Bug in ligi
};

/// A link in the error context chain
pub const ErrorContext = struct {
    message: []const u8,
    source: ?*const ErrorContext = null,

    pub fn format(
        self: ErrorContext,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.writeAll(self.message);
        if (self.source) |src| {
            try writer.writeAll(": ");
            try src.format("", .{}, writer);
        }
    }
};

/// Rich error with category and context chain
pub const LigiError = struct {
    category: ErrorCategory,
    context: ErrorContext,

    const Self = @This();

    pub fn filesystem(message: []const u8, cause: ?*const ErrorContext) Self {
        return .{
            .category = .filesystem,
            .context = .{ .message = message, .source = cause },
        };
    }

    pub fn config(message: []const u8, cause: ?*const ErrorContext) Self {
        return .{
            .category = .config,
            .context = .{ .message = message, .source = cause },
        };
    }

    pub fn usage(message: []const u8) Self {
        return .{
            .category = .usage,
            .context = .{ .message = message },
        };
    }

    /// Format full error chain for display
    pub fn write(self: Self, writer: anytype) !void {
        try writer.writeAll("error: ");
        try self.context.format("", .{}, writer);
        try writer.writeAll("\n");
    }

    pub fn exitCode(self: Self) u8 {
        return @intFromEnum(self.category);
    }
};

/// Result type for operations that can fail with context
pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: LigiError,

        const Self = @This();

        pub fn unwrap(self: Self) error{LigiError}!T {
            return switch (self) {
                .ok => |v| v,
                .err => error.LigiError,
            };
        }

        pub fn isOk(self: Self) bool {
            return switch (self) {
                .ok => true,
                .err => false,
            };
        }

        pub fn isErr(self: Self) bool {
            return !self.isOk();
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "ErrorContext formats single message" {
    const ctx = ErrorContext{ .message = "something failed" };
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try ctx.format("", .{}, stream.writer());
    try std.testing.expectEqualStrings("something failed", stream.getWritten());
}

test "ErrorContext formats chain of two messages" {
    const inner = ErrorContext{ .message = "inner error" };
    const outer = ErrorContext{ .message = "outer error", .source = &inner };
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try outer.format("", .{}, stream.writer());
    try std.testing.expectEqualStrings("outer error: inner error", stream.getWritten());
}

test "ErrorContext formats chain of three messages" {
    const innermost = ErrorContext{ .message = "root cause" };
    const middle = ErrorContext{ .message = "middle layer", .source = &innermost };
    const outer = ErrorContext{ .message = "top level", .source = &middle };
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try outer.format("", .{}, stream.writer());
    try std.testing.expectEqualStrings("top level: middle layer: root cause", stream.getWritten());
}

test "LigiError.filesystem sets category to filesystem" {
    const err = LigiError.filesystem("test error", null);
    try std.testing.expectEqual(ErrorCategory.filesystem, err.category);
}

test "LigiError.config sets category to config" {
    const err = LigiError.config("test error", null);
    try std.testing.expectEqual(ErrorCategory.config, err.category);
}

test "LigiError.usage sets category to usage" {
    const err = LigiError.usage("test error");
    try std.testing.expectEqual(ErrorCategory.usage, err.category);
}

test "exitCode returns correct value for each category" {
    try std.testing.expectEqual(@as(u8, 0), (LigiError{ .category = .success, .context = .{ .message = "" } }).exitCode());
    try std.testing.expectEqual(@as(u8, 1), LigiError.usage("").exitCode());
    try std.testing.expectEqual(@as(u8, 2), LigiError.filesystem("", null).exitCode());
    try std.testing.expectEqual(@as(u8, 3), LigiError.config("", null).exitCode());
}

test "Result isOk and isErr work correctly" {
    const ok_result: Result(i32) = .{ .ok = 42 };
    const err_result: Result(i32) = .{ .err = LigiError.usage("error") };

    try std.testing.expect(ok_result.isOk());
    try std.testing.expect(!ok_result.isErr());
    try std.testing.expect(!err_result.isOk());
    try std.testing.expect(err_result.isErr());
}
