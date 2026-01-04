//! The `ligi backup` command implementation.
//!
//! Runs a git backup of the global ~/.ligi repo and can install a cron job.

const std = @import("std");
const core = @import("../../core/mod.zig");
const paths = core.paths;
const fs = core.fs;

pub const DEFAULT_CRON_SCHEDULE = "0 3 * * *";
pub const CRON_MARKER = "# ligi-backup";

/// Run the backup command
pub fn run(
    allocator: std.mem.Allocator,
    install_cron: bool,
    schedule: ?[]const u8,
    quiet: bool,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const global_root = switch (paths.getGlobalRoot(allocator)) {
        .ok => |p| p,
        .err => |e| {
            try e.write(stderr);
            return e.exitCode();
        },
    };
    defer allocator.free(global_root);

    if (install_cron) {
        return installCron(allocator, global_root, schedule orelse DEFAULT_CRON_SCHEDULE, quiet, stdout, stderr);
    }

    return runBackupNow(allocator, global_root, quiet, stdout, stderr);
}

fn runBackupNow(
    allocator: std.mem.Allocator,
    global_root: []const u8,
    quiet: bool,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    if (!fs.dirExists(global_root)) {
        try stderr.print("error: global ligi root not found: {s}\n", .{global_root});
        return 2;
    }

    var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_dir = std.fmt.bufPrint(&git_dir_buf, "{s}/.git", .{global_root}) catch {
        try stderr.writeAll("error: failed to resolve global git directory\n");
        return 2;
    };
    if (!fs.dirExists(git_dir)) {
        try stderr.print("error: global ligi repo is not a git repository: {s}\n", .{global_root});
        return 2;
    }

    const status = try runCommandCapture(allocator, global_root, &.{ "git", "status", "--porcelain" });
    defer {
        allocator.free(status.stdout);
        allocator.free(status.stderr);
    }

    if (status.exit_code != 0) {
        if (status.stderr.len > 0) {
            try stderr.writeAll(status.stderr);
        }
        try stderr.writeAll("error: failed to check global repo status\n");
        return 2;
    }

    if (status.stdout.len == 0) {
        if (!quiet) {
            try stdout.writeAll("No changes to back up in ~/.ligi\n");
        }
        return 0;
    }

    if (try runCommand(global_root, &.{ "git", "add", "-A" }, quiet) != 0) {
        try stderr.writeAll("error: git add failed in ~/.ligi\n");
        return 2;
    }

    if (try runCommand(global_root, &.{ "git", "commit", "-m", "backup" }, quiet) != 0) {
        try stderr.writeAll("error: git commit failed in ~/.ligi\n");
        return 2;
    }

    if (try runCommand(global_root, &.{ "git", "push" }, quiet) != 0) {
        try stderr.writeAll("error: git push failed for ~/.ligi\n");
        return 2;
    }

    if (!quiet) {
        try stdout.writeAll("Backed up ~/.ligi (commit + push)\n");
    }
    return 0;
}

fn installCron(
    allocator: std.mem.Allocator,
    global_root: []const u8,
    schedule: []const u8,
    quiet: bool,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    if (!fs.dirExists(global_root)) {
        try stderr.print("error: global ligi root not found: {s}\n", .{global_root});
        return 2;
    }

    var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_dir = std.fmt.bufPrint(&git_dir_buf, "{s}/.git", .{global_root}) catch {
        try stderr.writeAll("error: failed to resolve global git directory\n");
        return 2;
    };
    if (!fs.dirExists(git_dir)) {
        try stderr.print("error: global ligi repo is not a git repository: {s}\n", .{global_root});
        return 2;
    }

    const scripts_dir = try paths.joinPath(allocator, &.{ global_root, "scripts" });
    defer allocator.free(scripts_dir);
    switch (fs.ensureDirRecursive(scripts_dir)) {
        .ok => {},
        .err => |e| {
            try e.write(stderr);
            return e.exitCode();
        },
    }

    const script_path = try paths.joinPath(allocator, &.{ scripts_dir, "backup.sh" });
    defer allocator.free(script_path);

    try writeBackupScript(script_path);

    const existing = try runCommandCapture(allocator, null, &.{ "crontab", "-l" });
    defer {
        allocator.free(existing.stdout);
        allocator.free(existing.stderr);
    }

    var existing_cron: []const u8 = "";
    if (existing.exit_code == 0) {
        existing_cron = existing.stdout;
    } else if (std.mem.indexOf(u8, existing.stderr, "no crontab") == null) {
        if (existing.stderr.len > 0) {
            try stderr.writeAll(existing.stderr);
        }
        try stderr.writeAll("error: failed to read existing crontab\n");
        return 2;
    }

    var new_cron = std.ArrayList(u8).init(allocator);
    defer new_cron.deinit();

    var lines = std.mem.splitScalar(u8, existing_cron, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) {
            continue;
        }
        if (std.mem.indexOf(u8, line, CRON_MARKER) != null) {
            continue;
        }
        if (std.mem.indexOf(u8, line, script_path) != null) {
            continue;
        }
        try new_cron.appendSlice(line);
        try new_cron.append('\n');
    }

    try new_cron.writer().print("{s} {s} {s}\n", .{ schedule, script_path, CRON_MARKER });

    if (try runCommandWithStdin(allocator, null, &.{ "crontab", "-" }, new_cron.items) != 0) {
        try stderr.writeAll("error: failed to install cron job\n");
        return 2;
    }

    if (!quiet) {
        try stdout.print("Installed cron backup for ~/.ligi ({s})\n", .{schedule});
    }
    return 0;
}

fn writeBackupScript(path: []const u8) !void {
    const content =
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\PATH="/usr/local/bin:/usr/bin:/bin"
        \\
        \\ROOT="${HOME}/.ligi"
        \\cd "$ROOT"
        \\
        \\git add -A
        \\if ! git diff --cached --quiet; then
        \\  git commit -m "backup"
        \\  git push
        \\fi
        \\
    ;

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
    try std.posix.chmod(path, 0o755);
}

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
};

fn runCommandCapture(
    allocator: std.mem.Allocator,
    cwd: ?[]const u8,
    argv: []const []const u8,
) !RunResult {
    var child = std.process.Child.init(argv, allocator);
    child.cwd = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    const term = try child.wait();

    return .{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = termExitCode(term),
    };
}

fn runCommand(cwd: []const u8, argv: []const []const u8, quiet: bool) !u8 {
    var child = std.process.Child.init(argv, std.heap.page_allocator);
    child.cwd = cwd;
    child.stdout_behavior = if (quiet) .Ignore else .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    const term = try child.wait();
    return termExitCode(term);
}

fn runCommandWithStdin(
    allocator: std.mem.Allocator,
    cwd: ?[]const u8,
    argv: []const []const u8,
    stdin_data: []const u8,
) !u8 {
    var child = std.process.Child.init(argv, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;

    try child.spawn();

    if (child.stdin) |stdin_file| {
        try stdin_file.writeAll(stdin_data);
        stdin_file.close();
    }

    const term = try child.wait();
    return termExitCode(term);
}

fn termExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .Exited => |code| @intCast(code),
        .Signal => |_| 1,
        .Stopped => |_| 1,
        .Unknown => 1,
    };
}
