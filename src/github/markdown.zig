//! Markdown generation for GitHub items.

const std = @import("std");
const parser = @import("parser.zig");
const repo_mod = @import("repo.zig");

const GithubItem = parser.GithubItem;
const RepoId = repo_mod.RepoId;

/// Generate markdown document for a GitHub item.
pub fn itemToMarkdown(
    allocator: std.mem.Allocator,
    item: GithubItem,
    repo: RepoId,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    // Title
    const escaped_title = try escapeTitle(allocator, item.title);
    defer if (escaped_title.ptr != item.title.ptr) allocator.free(escaped_title);

    try writer.print("# #{d}: {s}\n\n", .{ item.number, escaped_title });

    // Tags
    try writer.writeAll("[[t/github]] ");
    try writer.print("[[t/github/repo/{s}/{s}]] ", .{ repo.owner, repo.repo });
    try writer.print("[[t/github/number/{d}]] ", .{item.number});
    try writer.print("[[t/github/type/{s}]] ", .{@tagName(item.item_type)});
    try writer.print("[[t/github/state/{s}]] ", .{@tagName(item.state)});
    try writer.print("[[t/github/user/{s}]] ", .{item.author});

    // Label tags
    for (item.labels) |label| {
        const sanitized = try sanitizeLabel(allocator, label.name);
        defer allocator.free(sanitized);
        try writer.print("[[t/github/label/{s}]] ", .{sanitized});
    }
    try writer.writeAll("\n\n");

    // Metadata
    try writer.print("**Author**: @{s}\n", .{item.author});
    try writer.print("**Created**: {s}\n", .{formatDate(item.created_at)});
    try writer.print("**Updated**: {s}\n", .{formatDate(item.updated_at)});

    if (item.assignees.len > 0) {
        try writer.writeAll("**Assignees**: ");
        for (item.assignees, 0..) |assignee, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("@{s}", .{assignee});
        }
        try writer.writeAll("\n");
    }

    try writer.writeAll("\n---\n\n");

    // Body
    if (item.body.len > 0) {
        try writer.writeAll(item.body);
        try writer.writeAll("\n");
    }

    // Comments
    if (item.comments.len > 0) {
        try writer.writeAll("\n---\n\n## Comments\n\n");

        for (item.comments) |comment| {
            try writer.print("### @{s} ({s})\n\n", .{
                comment.author,
                formatDate(comment.created_at),
            });
            try writer.writeAll(comment.body);
            try writer.writeAll("\n\n");
        }
    }

    return buf.toOwnedSlice(allocator);
}

/// Generate index.md for a repository's GitHub items.
pub fn generateIndex(
    allocator: std.mem.Allocator,
    items: []const GithubItem,
    repo: RepoId,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.print("# GitHub: {s}/{s}\n\n", .{ repo.owner, repo.repo });

    // Get current timestamp
    const now = std.time.timestamp();
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(now) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    try writer.print("Last synced: {d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z\n\n", .{
        year_day.year,
        @intFromEnum(month_day.month) + 1, // month is 0-indexed enum
        month_day.day_index + 1, // day_index is 0-indexed
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });

    // Separate issues and PRs
    try writer.writeAll("## Issues\n\n");
    for (items) |item| {
        if (item.item_type == .issue) {
            try writer.print("- [[issue-{d}]] #{d}: {s}\n", .{ item.number, item.number, item.title });
        }
    }

    try writer.writeAll("\n## Pull Requests\n\n");
    for (items) |item| {
        if (item.item_type == .pull) {
            try writer.print("- [[pr-{d}]] #{d}: {s}\n", .{ item.number, item.number, item.title });
        }
    }

    return buf.toOwnedSlice(allocator);
}

/// Get filename for an item (e.g., "issue-42.md" or "pr-45.md")
pub fn getFilename(allocator: std.mem.Allocator, item: GithubItem) ![]const u8 {
    const prefix = switch (item.item_type) {
        .issue => "issue",
        .pull => "pr",
    };
    return std.fmt.allocPrint(allocator, "{s}-{d}.md", .{ prefix, item.number });
}

/// Sanitize a label name for use in tags.
/// Rules:
/// - Replace spaces with `-`
/// - Replace `/` with `-` (would break tag hierarchy)
/// - Replace `[` and `]` with `-` (would break wiki-links)
/// - Lowercase everything
/// - Truncate to 100 chars max
pub fn sanitizeLabel(allocator: std.mem.Allocator, label: []const u8) ![]const u8 {
    const max_len = @min(label.len, 100);
    var result = try allocator.alloc(u8, max_len);
    var i: usize = 0;

    for (label) |c| {
        if (i >= 100) break;
        result[i] = switch (c) {
            ' ', '/', '[', ']', '\t', '\n' => '-',
            'A'...'Z' => c + 32, // lowercase
            else => c,
        };
        i += 1;
    }

    // Resize to actual length used
    if (i < result.len) {
        result = allocator.realloc(result, i) catch result[0..i];
    }

    return result[0..i];
}

/// Escape characters in title that would break markdown/wiki-links.
/// Specifically: `[[` and `]]` sequences.
pub fn escapeTitle(allocator: std.mem.Allocator, title: []const u8) ![]const u8 {
    // Count occurrences to pre-allocate
    var extra: usize = 0;
    var i: usize = 0;
    while (i < title.len) : (i += 1) {
        if (i + 1 < title.len) {
            if ((title[i] == '[' and title[i + 1] == '[') or
                (title[i] == ']' and title[i + 1] == ']'))
            {
                extra += 1;
            }
        }
    }

    if (extra == 0) return title;

    var result = try allocator.alloc(u8, title.len + extra);
    var out_i: usize = 0;
    i = 0;

    while (i < title.len) {
        if (i + 1 < title.len and title[i] == '[' and title[i + 1] == '[') {
            result[out_i] = '[';
            result[out_i + 1] = '\\';
            result[out_i + 2] = '[';
            out_i += 3;
            i += 2;
        } else if (i + 1 < title.len and title[i] == ']' and title[i + 1] == ']') {
            result[out_i] = ']';
            result[out_i + 1] = '\\';
            result[out_i + 2] = ']';
            out_i += 3;
            i += 2;
        } else {
            result[out_i] = title[i];
            out_i += 1;
            i += 1;
        }
    }

    return result[0..out_i];
}

/// Format ISO 8601 timestamp to just the date portion.
fn formatDate(timestamp: []const u8) []const u8 {
    // ISO 8601: "2025-01-14T10:30:00Z" -> "2025-01-14"
    if (timestamp.len >= 10) {
        return timestamp[0..10];
    }
    return timestamp;
}

// ============================================================================
// Tests
// ============================================================================

test "sanitizeLabel replaces spaces with dashes" {
    const allocator = std.testing.allocator;
    const result = try sanitizeLabel(allocator, "bug fix");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("bug-fix", result);
}

test "sanitizeLabel replaces slashes with dashes" {
    const allocator = std.testing.allocator;
    const result = try sanitizeLabel(allocator, "type/bug");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("type-bug", result);
}

test "sanitizeLabel replaces brackets with dashes" {
    const allocator = std.testing.allocator;
    const result = try sanitizeLabel(allocator, "[wip]");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("-wip-", result);
}

test "sanitizeLabel lowercases" {
    const allocator = std.testing.allocator;
    const result = try sanitizeLabel(allocator, "BUG");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("bug", result);
}

test "sanitizeLabel truncates long labels" {
    const allocator = std.testing.allocator;
    const long_label = "a" ** 150;
    const result = try sanitizeLabel(allocator, long_label);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 100), result.len);
}

test "escapeTitle handles normal title" {
    const allocator = std.testing.allocator;
    const result = try escapeTitle(allocator, "Normal title");
    // Should return original string (no allocation)
    try std.testing.expectEqualStrings("Normal title", result);
}

test "escapeTitle escapes wiki-links" {
    const allocator = std.testing.allocator;
    const result = try escapeTitle(allocator, "Add [[tag]] support");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Add [\\[tag]\\] support", result);
}

test "formatDate extracts date from ISO 8601" {
    const result = formatDate("2025-01-14T10:30:00Z");
    try std.testing.expectEqualStrings("2025-01-14", result);
}

test "getFilename generates correct issue filename" {
    const allocator = std.testing.allocator;
    const item = GithubItem{
        .number = 42,
        .item_type = .issue,
        .title = "Test",
        .body = "",
        .state = .open,
        .author = "test",
        .labels = &.{},
        .assignees = &.{},
        .created_at = "",
        .updated_at = "",
        .comments = &.{},
    };
    const filename = try getFilename(allocator, item);
    defer allocator.free(filename);
    try std.testing.expectEqualStrings("issue-42.md", filename);
}

test "getFilename generates correct PR filename" {
    const allocator = std.testing.allocator;
    const item = GithubItem{
        .number = 45,
        .item_type = .pull,
        .title = "Test",
        .body = "",
        .state = .open,
        .author = "test",
        .labels = &.{},
        .assignees = &.{},
        .created_at = "",
        .updated_at = "",
        .comments = &.{},
    };
    const filename = try getFilename(allocator, item);
    defer allocator.free(filename);
    try std.testing.expectEqualStrings("pr-45.md", filename);
}
