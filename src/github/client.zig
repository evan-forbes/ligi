//! HTTP client wrapper for GitHub API.

const std = @import("std");
const errors = @import("../core/errors.zig");
const config_mod = @import("config.zig");

pub const GithubClient = struct {
    allocator: std.mem.Allocator,
    http_client: std.http.Client,
    token: ?[]const u8,
    api_base: []const u8,
    rate_limit_remaining: ?u32 = null,
    rate_limit_reset: ?i64 = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, cfg: config_mod.GithubConfig) !Self {
        var http_client = std.http.Client{ .allocator = allocator };

        // Set up TLS certificate bundle for HTTPS
        http_client.ca_bundle = .{};
        try http_client.ca_bundle.rescan(allocator);

        return .{
            .allocator = allocator,
            .http_client = http_client,
            .token = cfg.token,
            .api_base = cfg.api_base,
        };
    }

    pub fn deinit(self: *Self) void {
        self.http_client.ca_bundle.deinit(self.allocator);
        self.http_client.deinit();
    }

    /// Make a GET request to the GitHub API.
    /// Path should be relative to api_base (e.g., "/repos/owner/repo/issues")
    pub fn get(self: *Self, path: []const u8) !Response {
        // Build full URL
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.api_base, path });
        defer self.allocator.free(url);

        return self.getUrl(url);
    }

    /// Make a GET request to an absolute URL (for pagination).
    pub fn getUrl(self: *Self, url: []const u8) !Response {
        // Build authorization header if we have a token
        var auth_header: ?[]const u8 = null;
        defer if (auth_header) |h| self.allocator.free(h);

        if (self.token) |t| {
            auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{t});
        }

        // Read response into memory using Allocating writer
        var allocating: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer allocating.deinit();

        // Make request using fetch API
        const result = self.http_client.fetch(.{
            .location = .{ .url = url },
            .headers = .{
                .authorization = if (auth_header) |h| .{ .override = h } else .default,
                .user_agent = .{ .override = "ligi-cli/1.0" },
            },
            .extra_headers = &.{
                .{ .name = "Accept", .value = "application/vnd.github.v3+json" },
            },
            .response_writer = &allocating.writer,
        }) catch return error.HttpError;

        // Check for rate limiting via response
        if (result.status == .forbidden or result.status == .too_many_requests) {
            allocating.deinit();
            return error.RateLimited;
        }

        // Check for errors
        switch (result.status) {
            .ok => {},
            .unauthorized => {
                allocating.deinit();
                return error.Unauthorized;
            },
            .forbidden => {
                allocating.deinit();
                return error.Forbidden;
            },
            .not_found => {
                allocating.deinit();
                return error.NotFound;
            },
            else => {
                allocating.deinit();
                return error.HttpError;
            },
        }

        // Get the response body
        const body = allocating.toOwnedSlice() catch {
            allocating.deinit();
            return error.HttpError;
        };

        // Note: fetch API doesn't give us access to response headers for Link parsing
        // Pagination will need to be handled differently or we use a lower-level API
        return Response{
            .body = body,
            .next_url = null, // Pagination not supported with this simplified API
            .allocator = self.allocator,
        };
    }
};

pub const Response = struct {
    body: []const u8,
    next_url: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
        if (self.next_url) |url| {
            self.allocator.free(url);
        }
    }
};

/// Parse Link header to extract "next" URL.
/// Format: <https://api.github.com/...?page=2>; rel="next", <...>; rel="last"
pub fn parseLinkHeaderNext(allocator: std.mem.Allocator, header: []const u8) ?[]const u8 {
    var iter = std.mem.splitSequence(u8, header, ",");
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        // Check if this part has rel="next"
        if (std.mem.indexOf(u8, trimmed, "rel=\"next\"")) |_| {
            // Extract URL between < and >
            const start = std.mem.indexOf(u8, trimmed, "<") orelse continue;
            const end = std.mem.indexOf(u8, trimmed, ">") orelse continue;
            if (start < end) {
                const url = trimmed[start + 1 .. end];
                return allocator.dupe(u8, url) catch null;
            }
        }
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "parseLinkHeaderNext extracts next URL" {
    const allocator = std.testing.allocator;
    const header = "<https://api.github.com/repos/owner/repo/issues?page=2>; rel=\"next\", <https://api.github.com/repos/owner/repo/issues?page=5>; rel=\"last\"";

    const result = parseLinkHeaderNext(allocator, header);
    try std.testing.expect(result != null);
    defer if (result) |r| allocator.free(r);

    try std.testing.expectEqualStrings("https://api.github.com/repos/owner/repo/issues?page=2", result.?);
}

test "parseLinkHeaderNext returns null when no next" {
    const allocator = std.testing.allocator;
    const header = "<https://api.github.com/repos/owner/repo/issues?page=5>; rel=\"last\"";

    const result = parseLinkHeaderNext(allocator, header);
    try std.testing.expect(result == null);
}

test "parseLinkHeaderNext handles malformed header" {
    const allocator = std.testing.allocator;
    const result = parseLinkHeaderNext(allocator, "malformed");
    try std.testing.expect(result == null);
}
