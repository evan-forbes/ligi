//! Model download and cache handling.

const std = @import("std");
const models = @import("models.zig");

pub const ModelError = union(enum) {
    missing_no_download,
    download_failed: []const u8,
};

pub const ModelResult = union(enum) {
    ok: []const u8,
    err: ModelError,
};

pub const ModelRequest = struct {
    size: models.ModelSize,
    allow_download: bool,
    explicit_path: ?[]const u8 = null,
};

pub fn ensureModel(allocator: std.mem.Allocator, request: ModelRequest) ModelResult {
    if (request.explicit_path) |path| {
        if (fileExists(path)) return .{ .ok = path };
        return .{ .err = .missing_no_download };
    }

    const entry = models.entryFor(request.size);
    const cache_dir = getCacheDir(allocator) catch return .{ .err = .{ .download_failed = "cache dir unavailable" } };
    defer allocator.free(cache_dir);

    std.fs.cwd().makePath(cache_dir) catch return .{ .err = .{ .download_failed = "failed to create cache directory" } };

    const model_path = std.fs.path.join(allocator, &.{ cache_dir, entry.filename }) catch {
        return .{ .err = .{ .download_failed = "failed to build model path" } };
    };

    if (!fileExists(model_path)) {
        if (!request.allow_download) {
            allocator.free(model_path);
            return .{ .err = .missing_no_download };
        }
        const dl_res = downloadModel(allocator, entry, model_path);
        switch (dl_res) {
            .ok => return .{ .ok = model_path },
            .err => |err| {
                allocator.free(model_path);
                return .{ .err = err };
            },
        }
    }

    return .{ .ok = model_path };
}

fn fileExists(path: []const u8) bool {
    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}

fn getCacheDir(allocator: std.mem.Allocator) ![]const u8 {
    if (std.posix.getenv("XDG_CACHE_HOME")) |xdg| {
        return std.fs.path.join(allocator, &.{ xdg, "ligi", "whisper" });
    }
    const home = std.posix.getenv("HOME") orelse return error.MissingHome;
    return std.fs.path.join(allocator, &.{ home, ".cache", "ligi", "whisper" });
}

const DownloadResult = union(enum) {
    ok,
    err: ModelError,
};

fn downloadModel(allocator: std.mem.Allocator, entry: models.ModelEntry, dest_path: []const u8) DownloadResult {
    const url = std.fmt.allocPrint(allocator, "{s}/{s}", .{ models.base_url, entry.filename }) catch {
        return .{ .err = .{ .download_failed = "failed to build download URL" } };
    };
    defer allocator.free(url);

    const tmp_path = std.fmt.allocPrint(allocator, "{s}.part", .{dest_path}) catch {
        return .{ .err = .{ .download_failed = "failed to build temp path" } };
    };
    defer allocator.free(tmp_path);

    if (fetchToFile(allocator, url, tmp_path)) |err_msg| {
        std.fs.cwd().deleteFile(tmp_path) catch {};
        return .{ .err = .{ .download_failed = err_msg } };
    }

    std.fs.cwd().rename(tmp_path, dest_path) catch {
        std.fs.cwd().deleteFile(tmp_path) catch {};
        return .{ .err = .{ .download_failed = "failed to finalize download" } };
    };

    return .ok;
}

fn fetchToFile(allocator: std.mem.Allocator, url: []const u8, dest_path: []const u8) ?[]const u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var file = std.fs.cwd().createFile(dest_path, .{}) catch return "failed to create temp file";
    defer file.close();

    var buffer: [16 * 1024]u8 = undefined;
    var writer = file.writer(&buffer);
    const res = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &writer.interface,
    }) catch return "http fetch failed";

    if (res.status.class() != .success) {
        return "http status not successful";
    }

    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "model size entries are unique" {
    var seen = std.AutoHashMap(models.ModelSize, void).init(std.testing.allocator);
    defer seen.deinit();

    for (models.model_entries) |entry| {
        const res = try seen.getOrPut(entry.size);
        try std.testing.expect(!res.found_existing);
    }
}
