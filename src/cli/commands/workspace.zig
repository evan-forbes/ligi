//! The `ligi workspace` command implementation.
//!
//! Displays workspace hierarchy info and provides workspace management.
//! Supports subcommands: info, list, templates

const std = @import("std");
const core = @import("../../core/mod.zig");
const workspace = core.workspace;
const config = core.config;
const fs = core.fs;
const paths = core.paths;

/// Run the workspace command
pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    // Default subcommand is "info" if none provided
    const subcmd = if (args.len > 0) args[0] else "info";

    if (std.mem.eql(u8, subcmd, "info") or std.mem.eql(u8, subcmd, "i")) {
        return runInfo(allocator, stdout, stderr);
    } else if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
        return runList(allocator, stdout, stderr);
    } else if (std.mem.eql(u8, subcmd, "templates") or std.mem.eql(u8, subcmd, "t")) {
        return runTemplates(allocator, stdout, stderr);
    } else if (std.mem.eql(u8, subcmd, "-h") or std.mem.eql(u8, subcmd, "--help")) {
        try printHelp(stdout);
        return 0;
    } else {
        try stderr.print("error: unknown subcommand '{s}'\n", .{subcmd});
        try printHelp(stderr);
        return 1;
    }
}

/// Print help for the workspace command
fn printHelp(writer: anytype) !void {
    try writer.writeAll("Usage: ligi ws [subcommand]\n\n");
    try writer.writeAll("Display workspace hierarchy info.\n\n");
    try writer.writeAll("Subcommands:\n");
    try writer.writeAll("  info, i      Show current workspace context (default)\n");
    try writer.writeAll("  list, ls     List repos in org (if in org/repo workspace)\n");
    try writer.writeAll("  templates, t Show template resolution paths\n");
}

/// Show info about the current workspace
fn runInfo(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const cwd = std.fs.cwd().realpathAlloc(arena_alloc, ".") catch |err| {
        try stderr.print("error: failed to get current directory: {s}\n", .{@errorName(err)});
        return 1;
    };

    const ws_result = workspace.detectWorkspace(arena_alloc, cwd);
    if (ws_result != .ok) {
        try stderr.writeAll("error: not in a ligi workspace (run 'ligi init' first)\n");
        return 1;
    }
    var ctx = ws_result.ok;
    defer ctx.deinit();

    // Display workspace info
    try stdout.writeAll("workspace:\n");
    try stdout.print("  type: {s}\n", .{ctx.type.toString()});
    try stdout.print("  name: {s}\n", .{ctx.name});
    try stdout.print("  root: {s}\n", .{ctx.root});

    if (ctx.org_root) |org| {
        try stdout.writeAll("\norganization:\n");
        try stdout.print("  name: {s}\n", .{ctx.org_name orelse "(unknown)"});
        try stdout.print("  root: {s}\n", .{org});

        // Detect which repo we're in
        if (workspace.detectRepoContext(arena_alloc, org, cwd)) |repo_name| {
            defer arena_alloc.free(repo_name);
            try stdout.print("  current repo: {s}\n", .{repo_name});
        }
    }

    if (ctx.global_root) |global| {
        try stdout.writeAll("\nglobal:\n");
        try stdout.print("  root: {s}\n", .{global});
    }

    try stdout.writeAll("\nauto-tags: ");
    if (ctx.auto_tags_enabled) {
        try stdout.writeAll("enabled\n");
    } else {
        try stdout.writeAll("disabled\n");
    }

    return 0;
}

/// List repos in the current organization
fn runList(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const cwd = std.fs.cwd().realpathAlloc(arena_alloc, ".") catch |err| {
        try stderr.print("error: failed to get current directory: {s}\n", .{@errorName(err)});
        return 1;
    };

    const ws_result = workspace.detectWorkspace(arena_alloc, cwd);
    if (ws_result != .ok) {
        try stderr.writeAll("error: not in a ligi workspace\n");
        return 1;
    }
    var ctx = ws_result.ok;
    defer ctx.deinit();

    // Determine org root
    const org_root: []const u8 = blk: {
        if (ctx.type == .org) break :blk ctx.root;
        if (ctx.org_root) |org| break :blk org;
        try stderr.writeAll("error: not in an organization workspace\n");
        return 1;
    };

    // Get repos
    const repos = workspace.getOrgRepos(arena_alloc, org_root) catch |err| {
        if (err == error.ConfigNotFound) {
            try stderr.writeAll("error: org config not found\n");
        } else {
            try stderr.print("error: failed to read org repos: {s}\n", .{@errorName(err)});
        }
        return 1;
    };

    if (repos.len == 0) {
        try stdout.writeAll("no repos registered\n");
        return 0;
    }

    try stdout.writeAll("registered repos:\n");
    for (repos) |repo_path| {
        const name = std.fs.path.basename(repo_path);
        const art_path = std.fs.path.join(arena_alloc, &.{ repo_path, "art" }) catch continue;
        const has_local_art = fs.dirExists(art_path);
        const repo_exists = blk: {
            var d = std.fs.cwd().openDir(repo_path, .{}) catch break :blk false;
            d.close();
            break :blk true;
        };
        const status = if (!repo_exists) "not found" else if (has_local_art) "ok (has art/)" else "ok";
        try stdout.print("  {s} ({s})\n", .{ name, status });
    }

    return 0;
}

/// Show template resolution paths
fn runTemplates(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const cwd = std.fs.cwd().realpathAlloc(arena_alloc, ".") catch |err| {
        try stderr.print("error: failed to get current directory: {s}\n", .{@errorName(err)});
        return 1;
    };

    const ws_result = workspace.detectWorkspace(arena_alloc, cwd);
    if (ws_result != .ok) {
        try stderr.writeAll("error: not in a ligi workspace\n");
        return 1;
    }
    var ctx = ws_result.ok;
    defer ctx.deinit();

    try stdout.writeAll("template search paths (in priority order):\n");
    for (ctx.template_paths, 1..) |path, idx| {
        const exists = fs.dirExists(path);
        const status = if (exists) "" else " (not found)";
        try stdout.print("  {d}. {s}{s}\n", .{ idx, path, status });
    }

    try stdout.writeAll("\nfallback: builtin templates\n");

    return 0;
}

// ============================================================================
// Tests
// ============================================================================

test "workspace command module compiles" {
    _ = run;
    _ = runInfo;
    _ = runList;
    _ = runTemplates;
}
