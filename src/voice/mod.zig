//! Voice subsystem entry point.

const std = @import("std");
const audio = @import("audio.zig");
const download = @import("download.zig");
const keys = @import("keys.zig");
const models = @import("models.zig");
const whisper = @import("whisper.zig");

pub const ModelSize = models.ModelSize;

pub const VoiceOptions = struct {
    timeout_ms: u64,
    model_path: ?[]const u8,
    model_size: ModelSize,
    allow_download: bool,
};

pub const VoiceResult = struct {
    text: []const u8,
    duration_ms: u64,
};

pub const VoiceError = union(enum) {
    model_missing,
    download_failed: []const u8,
    audio_init_failed: []const u8,
    audio_capture_failed: []const u8,
    transcription_failed: []const u8,
    canceled,
};

pub const VoiceOutcome = union(enum) {
    ok: VoiceResult,
    err: VoiceError,
};

pub fn run(allocator: std.mem.Allocator, options: VoiceOptions, stderr: anytype) VoiceOutcome {
    const model_path_res = download.ensureModel(allocator, .{
        .size = options.model_size,
        .allow_download = options.allow_download,
        .explicit_path = options.model_path,
    });
    const model_path = switch (model_path_res) {
        .ok => |path| path,
        .err => |err| return .{ .err = mapModelError(err) },
    };

    var key_init = keys.KeyReader.init();
    defer key_init.reader.deinit();

    if (key_init.warning != null) {
        _ = stderr.writeAll("warning: voice: raw key controls unavailable; only Ctrl+C will cancel\n") catch {};
    }

    var cancel_flag = std.atomic.Value(bool).init(false);
    var sig_guard = installSigintHandler(&cancel_flag);
    defer sig_guard.deinit();

    const key_reader = if (key_init.reader.available) &key_init.reader else null;

    _ = stderr.writeAll("Recording... (Enter/Esc to stop, Space to pause, Ctrl+C to cancel)\n") catch {};
    _ = stderr.flush() catch {};

    const audio_res = audio.record(allocator, .{
        .timeout_ms = options.timeout_ms,
    }, key_reader, &cancel_flag);
    const audio_buf = switch (audio_res) {
        .ok => |buf| buf,
        .err => |err| return .{ .err = mapAudioError(err) },
    };

    if (audio_buf.samples.len == 0) {
        _ = stderr.writeAll("No audio recorded.\n") catch {};
        return .{ .ok = .{ .text = "", .duration_ms = 0 } };
    }

    _ = stderr.writeAll("Transcribing...\n") catch {};

    const english_only = models.isEnglishOnly(options.model_size);
    const transcribe_res = whisper.transcribe(allocator, model_path, audio_buf.samples, audio_buf.sample_rate, english_only);
    const text = switch (transcribe_res) {
        .ok => |result| result,
        .err => |detail| return .{ .err = .{ .transcription_failed = detail } },
    };

    return .{ .ok = .{ .text = text, .duration_ms = audio_buf.duration_ms } };
}

fn mapModelError(err: download.ModelError) VoiceError {
    return switch (err) {
        .missing_no_download => .model_missing,
        .download_failed => |detail| .{ .download_failed = detail },
    };
}

fn mapAudioError(err: audio.AudioError) VoiceError {
    return switch (err) {
        .canceled => .canceled,
        .init_failed => |detail| .{ .audio_init_failed = detail },
        .capture_failed => |detail| .{ .audio_capture_failed = detail },
    };
}

var sigint_target: ?*std.atomic.Value(bool) = null;

fn handleSigint(_: i32) callconv(.c) void {
    if (sigint_target) |target| target.store(true, .release);
}

const SigGuard = struct {
    previous: std.posix.Sigaction,
    installed: bool,

    fn deinit(self: *SigGuard) void {
        if (!self.installed) return;
        std.posix.sigaction(std.posix.SIG.INT, &self.previous, null);
        sigint_target = null;
    }
};

fn installSigintHandler(cancel_flag: *std.atomic.Value(bool)) SigGuard {
    sigint_target = cancel_flag;
    var action = std.posix.Sigaction{
        .handler = .{ .handler = handleSigint },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var previous: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.INT, &action, &previous);
    return .{ .previous = previous, .installed = true };
}

// ============================================================================
// Tests
// ============================================================================

test "voice module compiles" {
    _ = run;
}
