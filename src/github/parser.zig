//! JSON parsing for GitHub API responses.

const std = @import("std");

/// Represents a GitHub issue or PR after parsing
pub const GithubItem = struct {
    /// Issue/PR number
    number: u32,
    /// "issue" or "pull"
    item_type: ItemType,
    /// Issue/PR title
    title: []const u8,
    /// Markdown body content
    body: []const u8,
    /// Current state
    state: State,
    /// Author login
    author: []const u8,
    /// Labels attached to this item
    labels: []const Label,
    /// Assignees
    assignees: []const []const u8,
    /// Creation timestamp (ISO 8601)
    created_at: []const u8,
    /// Last update timestamp (ISO 8601)
    updated_at: []const u8,
    /// Comments on the issue/PR
    comments: []const Comment,
    /// For PRs: base branch
    base_branch: ?[]const u8 = null,
    /// For PRs: head branch
    head_branch: ?[]const u8 = null,
    /// For PRs: merged status
    merged: ?bool = null,

    pub const ItemType = enum { issue, pull };
    pub const State = enum { open, closed };
    pub const Label = struct { name: []const u8, color: []const u8 };
    pub const Comment = struct {
        author: []const u8,
        body: []const u8,
        created_at: []const u8,
    };
};

/// JSON struct matching GitHub API /repos/:owner/:repo/issues response
const GitHubIssueJson = struct {
    number: u64,
    title: []const u8,
    body: ?[]const u8 = null, // CAN BE NULL
    state: []const u8, // "open" or "closed"
    user: struct {
        login: []const u8,
    },
    labels: []const struct {
        name: []const u8,
        color: []const u8,
    } = &.{},
    assignees: []const struct {
        login: []const u8,
    } = &.{},
    created_at: []const u8,
    updated_at: []const u8,
    // If this field exists, it's a PR, not an issue
    pull_request: ?struct {
        url: []const u8,
    } = null,
};

/// JSON struct for /repos/:owner/:repo/issues/:number/comments
const GitHubCommentJson = struct {
    user: struct {
        login: []const u8,
    },
    body: []const u8,
    created_at: []const u8,
};

/// Parse issues from JSON response.
/// IMPORTANT: The returned GithubItem structs reference memory owned by the
/// arena allocator. Do NOT free the arena until you're done with all items.
pub fn parseIssues(
    arena: std.mem.Allocator,
    json_bytes: []const u8,
) ![]GithubItem {
    const parsed = try std.json.parseFromSlice(
        []GitHubIssueJson,
        arena,
        json_bytes,
        .{ .ignore_unknown_fields = true },
    );

    var items: std.ArrayList(GithubItem) = .empty;
    for (parsed.value) |issue_json| {
        try items.append(arena, try convertToGithubItem(arena, issue_json));
    }
    return items.toOwnedSlice(arena);
}

/// Parse a single issue from JSON response.
pub fn parseIssue(
    arena: std.mem.Allocator,
    json_bytes: []const u8,
) !GithubItem {
    const parsed = try std.json.parseFromSlice(
        GitHubIssueJson,
        arena,
        json_bytes,
        .{ .ignore_unknown_fields = true },
    );
    return convertToGithubItem(arena, parsed.value);
}

/// Parse comments from JSON response.
pub fn parseComments(
    arena: std.mem.Allocator,
    json_bytes: []const u8,
) ![]GithubItem.Comment {
    const parsed = try std.json.parseFromSlice(
        []GitHubCommentJson,
        arena,
        json_bytes,
        .{ .ignore_unknown_fields = true },
    );

    var comments = try arena.alloc(GithubItem.Comment, parsed.value.len);
    for (parsed.value, 0..) |c, i| {
        comments[i] = .{
            .author = c.user.login,
            .body = c.body,
            .created_at = c.created_at,
        };
    }
    return comments;
}

fn convertToGithubItem(arena: std.mem.Allocator, json: GitHubIssueJson) !GithubItem {
    // Convert labels
    var labels = try arena.alloc(GithubItem.Label, json.labels.len);
    for (json.labels, 0..) |l, i| {
        labels[i] = .{
            .name = l.name,
            .color = l.color,
        };
    }

    // Convert assignees
    var assignees = try arena.alloc([]const u8, json.assignees.len);
    for (json.assignees, 0..) |a, i| {
        assignees[i] = a.login;
    }

    return .{
        .number = @intCast(json.number),
        .title = json.title,
        .body = json.body orelse "",
        .state = if (std.mem.eql(u8, json.state, "open")) .open else .closed,
        .author = json.user.login,
        .item_type = if (json.pull_request != null) .pull else .issue,
        .labels = labels,
        .assignees = assignees,
        .created_at = json.created_at,
        .updated_at = json.updated_at,
        .comments = &.{},
    };
}

/// Update an item with fetched comments
pub fn withComments(item: GithubItem, comments: []const GithubItem.Comment) GithubItem {
    var new_item = item;
    new_item.comments = comments;
    return new_item;
}

// ============================================================================
// Tests
// ============================================================================

test "parseIssues parses basic issue" {
    const allocator = std.testing.allocator;
    var arena_impl = std.heap.ArenaAllocator.init(allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const json =
        \\[{
        \\  "number": 42,
        \\  "title": "Fix memory leak",
        \\  "body": "The parser leaks memory...",
        \\  "state": "open",
        \\  "user": { "login": "evan-forbes" },
        \\  "labels": [
        \\    { "name": "bug", "color": "d73a4a" }
        \\  ],
        \\  "assignees": [],
        \\  "created_at": "2025-01-10T12:00:00Z",
        \\  "updated_at": "2025-01-14T15:30:00Z"
        \\}]
    ;

    const items = try parseIssues(arena, json);
    try std.testing.expectEqual(@as(usize, 1), items.len);

    const item = items[0];
    try std.testing.expectEqual(@as(u32, 42), item.number);
    try std.testing.expectEqualStrings("Fix memory leak", item.title);
    try std.testing.expectEqualStrings("The parser leaks memory...", item.body);
    try std.testing.expectEqual(GithubItem.State.open, item.state);
    try std.testing.expectEqual(GithubItem.ItemType.issue, item.item_type);
    try std.testing.expectEqualStrings("evan-forbes", item.author);
    try std.testing.expectEqual(@as(usize, 1), item.labels.len);
    try std.testing.expectEqualStrings("bug", item.labels[0].name);
}

test "parseIssues handles null body" {
    const allocator = std.testing.allocator;
    var arena_impl = std.heap.ArenaAllocator.init(allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const json =
        \\[{
        \\  "number": 1,
        \\  "title": "No body",
        \\  "body": null,
        \\  "state": "closed",
        \\  "user": { "login": "test" },
        \\  "labels": [],
        \\  "assignees": [],
        \\  "created_at": "2025-01-10T12:00:00Z",
        \\  "updated_at": "2025-01-14T15:30:00Z"
        \\}]
    ;

    const items = try parseIssues(arena, json);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("", items[0].body);
}

test "parseIssues detects PR via pull_request field" {
    const allocator = std.testing.allocator;
    var arena_impl = std.heap.ArenaAllocator.init(allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const json =
        \\[{
        \\  "number": 45,
        \\  "title": "Add feature",
        \\  "body": "New feature",
        \\  "state": "open",
        \\  "user": { "login": "dev" },
        \\  "labels": [],
        \\  "assignees": [],
        \\  "created_at": "2025-01-10T12:00:00Z",
        \\  "updated_at": "2025-01-14T15:30:00Z",
        \\  "pull_request": { "url": "https://api.github.com/repos/owner/repo/pulls/45" }
        \\}]
    ;

    const items = try parseIssues(arena, json);
    try std.testing.expectEqual(GithubItem.ItemType.pull, items[0].item_type);
}

test "parseComments parses comment list" {
    const allocator = std.testing.allocator;
    var arena_impl = std.heap.ArenaAllocator.init(allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const json =
        \\[{
        \\  "user": { "login": "commenter1" },
        \\  "body": "I can reproduce this...",
        \\  "created_at": "2025-01-11T10:00:00Z"
        \\}, {
        \\  "user": { "login": "commenter2" },
        \\  "body": "Here's a fix...",
        \\  "created_at": "2025-01-12T14:00:00Z"
        \\}]
    ;

    const comments = try parseComments(arena, json);
    try std.testing.expectEqual(@as(usize, 2), comments.len);
    try std.testing.expectEqualStrings("commenter1", comments[0].author);
    try std.testing.expectEqualStrings("I can reproduce this...", comments[0].body);
}
