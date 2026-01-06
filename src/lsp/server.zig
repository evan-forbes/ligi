//! Minimal LSP server for ligi completions.

const std = @import("std");
const protocol = @import("protocol.zig");
const core = @import("../core/mod.zig");
const tag_index = @import("../core/tag_index.zig");

const RpcId = union(enum) {
    int: i64,
    string: []const u8,
};

/// LSP CompletionItemKind values (subset used by ligi)
const CompletionItemKind = struct {
    const file: u8 = 17; // File
    const keyword: u8 = 18; // Keyword (used for tags)
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    root_path: ?[]const u8 = null,
    buffers: std.StringHashMap([]u8),
    shutdown_requested: bool = false,

    pub fn init(allocator: std.mem.Allocator) Server {
        return .{
            .allocator = allocator,
            .buffers = std.StringHashMap([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Server) void {
        var it = self.buffers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.buffers.deinit();
        if (self.root_path) |path| {
            self.allocator.free(path);
        }
    }

    pub fn run(
        self: *Server,
        stdin_reader: anytype,
        stdout: anytype,
        stderr: anytype,
    ) !void {
        while (true) {
            const message = try readMessage(self.allocator, stdin_reader, stderr) orelse return;
            defer self.allocator.free(message);

            self.handleMessage(message, stdout, stderr) catch |err| {
                try stderr.print("warning: lsp message error: {}\n", .{err});
            };

            if (self.shutdown_requested) {
                return;
            }
        }
    }

    fn handleMessage(self: *Server, message: []const u8, stdout: anytype, stderr: anytype) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, message, .{}) catch |err| {
            try stderr.print("warning: failed to parse json: {}\n", .{err});
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            return;
        }

        const obj = root.object;
        const method = getStringField(obj, "method");
        const id_val = obj.get("id");

        if (method) |method_name| {
            if (std.mem.eql(u8, method_name, "initialize")) {
                try self.handleInitialize(obj, id_val, stdout, stderr);
                return;
            }

            if (std.mem.eql(u8, method_name, "shutdown")) {
                if (id_val) |id_value| {
                    const id = parseId(id_value) orelse return;
                    try writeResult(self.allocator, stdout, id, @as(?u8, null));
                }
                self.shutdown_requested = true;
                return;
            }

            if (std.mem.eql(u8, method_name, "exit")) {
                self.shutdown_requested = true;
                return;
            }

            if (std.mem.eql(u8, method_name, "textDocument/didOpen")) {
                try self.handleDidOpen(obj);
                return;
            }

            if (std.mem.eql(u8, method_name, "textDocument/didChange")) {
                try self.handleDidChange(obj);
                return;
            }

            if (std.mem.eql(u8, method_name, "textDocument/didClose")) {
                try self.handleDidClose(obj);
                return;
            }

            if (std.mem.eql(u8, method_name, "textDocument/completion")) {
                if (id_val) |id_value| {
                    const id = parseId(id_value) orelse return;
                    try self.handleCompletion(obj, id, stdout, stderr);
                }
                return;
            }
        }
    }

    fn handleInitialize(
        self: *Server,
        obj: std.json.ObjectMap,
        id_val: ?std.json.Value,
        stdout: anytype,
        stderr: anytype,
    ) !void {
        if (extractRootUri(obj)) |uri| {
            self.setRootPath(uri, stderr);
        }

        const id = parseId(id_val orelse return) orelse return;

        const result = protocol.InitializeResult{
            .capabilities = .{
                .completionProvider = .{
                    .triggerCharacters = &.{ "[", "/" },
                },
                .textDocumentSync = .{
                    .openClose = true,
                    .change = .full,
                },
            },
        };

        try writeResult(self.allocator, stdout, id, result);
    }

    fn setRootPath(self: *Server, uri: []const u8, stderr: anytype) void {
        if (self.root_path) |existing| {
            self.allocator.free(existing);
            self.root_path = null;
        }
        self.root_path = uriToPath(self.allocator, uri) catch {
            stderr.print("warning: invalid root uri: {s}\n", .{uri}) catch {};
            return;
        };
    }

    fn handleDidOpen(self: *Server, obj: std.json.ObjectMap) !void {
        const doc = extractTextDocument(obj) orelse return;
        const text = doc.text orelse return;
        try self.storeBuffer(doc.uri, text);
    }

    fn handleDidChange(self: *Server, obj: std.json.ObjectMap) !void {
        const doc = extractTextDocument(obj) orelse return;
        const text = extractContentChangeText(obj) orelse return;
        try self.storeBuffer(doc.uri, text);
    }

    fn handleDidClose(self: *Server, obj: std.json.ObjectMap) !void {
        const doc = extractTextDocument(obj) orelse return;
        if (self.buffers.fetchRemove(doc.uri)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
    }

    fn handleCompletion(
        self: *Server,
        obj: std.json.ObjectMap,
        id: RpcId,
        stdout: anytype,
        stderr: anytype,
    ) !void {
        const doc = extractTextDocument(obj) orelse return;
        const position = extractPosition(obj) orelse return;

        const text = try self.getBufferOrFile(doc.uri, stderr);
        defer self.allocator.free(text);

        const line_range = findLineRange(text, position.line);
        if (line_range.start >= text.len) return;
        const line = text[line_range.start..line_range.end];
        const cursor_col = @min(position.character, line.len);

        const context = findCompletionContext(line, cursor_col) orelse {
            try writeResult(self.allocator, stdout, id, &[_]protocol.CompletionItem{});
            return;
        };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        // Resolve art path once for both completion kinds
        const art_path = resolveArtPath(arena_alloc, self.root_path, doc.uri) catch |err| {
            try stderr.print("warning: failed to resolve art path: {}\n", .{err});
            try writeResult(self.allocator, stdout, id, &[_]protocol.CompletionItem{});
            return;
        };
        if (art_path.len == 0) {
            try stderr.print("warning: could not determine art directory\n", .{});
            try writeResult(self.allocator, stdout, id, &[_]protocol.CompletionItem{});
            return;
        }

        const range = protocol.Range{
            .start = .{ .line = position.line, .character = context.start_column },
            .end = .{ .line = position.line, .character = cursor_col },
        };

        var items: std.ArrayList(protocol.CompletionItem) = .empty;
        defer items.deinit(arena_alloc);

        switch (context.kind) {
            .tag => try self.collectTagCompletions(arena_alloc, art_path, range, &items, stderr),
            .file => try self.collectFileCompletions(arena_alloc, art_path, range, &items),
        }

        try writeResult(self.allocator, stdout, id, items.items);
    }

    fn collectTagCompletions(
        _: *Server,
        arena_alloc: std.mem.Allocator,
        art_path: []const u8,
        range: protocol.Range,
        items: *std.ArrayList(protocol.CompletionItem),
        stderr: anytype,
    ) !void {
        var tag_map = tag_index.loadTagMapFromIndexes(arena_alloc, art_path, stderr) catch |err| {
            try stderr.print("warning: failed to load tag index: {}\n", .{err});
            return;
        };
        defer tag_map.deinit();

        const tags = try tag_map.getSortedTags(arena_alloc);
        defer arena_alloc.free(tags);

        for (tags) |tag| {
            try items.append(arena_alloc, .{
                .label = tag,
                .kind = CompletionItemKind.keyword,
                .detail = "tag",
                .textEdit = .{ .range = range, .newText = tag },
            });
        }
    }

    fn collectFileCompletions(
        self: *Server,
        arena_alloc: std.mem.Allocator,
        art_path: []const u8,
        range: protocol.Range,
        items: *std.ArrayList(protocol.CompletionItem),
    ) !void {
        _ = self;
        const files = try collectArtFiles(arena_alloc, art_path);
        defer freeStringList(arena_alloc, files);

        for (files) |file_rel| {
            const label = stripMdExtension(file_rel);
            try items.append(arena_alloc, .{
                .label = label,
                .kind = CompletionItemKind.file,
                .detail = file_rel,
                .textEdit = .{ .range = range, .newText = label },
            });
        }
    }

    fn storeBuffer(self: *Server, uri: []const u8, text: []const u8) !void {
        const text_copy = try self.allocator.dupe(u8, text);
        if (self.buffers.getPtr(uri)) |existing| {
            self.allocator.free(existing.*);
            existing.* = text_copy;
            return;
        }

        errdefer self.allocator.free(text_copy);
        const uri_copy = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(uri_copy);

        try self.buffers.put(uri_copy, text_copy);
    }

    fn getBufferOrFile(self: *Server, uri: []const u8, stderr: anytype) ![]const u8 {
        if (self.buffers.get(uri)) |text| {
            return self.allocator.dupe(u8, text);
        }

        const path = uriToPath(self.allocator, uri) catch {
            return self.allocator.dupe(u8, "");
        };
        defer self.allocator.free(path);

        const content = switch (core.fs.readFile(self.allocator, path)) {
            .ok => |data| data,
            .err => {
                try stderr.print("warning: cannot read file for completion: {s}\n", .{path});
                return self.allocator.dupe(u8, "");
            },
        };

        return content;
    }
};

const CompletionContext = struct {
    const Kind = enum { tag, file };
    kind: Kind,
    start_column: usize,
};

fn readMessage(
    allocator: std.mem.Allocator,
    reader: anytype,
    stderr: anytype,
) !?[]u8 {
    var content_length: ?usize = null;

    while (true) {
        const line_opt = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 8192);
        if (line_opt == null) {
            return null;
        }
        const line = line_opt.?;
        defer allocator.free(line);

        const trimmed = std.mem.trimRight(u8, line, "\r\n");
        if (trimmed.len == 0) {
            break;
        }
        if (std.mem.startsWith(u8, trimmed, "Content-Length:")) {
            const value = std.mem.trim(u8, trimmed["Content-Length:".len..], " ");
            content_length = std.fmt.parseInt(usize, value, 10) catch null;
        }
    }

    if (content_length == null) {
        try stderr.writeAll("warning: missing Content-Length\n");
        return null;
    }

    const length = content_length.?;
    const message = try allocator.alloc(u8, length);
    reader.readNoEof(message) catch {
        allocator.free(message);
        return null;
    };

    return message;
}

fn writeResult(allocator: std.mem.Allocator, stdout: anytype, id: RpcId, result: anytype) !void {
    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(allocator);

    const result_json = try std.json.Stringify.valueAlloc(allocator, result, .{
        .emit_null_optional_fields = false,
    });
    defer allocator.free(result_json);

    var writer = body_buf.writer(allocator);
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(writer, allocator, id);
    try writer.writeAll(",\"result\":");
    try writer.writeAll(result_json);
    try writer.writeAll("}");

    try stdout.print("Content-Length: {d}\r\n\r\n", .{body_buf.items.len});
    try stdout.writeAll(body_buf.items);
    try stdout.flush();
}

fn writeId(writer: anytype, allocator: std.mem.Allocator, id: RpcId) !void {
    switch (id) {
        .int => |value| try writer.print("{d}", .{value}),
        .string => |value| {
            const id_json = try std.json.Stringify.valueAlloc(allocator, value, .{});
            defer allocator.free(id_json);
            try writer.writeAll(id_json);
        },
    }
}

fn parseId(value: std.json.Value) ?RpcId {
    return switch (value) {
        .integer => |i| .{ .int = i },
        .float => |f| .{ .int = @as(i64, @intFromFloat(f)) },
        .string => |s| .{ .string = s },
        else => null,
    };
}

fn getStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn extractRootUri(obj: std.json.ObjectMap) ?[]const u8 {
    const params_val = obj.get("params") orelse return null;
    if (params_val != .object) return null;
    const params = params_val.object;

    // Try rootUri first
    if (params.get("rootUri")) |root_val| {
        if (root_val == .string) return root_val.string;
    }

    // Fall back to first workspaceFolder
    const folders_val = params.get("workspaceFolders") orelse return null;
    if (folders_val != .array or folders_val.array.items.len == 0) return null;
    const first = folders_val.array.items[0];
    if (first != .object) return null;
    const uri_val = first.object.get("uri") orelse return null;
    return if (uri_val == .string) uri_val.string else null;
}

const TextDocumentInfo = struct {
    uri: []const u8,
    text: ?[]const u8 = null,
};

fn extractTextDocument(obj: std.json.ObjectMap) ?TextDocumentInfo {
    const params_val = obj.get("params") orelse return null;
    if (params_val != .object) return null;
    const text_doc_val = params_val.object.get("textDocument") orelse return null;
    if (text_doc_val != .object) return null;
    const text_doc = text_doc_val.object;

    const uri = getStringField(text_doc, "uri") orelse return null;
    const text = getStringField(text_doc, "text");
    return .{ .uri = uri, .text = text };
}

fn extractContentChangeText(obj: std.json.ObjectMap) ?[]const u8 {
    const params_val = obj.get("params") orelse return null;
    if (params_val != .object) return null;
    const changes_val = params_val.object.get("contentChanges") orelse return null;
    if (changes_val != .array or changes_val.array.items.len == 0) return null;
    const first = changes_val.array.items[0];
    if (first != .object) return null;
    return getStringField(first.object, "text");
}

fn extractPosition(obj: std.json.ObjectMap) ?protocol.Position {
    const params_val = obj.get("params") orelse return null;
    if (params_val != .object) return null;
    const position_val = params_val.object.get("position") orelse return null;
    if (position_val != .object) return null;
    return parsePosition(position_val.object);
}

fn parsePosition(obj: std.json.ObjectMap) ?protocol.Position {
    const line_val = obj.get("line") orelse return null;
    const char_val = obj.get("character") orelse return null;

    const line = parseUsize(line_val) orelse return null;
    const character = parseUsize(char_val) orelse return null;

    return .{ .line = line, .character = character };
}

fn parseUsize(value: std.json.Value) ?usize {
    return switch (value) {
        .integer => |i| if (i < 0) null else @as(usize, @intCast(i)),
        .float => |f| if (f < 0) null else @as(usize, @intFromFloat(f)),
        else => null,
    };
}

fn findLineRange(text: []const u8, target_line: usize) struct { start: usize, end: usize } {
    var current_line: usize = 0;
    var start: usize = 0;
    var i: usize = 0;

    while (i < text.len) : (i += 1) {
        if (current_line == target_line) {
            var end = i;
            while (end < text.len and text[end] != '\n') : (end += 1) {}
            return .{ .start = start, .end = end };
        }
        if (text[i] == '\n') {
            current_line += 1;
            start = i + 1;
        }
    }

    if (current_line == target_line) {
        return .{ .start = start, .end = text.len };
    }

    return .{ .start = text.len, .end = text.len };
}

fn findCompletionContext(line: []const u8, cursor_col: usize) ?CompletionContext {
    const prefix = line[0..cursor_col];

    const tag_idx = std.mem.lastIndexOf(u8, prefix, "[[t/");
    const file_idx = std.mem.lastIndexOf(u8, prefix, "[[");

    if (tag_idx != null and (file_idx == null or tag_idx.? >= file_idx.?)) {
        const idx = tag_idx.?;
        if (std.mem.indexOfPos(u8, prefix, idx, "]]")) | _ | {
            return null;
        }
        return .{ .kind = .tag, .start_column = idx + 4 };
    }

    if (file_idx) |idx| {
        if (std.mem.indexOfPos(u8, prefix, idx, "]]")) | _ | {
            return null;
        }
        return .{ .kind = .file, .start_column = idx + 2 };
    }

    return null;
}

fn resolveArtPath(allocator: std.mem.Allocator, root_path: ?[]const u8, uri: []const u8) ![]const u8 {
    if (root_path) |root| {
        return std.fs.path.join(allocator, &.{ root, "art" });
    }

    const path = try uriToPath(allocator, uri);
    defer allocator.free(path);

    if (std.mem.lastIndexOf(u8, path, "/art/")) |idx| {
        return allocator.dupe(u8, path[0..idx + 4]);
    }
    if (std.mem.lastIndexOf(u8, path, "\\art\\")) |idx| {
        return allocator.dupe(u8, path[0..idx + 4]);
    }

    return allocator.dupe(u8, "");
}

fn collectArtFiles(allocator: std.mem.Allocator, art_path: []const u8) ![][]const u8 {
    var results: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (results.items) |item| allocator.free(item);
        results.deinit(allocator);
    }

    var dir = std.fs.cwd().openDir(art_path, .{ .iterate = true }) catch {
        return results.toOwnedSlice(allocator);
    };
    defer dir.close();

    var walker = dir.walk(allocator) catch return results.toOwnedSlice(allocator);
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        if (entry.kind == .directory) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;
        if (std.mem.startsWith(u8, entry.path, "index/") or std.mem.startsWith(u8, entry.path, "index\\")) {
            continue;
        }

        const path_copy = try allocator.dupe(u8, entry.path);
        try results.append(allocator, path_copy);
    }

    return results.toOwnedSlice(allocator);
}

fn freeStringList(allocator: std.mem.Allocator, list: [][]const u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

fn stripMdExtension(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".md")) {
        return path[0 .. path.len - 3];
    }
    return path;
}

fn uriToPath(allocator: std.mem.Allocator, uri: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) {
        return error.InvalidUri;
    }

    var path = uri["file://".len..];
    if (path.len >= 3 and path[0] == '/' and path[2] == ':' and path[1] >= 'A' and path[1] <= 'Z') {
        path = path[1..];
    }

    return try percentDecode(allocator, path);
}

fn percentDecode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = hexValue(input[i + 1]) orelse return error.InvalidUri;
            const lo = hexValue(input[i + 2]) orelse return error.InvalidUri;
            try output.append(allocator, @as(u8, (hi << 4) | lo));
            i += 3;
        } else {
            try output.append(allocator, input[i]);
            i += 1;
        }
    }

    return output.toOwnedSlice(allocator);
}

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// ============================================================================
// Unit Tests
// ============================================================================

test "findCompletionContext: detects file completion after [[" {
    const ctx = findCompletionContext("some text [[foo", 15);
    try std.testing.expect(ctx != null);
    try std.testing.expectEqual(CompletionContext.Kind.file, ctx.?.kind);
    try std.testing.expectEqual(@as(usize, 12), ctx.?.start_column);
}

test "findCompletionContext: detects tag completion after [[t/" {
    const ctx = findCompletionContext("some text [[t/bar", 17);
    try std.testing.expect(ctx != null);
    try std.testing.expectEqual(CompletionContext.Kind.tag, ctx.?.kind);
    try std.testing.expectEqual(@as(usize, 14), ctx.?.start_column);
}

test "findCompletionContext: returns null when no [[ prefix" {
    const ctx = findCompletionContext("some plain text", 15);
    try std.testing.expect(ctx == null);
}

test "findCompletionContext: returns null when bracket is closed" {
    const ctx = findCompletionContext("some [[link]] more", 18);
    try std.testing.expect(ctx == null);
}

test "findCompletionContext: tag takes priority over file when [[t/ present" {
    const ctx = findCompletionContext("[[t/", 4);
    try std.testing.expect(ctx != null);
    try std.testing.expectEqual(CompletionContext.Kind.tag, ctx.?.kind);
}

test "findCompletionContext: handles cursor at start of line" {
    const ctx = findCompletionContext("[[", 2);
    try std.testing.expect(ctx != null);
    try std.testing.expectEqual(CompletionContext.Kind.file, ctx.?.kind);
    try std.testing.expectEqual(@as(usize, 2), ctx.?.start_column);
}

test "findCompletionContext: handles empty prefix typed after [[" {
    const ctx = findCompletionContext("see [[", 6);
    try std.testing.expect(ctx != null);
    try std.testing.expectEqual(@as(usize, 6), ctx.?.start_column);
}

test "findLineRange: finds first line" {
    const text = "line one\nline two\nline three";
    const range = findLineRange(text, 0);
    try std.testing.expectEqual(@as(usize, 0), range.start);
    try std.testing.expectEqual(@as(usize, 8), range.end);
    try std.testing.expectEqualStrings("line one", text[range.start..range.end]);
}

test "findLineRange: finds middle line" {
    const text = "line one\nline two\nline three";
    const range = findLineRange(text, 1);
    try std.testing.expectEqual(@as(usize, 9), range.start);
    try std.testing.expectEqual(@as(usize, 17), range.end);
    try std.testing.expectEqualStrings("line two", text[range.start..range.end]);
}

test "findLineRange: finds last line without trailing newline" {
    const text = "line one\nline two\nline three";
    const range = findLineRange(text, 2);
    try std.testing.expectEqual(@as(usize, 18), range.start);
    try std.testing.expectEqual(@as(usize, 28), range.end);
    try std.testing.expectEqualStrings("line three", text[range.start..range.end]);
}

test "findLineRange: handles line beyond end" {
    const text = "only one line";
    const range = findLineRange(text, 5);
    try std.testing.expectEqual(@as(usize, 13), range.start);
    try std.testing.expectEqual(@as(usize, 13), range.end);
}

test "findLineRange: handles empty text" {
    const text = "";
    const range = findLineRange(text, 0);
    try std.testing.expectEqual(@as(usize, 0), range.start);
    try std.testing.expectEqual(@as(usize, 0), range.end);
}

test "uriToPath: converts simple file URI" {
    const allocator = std.testing.allocator;
    const path = try uriToPath(allocator, "file:///home/user/file.md");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/home/user/file.md", path);
}

test "uriToPath: handles percent-encoded spaces" {
    const allocator = std.testing.allocator;
    const path = try uriToPath(allocator, "file:///home/user/my%20file.md");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/home/user/my file.md", path);
}

test "uriToPath: handles Windows drive letter" {
    const allocator = std.testing.allocator;
    const path = try uriToPath(allocator, "file:///C:/Users/test.md");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("C:/Users/test.md", path);
}

test "uriToPath: rejects non-file URI" {
    const allocator = std.testing.allocator;
    const result = uriToPath(allocator, "http://example.com");
    try std.testing.expectError(error.InvalidUri, result);
}

test "percentDecode: handles mixed encoding" {
    const allocator = std.testing.allocator;
    const decoded = try percentDecode(allocator, "hello%20world%21");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("hello world!", decoded);
}

test "percentDecode: handles uppercase hex" {
    const allocator = std.testing.allocator;
    const decoded = try percentDecode(allocator, "%2F%2E");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("/.", decoded);
}

test "percentDecode: handles lowercase hex" {
    const allocator = std.testing.allocator;
    const decoded = try percentDecode(allocator, "%2f%2e");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("/.", decoded);
}

test "percentDecode: passes through plain text" {
    const allocator = std.testing.allocator;
    const decoded = try percentDecode(allocator, "plain-text_123");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("plain-text_123", decoded);
}

test "percentDecode: rejects invalid hex" {
    const allocator = std.testing.allocator;
    const result = percentDecode(allocator, "%GG");
    try std.testing.expectError(error.InvalidUri, result);
}

test "hexValue: converts decimal digits" {
    try std.testing.expectEqual(@as(u8, 0), hexValue('0').?);
    try std.testing.expectEqual(@as(u8, 9), hexValue('9').?);
}

test "hexValue: converts lowercase hex" {
    try std.testing.expectEqual(@as(u8, 10), hexValue('a').?);
    try std.testing.expectEqual(@as(u8, 15), hexValue('f').?);
}

test "hexValue: converts uppercase hex" {
    try std.testing.expectEqual(@as(u8, 10), hexValue('A').?);
    try std.testing.expectEqual(@as(u8, 15), hexValue('F').?);
}

test "hexValue: returns null for invalid chars" {
    try std.testing.expect(hexValue('g') == null);
    try std.testing.expect(hexValue('Z') == null);
    try std.testing.expect(hexValue(' ') == null);
}

test "stripMdExtension: removes .md suffix" {
    try std.testing.expectEqualStrings("file", stripMdExtension("file.md"));
}

test "stripMdExtension: preserves non-md files" {
    try std.testing.expectEqualStrings("file.txt", stripMdExtension("file.txt"));
}

test "stripMdExtension: handles nested paths" {
    try std.testing.expectEqualStrings("path/to/file", stripMdExtension("path/to/file.md"));
}

test "parseId: parses integer id" {
    const id = parseId(.{ .integer = 42 });
    try std.testing.expect(id != null);
    try std.testing.expectEqual(@as(i64, 42), id.?.int);
}

test "parseId: parses string id" {
    const id = parseId(.{ .string = "req-123" });
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("req-123", id.?.string);
}

test "parseId: parses float as integer" {
    const id = parseId(.{ .float = 42.0 });
    try std.testing.expect(id != null);
    try std.testing.expectEqual(@as(i64, 42), id.?.int);
}

test "parseId: returns null for invalid types" {
    try std.testing.expect(parseId(.null) == null);
    try std.testing.expect(parseId(.{ .bool = true }) == null);
}

test "parseUsize: parses positive integer" {
    const val = parseUsize(.{ .integer = 10 });
    try std.testing.expectEqual(@as(usize, 10), val.?);
}

test "parseUsize: returns null for negative" {
    const val = parseUsize(.{ .integer = -1 });
    try std.testing.expect(val == null);
}

test "parseUsize: parses positive float" {
    const val = parseUsize(.{ .float = 5.0 });
    try std.testing.expectEqual(@as(usize, 5), val.?);
}

test "Server: init and deinit work correctly" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator);
    defer server.deinit();
    try std.testing.expect(server.root_path == null);
    try std.testing.expect(!server.shutdown_requested);
}
