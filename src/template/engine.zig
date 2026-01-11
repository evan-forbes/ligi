//! Template engine - substitutes values and expands includes.

const std = @import("std");

pub const EngineContext = struct {
    values: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
    cwd: []const u8,
};

/// Strip ```@remove blocks from input, returning cleaned content.
/// Caller owns returned memory.
pub fn stripRemoveBlocks(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const open_marker = "```@remove";
    const close_marker = "```";

    // Count how many @remove blocks exist to decide if we need to allocate
    if (std.mem.indexOf(u8, input, open_marker) == null) {
        // No @remove blocks, return a copy
        return try allocator.dupe(u8, input);
    }

    var result = try std.ArrayList(u8).initCapacity(allocator, input.len);
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        // Check if we're at start of line (or start of input) for ```@remove
        const at_line_start = (i == 0) or (i > 0 and input[i - 1] == '\n');

        if (at_line_start and i + open_marker.len <= input.len and
            std.mem.eql(u8, input[i .. i + open_marker.len], open_marker))
        {
            // Find end of opening line (skip past ```@remove and any trailing chars on that line)
            var open_end = i + open_marker.len;
            while (open_end < input.len and input[open_end] != '\n') : (open_end += 1) {}
            if (open_end < input.len) open_end += 1; // skip the newline

            // Find closing ``` on its own line
            var search_pos = open_end;
            var found_close = false;
            while (search_pos < input.len) {
                // Look for ``` at start of a line
                if (search_pos + close_marker.len <= input.len and
                    std.mem.eql(u8, input[search_pos .. search_pos + close_marker.len], close_marker))
                {
                    // Check it's actually a closing fence (not ```something)
                    const after_fence = search_pos + close_marker.len;
                    if (after_fence >= input.len or input[after_fence] == '\n' or input[after_fence] == '\r') {
                        // Found closing fence - skip past it including newline
                        var close_end = after_fence;
                        while (close_end < input.len and input[close_end] != '\n') : (close_end += 1) {}
                        if (close_end < input.len) close_end += 1; // skip newline

                        i = close_end;
                        found_close = true;
                        break;
                    }
                }
                // Move to next line
                while (search_pos < input.len and input[search_pos] != '\n') : (search_pos += 1) {}
                if (search_pos < input.len) search_pos += 1;
            }

            if (!found_close) {
                // Unclosed @remove block - treat rest of input as removed
                break;
            }
            continue;
        }

        try result.append(allocator, input[i]);
        i += 1;
    }

    return try result.toOwnedSlice(allocator);
}

pub fn process(
    ctx: EngineContext,
    input: []const u8,
    writer: anytype,
    depth: usize,
) anyerror!void {
    if (depth > 10) {
        return error.RecursionLimitExceeded;
    }

    // Strip @remove blocks first
    const cleaned = try stripRemoveBlocks(ctx.allocator, input);
    defer ctx.allocator.free(cleaned);

    var i: usize = 0;
    while (i < cleaned.len) {
        // Check for {{
        if (i + 2 < cleaned.len and std.mem.eql(u8, cleaned[i .. i + 2], "{{")) {
            const rest = cleaned[i + 2 ..];
            if (std.mem.indexOf(u8, rest, "}}")) |idx| {
                const key_raw = rest[0..idx];
                const key = std.mem.trim(u8, key_raw, " ");

                if (ctx.values.get(key)) |val| {
                    try writer.writeAll(val);
                } else {
                    try writer.writeAll("{{");
                    try writer.writeAll(key_raw);
                    try writer.writeAll("}}");
                }
                i += 2 + idx + 2;
                continue;
            }
        }

        // Check for !![
        if (i + 3 < cleaned.len and std.mem.eql(u8, cleaned[i .. i + 3], "!![")) {
            const rest = cleaned[i + 3 ..];
            if (std.mem.indexOf(u8, rest, "]")) |cb_idx| {
                const after_bracket = rest[cb_idx + 1 ..];
                if (after_bracket.len > 0 and after_bracket[0] == '(') {
                    if (std.mem.indexOf(u8, after_bracket, ")")) |cp_idx| {
                        const path_raw = after_bracket[1..cp_idx];
                        const path = std.mem.trim(u8, path_raw, " ");

                        // Expand
                        if (try expandFile(ctx, path, writer, depth)) {
                            // Success
                        } else {
                            // Failed to read, keep raw?
                            // expandFile returns error if fail.
                        }

                        i += 3 + cb_idx + 1 + 1 + cp_idx + 1; // !![ ... ] ( ... )
                        continue;
                    }
                }
            }
        }

        try writer.writeByte(cleaned[i]);
        i += 1;
    }
}

fn expandFile(ctx: EngineContext, path: []const u8, writer: anytype, depth: usize) anyerror!bool {
    // Resolve path
    const abs_path = try std.fs.path.resolve(ctx.allocator, &.{ ctx.cwd, path });
    defer ctx.allocator.free(abs_path);

    const file = std.fs.openFileAbsolute(abs_path, .{}) catch |err| {
        // If file missing, maybe warn? For now let's just fail.
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(ctx.allocator, 1024 * 1024);
    defer ctx.allocator.free(content);

    // Strip frontmatter if present
    var body = content;
    if (std.mem.indexOf(u8, content, "# front")) |front_idx| {
        // Check if # front is at the start (ignoring whitespace?) or just strict
        // Parser is strict about finding it.
        if (std.mem.indexOf(u8, content[front_idx..], "# Document")) |doc_idx_rel| {
            const doc_idx = front_idx + doc_idx_rel;
            const marker_len = "# Document".len;
            var body_start = doc_idx + marker_len;
            while (body_start < content.len and content[body_start] != '\n') : (body_start += 1) {}
            if (body_start < content.len) body_start += 1; // skip \n
            body = content[body_start..];
        }
    } else if (std.mem.startsWith(u8, content, "---")) {
        // Legacy support just in case
        const rest = content[3..];
        if (std.mem.indexOf(u8, rest, "---")) |fm_end| {
            body = rest[fm_end + 3 ..];
            if (body.len > 0 and body[0] == '\n') body = body[1..];
        }
    }

    // Recurse with new CWD
    const next_cwd = std.fs.path.dirname(abs_path) orelse ".";

    try process(.{
        .values = ctx.values,
        .allocator = ctx.allocator,
        .cwd = next_cwd,
    }, body, writer, depth + 1);

    return true;
}

test "engine substitution" {
    const allocator = std.testing.allocator;
    var map = std.StringHashMap([]const u8).init(allocator);
    defer map.deinit();
    try map.put("name", "Bob");

    var output_list = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer output_list.deinit(allocator);
    const writer = output_list.writer(allocator);

    const input = "Hello {{ name }}!";
    try process(.{
        .values = map,
        .allocator = allocator,
        .cwd = ".",
    }, input, writer, 0);

    try std.testing.expectEqualStrings("Hello Bob!", output_list.items);
}

test "engine unknown var" {
    const allocator = std.testing.allocator;
    var map = std.StringHashMap([]const u8).init(allocator);
    defer map.deinit();

    var output_list = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer output_list.deinit(allocator);
    const writer = output_list.writer(allocator);

    const input = "Hello {{ unknown }}!";
    try process(.{
        .values = map,
        .allocator = allocator,
        .cwd = ".",
    }, input, writer, 0);

    try std.testing.expectEqualStrings("Hello {{ unknown }}!", output_list.items);
}

test "stripRemoveBlocks basic" {
    const allocator = std.testing.allocator;

    const input =
        \\# Title
        \\
        \\```@remove
        \\Do not edit this.
        \\```
        \\
        \\Content here.
    ;

    const result = try stripRemoveBlocks(allocator, input);
    defer allocator.free(result);

    // The blank line before ```@remove is preserved
    const expected =
        \\# Title
        \\
        \\
        \\Content here.
    ;
    try std.testing.expectEqualStrings(expected, result);
}

test "stripRemoveBlocks no blocks" {
    const allocator = std.testing.allocator;

    const input = "Hello world\nNo remove blocks here.";
    const result = try stripRemoveBlocks(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(input, result);
}

test "stripRemoveBlocks multiple blocks" {
    const allocator = std.testing.allocator;

    const input =
        \\Start
        \\```@remove
        \\First block
        \\```
        \\Middle
        \\```@remove
        \\Second block
        \\```
        \\End
    ;

    const result = try stripRemoveBlocks(allocator, input);
    defer allocator.free(result);

    const expected =
        \\Start
        \\Middle
        \\End
    ;
    try std.testing.expectEqualStrings(expected, result);
}

test "stripRemoveBlocks preserves other code blocks" {
    const allocator = std.testing.allocator;

    const input =
        \\# Code
        \\
        \\```zig
        \\const x = 1;
        \\```
        \\
        \\```@remove
        \\Hidden
        \\```
        \\
        \\Done
    ;

    const result = try stripRemoveBlocks(allocator, input);
    defer allocator.free(result);

    // Blank line before @remove is preserved
    const expected =
        \\# Code
        \\
        \\```zig
        \\const x = 1;
        \\```
        \\
        \\
        \\Done
    ;
    try std.testing.expectEqualStrings(expected, result);
}
