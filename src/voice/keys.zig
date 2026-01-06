//! Terminal key handling for pause/cancel controls.

const std = @import("std");
const build_options = @import("build_options");

const c = if (build_options.voice) @cImport({
    @cInclude("termios.h");
}) else struct {};

pub const KeyEvent = enum {
    none,
    stop,
    toggle_pause,
};

pub const Warning = enum {
    not_tty,
    termios_failed,
    nonblocking_failed,
};

pub const KeyInit = struct {
    reader: KeyReader,
    warning: ?Warning,
};

pub const KeyReader = struct {
    fd: std.posix.fd_t,
    orig_termios: std.posix.termios,
    orig_flags: usize,
    available: bool,

    pub fn init() KeyInit {
        const vmin_index: usize = if (build_options.voice) @intCast(c.VMIN) else 6;
        const vtime_index: usize = if (build_options.voice) @intCast(c.VTIME) else 5;
        const fd = std.posix.STDIN_FILENO;
        if (!std.posix.isatty(fd)) {
            return .{ .reader = .{ .fd = fd, .orig_termios = undefined, .orig_flags = 0, .available = false }, .warning = .not_tty };
        }

        const termios = std.posix.tcgetattr(fd) catch {
            return .{ .reader = .{ .fd = fd, .orig_termios = undefined, .orig_flags = 0, .available = false }, .warning = .termios_failed };
        };

        var raw = termios;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.cc[vmin_index] = 0;
        raw.cc[vtime_index] = 0;

        std.posix.tcsetattr(fd, .FLUSH, raw) catch {
            return .{ .reader = .{ .fd = fd, .orig_termios = undefined, .orig_flags = 0, .available = false }, .warning = .termios_failed };
        };

        const flags = std.posix.fcntl(fd, std.posix.F.GETFL, 0) catch {
            _ = std.posix.tcsetattr(fd, .FLUSH, termios) catch {};
            return .{ .reader = .{ .fd = fd, .orig_termios = undefined, .orig_flags = 0, .available = false }, .warning = .nonblocking_failed };
        };

        const nonblock_flag: usize = @intCast(@as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));
        _ = std.posix.fcntl(fd, std.posix.F.SETFL, flags | nonblock_flag) catch {
            _ = std.posix.tcsetattr(fd, .FLUSH, termios) catch {};
            return .{ .reader = .{ .fd = fd, .orig_termios = undefined, .orig_flags = 0, .available = false }, .warning = .nonblocking_failed };
        };

        return .{ .reader = .{ .fd = fd, .orig_termios = termios, .orig_flags = flags, .available = true }, .warning = null };
    }

    pub fn deinit(self: *KeyReader) void {
        if (!self.available) return;
        _ = std.posix.tcsetattr(self.fd, .FLUSH, self.orig_termios) catch {};
        _ = std.posix.fcntl(self.fd, std.posix.F.SETFL, self.orig_flags) catch {};
    }

    pub fn poll(self: *KeyReader) KeyEvent {
        if (!self.available) return .none;

        var fds = [_]std.posix.pollfd{.{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, 0) catch return .none;
        if (ready <= 0) return .none;
        if (fds[0].revents & std.posix.POLL.IN == 0) return .none;

        var buffer: [8]u8 = undefined;
        const amt = std.posix.read(self.fd, &buffer) catch |err| switch (err) {
            error.WouldBlock => return .none,
            else => return .none,
        };

        for (buffer[0..amt]) |byte| {
            if (byte == 27 or byte == '\n' or byte == '\r') return .stop;
            if (byte == ' ') return .toggle_pause;
        }

        return .none;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "KeyReader init compiles" {
    _ = KeyReader.init;
}
