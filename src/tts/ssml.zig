//! Markdown to SSML conversion utilities.

const std = @import("std");

/// State machine for tracking parser position within the markdown document.
pub const ParserState = enum {
    /// Normal text outside any special block. Also the initial state.
    normal,
    /// Inside a fenced code block (``` ... ```)
    fenced_code,
    /// Inside a TOML frontmatter block (```toml at the start of the document)
    frontmatter,
    /// Inside an @remove block
    remove_block,
    /// Inside an HTML comment that spans multiple lines
    html_comment,
    /// Inside a table (consecutive lines starting with |)
    table,
};

/// Result of converting a markdown document to SSML.
/// Caller owns the returned memory (allocated via the provided allocator).
pub const SsmlResult = struct {
    /// The SSML string, wrapped in <speak>...</speak>
    ssml: []const u8,
    /// Number of lines skipped (code blocks, tables, etc.)
    lines_skipped: u32,
    /// Number of content lines processed
    lines_processed: u32,
};

/// SSML timing constants. These are not user-configurable.
const h1_pre_pause = 600;
const h1_post_pause = 400;
const h2_pre_pause = 500;
const h2_post_pause = 300;
const h3_pre_pause = 400;
const h3_post_pause = 200;
const rule_pause = 800;

/// Escape XML special characters in a string.
/// & -> &amp;  (must be first to avoid double-escaping)
/// < -> &lt;
/// > -> &gt;
/// " -> &quot;
/// ' -> &apos;
/// Returns: allocated escaped string (caller owns).
pub fn escapeXml(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            else => try out.append(allocator, c),
        }
    }

    return out.toOwnedSlice(allocator);
}

/// Remove all [[t/...]] tag references from a string.
/// Handles nested paths like [[t/t/d/26-01-14]].
/// Scans for "[[t/" and finds the matching "]]", removing everything between (inclusive).
/// Returns: allocated string with tags removed (caller owns).
pub fn stripTags(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], "[[t/")) {
            if (std.mem.indexOf(u8, input[i + 4 ..], "]]") ) |rel| {
                i = i + 4 + rel + 2;
                continue;
            }
        }

        try out.append(allocator, input[i]);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

fn stripImages(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '!' and i + 1 < input.len and input[i + 1] == '[') {
            const alt_start = i + 2;
            if (std.mem.indexOf(u8, input[alt_start..], "](") ) |rel| {
                const link_start = alt_start + rel + 2;
                if (std.mem.indexOfScalar(u8, input[link_start..], ')')) |rel_close| {
                    i = link_start + rel_close + 1;
                    continue;
                }
            }
        }

        try out.append(allocator, input[i]);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

fn stripLinks(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '[') {
            if (std.mem.indexOf(u8, input[i + 1 ..], "](") ) |rel| {
                const text_end = i + 1 + rel;
                const link_start = text_end + 2;
                if (std.mem.indexOfScalar(u8, input[link_start..], ')')) |rel_close| {
                    try out.appendSlice(allocator, input[i + 1 .. text_end]);
                    i = link_start + rel_close + 1;
                    continue;
                }
            }
        }

        try out.append(allocator, input[i]);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

fn transformBold(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (i + 1 < input.len and ((input[i] == '*' and input[i + 1] == '*') or (input[i] == '_' and input[i + 1] == '_'))) {
            const marker = input[i];
            const start = i + 2;
            var j: usize = start;
            var found = false;
            while (j + 1 < input.len) : (j += 1) {
                if (input[j] == marker and input[j + 1] == marker) {
                    found = true;
                    break;
                }
            }

            if (found) {
                try out.appendSlice(allocator, "<emphasis level=\"strong\">");
                try out.appendSlice(allocator, input[start..j]);
                try out.appendSlice(allocator, "</emphasis>");
                i = j + 2;
                continue;
            }

            try out.append(allocator, input[i]);
            try out.append(allocator, input[i + 1]);
            i += 2;
            continue;
        }

        try out.append(allocator, input[i]);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

fn transformItalic(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '*' or input[i] == '_') {
            const marker = input[i];
            if (i + 1 < input.len and input[i + 1] == marker) {
                try out.append(allocator, marker);
                try out.append(allocator, marker);
                i += 2;
                continue;
            }

            var j: usize = i + 1;
            var found = false;
            while (j < input.len) : (j += 1) {
                if (input[j] == marker) {
                    found = true;
                    break;
                }
            }

            if (found) {
                try out.appendSlice(allocator, "<emphasis level=\"moderate\">");
                try out.appendSlice(allocator, input[i + 1 .. j]);
                try out.appendSlice(allocator, "</emphasis>");
                i = j + 1;
                continue;
            }

            try out.append(allocator, input[i]);
            i += 1;
            continue;
        }

        try out.append(allocator, input[i]);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

fn stripInlineCode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '`') {
            if (std.mem.indexOfScalar(u8, input[i + 1 ..], '`')) |rel| {
                const end = i + 1 + rel;
                try out.appendSlice(allocator, input[i + 1 .. end]);
                i = end + 1;
                continue;
            }
        }

        try out.append(allocator, input[i]);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

/// Transform inline markdown elements within a content string to SSML.
///
/// **Critical: escaping order.** XML escaping happens FIRST on the raw input.
/// Then markdown syntax is identified and replaced with SSML tags.
/// This ensures SSML tags are never double-escaped.
///
/// Algorithm:
/// 1. Escape XML special characters in the full input string (& < > " ')
/// 2. Strip tags: remove all occurrences of [[t/...]]
/// 3. Strip images: remove all occurrences of ![alt](url) entirely
/// 4. Transform links: replace [text](url) with just text
/// 5. Transform bold: replace **text** with <emphasis level="strong">text</emphasis>
///    - Also handle __text__ variant
///    - If no closing ** is found, leave the ** as literal text
/// 6. Transform italic: replace *text* with <emphasis level="moderate">text</emphasis>
///    - Also handle _text_ variant
///    - Must not conflict with bold (** already consumed by step 5)
///    - If no closing * is found, leave the * as literal text
/// 7. Transform inline code: replace `code` with just code (strip backticks)
///
/// Returns: allocated string with SSML inline markup (caller owns).
pub fn transformInline(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    const escaped = try escapeXml(allocator, content);
    defer allocator.free(escaped);

    const no_tags = try stripTags(allocator, escaped);
    defer allocator.free(no_tags);

    const no_images = try stripImages(allocator, no_tags);
    defer allocator.free(no_images);

    const no_links = try stripLinks(allocator, no_images);
    defer allocator.free(no_links);

    const bolded = try transformBold(allocator, no_links);
    defer allocator.free(bolded);

    const italicized = try transformItalic(allocator, bolded);
    defer allocator.free(italicized);

    const no_code = try stripInlineCode(allocator, italicized);
    return no_code;
}

fn closeParagraph(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, in_paragraph: *bool) !void {
    if (in_paragraph.*) {
        try buf.appendSlice(allocator, "</p>");
        in_paragraph.* = false;
    }
}

fn isFenceLine(trimmed_left: []const u8) bool {
    return std.mem.startsWith(u8, trimmed_left, "```");
}

fn isTableLine(trimmed_left: []const u8) bool {
    return trimmed_left.len > 0 and trimmed_left[0] == '|';
}

fn isHorizontalRule(trimmed: []const u8) bool {
    if (trimmed.len < 3) return false;
    const c = trimmed[0];
    if (c != '-' and c != '_' and c != '*') return false;
    for (trimmed[1..]) |ch| {
        if (ch != c) return false;
    }
    return true;
}

fn parseHeading(trimmed_left: []const u8) ?struct { level: u8, content: []const u8 } {
    if (trimmed_left.len == 0) return null;
    var count: usize = 0;
    while (count < trimmed_left.len and trimmed_left[count] == '#') : (count += 1) {}
    if (count == 0 or count > 6) return null;
    if (count >= trimmed_left.len or trimmed_left[count] != ' ') return null;
    return .{ .level = @intCast(count), .content = trimmed_left[count + 1 ..] };
}

fn parseCheckbox(trimmed_left: []const u8) ?struct { checked: bool, content: []const u8 } {
    if (trimmed_left.len < 5) return null;
    if (trimmed_left[0] != '-' or trimmed_left[1] != ' ') return null;
    if (trimmed_left[2] != '[' or trimmed_left[4] != ']') return null;
    if (trimmed_left[3] != ' ' and trimmed_left[3] != 'x' and trimmed_left[3] != 'X') return null;

    var content = trimmed_left[5..];
    if (content.len > 0 and content[0] == ' ') content = content[1..];
    return .{ .checked = trimmed_left[3] != ' ', .content = content };
}

fn parseBullet(trimmed_left: []const u8) ?[]const u8 {
    if (trimmed_left.len < 2) return null;
    if ((trimmed_left[0] == '-' or trimmed_left[0] == '*') and trimmed_left[1] == ' ') {
        return trimmed_left[2..];
    }
    return null;
}

fn parseNumbered(trimmed_left: []const u8) ?[]const u8 {
    if (trimmed_left.len < 3) return null;
    var i: usize = 0;
    while (i < trimmed_left.len and std.ascii.isDigit(trimmed_left[i])) : (i += 1) {}
    if (i == 0 or i + 1 >= trimmed_left.len) return null;
    if (trimmed_left[i] != '.' or trimmed_left[i + 1] != ' ') return null;
    return trimmed_left[i + 2 ..];
}

fn parseBlockquote(trimmed_left: []const u8) ?[]const u8 {
    if (trimmed_left.len < 2) return null;
    if (trimmed_left[0] == '>' and trimmed_left[1] == ' ') {
        return trimmed_left[2..];
    }
    return null;
}

fn appendBreak(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, ms: u32) !void {
    const writer = buf.writer(allocator);
    try writer.print("<break time=\"{d}ms\"/>", .{ms});
}

fn emitHeading(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    level: u8,
    content: []const u8,
) !void {
    switch (level) {
        1 => {
            try appendBreak(buf, allocator, h1_pre_pause);
            try buf.appendSlice(allocator, "<prosody rate=\"95%\" pitch=\"+5%\"><emphasis level=\"strong\">");
            try buf.appendSlice(allocator, content);
            try buf.appendSlice(allocator, "</emphasis></prosody>");
            try appendBreak(buf, allocator, h1_post_pause);
        },
        2 => {
            try appendBreak(buf, allocator, h2_pre_pause);
            try buf.appendSlice(allocator, "<prosody rate=\"97%\"><emphasis level=\"strong\">");
            try buf.appendSlice(allocator, content);
            try buf.appendSlice(allocator, "</emphasis></prosody>");
            try appendBreak(buf, allocator, h2_post_pause);
        },
        else => {
            try appendBreak(buf, allocator, h3_pre_pause);
            try buf.appendSlice(allocator, "<emphasis level=\"moderate\">");
            try buf.appendSlice(allocator, content);
            try buf.appendSlice(allocator, "</emphasis>");
            try appendBreak(buf, allocator, h3_post_pause);
        },
    }
}

/// Convert markdown to SSML in a single pass.
pub fn convert(allocator: std.mem.Allocator, markdown: []const u8) !SsmlResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(arena_alloc);

    try buf.appendSlice(arena_alloc, "<speak>");

    var state: ParserState = .normal;
    var in_paragraph = false;
    var lines_processed: u32 = 0;
    var lines_skipped: u32 = 0;
    var non_empty_seen: u32 = 0;

    var it = std.mem.splitScalar(u8, markdown, '\n');
    while (it.next()) |raw_line| {
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }

        const trimmed = std.mem.trim(u8, line, " \t");
        const trimmed_left = std.mem.trimLeft(u8, line, " \t");
        const is_non_empty = trimmed.len > 0;
        const within_frontmatter_window = non_empty_seen < 5;
        if (is_non_empty) {
            non_empty_seen += 1;
        }

        switch (state) {
            .fenced_code, .frontmatter, .remove_block => {
                if (isFenceLine(trimmed_left)) {
                    state = .normal;
                }
                lines_skipped += 1;
                continue;
            },
            .html_comment => {
                if (std.mem.indexOf(u8, line, "-->") != null) {
                    state = .normal;
                }
                lines_skipped += 1;
                continue;
            },
            .table => {
                if (isTableLine(trimmed_left)) {
                    lines_skipped += 1;
                    continue;
                }
                state = .normal;
            },
            .normal => {},
        }

        if (std.mem.startsWith(u8, trimmed_left, "<!--")) {
            try closeParagraph(&buf, arena_alloc, &in_paragraph);
            if (std.mem.indexOf(u8, line, "-->") == null) {
                state = .html_comment;
            }
            lines_skipped += 1;
            continue;
        }

        if (isFenceLine(trimmed_left)) {
            try closeParagraph(&buf, arena_alloc, &in_paragraph);
            if (within_frontmatter_window and std.mem.startsWith(u8, trimmed_left, "```toml")) {
                state = .frontmatter;
            } else if (std.mem.startsWith(u8, trimmed_left, "```@remove")) {
                state = .remove_block;
            } else {
                state = .fenced_code;
            }
            lines_skipped += 1;
            continue;
        }

        if (isTableLine(trimmed_left)) {
            try closeParagraph(&buf, arena_alloc, &in_paragraph);
            state = .table;
            lines_skipped += 1;
            continue;
        }

        if (trimmed.len == 0) {
            try closeParagraph(&buf, arena_alloc, &in_paragraph);
            continue;
        }

        if (parseHeading(trimmed_left)) |heading| {
            try closeParagraph(&buf, arena_alloc, &in_paragraph);
            const transformed = try transformInline(arena_alloc, std.mem.trim(u8, heading.content, " \t"));
            const transformed_trimmed = std.mem.trim(u8, transformed, " \t");
            if (transformed_trimmed.len == 0) continue;
            try emitHeading(&buf, arena_alloc, heading.level, transformed_trimmed);
            lines_processed += 1;
            continue;
        }

        if (parseCheckbox(trimmed_left)) |checkbox| {
            try closeParagraph(&buf, arena_alloc, &in_paragraph);
            const transformed = try transformInline(arena_alloc, std.mem.trim(u8, checkbox.content, " \t"));
            const transformed_trimmed = std.mem.trim(u8, transformed, " \t");
            if (transformed_trimmed.len == 0) continue;
            try buf.appendSlice(arena_alloc, "<s>");
            try buf.appendSlice(arena_alloc, transformed_trimmed);
            if (checkbox.checked) {
                try buf.appendSlice(arena_alloc, ". Done.");
            } else {
                try buf.appendSlice(arena_alloc, ". Not yet done.");
            }
            try buf.appendSlice(arena_alloc, "</s>");
            lines_processed += 1;
            continue;
        }

        if (parseBullet(trimmed_left)) |bullet| {
            try closeParagraph(&buf, arena_alloc, &in_paragraph);
            const transformed = try transformInline(arena_alloc, std.mem.trim(u8, bullet, " \t"));
            const transformed_trimmed = std.mem.trim(u8, transformed, " \t");
            if (transformed_trimmed.len == 0) continue;
            try buf.appendSlice(arena_alloc, "<s>");
            try buf.appendSlice(arena_alloc, transformed_trimmed);
            try buf.appendSlice(arena_alloc, "</s>");
            lines_processed += 1;
            continue;
        }

        if (parseNumbered(trimmed_left)) |numbered| {
            try closeParagraph(&buf, arena_alloc, &in_paragraph);
            const transformed = try transformInline(arena_alloc, std.mem.trim(u8, numbered, " \t"));
            const transformed_trimmed = std.mem.trim(u8, transformed, " \t");
            if (transformed_trimmed.len == 0) continue;
            try buf.appendSlice(arena_alloc, "<s>");
            try buf.appendSlice(arena_alloc, transformed_trimmed);
            try buf.appendSlice(arena_alloc, "</s>");
            lines_processed += 1;
            continue;
        }

        if (parseBlockquote(trimmed_left)) |quote| {
            try closeParagraph(&buf, arena_alloc, &in_paragraph);
            const transformed = try transformInline(arena_alloc, std.mem.trim(u8, quote, " \t"));
            const transformed_trimmed = std.mem.trim(u8, transformed, " \t");
            if (transformed_trimmed.len == 0) continue;
            try buf.appendSlice(arena_alloc, "<emphasis level=\"moderate\">");
            try buf.appendSlice(arena_alloc, transformed_trimmed);
            try buf.appendSlice(arena_alloc, "</emphasis>");
            lines_processed += 1;
            continue;
        }

        if (isHorizontalRule(trimmed)) {
            try closeParagraph(&buf, arena_alloc, &in_paragraph);
            try appendBreak(&buf, arena_alloc, rule_pause);
            lines_processed += 1;
            continue;
        }

        const paragraph_text = try transformInline(arena_alloc, line);
        const paragraph_trimmed = std.mem.trim(u8, paragraph_text, " \t");
        if (paragraph_trimmed.len == 0) {
            try closeParagraph(&buf, arena_alloc, &in_paragraph);
            continue;
        }

        if (!in_paragraph) {
            try buf.appendSlice(arena_alloc, "<p>");
            in_paragraph = true;
            try buf.appendSlice(arena_alloc, paragraph_trimmed);
        } else {
            try buf.append(arena_alloc, ' ');
            try buf.appendSlice(arena_alloc, paragraph_trimmed);
        }
        lines_processed += 1;
    }

    if (in_paragraph) {
        try buf.appendSlice(arena_alloc, "</p>");
    }

    try buf.appendSlice(arena_alloc, "</speak>");

    const ssml = try allocator.dupe(u8, buf.items);
    return .{ .ssml = ssml, .lines_skipped = lines_skipped, .lines_processed = lines_processed };
}

// ============================================================================
// Tests - Phase 1
// ============================================================================

test "escape_xml_ampersand" {
    const allocator = std.testing.allocator;
    const result = try escapeXml(allocator, "A & B");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("A &amp; B", result);
}

test "escape_xml_angle_brackets" {
    const allocator = std.testing.allocator;
    const result = try escapeXml(allocator, "a < b > c");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("a &lt; b &gt; c", result);
}

test "escape_xml_all_five" {
    const allocator = std.testing.allocator;
    const result = try escapeXml(allocator, "<script>&'\"test\"");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("&lt;script&gt;&amp;&apos;&quot;test&quot;", result);
}

test "escape_xml_no_double_escape" {
    const allocator = std.testing.allocator;
    const result = try escapeXml(allocator, "already &amp; here");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("already &amp;amp; here", result);
}

test "escape_xml_empty" {
    const allocator = std.testing.allocator;
    const result = try escapeXml(allocator, "");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "escape_xml_no_specials" {
    const allocator = std.testing.allocator;
    const result = try escapeXml(allocator, "plain text");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("plain text", result);
}

test "strip_tags_simple" {
    const allocator = std.testing.allocator;
    const result = try stripTags(allocator, "tagged [[t/planning]] here");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("tagged  here", result);
}

test "strip_tags_nested" {
    const allocator = std.testing.allocator;
    const result = try stripTags(allocator, "date [[t/t/d/26-01-14]] done");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("date  done", result);
}

test "strip_tags_multiple" {
    const allocator = std.testing.allocator;
    const result = try stripTags(allocator, "[[t/a]] text [[t/b]]");
    defer allocator.free(result);
    try std.testing.expectEqualStrings(" text ", result);
}

test "strip_tags_at_boundaries" {
    const allocator = std.testing.allocator;
    const result = try stripTags(allocator, "[[t/start]]text[[t/end]]");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("text", result);
}

test "strip_tags_none" {
    const allocator = std.testing.allocator;
    const result = try stripTags(allocator, "no tags here");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("no tags here", result);
}

test "inline_bold_double_star" {
    const allocator = std.testing.allocator;
    const result = try transformInline(allocator, "this is **bold** text");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("this is <emphasis level=\"strong\">bold</emphasis> text", result);
}

test "inline_bold_double_underscore" {
    const allocator = std.testing.allocator;
    const result = try transformInline(allocator, "this is __bold__ text");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("this is <emphasis level=\"strong\">bold</emphasis> text", result);
}

test "inline_italic_single_star" {
    const allocator = std.testing.allocator;
    const result = try transformInline(allocator, "this is *italic* text");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("this is <emphasis level=\"moderate\">italic</emphasis> text", result);
}

test "inline_italic_single_underscore" {
    const allocator = std.testing.allocator;
    const result = try transformInline(allocator, "this is _italic_ text");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("this is <emphasis level=\"moderate\">italic</emphasis> text", result);
}

test "inline_bold_and_italic" {
    const allocator = std.testing.allocator;
    const result = try transformInline(allocator, "**bold** and *italic*");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("<emphasis level=\"strong\">bold</emphasis> and <emphasis level=\"moderate\">italic</emphasis>", result);
}

test "inline_code" {
    const allocator = std.testing.allocator;
    const result = try transformInline(allocator, "use `fmt.print` here");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("use fmt.print here", result);
}

test "inline_link" {
    const allocator = std.testing.allocator;
    const result = try transformInline(allocator, "see [docs](https://example.com) here");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("see docs here", result);
}

test "inline_link_no_url" {
    const allocator = std.testing.allocator;
    const result = try transformInline(allocator, "plain [text] here");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("plain [text] here", result);
}

test "inline_image" {
    const allocator = std.testing.allocator;
    const result = try transformInline(allocator, "![alt text](img.png)");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "inline_image_mid_line" {
    const allocator = std.testing.allocator;
    const result = try transformInline(allocator, "before ![alt](img.png) after");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("before  after", result);
}

test "inline_xml_then_bold" {
    const allocator = std.testing.allocator;
    const result = try transformInline(allocator, "A & **B**");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("A &amp; <emphasis level=\"strong\">B</emphasis>", result);
}

test "inline_empty_string" {
    const allocator = std.testing.allocator;
    const result = try transformInline(allocator, "");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "inline_no_markdown" {
    const allocator = std.testing.allocator;
    const result = try transformInline(allocator, "plain text");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("plain text", result);
}

test "inline_unclosed_bold" {
    const allocator = std.testing.allocator;
    const result = try transformInline(allocator, "**never closed");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("**never closed", result);
}

test "inline_unclosed_italic" {
    const allocator = std.testing.allocator;
    const result = try transformInline(allocator, "*never closed");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("*never closed", result);
}

test "inline_complex_mixed" {
    const allocator = std.testing.allocator;
    const result = try transformInline(allocator, "**Bold** [link](url) and `code` with [[t/tag]]");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("<emphasis level=\"strong\">Bold</emphasis> link and code with ", result);
}

test "inline_real_plan_line" {
    const allocator = std.testing.allocator;
    const result = try transformInline(allocator, "Review yesterday: [[t/t/d/26-01-13]] and see [notes](art/notes.md)");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Review yesterday:  and see notes", result);
}

// ============================================================================
// Tests - Phase 2
// ============================================================================

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

fn expectNoBareAmpersands(ssml: []const u8) !void {
    var i: usize = 0;
    while (i < ssml.len) : (i += 1) {
        if (ssml[i] == '&') {
            const rest = ssml[i..];
            if (std.mem.startsWith(u8, rest, "&amp;") or
                std.mem.startsWith(u8, rest, "&lt;") or
                std.mem.startsWith(u8, rest, "&gt;") or
                std.mem.startsWith(u8, rest, "&quot;") or
                std.mem.startsWith(u8, rest, "&apos;"))
            {
                continue;
            }
            try std.testing.expect(false);
        }
    }
}

test "convert_empty" {
    const allocator = std.testing.allocator;
    const result = try convert(allocator, "");
    defer allocator.free(result.ssml);
    try std.testing.expectEqualStrings("<speak></speak>", result.ssml);
    try std.testing.expectEqual(@as(u32, 0), result.lines_processed);
    try std.testing.expectEqual(@as(u32, 0), result.lines_skipped);
}

test "convert_single_heading" {
    const allocator = std.testing.allocator;
    const result = try convert(allocator, "# Hello");
    defer allocator.free(result.ssml);
    try expectContains(result.ssml, "<break time=\"600ms\"/>");
    try expectContains(result.ssml, "<prosody rate=\"95%\" pitch=\"+5%\">");
    try expectContains(result.ssml, "<emphasis level=\"strong\">Hello</emphasis>");
    try expectContains(result.ssml, "</prosody>");
    try expectContains(result.ssml, "<break time=\"400ms\"/>");
}

test "convert_h2" {
    const allocator = std.testing.allocator;
    const result = try convert(allocator, "## Section");
    defer allocator.free(result.ssml);
    try expectContains(result.ssml, "<break time=\"500ms\"/>");
    try expectContains(result.ssml, "rate=\"97%\"");
}

test "convert_h3" {
    const allocator = std.testing.allocator;
    const result = try convert(allocator, "### Sub");
    defer allocator.free(result.ssml);
    try expectContains(result.ssml, "<break time=\"400ms\"/>");
    try expectContains(result.ssml, "<emphasis level=\"moderate\">");
}

test "convert_bullet" {
    const allocator = std.testing.allocator;
    const result = try convert(allocator, "- item");
    defer allocator.free(result.ssml);
    try expectContains(result.ssml, "<s>item</s>");
}

test "convert_heading_and_bullets" {
    const allocator = std.testing.allocator;
    const result = try convert(allocator, "## List\n- a\n- b");
    defer allocator.free(result.ssml);
    try expectContains(result.ssml, "rate=\"97%\"");
    try expectContains(result.ssml, "<s>a</s>");
    try expectContains(result.ssml, "<s>b</s>");
}

test "convert_paragraph" {
    const allocator = std.testing.allocator;
    const result = try convert(allocator, "First line.\nSecond line.");
    defer allocator.free(result.ssml);
    try std.testing.expectEqualStrings("<speak><p>First line. Second line.</p></speak>", result.ssml);
}

test "convert_paragraph_break" {
    const allocator = std.testing.allocator;
    const result = try convert(allocator, "Para 1.\n\nPara 2.");
    defer allocator.free(result.ssml);
    try std.testing.expectEqualStrings("<speak><p>Para 1.</p><p>Para 2.</p></speak>", result.ssml);
}

test "convert_code_block_skipped" {
    const allocator = std.testing.allocator;
    const result = try convert(allocator, "Before\n```zig\ncode\n```\nAfter");
    defer allocator.free(result.ssml);
    try expectContains(result.ssml, "Before");
    try expectContains(result.ssml, "After");
    try expectNotContains(result.ssml, "code");
}

test "convert_table_skipped" {
    const allocator = std.testing.allocator;
    const result = try convert(allocator, "Before\n| A | B |\n| 1 | 2 |\nAfter");
    defer allocator.free(result.ssml);
    try expectContains(result.ssml, "Before");
    try expectContains(result.ssml, "After");
    try expectNotContains(result.ssml, "|");
}

test "convert_frontmatter_skipped" {
    const allocator = std.testing.allocator;
    const result = try convert(allocator, "```toml\nkey = \"val\"\n```\n# Title");
    defer allocator.free(result.ssml);
    try expectContains(result.ssml, "Title");
    try expectNotContains(result.ssml, "key");
    try expectNotContains(result.ssml, "val");
}

test "convert_checkbox_unchecked" {
    const allocator = std.testing.allocator;
    const result = try convert(allocator, "- [ ] Buy milk");
    defer allocator.free(result.ssml);
    try expectContains(result.ssml, "<s>Buy milk. Not yet done.</s>");
}

test "convert_checkbox_checked" {
    const allocator = std.testing.allocator;
    const result = try convert(allocator, "- [x] Buy milk");
    defer allocator.free(result.ssml);
    try expectContains(result.ssml, "<s>Buy milk. Done.</s>");
}

test "convert_horizontal_rule" {
    const allocator = std.testing.allocator;
    const result = try convert(allocator, "Above\n---\nBelow");
    defer allocator.free(result.ssml);
    try expectContains(result.ssml, "Above");
    try expectContains(result.ssml, "Below");
    try expectContains(result.ssml, "<break time=\"800ms\"/>");
}

test "convert_blockquote" {
    const allocator = std.testing.allocator;
    const result = try convert(allocator, "> Important note");
    defer allocator.free(result.ssml);
    try expectContains(result.ssml, "<emphasis level=\"moderate\">Important note</emphasis>");
}

test "convert_inline_in_heading" {
    const allocator = std.testing.allocator;
    const result = try convert(allocator, "# **Bold** Title");
    defer allocator.free(result.ssml);
    try expectContains(result.ssml, "<emphasis level=\"strong\">Bold</emphasis> Title");
}

test "convert_tags_stripped" {
    const allocator = std.testing.allocator;
    const result = try convert(allocator, "[[t/planning]] [[t/feature]]\n## Real Content");
    defer allocator.free(result.ssml);
    try expectContains(result.ssml, "Real Content");
    try expectNotContains(result.ssml, "planning");
    try expectNotContains(result.ssml, "feature");
}

test "convert_html_comment_stripped" {
    const allocator = std.testing.allocator;
    const result = try convert(allocator, "Before\n<!-- hidden -->\nAfter");
    defer allocator.free(result.ssml);
    try expectContains(result.ssml, "Before");
    try expectContains(result.ssml, "After");
    try expectNotContains(result.ssml, "hidden");
}

test "convert_multiline_comment" {
    const allocator = std.testing.allocator;
    const result = try convert(allocator, "Before\n<!-- start\nmiddle\nend -->\nAfter");
    defer allocator.free(result.ssml);
    try expectContains(result.ssml, "Before");
    try expectContains(result.ssml, "After");
    try expectNotContains(result.ssml, "start");
    try expectNotContains(result.ssml, "middle");
    try expectNotContains(result.ssml, "end");
}

test "convert_statistics" {
    const allocator = std.testing.allocator;
    const input = "Line one\nLine two\nLine three\n```zig\ncode\n```\nLine four\nLine five";
    const result = try convert(allocator, input);
    defer allocator.free(result.ssml);
    try std.testing.expectEqual(@as(u32, 5), result.lines_processed);
    try std.testing.expectEqual(@as(u32, 3), result.lines_skipped);
}

test "convert_windows_line_endings" {
    const allocator = std.testing.allocator;
    const unix = try convert(allocator, "# Title\n- item\n");
    defer allocator.free(unix.ssml);
    const windows = try convert(allocator, "# Title\r\n- item\r\n");
    defer allocator.free(windows.ssml);
    try std.testing.expectEqualStrings(unix.ssml, windows.ssml);
}

test "convert_remove_block" {
    const allocator = std.testing.allocator;
    const result = try convert(allocator, "```@remove\ntemplate stuff\n```\n# Real");
    defer allocator.free(result.ssml);
    try expectContains(result.ssml, "Real");
    try expectNotContains(result.ssml, "template");
}

test "convert_mermaid_block" {
    const allocator = std.testing.allocator;
    const result = try convert(allocator, "```mermaid\nA --> B\n```\nText");
    defer allocator.free(result.ssml);
    try expectContains(result.ssml, "Text");
    try expectNotContains(result.ssml, "A --> B");
}

test "convert_numbered_item" {
    const allocator = std.testing.allocator;
    const result = try convert(allocator, "1. First thing");
    defer allocator.free(result.ssml);
    try expectContains(result.ssml, "<s>First thing</s>");
}

test "convert_nested_bullet" {
    const allocator = std.testing.allocator;
    const result = try convert(allocator, "- top\n  - nested");
    defer allocator.free(result.ssml);
    try expectContains(result.ssml, "<s>top</s>");
    try expectContains(result.ssml, "<s>nested</s>");
}

test "convert_star_bullet" {
    const allocator = std.testing.allocator;
    const result = try convert(allocator, "* star item");
    defer allocator.free(result.ssml);
    try expectContains(result.ssml, "<s>star item</s>");
}

test "convert_xml_in_content" {
    const allocator = std.testing.allocator;
    const result = try convert(allocator, "Use a < b & c");
    defer allocator.free(result.ssml);
    try expectContains(result.ssml, "&lt;");
    try expectContains(result.ssml, "&amp;");
}

test "convert_realistic_feature_plan" {
    const allocator = std.testing.allocator;
    const content = try std.fs.cwd().readFileAlloc(allocator, "art/template/plan_feature.md", 1024 * 1024);
    defer allocator.free(content);
    const result = try convert(allocator, content);
    defer allocator.free(result.ssml);
    try expectContains(result.ssml, "Feature Plan");
    try expectContains(result.ssml, "Summary");
    try expectNotContains(result.ssml, "[[t/");
    try expectNotContains(result.ssml, "```toml");
    try expectNotContains(result.ssml, "Template Instructions");
    try expectNotContains(result.ssml, "```@remove");
}

test "convert_realistic_daily_plan" {
    const allocator = std.testing.allocator;
    const content = try std.fs.cwd().readFileAlloc(allocator, "art/template/plan_day.md", 1024 * 1024);
    defer allocator.free(content);
    const result = try convert(allocator, content);
    defer allocator.free(result.ssml);
    try expectContains(result.ssml, "Daily Plan");
    try expectContains(result.ssml, "Review yesterday:");
    try expectContains(result.ssml, "ligi q t TODO | planning");
    try expectNotContains(result.ssml, "[[t/");
    try expectNotContains(result.ssml, "prev_day_tag");
    try expectNotContains(result.ssml, "Template Instructions");
    try expectNotContains(result.ssml, "`");
}

test "convert_only_skippable" {
    const allocator = std.testing.allocator;
    const input = "```zig\ncode\n```\n| A | B |\n| 1 | 2 |";
    const result = try convert(allocator, input);
    defer allocator.free(result.ssml);
    try std.testing.expectEqualStrings("<speak></speak>", result.ssml);
    try std.testing.expectEqual(@as(u32, 0), result.lines_processed);
    try std.testing.expectEqual(@as(u32, 5), result.lines_skipped);
}

test "convert_no_bare_ampersands" {
    const allocator = std.testing.allocator;
    const input = "Fish & Chips\n\nRock & Roll";
    const result = try convert(allocator, input);
    defer allocator.free(result.ssml);
    try expectNoBareAmpersands(result.ssml);
}
