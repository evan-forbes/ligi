//! Recursive markdown link collection and merge/rewrite helpers for PDF mode.

const std = @import("std");

pub const CollectResult = struct {
    files: []const []const u8,
    warnings: []const []const u8,

    pub fn deinit(self: *CollectResult, allocator: std.mem.Allocator) void {
        for (self.files) |file_path| allocator.free(file_path);
        allocator.free(self.files);

        for (self.warnings) |warning| allocator.free(warning);
        allocator.free(self.warnings);
    }
};

pub const MergeResult = struct {
    markdown: []const u8,

    pub fn deinit(self: *MergeResult, allocator: std.mem.Allocator) void {
        allocator.free(self.markdown);
    }
};

const LinkToken = struct {
    start: usize,
    end: usize,
    target_start: usize,
    target_end: usize,
    is_image: bool,
};

const RootViolation = error{
    OutsideRoot,
    MissingFile,
};

/// Collect markdown files reachable from `input_abs` via local markdown links.
/// Files outside `workspace_root_abs` are skipped with warnings.
pub fn collectLinkedMarkdown(
    allocator: std.mem.Allocator,
    input_abs: []const u8,
    workspace_root_abs: []const u8,
) !CollectResult {
    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();

    var ordered: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (ordered.items) |path| allocator.free(path);
        ordered.deinit(allocator);
    }

    var warnings: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (warnings.items) |warning| allocator.free(warning);
        warnings.deinit(allocator);
    }

    const Ctx = struct {
        allocator: std.mem.Allocator,
        workspace_root_abs: []const u8,
        visited: *std.StringHashMap(void),
        ordered: *std.ArrayList([]const u8),
        warnings: *std.ArrayList([]const u8),

        fn visit(self: *@This(), file_abs_owned: []const u8) !void {
            if (self.visited.contains(file_abs_owned)) {
                self.allocator.free(file_abs_owned);
                return;
            }

            try self.visited.put(file_abs_owned, {});
            try self.ordered.append(self.allocator, file_abs_owned);

            const content = try readFileAbsolute(self.allocator, file_abs_owned);
            defer self.allocator.free(content);

            const tokens = try parseMarkdownLinks(self.allocator, content);
            defer self.allocator.free(tokens);

            for (tokens) |token| {
                if (token.is_image) continue;

                const raw = std.mem.trim(u8, content[token.target_start..token.target_end], " \t\r\n");
                const destination = parseLinkDestination(raw) orelse continue;
                if (destination.len == 0) continue;
                if (destination[0] == '#') continue;
                if (isExternalLink(destination)) continue;

                const local_path = stripQueryAndFragment(destination).path;
                if (local_path.len == 0) continue;
                if (!isMarkdownPath(local_path)) continue;

                const resolved_abs = resolveLinkedPath(
                    self.allocator,
                    file_abs_owned,
                    local_path,
                    self.workspace_root_abs,
                ) catch |err| {
                    if (err == RootViolation.OutsideRoot) {
                        const warning = try std.fmt.allocPrint(
                            self.allocator,
                            "warning: pdf: skipping linked markdown outside root: {s}",
                            .{local_path},
                        );
                        try self.warnings.append(self.allocator, warning);
                        continue;
                    }
                    if (err == RootViolation.MissingFile) {
                        const warning = try std.fmt.allocPrint(
                            self.allocator,
                            "warning: pdf: skipping missing linked markdown: {s}",
                            .{local_path},
                        );
                        try self.warnings.append(self.allocator, warning);
                        continue;
                    }
                    return err;
                };

                try self.visit(resolved_abs);
            }
        }
    };

    var ctx: Ctx = .{
        .allocator = allocator,
        .workspace_root_abs = workspace_root_abs,
        .visited = &visited,
        .ordered = &ordered,
        .warnings = &warnings,
    };

    try ctx.visit(try allocator.dupe(u8, input_abs));

    return .{
        .files = try ordered.toOwnedSlice(allocator),
        .warnings = try warnings.toOwnedSlice(allocator),
    };
}

/// Build merged markdown from collected files, rewriting links:
/// - intra-collection markdown links => internal anchors
/// - local images => `/api/file?path=<encoded-relative-path>`
pub fn buildMergedMarkdown(
    allocator: std.mem.Allocator,
    files_abs: []const []const u8,
    serve_root_abs: []const u8,
) !MergeResult {
    var anchor_map = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iter = anchor_map.iterator();
        while (iter.next()) |entry| allocator.free(entry.value_ptr.*);
        anchor_map.deinit();
    }

    for (files_abs) |file_abs| {
        const rel = relativeForDisplay(allocator, serve_root_abs, file_abs) catch try allocator.dupe(u8, file_abs);
        defer allocator.free(rel);

        const anchor = try makeAnchor(allocator, rel);
        try anchor_map.put(file_abs, anchor);
    }

    var merged: std.ArrayList(u8) = .empty;
    errdefer merged.deinit(allocator);

    for (files_abs, 0..) |file_abs, idx| {
        const rel = relativeForDisplay(allocator, serve_root_abs, file_abs) catch try allocator.dupe(u8, file_abs);
        defer allocator.free(rel);

        const content = try readFileAbsolute(allocator, file_abs);
        defer allocator.free(content);

        const rewritten = try rewriteMarkdownContent(
            allocator,
            content,
            file_abs,
            serve_root_abs,
            &anchor_map,
        );
        defer allocator.free(rewritten);

        const anchor = anchor_map.get(file_abs).?;
        if (idx > 0) {
            try merged.appendSlice(allocator, "\n\n---\n\n");
            try std.fmt.format(merged.writer(allocator), "## {s}\n\n", .{rel});
        }

        try std.fmt.format(merged.writer(allocator), "<a id=\"{s}\"></a>\n\n", .{anchor});
        try merged.appendSlice(allocator, rewritten);
        try merged.appendSlice(allocator, "\n");
    }

    return .{ .markdown = try merged.toOwnedSlice(allocator) };
}

fn rewriteMarkdownContent(
    allocator: std.mem.Allocator,
    content: []const u8,
    source_abs: []const u8,
    serve_root_abs: []const u8,
    anchor_map: *const std.StringHashMap([]const u8),
) ![]const u8 {
    const tokens = try parseMarkdownLinks(allocator, content);
    defer allocator.free(tokens);

    if (tokens.len == 0) {
        return try allocator.dupe(u8, content);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var cursor: usize = 0;
    for (tokens) |token| {
        try out.appendSlice(allocator, content[cursor..token.target_start]);

        const raw = std.mem.trim(u8, content[token.target_start..token.target_end], " \t\r\n");
        const parsed = parseLinkDestination(raw);
        if (parsed == null) {
            try out.appendSlice(allocator, content[token.target_start..token.target_end]);
            cursor = token.target_end;
            continue;
        }

        const replacement = try rewriteTarget(
            allocator,
            parsed.?,
            token.is_image,
            source_abs,
            serve_root_abs,
            anchor_map,
        );
        defer if (replacement) |r| allocator.free(r);

        if (replacement) |r| {
            try out.appendSlice(allocator, r);
        } else {
            try out.appendSlice(allocator, content[token.target_start..token.target_end]);
        }

        cursor = token.target_end;
    }
    try out.appendSlice(allocator, content[cursor..]);

    return try out.toOwnedSlice(allocator);
}

fn rewriteTarget(
    allocator: std.mem.Allocator,
    destination: []const u8,
    is_image: bool,
    source_abs: []const u8,
    serve_root_abs: []const u8,
    anchor_map: *const std.StringHashMap([]const u8),
) !?[]const u8 {
    if (destination.len == 0) return null;
    if (destination[0] == '#') return null;
    if (isExternalLink(destination)) return null;

    const split = stripQueryAndFragment(destination);
    if (split.path.len == 0) return null;

    const resolved_abs = resolveLinkedPath(allocator, source_abs, split.path, serve_root_abs) catch return null;
    defer allocator.free(resolved_abs);

    if (is_image) {
        const rel = relativeForDisplay(allocator, serve_root_abs, resolved_abs) catch return null;
        defer allocator.free(rel);

        const encoded = try encodeURIComponent(allocator, rel);
        defer allocator.free(encoded);

        return try std.fmt.allocPrint(allocator, "/api/file?path={s}", .{encoded});
    }

    if (isMarkdownPath(split.path)) {
        if (anchor_map.get(resolved_abs)) |anchor| {
            return try std.fmt.allocPrint(allocator, "#{s}", .{anchor});
        }
    }

    return null;
}

fn resolveLinkedPath(
    allocator: std.mem.Allocator,
    source_abs: []const u8,
    link_path: []const u8,
    workspace_root_abs: []const u8,
) RootViolation![]const u8 {
    const source_dir = std.fs.path.dirname(source_abs) orelse return RootViolation.MissingFile;
    const joined = if (std.fs.path.isAbsolute(link_path))
        allocator.dupe(u8, link_path) catch return RootViolation.MissingFile
    else
        std.fs.path.join(allocator, &.{ source_dir, link_path }) catch return RootViolation.MissingFile;
    defer allocator.free(joined);

    const resolved = std.fs.cwd().realpathAlloc(allocator, joined) catch return RootViolation.MissingFile;
    errdefer allocator.free(resolved);

    if (!isWithinRoot(workspace_root_abs, resolved)) {
        return RootViolation.OutsideRoot;
    }

    const stat = std.fs.openFileAbsolute(resolved, .{}) catch return RootViolation.MissingFile;
    stat.close();

    return resolved;
}

fn parseMarkdownLinks(allocator: std.mem.Allocator, content: []const u8) ![]const LinkToken {
    var tokens: std.ArrayList(LinkToken) = .empty;
    errdefer tokens.deinit(allocator);

    var in_fence = false;
    var line_start: usize = 0;
    while (line_start <= content.len) {
        const rel_end = std.mem.indexOfScalarPos(u8, content, line_start, '\n') orelse content.len;
        const line = content[line_start..rel_end];

        const trimmed_left = std.mem.trimLeft(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed_left, "```") or std.mem.startsWith(u8, trimmed_left, "~~~")) {
            in_fence = !in_fence;
        } else if (!in_fence) {
            try parseLinksInLine(allocator, line, line_start, &tokens);
        }

        if (rel_end == content.len) break;
        line_start = rel_end + 1;
    }

    return try tokens.toOwnedSlice(allocator);
}

fn parseLinksInLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_offset: usize,
    tokens: *std.ArrayList(LinkToken),
) !void {
    var i: usize = 0;
    var in_inline_code = false;

    while (i < line.len) {
        const c = line[i];

        if (c == '`') {
            in_inline_code = !in_inline_code;
            i += 1;
            continue;
        }
        if (in_inline_code) {
            i += 1;
            continue;
        }

        var is_image = false;
        var link_start = i;
        if (c == '!' and i + 1 < line.len and line[i + 1] == '[') {
            is_image = true;
            i += 2;
            link_start = i - 2;
        } else if (c == '[') {
            i += 1;
            link_start = i - 1;
        } else {
            i += 1;
            continue;
        }

        var label_end = i;
        while (label_end < line.len) {
            if (line[label_end] == '\\' and label_end + 1 < line.len) {
                label_end += 2;
                continue;
            }
            if (line[label_end] == ']') break;
            label_end += 1;
        }
        if (label_end >= line.len or label_end + 1 >= line.len or line[label_end + 1] != '(') {
            i = link_start + 1;
            continue;
        }

        const target_start = label_end + 2;
        var target_end = target_start;
        var depth: usize = 0;
        while (target_end < line.len) {
            const ch = line[target_end];
            if (ch == '\\' and target_end + 1 < line.len) {
                target_end += 2;
                continue;
            }
            if (ch == '(') {
                depth += 1;
                target_end += 1;
                continue;
            }
            if (ch == ')') {
                if (depth == 0) break;
                depth -= 1;
                target_end += 1;
                continue;
            }
            target_end += 1;
        }
        if (target_end >= line.len) {
            i = link_start + 1;
            continue;
        }

        try tokens.append(allocator, .{
            .start = line_offset + link_start,
            .end = line_offset + target_end + 1,
            .target_start = line_offset + target_start,
            .target_end = line_offset + target_end,
            .is_image = is_image,
        });
        i = target_end + 1;
    }
}

fn parseLinkDestination(raw_target: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw_target, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (trimmed[0] == '<') {
        const close = std.mem.indexOfScalar(u8, trimmed, '>') orelse return null;
        if (close <= 1) return null;
        return trimmed[1..close];
    }

    if (std.mem.indexOfAny(u8, trimmed, " \t\r\n") != null) return null;
    return trimmed;
}

fn stripQueryAndFragment(destination: []const u8) struct { path: []const u8, fragment: []const u8 } {
    const q_idx = std.mem.indexOfScalar(u8, destination, '?');
    const h_idx = std.mem.indexOfScalar(u8, destination, '#');

    const cut_idx = blk: {
        if (q_idx == null and h_idx == null) break :blk destination.len;
        if (q_idx == null) break :blk h_idx.?;
        if (h_idx == null) break :blk q_idx.?;
        break :blk @min(q_idx.?, h_idx.?);
    };

    const fragment = if (h_idx) |idx| destination[idx + 1 ..] else "";
    return .{
        .path = destination[0..cut_idx],
        .fragment = fragment,
    };
}

fn isExternalLink(target: []const u8) bool {
    if (std.mem.startsWith(u8, target, "//")) return true;
    if (std.mem.startsWith(u8, target, "http://")) return true;
    if (std.mem.startsWith(u8, target, "https://")) return true;
    if (std.mem.startsWith(u8, target, "mailto:")) return true;
    if (std.mem.startsWith(u8, target, "tel:")) return true;
    if (std.mem.startsWith(u8, target, "data:")) return true;

    if (std.mem.indexOfScalar(u8, target, ':')) |colon| {
        const slash = std.mem.indexOfScalar(u8, target, '/') orelse target.len;
        if (colon < slash) return true;
    }
    return false;
}

fn isMarkdownPath(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(ext, ".md") or std.ascii.eqlIgnoreCase(ext, ".markdown");
}

pub fn isWithinRoot(root_abs: []const u8, path_abs: []const u8) bool {
    if (std.mem.eql(u8, root_abs, "/")) return true;
    if (!std.mem.startsWith(u8, path_abs, root_abs)) return false;
    if (path_abs.len == root_abs.len) return true;
    if (root_abs[root_abs.len - 1] == std.fs.path.sep) return true;
    return path_abs[root_abs.len] == std.fs.path.sep;
}

fn readFileAbsolute(allocator: std.mem.Allocator, abs_path: []const u8) ![]const u8 {
    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 32 * 1024 * 1024);
}

fn relativeForDisplay(allocator: std.mem.Allocator, root_abs: []const u8, abs_path: []const u8) ![]const u8 {
    return try std.fs.path.relative(allocator, root_abs, abs_path);
}

fn makeAnchor(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "ligi-doc-");

    var wrote_non_dash = false;
    var last_dash = false;
    for (text) |c| {
        const normalized = if (std.ascii.isAlphanumeric(c)) std.ascii.toLower(c) else '-';
        if (normalized == '-') {
            if (last_dash) continue;
            try out.append(allocator, normalized);
            last_dash = true;
        } else {
            wrote_non_dash = true;
            last_dash = false;
            try out.append(allocator, normalized);
        }
    }

    if (!wrote_non_dash) {
        try out.appendSlice(allocator, "root");
    }

    // Strip trailing dashes.
    while (out.items.len > "ligi-doc-".len and out.items[out.items.len - 1] == '-') {
        _ = out.pop();
    }

    return try out.toOwnedSlice(allocator);
}

pub fn encodeURIComponent(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(allocator, c);
        } else {
            try std.fmt.format(out.writer(allocator), "%{X:0>2}", .{c});
        }
    }

    return try out.toOwnedSlice(allocator);
}

test "parse markdown links ignores code fences and images when collecting markdown links" {
    const allocator = std.testing.allocator;
    const md =
        \\# Title
        \\[one](a.md)
        \\![img](img.png)
        \\```md
        \\[not-a-link](inside.md)
        \\```
    ;
    const tokens = try parseMarkdownLinks(allocator, md);
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expect(!tokens[0].is_image);
    try std.testing.expect(tokens[1].is_image);
}

test "encodeURIComponent encodes slashes and spaces" {
    const allocator = std.testing.allocator;
    const encoded = try encodeURIComponent(allocator, "a/b c");
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("a%2Fb%20c", encoded);
}

test "makeAnchor normalizes symbols" {
    const allocator = std.testing.allocator;
    const anchor = try makeAnchor(allocator, "docs/Guide Intro.md");
    defer allocator.free(anchor);

    try std.testing.expectEqualStrings("ligi-doc-docs-guide-intro-md", anchor);
}

test "makeAnchor strips trailing dashes" {
    const allocator = std.testing.allocator;
    const anchor = try makeAnchor(allocator, "docs/guide/");
    defer allocator.free(anchor);

    try std.testing.expectEqualStrings("ligi-doc-docs-guide", anchor);
}

test "extract links ignores inline code" {
    const allocator = std.testing.allocator;
    const md = "See `[not-a-link](foo.md)` for details and [real](bar.md).";
    const tokens = try parseMarkdownLinks(allocator, md);
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try std.testing.expect(!tokens[0].is_image);
    const target = md[tokens[0].target_start..tokens[0].target_end];
    try std.testing.expectEqualStrings("bar.md", target);
}

test "isExternalLink identifies external protocols" {
    try std.testing.expect(isExternalLink("https://example.com"));
    try std.testing.expect(isExternalLink("http://example.com"));
    try std.testing.expect(isExternalLink("mailto:a@b.c"));
    try std.testing.expect(isExternalLink("//cdn.example.com"));
    try std.testing.expect(!isExternalLink("docs/guide.md"));
    try std.testing.expect(!isExternalLink("../readme.md"));
    try std.testing.expect(!isExternalLink("#anchor"));
}

test "stripQueryAndFragment separates path from query and fragment" {
    const full = stripQueryAndFragment("docs/guide.md?v=1#section");
    try std.testing.expectEqualStrings("docs/guide.md", full.path);

    const no_query = stripQueryAndFragment("docs/guide.md#section");
    try std.testing.expectEqualStrings("docs/guide.md", no_query.path);
    try std.testing.expectEqualStrings("section", no_query.fragment);

    const plain = stripQueryAndFragment("docs/guide.md");
    try std.testing.expectEqualStrings("docs/guide.md", plain.path);
    try std.testing.expectEqualStrings("", plain.fragment);
}

test "isWithinRoot rejects paths outside root" {
    try std.testing.expect(isWithinRoot("/home/user/project", "/home/user/project/docs/a.md"));
    try std.testing.expect(isWithinRoot("/home/user/project", "/home/user/project"));
    try std.testing.expect(!isWithinRoot("/home/user/project", "/home/user/other/a.md"));
    try std.testing.expect(!isWithinRoot("/home/user/project", "/home/user/projectx/a.md"));
    try std.testing.expect(isWithinRoot("/", "/anything"));
}

test "isMarkdownPath recognizes md and markdown extensions" {
    try std.testing.expect(isMarkdownPath("file.md"));
    try std.testing.expect(isMarkdownPath("FILE.MD"));
    try std.testing.expect(isMarkdownPath("notes.markdown"));
    try std.testing.expect(!isMarkdownPath("image.png"));
    try std.testing.expect(!isMarkdownPath("script.js"));
}

test "parseLinkDestination handles angle brackets and spaces" {
    try std.testing.expectEqualStrings("foo.md", parseLinkDestination("  foo.md  ").?);
    try std.testing.expectEqualStrings("foo.md", parseLinkDestination("<foo.md>").?);
    try std.testing.expect(parseLinkDestination("has space") == null);
    try std.testing.expect(parseLinkDestination("") == null);
    try std.testing.expect(parseLinkDestination("  ") == null);
}
