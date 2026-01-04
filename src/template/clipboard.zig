//! Clipboard support - copies text to system clipboard.

const std = @import("std");

pub fn copy(allocator: std.mem.Allocator, text: []const u8) !void {
    const commands = &[_][]const []const u8{
        &.{"wl-copy"},
        &.{ "xclip", "-selection", "clipboard" },
        &.{ "xsel", "-b" },
    };

    for (commands) |argv| {
        var child = std.process.Child.init(argv, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        child.spawn() catch continue;

        if (child.stdin) |stdin| {
            // Write to stdin.
            stdin.writeAll(text) catch {
                _ = child.kill() catch {};
                continue;
            };
            stdin.close();
            child.stdin = null;
        }

        const term = child.wait() catch continue;
        switch (term) {
            .Exited => |code| {
                if (code == 0) return; // Success!
            },
            else => {},
        }
    }

    return error.ClipboardCopyFailed;
}

test "clipboard basic" {
    // Hard to test in CI/headless without tools.
    // We can just assert that it compiles and maybe returns error if no tools.
    copy(std.testing.allocator, "test") catch {};
}
