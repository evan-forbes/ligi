//! The `ligi globalize` command implementation.
//!
//! Copies local ligi assets (art/, template/, data/, media/) to the global
//! ~/.ligi directory, making them accessible across all ligi repositories.

const std = @import("std");
const core = @import("../../core/mod.zig");
const paths = core.paths;
const fs = core.fs;
const errors = core.errors;
const Io = std.Io;

/// Result of a single file globalization
pub const GlobalizeResult = union(enum) {
    success: struct {
        source: []const u8,
        dest: []const u8,
    },
    skipped: []const u8, // user declined overwrite
    err: errors.LigiError,
};

/// User's overwrite choice
pub const OverwriteChoice = enum {
    yes,
    no,
    yes_all,
    no_all,
};

/// Exit codes for the globalize command
pub const ExitCode = enum(u8) {
    success = 0,
    err = 1,
    aborted = 2,
};

/// Run the globalize command
pub fn run(
    allocator: std.mem.Allocator,
    file_paths: []const []const u8,
    force: bool,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    // Need at least one path
    if (file_paths.len == 0) {
        try stderr.writeAll("error: no paths specified\n");
        try stderr.writeAll("usage: ligi globalize <path>... [-f|--force]\n");
        return @intFromEnum(ExitCode.err);
    }

    // Get global root
    const global_root = switch (paths.getGlobalRoot(allocator)) {
        .ok => |p| p,
        .err => |e| {
            try e.write(stderr);
            try stderr.writeAll("hint: run 'ligi init --global' first\n");
            return e.exitCode();
        },
    };
    defer allocator.free(global_root);

    // Verify global root exists
    if (!fs.dirExists(global_root)) {
        try stderr.print("error: global ligi directory not found: {s}\n", .{global_root});
        try stderr.writeAll("hint: run 'ligi init --global' first\n");
        return @intFromEnum(ExitCode.err);
    }

    // Track overwrite-all choice across files
    var overwrite_all: ?bool = if (force) true else null;
    var had_errors = false;
    var all_skipped = true;

    for (file_paths) |source_path| {
        const result = globalizeSingleFile(
            allocator,
            source_path,
            global_root,
            &overwrite_all,
            stdout,
            stderr,
        ) catch |err| {
            try stderr.print("error: failed to process '{s}': {s}\n", .{ source_path, @errorName(err) });
            had_errors = true;
            continue;
        };

        switch (result) {
            .success => {
                // Success message already printed in globalizeSingleFile
                all_skipped = false;
            },
            .skipped => |path| {
                try stdout.print("Skipped {s}\n", .{path});
            },
            .err => |e| {
                try e.write(stderr);
                had_errors = true;
            },
        }

        // Check if user chose no-all (abort)
        if (overwrite_all) |choice| {
            if (!choice and !force) {
                // no-all was chosen, but we only set this when it happens
                // Actually we track yes_all/no_all differently...
                // no_all means don't prompt anymore, skip all
            }
        }
    }

    if (had_errors) {
        return @intFromEnum(ExitCode.err);
    }
    return @intFromEnum(ExitCode.success);
}

/// Globalize a single file, returns success message or error
fn globalizeSingleFile(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    global_root: []const u8,
    overwrite_all: *?bool,
    stdout: anytype,
    stderr: anytype,
) !GlobalizeResult {
    // Validate source path
    if (std.fs.path.isAbsolute(source_path)) {
        return .{ .err = errors.LigiError.usage("absolute paths not allowed; use relative path from repo root") };
    }

    // Check for directory traversal
    if (std.mem.indexOf(u8, source_path, "..") != null) {
        return .{ .err = errors.LigiError.usage("path traversal (..) not allowed") };
    }

    // Check source exists
    if (!fs.fileExists(source_path)) {
        return .{ .err = errors.LigiError.filesystem("source file not found", null) };
    }

    // Build destination path: global_root + source_path
    const dest_path = try paths.joinPath(allocator, &.{ global_root, source_path });

    // Check if destination exists
    const dest_exists = fs.fileExists(dest_path);

    if (dest_exists) {
        // Handle overwrite logic
        if (overwrite_all.*) |choice| {
            if (!choice) {
                // User chose no-all, skip
                allocator.free(dest_path);
                return .{ .skipped = source_path };
            }
            // User chose yes-all, continue to copy
        } else {
            // Prompt user
            try stdout.print("File exists: {s}\n", .{dest_path});
            const choice = promptOverwrite(stdout, stderr) catch |err| {
                allocator.free(dest_path);
                if (err == error.EndOfStream or err == error.Aborted) {
                    return .{ .err = errors.LigiError.usage("aborted by user") };
                }
                return err;
            };

            switch (choice) {
                .yes => {}, // continue to copy
                .no => {
                    allocator.free(dest_path);
                    return .{ .skipped = source_path };
                },
                .yes_all => overwrite_all.* = true,
                .no_all => {
                    overwrite_all.* = false;
                    allocator.free(dest_path);
                    return .{ .skipped = source_path };
                },
            }
        }
    }

    // Ensure destination directory exists
    const dest_dir = std.fs.path.dirname(dest_path) orelse ".";
    switch (fs.ensureDirRecursive(dest_dir)) {
        .ok => {},
        .err => |e| {
            allocator.free(dest_path);
            return .{ .err = e };
        },
    }

    // Copy the file
    copyFile(source_path, dest_path) catch {
        allocator.free(dest_path);
        return .{ .err = errors.LigiError.filesystem("failed to copy file", null) };
    };

    // Print success message here while we still have dest_path
    try stdout.print("Copied {s} -> {s}\n", .{ source_path, dest_path });
    allocator.free(dest_path);

    // Return success indicator (paths already printed)
    return .{ .success = .{
        .source = source_path,
        .dest = source_path, // Not used, just a placeholder
    } };
}

/// Prompt user for overwrite confirmation
fn promptOverwrite(stdout: anytype, stderr: anytype) !OverwriteChoice {
    _ = stderr;
    try stdout.writeAll("Overwrite? [y/n/Y(es all)/N(o all)]: ");

    // Read from stdin using Zig 0.15 API
    var stdin_buf: [64]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);

    const input = stdin_reader.interface.takeDelimiter('\n') catch return error.EndOfStream;
    if (input == null) return error.EndOfStream;

    const trimmed = std.mem.trim(u8, input.?, " \t\r\n");

    if (trimmed.len == 0) {
        return .no; // Default to no
    }

    if (std.mem.eql(u8, trimmed, "y") or std.mem.eql(u8, trimmed, "yes")) {
        return .yes;
    } else if (std.mem.eql(u8, trimmed, "n") or std.mem.eql(u8, trimmed, "no")) {
        return .no;
    } else if (std.mem.eql(u8, trimmed, "Y")) {
        return .yes_all;
    } else if (std.mem.eql(u8, trimmed, "N")) {
        return .no_all;
    }

    return .no; // Default to no for unrecognized input
}

/// Copy a file from source to destination
fn copyFile(source: []const u8, dest: []const u8) !void {
    const cwd = std.fs.cwd();
    try cwd.copyFile(source, cwd, dest, .{});
}

// ============================================================================
// Tests
// ============================================================================

test "GlobalizeResult union types" {
    const success: GlobalizeResult = .{ .success = .{ .source = "a", .dest = "b" } };
    const skipped: GlobalizeResult = .{ .skipped = "path" };
    const err_result: GlobalizeResult = .{ .err = errors.LigiError.usage("test") };

    switch (success) {
        .success => |s| {
            try std.testing.expectEqualStrings("a", s.source);
            try std.testing.expectEqualStrings("b", s.dest);
        },
        else => unreachable,
    }

    switch (skipped) {
        .skipped => |p| try std.testing.expectEqualStrings("path", p),
        else => unreachable,
    }

    switch (err_result) {
        .err => |e| try std.testing.expectEqual(errors.ErrorCategory.usage, e.category),
        else => unreachable,
    }
}

test "OverwriteChoice enum values" {
    const yes = OverwriteChoice.yes;
    const no = OverwriteChoice.no;
    const yes_all = OverwriteChoice.yes_all;
    const no_all = OverwriteChoice.no_all;

    try std.testing.expect(yes == .yes);
    try std.testing.expect(no == .no);
    try std.testing.expect(yes_all == .yes_all);
    try std.testing.expect(no_all == .no_all);
}

test "ExitCode values match spec" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(ExitCode.success));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(ExitCode.err));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(ExitCode.aborted));
}

test "copyFile copies content correctly" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create source file
    const source_content = "Hello, globalize test!";
    try tmp_dir.dir.writeFile(.{ .sub_path = "source.txt", .data = source_content });

    // Copy using Dir.copyFile
    try tmp_dir.dir.copyFile("source.txt", tmp_dir.dir, "dest.txt", .{});

    // Read back and verify
    const dest_content = try tmp_dir.dir.readFileAlloc(std.testing.allocator, "dest.txt", 1024);
    defer std.testing.allocator.free(dest_content);

    try std.testing.expectEqualStrings(source_content, dest_content);
}
