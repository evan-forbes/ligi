//! whisper.cpp inference wrapper.

const std = @import("std");
const build_options = @import("build_options");

const c = if (build_options.voice) @cImport({
    @cInclude("whisper.h");
}) else struct {};

pub const TranscribeResult = union(enum) {
    ok: []const u8,
    err: []const u8,
};

const Impl = if (build_options.voice) struct {
    const StderrRedirect = struct {
        original_fd: ?std.posix.fd_t,

        fn init() StderrRedirect {
            const dev_null = std.posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch return .{ .original_fd = null };
            const original = std.posix.dup(std.posix.STDERR_FILENO) catch {
                std.posix.close(dev_null);
                return .{ .original_fd = null };
            };
            _ = std.posix.dup2(dev_null, std.posix.STDERR_FILENO) catch {};
            std.posix.close(dev_null);
            return .{ .original_fd = original };
        }

        fn restore(self: *StderrRedirect) void {
            if (self.original_fd) |fd| {
                _ = std.posix.dup2(fd, std.posix.STDERR_FILENO) catch {};
                std.posix.close(fd);
                self.original_fd = null;
            }
        }
    };

    pub fn transcribe(
        allocator: std.mem.Allocator,
        model_path: []const u8,
        samples: []const i16,
        sample_rate: u32,
        english_only: bool,
    ) TranscribeResult {
        if (sample_rate != 16_000) return .{ .err = "unsupported sample rate" };
        if (samples.len == 0) return .{ .ok = "" };

        const model_cstr = allocator.dupeZ(u8, model_path) catch {
            return .{ .err = "invalid model path" };
        };
        defer allocator.free(model_cstr);

        // Suppress whisper.cpp verbose output by redirecting stderr
        var stderr_redirect = StderrRedirect.init();
        defer stderr_redirect.restore();

        const ctx = c.whisper_init_from_file(model_cstr.ptr) orelse {
            return .{ .err = "failed to load model" };
        };
        defer c.whisper_free(ctx);

        var params = c.whisper_full_default_params(c.WHISPER_SAMPLING_GREEDY);
        params.print_progress = false;
        params.print_realtime = false;
        params.print_timestamps = false;
        params.print_special = false;
        params.no_timestamps = true;
        params.translate = false;
        params.language = if (english_only) "en" else null;

        const cpu_count = std.Thread.getCpuCount() catch 1;
        params.n_threads = @intCast(cpu_count);

        const float_samples = allocator.alloc(f32, samples.len) catch {
            return .{ .err = "out of memory" };
        };
        defer allocator.free(float_samples);

        for (samples, 0..) |sample, idx| {
            float_samples[idx] = @as(f32, @floatFromInt(sample)) / 32768.0;
        }

        const res = c.whisper_full(ctx, params, float_samples.ptr, @intCast(float_samples.len));
        if (res != 0) return .{ .err = "whisper inference failed" };

        const segments = c.whisper_full_n_segments(ctx);
        if (segments <= 0) return .{ .ok = "" };

        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);

        var i: c_int = 0;
        while (i < segments) : (i += 1) {
            const segment_text = c.whisper_full_get_segment_text(ctx, i);
            if (segment_text == null) continue;
            const slice = std.mem.span(segment_text);
            text.appendSlice(allocator, slice) catch return .{ .err = "out of memory" };
        }

        const owned = text.toOwnedSlice(allocator) catch return .{ .err = "out of memory" };
        return .{ .ok = owned };
    }
} else struct {
    pub fn transcribe(
        allocator: std.mem.Allocator,
        model_path: []const u8,
        samples: []const i16,
        sample_rate: u32,
        english_only: bool,
    ) TranscribeResult {
        _ = allocator;
        _ = model_path;
        _ = samples;
        _ = sample_rate;
        _ = english_only;
        return .{ .err = "voice support not built" };
    }
};

pub const transcribe = Impl.transcribe;

// ============================================================================
// Tests
// ============================================================================

test "transcribe symbol compiles" {
    _ = transcribe;
}
