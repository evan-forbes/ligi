//! The `ligi github` command implementation.
//! Pulls GitHub issues and PRs as local markdown documents.

const std = @import("std");
const core = @import("../../core/mod.zig");
const github = @import("../../github/mod.zig");

const fs = core.fs;
const paths = core.paths;
const errors = core.errors;

const GithubClient = github.client.GithubClient;
const GithubConfig = github.config.GithubConfig;
const GithubItem = github.parser.GithubItem;
const RepoId = github.repo.RepoId;

pub const Subcommand = enum {
    pull,
    refresh,
};

pub const GithubOptions = struct {
    subcommand: Subcommand,
    repo_arg: ?[]const u8 = null,
    quiet: bool = false,
    // Pull-specific
    state: ?[]const u8 = null,
    since: ?[]const u8 = null,
    // Refresh-specific
    range: ?[]const u8 = null,
};

pub fn parseSubcommand(input: []const u8) ?Subcommand {
    if (std.mem.eql(u8, input, "pull") or std.mem.eql(u8, input, "p")) return .pull;
    if (std.mem.eql(u8, input, "refresh") or std.mem.eql(u8, input, "r")) return .refresh;
    return null;
}

pub fn run(
    allocator: std.mem.Allocator,
    options: GithubOptions,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var arena_impl = std.heap.ArenaAllocator.init(allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    // Resolve repository
    var repo_buffer: ?[]u8 = null;
    defer if (repo_buffer) |buf| allocator.free(buf);

    const repo_id: RepoId = blk: {
        if (options.repo_arg) |arg| {
            switch (github.repo.parseRepoId(arg)) {
                .ok => |id| break :blk id,
                .err => |e| {
                    try e.write(stderr);
                    return 1;
                },
            }
        } else {
            // Try to infer from git
            if (github.repo.inferRepoFromGit(allocator)) |result| {
                repo_buffer = result.buffer;
                if (!options.quiet) {
                    try stderr.print("Inferred repository: {s}/{s} (from git remote)\n", .{ result.repo_id.owner, result.repo_id.repo });
                }
                break :blk result.repo_id;
            } else {
                try stderr.writeAll("error: github: no repository specified and could not infer from git remote\n");
                return 1;
            }
        }
    };

    // Check art directory exists
    if (!fs.dirExists("art")) {
        try stderr.writeAll("error: github: art/ directory not found (run 'ligi init' first)\n");
        return 2;
    }

    // Load config
    var config = switch (github.config.loadConfig(allocator, "art")) {
        .ok => |c| c,
        .err => |e| {
            try e.write(stderr);
            return 3;
        },
    };
    defer github.config.freeConfig(allocator, &config);

    // If no token, warn that we may hit rate limits
    if (config.token == null and !options.quiet) {
        try stderr.writeAll("warning: github: no token found (set GITHUB_TOKEN or add to art/config/github.toml)\n");
        try stderr.writeAll("warning: github: unauthenticated requests are limited to 60/hour\n");
    }

    // Initialize client
    var client = GithubClient.init(allocator, config) catch {
        try stderr.writeAll("error: github: failed to initialize HTTP client\n");
        return 4;
    };
    defer client.deinit();

    return switch (options.subcommand) {
        .pull => runPull(arena, &client, repo_id, options, stdout, stderr),
        .refresh => runRefresh(arena, allocator, &client, repo_id, options, stdout, stderr),
    };
}

fn runPull(
    arena: std.mem.Allocator,
    client: *GithubClient,
    repo_id: RepoId,
    options: GithubOptions,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    if (!options.quiet) {
        try stderr.print("Fetching issues from {s}/{s}...\n", .{ repo_id.owner, repo_id.repo });
    }

    // Build API URL with query params
    var url: std.ArrayList(u8) = .empty;
    try url.writer(arena).print("/repos/{s}/{s}/issues?state=all&per_page=100", .{ repo_id.owner, repo_id.repo });

    if (options.state) |state| {
        if (std.mem.eql(u8, state, "open") or std.mem.eql(u8, state, "closed")) {
            try url.writer(arena).print("&state={s}", .{state});
        }
    }
    if (options.since) |since| {
        try url.writer(arena).print("&since={s}", .{since});
    }

    // Fetch all issues (with pagination)
    var all_items: std.ArrayList(GithubItem) = .empty;
    var current_url: ?[]const u8 = try url.toOwnedSlice(arena);
    var page: u32 = 1;

    while (current_url) |fetch_url| {
        if (!options.quiet) {
            try stderr.print("  Fetching page {d} of issues...\n", .{page});
        }

        var response = client.get(fetch_url) catch |err| {
            try stderr.print("error: github: API request failed: {s}\n", .{@errorName(err)});
            return 4;
        };
        defer response.deinit();

        const items = github.parser.parseIssues(arena, response.body) catch |err| {
            try stderr.print("error: github: failed to parse response: {s}\n", .{@errorName(err)});
            return 4;
        };

        if (!options.quiet and items.len > 0) {
            try stderr.print("    ({d} items)\n", .{items.len});
        }

        for (items) |item| {
            try all_items.append(arena, item);
        }

        // Follow pagination
        if (response.next_url) |next| {
            // For pagination, we need to use the full URL
            current_url = next;
            page += 1;
        } else {
            current_url = null;
        }
    }

    if (all_items.items.len == 0) {
        if (!options.quiet) {
            try stdout.print("No issues found in {s}/{s}\n", .{ repo_id.owner, repo_id.repo });
        }
        return 0;
    }

    // Fetch comments for each item
    if (!options.quiet) {
        try stderr.print("  Fetching comments for {d} items...\n", .{all_items.items.len});
    }

    for (all_items.items, 0..) |*item, i| {
        const comments = fetchComments(arena, client, repo_id, item.number, options.quiet, stderr) catch |err| {
            if (!options.quiet) {
                try stderr.print("    warning: failed to fetch comments for #{d}: {s}\n", .{ item.number, @errorName(err) });
            }
            continue;
        };
        all_items.items[i] = github.parser.withComments(item.*, comments);
    }

    // Create output directory
    const output_dir = try std.fmt.allocPrint(arena, "art/github/{s}/{s}", .{ repo_id.owner, repo_id.repo });
    switch (fs.ensureDirRecursive(output_dir)) {
        .ok => {},
        .err => |e| {
            try e.write(stderr);
            return 2;
        },
    }

    // Write documents
    if (!options.quiet) {
        try stderr.writeAll("  Writing documents...\n");
    }

    for (all_items.items) |item| {
        const content = try github.markdown.itemToMarkdown(arena, item, repo_id);
        const filename = try github.markdown.getFilename(arena, item);
        const filepath = try std.fs.path.join(arena, &.{ output_dir, filename });

        switch (fs.writeFile(filepath, content)) {
            .ok => {
                if (!options.quiet) {
                    try stdout.print("created: {s}\n", .{filepath});
                }
            },
            .err => |e| {
                try e.write(stderr);
            },
        }
    }

    // Generate index
    const index_content = try github.markdown.generateIndex(arena, all_items.items, repo_id);
    const index_path = try std.fs.path.join(arena, &.{ output_dir, "index.md" });

    switch (fs.writeFile(index_path, index_content)) {
        .ok => {
            if (!options.quiet) {
                try stdout.print("created: {s}\n", .{index_path});
            }
        },
        .err => |e| {
            try e.write(stderr);
        },
    }

    try stdout.print("Synced {d} items from {s}/{s}\n", .{ all_items.items.len, repo_id.owner, repo_id.repo });
    return 0;
}

fn runRefresh(
    arena: std.mem.Allocator,
    allocator: std.mem.Allocator,
    client: *GithubClient,
    repo_id: RepoId,
    options: GithubOptions,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const range_str = options.range orelse {
        try stderr.writeAll("error: github refresh: range argument required (e.g., '1-10', '42', '1,5,10-20')\n");
        return 1;
    };

    const numbers = github.repo.parseRange(allocator, range_str) catch |err| {
        const msg = switch (err) {
            error.EmptyRange => "empty range",
            error.ReversedRange => "reversed range (start must be <= end)",
            error.InvalidRangeNumber => "invalid number in range",
            error.RangeTooLarge => "range too large (maximum 1000 items)",
            else => "invalid range",
        };
        try stderr.print("error: github refresh: {s} '{s}'\n", .{ msg, range_str });
        return 1;
    };
    defer allocator.free(numbers);

    if (!options.quiet) {
        try stderr.print("Refreshing {d} items from {s}/{s}...\n", .{ numbers.len, repo_id.owner, repo_id.repo });
    }

    // Create output directory
    const output_dir = try std.fmt.allocPrint(arena, "art/github/{s}/{s}", .{ repo_id.owner, repo_id.repo });
    switch (fs.ensureDirRecursive(output_dir)) {
        .ok => {},
        .err => |e| {
            try e.write(stderr);
            return 2;
        },
    }

    var refreshed: std.ArrayList(GithubItem) = .empty;
    var not_found: u32 = 0;

    for (numbers) |num| {
        const item = fetchSingleItem(arena, client, repo_id, num, options.quiet, stderr) catch |err| {
            if (err == error.NotFound) {
                not_found += 1;
                if (!options.quiet) {
                    try stderr.print("  #{d}: not found\n", .{num});
                }
            } else {
                try stderr.print("  #{d}: error: {s}\n", .{ num, @errorName(err) });
            }
            continue;
        };

        // Fetch comments
        const comments = fetchComments(arena, client, repo_id, num, options.quiet, stderr) catch &[_]GithubItem.Comment{};
        const item_with_comments = github.parser.withComments(item, comments);

        // Write document
        const content = try github.markdown.itemToMarkdown(arena, item_with_comments, repo_id);
        const filename = try github.markdown.getFilename(arena, item_with_comments);
        const filepath = try std.fs.path.join(arena, &.{ output_dir, filename });

        switch (fs.writeFile(filepath, content)) {
            .ok => {
                if (!options.quiet) {
                    try stdout.print("updated: {s}\n", .{filepath});
                }
                try refreshed.append(arena, item_with_comments);
            },
            .err => |e| {
                try e.write(stderr);
            },
        }
    }

    if (refreshed.items.len > 0) {
        // Update index with all items in directory
        // For simplicity, just regenerate with what we have
        const index_content = try github.markdown.generateIndex(arena, refreshed.items, repo_id);
        const index_path = try std.fs.path.join(arena, &.{ output_dir, "index.md" });

        switch (fs.writeFile(index_path, index_content)) {
            .ok => {},
            .err => {},
        }
    }

    if (not_found > 0) {
        try stdout.print("Refreshed {d} items ({d} not found)\n", .{ refreshed.items.len, not_found });
    } else {
        try stdout.print("Refreshed {d} items\n", .{refreshed.items.len});
    }

    return 0;
}

fn fetchComments(
    arena: std.mem.Allocator,
    client: *GithubClient,
    repo_id: RepoId,
    number: u32,
    quiet: bool,
    stderr: anytype,
) ![]const GithubItem.Comment {
    var all_comments: std.ArrayList(GithubItem.Comment) = .empty;

    var url = try std.fmt.allocPrint(arena, "/repos/{s}/{s}/issues/{d}/comments?per_page=100", .{ repo_id.owner, repo_id.repo, number });
    var page: u32 = 1;

    while (true) {
        var response = try client.get(url);
        defer response.deinit();

        const comments = try github.parser.parseComments(arena, response.body);
        for (comments) |c| {
            try all_comments.append(arena, c);
        }

        if (!quiet and page > 1) {
            try stderr.print("    #{d}: {d} comments (page {d})\n", .{ number, all_comments.items.len, page });
        }

        if (response.next_url) |next| {
            url = try arena.dupe(u8, next);
            page += 1;
        } else {
            break;
        }
    }

    return all_comments.toOwnedSlice(arena);
}

fn fetchSingleItem(
    arena: std.mem.Allocator,
    client: *GithubClient,
    repo_id: RepoId,
    number: u32,
    quiet: bool,
    stderr: anytype,
) !GithubItem {
    _ = quiet;
    _ = stderr;

    const url = try std.fmt.allocPrint(arena, "/repos/{s}/{s}/issues/{d}", .{ repo_id.owner, repo_id.repo, number });

    var response = try client.get(url);
    defer response.deinit();

    return github.parser.parseIssue(arena, response.body);
}
