//! Repository identification and parsing.

const std = @import("std");
const errors = @import("../core/errors.zig");

/// Parsed repository identifier
pub const RepoId = struct {
    owner: []const u8,
    repo: []const u8,

    /// Format as "owner/repo"
    pub fn format(
        self: RepoId,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s}/{s}", .{ self.owner, self.repo });
    }
};

/// Parse a repository identifier from various formats.
/// Supports:
/// - "owner/repo"
/// - "https://github.com/owner/repo"
/// - "https://github.com/owner/repo.git"
/// - "git@github.com:owner/repo.git"
///
/// NOTE: Returned strings point into the input - caller must manage lifetime.
pub fn parseRepoId(input: []const u8) errors.Result(RepoId) {
    const trimmed = std.mem.trim(u8, input, " \n\r\t");
    if (trimmed.len == 0) {
        return .{ .err = errors.LigiError.usage("github: empty repository identifier") };
    }

    // Strip trailing slash (common typo)
    const without_slash = if (trimmed[trimmed.len - 1] == '/')
        trimmed[0 .. trimmed.len - 1]
    else
        trimmed;

    // Strip .git suffix
    const without_git = if (std.mem.endsWith(u8, without_slash, ".git"))
        without_slash[0 .. without_slash.len - 4]
    else
        without_slash;

    // Try different formats
    if (std.mem.startsWith(u8, without_git, "https://github.com/")) {
        // HTTPS: https://github.com/owner/repo
        const path = without_git["https://github.com/".len..];
        return parseOwnerRepo(path);
    } else if (std.mem.startsWith(u8, without_git, "git@github.com:")) {
        // SSH: git@github.com:owner/repo
        const path = without_git["git@github.com:".len..];
        return parseOwnerRepo(path);
    } else if (std.mem.indexOf(u8, without_git, "/")) |_| {
        // Plain: owner/repo
        return parseOwnerRepo(without_git);
    }

    return .{ .err = errors.LigiError.usage(
        "github: invalid repository format (expected 'owner/repo' or URL)",
    ) };
}

fn parseOwnerRepo(path: []const u8) errors.Result(RepoId) {
    const slash_idx = std.mem.indexOf(u8, path, "/") orelse {
        return .{ .err = errors.LigiError.usage("github: invalid repository format (no slash)") };
    };

    const owner = path[0..slash_idx];
    const repo = path[slash_idx + 1 ..];

    // Validate: no more slashes, non-empty parts
    if (owner.len == 0 or repo.len == 0) {
        return .{ .err = errors.LigiError.usage("github: invalid repository format (empty owner or repo)") };
    }
    if (std.mem.indexOf(u8, repo, "/") != null) {
        return .{ .err = errors.LigiError.usage("github: invalid repository format (too many slashes)") };
    }

    return .{ .ok = .{
        .owner = owner,
        .repo = repo,
    } };
}

/// Infer repository from git remote.
/// Returns null if not in a git repo or no origin remote.
pub fn inferRepoFromGit(allocator: std.mem.Allocator) ?struct { repo_id: RepoId, buffer: []u8 } {
    // Run: git remote get-url origin
    var child = std.process.Child.init(&.{ "git", "remote", "get-url", "origin" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return null;

    const stdout = child.stdout orelse return null;
    const output = stdout.readToEndAlloc(allocator, 1024) catch return null;
    if (output.len == 0) {
        allocator.free(output);
        return null;
    }

    const term = child.wait() catch {
        allocator.free(output);
        return null;
    };

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                allocator.free(output);
                return null;
            }
        },
        else => {
            allocator.free(output);
            return null;
        },
    }

    return switch (parseRepoId(output)) {
        .ok => |repo_id| .{ .repo_id = repo_id, .buffer = output },
        .err => {
            allocator.free(output);
            return null;
        },
    };
}

/// Parse a range specification like "1-10", "42", or "1,5,10-20"
/// Returns list of individual numbers.
///
/// Constraints:
/// - Reversed ranges (5-1) are an error
/// - Maximum 1000 total items per command (prevent OOM)
/// - Whitespace around commas is allowed
/// - Duplicates are kept (simpler implementation)
pub fn parseRange(allocator: std.mem.Allocator, input: []const u8) ![]u32 {
    const trimmed = std.mem.trim(u8, input, " \t");
    if (trimmed.len == 0) {
        return error.EmptyRange;
    }

    var result: std.ArrayList(u32) = .empty;
    errdefer result.deinit(allocator);

    // Split by comma
    var parts = std.mem.splitSequence(u8, trimmed, ",");
    while (parts.next()) |part| {
        const p = std.mem.trim(u8, part, " \t");
        if (p.len == 0) continue;

        // Check for range (contains '-')
        if (std.mem.indexOf(u8, p, "-")) |dash_idx| {
            const start_str = std.mem.trim(u8, p[0..dash_idx], " ");
            const end_str = std.mem.trim(u8, p[dash_idx + 1 ..], " ");

            const start = std.fmt.parseInt(u32, start_str, 10) catch {
                return error.InvalidRangeNumber;
            };
            const end = std.fmt.parseInt(u32, end_str, 10) catch {
                return error.InvalidRangeNumber;
            };

            if (start > end) {
                return error.ReversedRange;
            }

            // Check total size limit
            if (result.items.len + (end - start + 1) > 1000) {
                return error.RangeTooLarge;
            }

            var i = start;
            while (i <= end) : (i += 1) {
                try result.append(allocator, i);
            }
        } else {
            // Single number
            const num = std.fmt.parseInt(u32, p, 10) catch {
                return error.InvalidRangeNumber;
            };
            if (result.items.len >= 1000) {
                return error.RangeTooLarge;
            }
            try result.append(allocator, num);
        }
    }

    if (result.items.len == 0) {
        return error.EmptyRange;
    }

    return result.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "parseRepoId parses owner/repo" {
    const result = parseRepoId("owner/repo");
    try std.testing.expect(result.isOk());
    const id = result.ok;
    try std.testing.expectEqualStrings("owner", id.owner);
    try std.testing.expectEqualStrings("repo", id.repo);
}

test "parseRepoId parses https URL" {
    const result = parseRepoId("https://github.com/evan-forbes/ligi");
    try std.testing.expect(result.isOk());
    const id = result.ok;
    try std.testing.expectEqualStrings("evan-forbes", id.owner);
    try std.testing.expectEqualStrings("ligi", id.repo);
}

test "parseRepoId parses https URL with .git suffix" {
    const result = parseRepoId("https://github.com/owner/repo.git");
    try std.testing.expect(result.isOk());
    const id = result.ok;
    try std.testing.expectEqualStrings("owner", id.owner);
    try std.testing.expectEqualStrings("repo", id.repo);
}

test "parseRepoId parses SSH URL" {
    const result = parseRepoId("git@github.com:owner/repo");
    try std.testing.expect(result.isOk());
    const id = result.ok;
    try std.testing.expectEqualStrings("owner", id.owner);
    try std.testing.expectEqualStrings("repo", id.repo);
}

test "parseRepoId parses SSH URL with .git suffix" {
    const result = parseRepoId("git@github.com:owner/repo.git");
    try std.testing.expect(result.isOk());
    const id = result.ok;
    try std.testing.expectEqualStrings("owner", id.owner);
    try std.testing.expectEqualStrings("repo", id.repo);
}

test "parseRepoId handles trailing slash" {
    const result = parseRepoId("owner/repo/");
    try std.testing.expect(result.isOk());
    const id = result.ok;
    try std.testing.expectEqualStrings("owner", id.owner);
    try std.testing.expectEqualStrings("repo", id.repo);
}

test "parseRepoId rejects empty string" {
    const result = parseRepoId("");
    try std.testing.expect(result.isErr());
}

test "parseRepoId rejects string without slash" {
    const result = parseRepoId("noslash");
    try std.testing.expect(result.isErr());
}

test "parseRepoId rejects too many slashes" {
    const result = parseRepoId("a/b/c");
    try std.testing.expect(result.isErr());
}

test "parseRange parses single number" {
    const allocator = std.testing.allocator;
    const result = try parseRange(allocator, "42");
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(u32, 42), result[0]);
}

test "parseRange parses range" {
    const allocator = std.testing.allocator;
    const result = try parseRange(allocator, "1-5");
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqual(@as(u32, 1), result[0]);
    try std.testing.expectEqual(@as(u32, 5), result[4]);
}

test "parseRange parses mixed format" {
    const allocator = std.testing.allocator;
    const result = try parseRange(allocator, "1,3-5,10");
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqual(@as(u32, 1), result[0]);
    try std.testing.expectEqual(@as(u32, 3), result[1]);
    try std.testing.expectEqual(@as(u32, 4), result[2]);
    try std.testing.expectEqual(@as(u32, 5), result[3]);
    try std.testing.expectEqual(@as(u32, 10), result[4]);
}

test "parseRange handles whitespace" {
    const allocator = std.testing.allocator;
    const result = try parseRange(allocator, " 1 , 2 , 3 ");
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 3), result.len);
}

test "parseRange rejects empty string" {
    const allocator = std.testing.allocator;
    const result = parseRange(allocator, "");
    try std.testing.expectError(error.EmptyRange, result);
}

test "parseRange rejects reversed range" {
    const allocator = std.testing.allocator;
    const result = parseRange(allocator, "5-1");
    try std.testing.expectError(error.ReversedRange, result);
}

test "parseRange rejects non-number" {
    const allocator = std.testing.allocator;
    const result = parseRange(allocator, "abc");
    try std.testing.expectError(error.InvalidRangeNumber, result);
}
