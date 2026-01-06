//! ALSA audio capture for Linux.

const std = @import("std");
const build_options = @import("build_options");
const keys = @import("keys.zig");

const c = if (build_options.voice) @cImport({
    @cInclude("alsa/asoundlib.h");
}) else struct {};

pub const AudioBuffer = struct {
    samples: []i16,
    sample_rate: u32,
    duration_ms: u64,
};

pub const AudioError = union(enum) {
    canceled,
    init_failed: []const u8,
    capture_failed: []const u8,
};

pub const AudioResult = union(enum) {
    ok: AudioBuffer,
    err: AudioError,
};

pub const RecordOptions = struct {
    timeout_ms: u64,
    sample_rate: u32 = 16_000,
    device: []const u8 = "default",
};

const Impl = if (build_options.voice) struct {
    pub fn record(
        allocator: std.mem.Allocator,
        options: RecordOptions,
        key_reader: ?*keys.KeyReader,
        cancel_flag: *const std.atomic.Value(bool),
    ) AudioResult {
        const sample_rate = options.sample_rate;
        const max_frames = maxFrames(options.timeout_ms, sample_rate) orelse {
            return .{ .err = .{ .capture_failed = "invalid timeout" } };
        };

        const device_cstr = allocator.dupeZ(u8, options.device) catch {
            return .{ .err = .{ .init_failed = "invalid device" } };
        };
        defer allocator.free(device_cstr);

        var handle: ?*c.snd_pcm_t = null;
        const open_res = c.snd_pcm_open(&handle, device_cstr.ptr, c.SND_PCM_STREAM_CAPTURE, 0);
        if (open_res < 0) {
            return .{ .err = .{ .init_failed = std.mem.span(c.snd_strerror(open_res)) } };
        }
        const pcm = handle.?;
        defer _ = c.snd_pcm_close(pcm);

        const set_res = c.snd_pcm_set_params(
            pcm,
            c.SND_PCM_FORMAT_S16_LE,
            c.SND_PCM_ACCESS_RW_INTERLEAVED,
            1,
            sample_rate,
            1,
            500_000,
        );
        if (set_res < 0) {
            return .{ .err = .{ .init_failed = std.mem.span(c.snd_strerror(set_res)) } };
        }

        var samples: std.ArrayList(i16) = .empty;
        defer samples.deinit(allocator);

        const frames_per_read: usize = 1024;
        var buffer: [frames_per_read]i16 = undefined;

        var recorded_frames: u64 = 0;
        var paused = false;

        while (recorded_frames < max_frames) {
            if (cancel_flag.load(.acquire)) return .{ .err = .canceled };

            if (key_reader) |reader| {
                switch (reader.poll()) {
                    .stop => break,
                    .toggle_pause => paused = !paused,
                    .none => {},
                }
            }

            const read_res = readFrames(pcm, buffer[0..]);
            const frames_read = switch (read_res) {
                .ok => |count| count,
                .err => |err_msg| return .{ .err = .{ .capture_failed = err_msg } },
            };
            if (frames_read == 0) continue;
            if (paused) continue;

            const remaining = max_frames - recorded_frames;
            const keep = if (frames_read > remaining) remaining else frames_read;
            if (keep == 0) break;

            const samples_len = @as(usize, @intCast(keep));
            samples.appendSlice(allocator, buffer[0..samples_len]) catch return .{ .err = .{ .capture_failed = "out of memory" } };
            recorded_frames += keep;
        }

        const duration_ms = (recorded_frames * 1000) / sample_rate;
        const owned = samples.toOwnedSlice(allocator) catch return .{ .err = .{ .capture_failed = "out of memory" } };
        return .{ .ok = .{ .samples = owned, .sample_rate = sample_rate, .duration_ms = duration_ms } };
    }

    const ReadResult = union(enum) {
        ok: u64,
        err: []const u8,
    };

    fn readFrames(handle: *c.snd_pcm_t, buffer: []i16) ReadResult {
        const frames = @as(c.snd_pcm_uframes_t, @intCast(buffer.len));
        const res = c.snd_pcm_readi(handle, buffer.ptr, frames);
        if (res >= 0) return .{ .ok = @as(u64, @intCast(res)) };

        const recovered = c.snd_pcm_recover(handle, @intCast(res), 0);
        if (recovered >= 0) return .{ .ok = 0 };

        return .{ .err = std.mem.span(c.snd_strerror(recovered)) };
    }
} else struct {
    pub fn record(
        allocator: std.mem.Allocator,
        options: RecordOptions,
        key_reader: ?*keys.KeyReader,
        cancel_flag: *const std.atomic.Value(bool),
    ) AudioResult {
        _ = allocator;
        _ = options;
        _ = key_reader;
        _ = cancel_flag;
        return .{ .err = .{ .init_failed = "voice support not built" } };
    }
};

pub const record = Impl.record;

fn maxFrames(timeout_ms: u64, sample_rate: u32) ?u64 {
    if (timeout_ms == 0) return null;
    const total = (@as(u128, timeout_ms) * sample_rate) / 1000;
    return @intCast(total);
}

// ============================================================================
// Tests
// ============================================================================

test "maxFrames handles basic values" {
    try std.testing.expectEqual(@as(u64, 16_000), maxFrames(1000, 16_000).?);
}
