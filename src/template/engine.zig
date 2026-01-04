//! Template engine - substitutes values and expands includes.

const std = @import("std");

pub const EngineContext = struct {
    values: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
    cwd: []const u8,
};

pub fn process(
    ctx: EngineContext,
    input: []const u8,
    writer: anytype,
    depth: usize,
) anyerror!void {
    if (depth > 10) {
        return error.RecursionLimitExceeded;
    }

    var i: usize = 0;
    while (i < input.len) {
        // Check for {{
        if (i + 2 < input.len and std.mem.eql(u8, input[i .. i + 2], "{{")) {
            const rest = input[i + 2 ..];
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
        if (i + 3 < input.len and std.mem.eql(u8, input[i .. i + 3], "!![")) {
            const rest = input[i + 3 ..];
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

        try writer.writeByte(input[i]);
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
