//! HTTP server module for serving markdown files.
//!
//! Provides a local HTTP server that serves markdown files with GFM rendering
//! and Mermaid diagram support. All static assets are embedded in the binary.

const std = @import("std");
const path_mod = @import("path.zig");
const assets = @import("assets.zig");

// Re-export submodules
pub const path = path_mod;

/// Server configuration
pub const Config = struct {
    root: []const u8,
    host: []const u8,
    port: u16,
    open_browser: bool,
    enable_index: bool,
};

/// Start the HTTP server
pub fn startServer(
    allocator: std.mem.Allocator,
    config: anytype,
    stdout: anytype,
    stderr: anytype,
) !void {
    const address = std.net.Address.parseIp4(config.host, config.port) catch |err| {
        try stderr.print("error: invalid host address '{s}': {}\n", .{ config.host, err });
        return err;
    };

    var server = try address.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    // Open browser if requested
    if (config.open_browser) {
        openBrowser(allocator, config.host, config.port) catch {
            try stderr.writeAll("warning: could not open browser\n");
        };
    }

    // Main server loop
    while (true) {
        var conn = server.accept() catch |err| {
            try stderr.print("error: accept failed: {}\n", .{err});
            continue;
        };

        handleConnection(allocator, &conn, config, stdout, stderr) catch |err| {
            try stderr.print("error: request failed: {}\n", .{err});
        };
    }
}

/// Handle a single HTTP connection
fn handleConnection(
    allocator: std.mem.Allocator,
    conn: *std.net.Server.Connection,
    config: anytype,
    stdout: anytype,
    stderr: anytype,
) !void {
    defer conn.stream.close();

    var recv_buffer: [8192]u8 = undefined;
    var send_buffer: [8192]u8 = undefined;
    var connection_reader = conn.stream.reader(&recv_buffer);
    var connection_writer = conn.stream.writer(&send_buffer);
    var http_server: std.http.Server = .init(connection_reader.interface(), &connection_writer.interface);

    while (true) {
        var request = http_server.receiveHead() catch |err| {
            if (err == error.HttpConnectionClosing) return;
            return err;
        };

        try handleRequest(allocator, &request, config, stdout, stderr);
    }
}

/// Handle a single HTTP request
fn handleRequest(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    config: anytype,
    stdout: anytype,
    stderr: anytype,
) !void {
    const target = request.head.target;

    // Log the request
    try stdout.print("{s} {s}\n", .{ @tagName(request.head.method), target });

    // Parse the path (remove query string)
    const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const request_path = target[0..path_end];

    // Route the request
    if (std.mem.eql(u8, request_path, "/") or std.mem.eql(u8, request_path, "/index.html")) {
        try serveAsset(request, "", assets.MimeType.html);
    } else if (std.mem.startsWith(u8, request_path, "/assets/")) {
        try serveStaticAsset(request, request_path);
    } else if (std.mem.eql(u8, request_path, "/api/list")) {
        try serveFileList(allocator, request, config);
    } else if (std.mem.eql(u8, request_path, "/api/file")) {
        try serveFile(allocator, request, config, target);
    } else if (std.mem.eql(u8, request_path, "/api/health")) {
        try serveHealth(request);
    } else {
        // Try to serve as a static asset
        if (assets.getAsset(request_path)) |_| {
            try serveStaticAsset(request, request_path);
        } else {
            try serve404(request, stderr);
        }
    }
}

/// Serve an embedded asset
fn serveAsset(request: *std.http.Server.Request, asset_path: []const u8, content_type: []const u8) !void {
    const content = assets.getAsset(asset_path) orelse {
        try sendResponse(request, .not_found, "text/plain", "Not Found");
        return;
    };
    try sendResponse(request, .ok, content_type, content);
}

/// Serve a static asset from /assets/
fn serveStaticAsset(request: *std.http.Server.Request, asset_path: []const u8) !void {
    const content = assets.getAsset(asset_path) orelse {
        try sendResponse(request, .not_found, "text/plain", "Asset not found");
        return;
    };
    const content_type = assets.getMimeType(asset_path);
    try sendResponse(request, .ok, content_type, content);
}

/// Serve the file listing as JSON
fn serveFileList(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    config: anytype,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Collect markdown files
    var files = try std.ArrayList([]const u8).initCapacity(arena_alloc, 0);

    var dir = std.fs.cwd().openDir(config.root, .{ .iterate = true }) catch {
        try sendResponse(request, .internal_server_error, "text/plain", "Cannot open directory");
        return;
    };
    defer dir.close();

    var walker = try dir.walk(arena_alloc);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind == .directory) {
            if (path_mod.shouldSkipDir(entry.basename)) {
                // Skip this directory - unfortunately we can't skip walker entries
                continue;
            }
        } else if (entry.kind == .file) {
            // Skip non-markdown files
            if (!path_mod.hasAllowedExtension(entry.path)) continue;

            // Only include markdown files in the list
            const ext = path_mod.AllowedExtension.fromPath(entry.path);
            if (ext != null and ext.? == .markdown) {
                const path_copy = try arena_alloc.dupe(u8, entry.path);
                try files.append(arena_alloc, path_copy);
            }
        }
    }

    // Sort the files
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    // Build JSON response
    var json_buf = try std.ArrayList(u8).initCapacity(arena_alloc, 0);
    try json_buf.appendSlice(arena_alloc, "[");
    for (files.items, 0..) |file, i| {
        if (i > 0) try json_buf.appendSlice(arena_alloc, ",");
        try json_buf.appendSlice(arena_alloc, "\"");
        // Escape the path for JSON
        for (file) |c| {
            switch (c) {
                '"' => try json_buf.appendSlice(arena_alloc, "\\\""),
                '\\' => try json_buf.appendSlice(arena_alloc, "\\\\"),
                '\n' => try json_buf.appendSlice(arena_alloc, "\\n"),
                '\r' => try json_buf.appendSlice(arena_alloc, "\\r"),
                '\t' => try json_buf.appendSlice(arena_alloc, "\\t"),
                else => try json_buf.append(arena_alloc, c),
            }
        }
        try json_buf.appendSlice(arena_alloc, "\"");
    }
    try json_buf.appendSlice(arena_alloc, "]");

    try sendResponse(request, .ok, assets.MimeType.json, json_buf.items);
}

/// Serve a file's raw content
fn serveFile(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    config: anytype,
    target: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Parse query string to get path parameter
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse {
        try sendResponse(request, .bad_request, "text/plain", "Missing path parameter");
        return;
    };
    const query = target[query_start + 1 ..];

    // Simple query parsing for path=value
    var file_path: ?[]const u8 = null;
    var iter = std.mem.splitScalar(u8, query, '&');
    while (iter.next()) |param| {
        if (std.mem.startsWith(u8, param, "path=")) {
            file_path = param[5..];
            break;
        }
    }

    const rel_path = file_path orelse {
        try sendResponse(request, .bad_request, "text/plain", "Missing path parameter");
        return;
    };

    // URL decode the path
    const decoded_path = try urlDecode(arena_alloc, rel_path);

    // Validate the path
    _ = path_mod.validatePath(decoded_path) catch {
        try sendResponse(request, .bad_request, "text/plain", "Invalid path");
        return;
    };

    // Check extension
    if (!path_mod.hasAllowedExtension(decoded_path)) {
        try sendResponse(request, .forbidden, "text/plain", "File type not allowed");
        return;
    }

    // Join with root safely
    const full_path = path_mod.joinSafePath(arena_alloc, config.root, decoded_path) orelse {
        try sendResponse(request, .bad_request, "text/plain", "Invalid path");
        return;
    };

    // Read the file
    const file = std.fs.cwd().openFile(full_path, .{}) catch {
        try sendResponse(request, .not_found, "text/plain", "File not found");
        return;
    };
    defer file.close();

    const content = file.readToEndAlloc(arena_alloc, 10 * 1024 * 1024) catch {
        try sendResponse(request, .internal_server_error, "text/plain", "Failed to read file");
        return;
    };

    const content_type = assets.getMimeType(decoded_path);
    try sendResponse(request, .ok, content_type, content);
}

/// Serve health check endpoint
fn serveHealth(request: *std.http.Server.Request) !void {
    try sendResponse(request, .ok, "text/plain", "ok");
}

/// Serve 404 response
fn serve404(request: *std.http.Server.Request, stderr: anytype) !void {
    _ = stderr;
    try sendResponse(request, .not_found, "text/plain", "Not Found");
}

/// Send an HTTP response
fn sendResponse(
    request: *std.http.Server.Request,
    status: std.http.Status,
    content_type: []const u8,
    body: []const u8,
) !void {
    try request.respond(body, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = content_type },
            .{ .name = "Access-Control-Allow-Origin", .value = "*" },
        },
    });
}

/// URL decode a string
fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, input.len);
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hex = input[i + 1 .. i + 3];
            const byte = std.fmt.parseInt(u8, hex, 16) catch {
                try result.append(allocator, input[i]);
                i += 1;
                continue;
            };
            try result.append(allocator, byte);
            i += 3;
        } else if (input[i] == '+') {
            try result.append(allocator, ' ');
            i += 1;
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Open browser with the server URL
fn openBrowser(allocator: std.mem.Allocator, host: []const u8, port: u16) !void {
    const url = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ host, port });
    defer allocator.free(url);

    // Detect platform and use appropriate command
    const builtin = @import("builtin");
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", url },
        .windows => &.{ "cmd", "/c", "start", url },
        else => &.{ "xdg-open", url }, // Linux and others
    };

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = try child.spawnAndWait();
}

// ============================================================================
// Tests
// ============================================================================

test "urlDecode handles simple strings" {
    const allocator = std.testing.allocator;
    const result = try urlDecode(allocator, "hello");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "urlDecode handles percent encoding" {
    const allocator = std.testing.allocator;
    const result = try urlDecode(allocator, "hello%20world");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "urlDecode handles plus as space" {
    const allocator = std.testing.allocator;
    const result = try urlDecode(allocator, "hello+world");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "urlDecode handles complex paths" {
    const allocator = std.testing.allocator;
    const result = try urlDecode(allocator, "docs%2Fguide%2Fintro.md");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("docs/guide/intro.md", result);
}

test "imports compile" {
    _ = path_mod;
    _ = assets;
}
