//! Internal TOML parser for template frontmatter.
//! Not re-exported - used only by parser.zig.

const std = @import("std");

pub const TomlValue = union(enum) {
    string: []const u8,
    int: i64,
    boolean: bool,
    table: std.StringHashMap(TomlValue),

    pub fn deinit(self: *TomlValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .table => |*t| {
                var it = t.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                t.deinit();
            },
            else => {},
        }
    }
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8) !std.StringHashMap(TomlValue) {
    var root = std.StringHashMap(TomlValue).init(allocator);
    errdefer {
        var it = root.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        root.deinit();
    }

    // Pointer to current table we are filling. Start at root.
    var current_table: *std.StringHashMap(TomlValue) = &root;

    var iter = std.mem.splitSequence(u8, input, "\n");
    while (iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        // Section [header]
        if (line[0] == '[' and line[line.len - 1] == ']') {
            const section_name = line[1 .. line.len - 1];

            // Check if section already exists
            if (root.getPtr(section_name)) |existing_table_val| {
                if (existing_table_val.* == .table) {
                    current_table = &existing_table_val.table;
                    continue;
                } else {
                    return error.DuplicateKeyTypeMismatch;
                }
            }

            // Create new table in root
            const name_copy = try allocator.dupe(u8, section_name);
            errdefer allocator.free(name_copy);

            const new_table = std.StringHashMap(TomlValue).init(allocator);
            try root.put(name_copy, .{ .table = new_table });

            // Update current_table pointer
            current_table = &root.getPtr(name_copy).?.table;
            continue;
        }

        // Key = Value
        if (std.mem.indexOf(u8, line, "=")) |eq_idx| {
            const key_raw = std.mem.trim(u8, line[0..eq_idx], " ");
            const val_raw = std.mem.trim(u8, line[eq_idx + 1 ..], " ");

            if (key_raw.len == 0) continue;

            const key = try allocator.dupe(u8, key_raw);
            errdefer allocator.free(key);

            const value = parseValue(allocator, val_raw) catch |err| {
                allocator.free(key);
                return err;
            };

            try current_table.put(key, value);
        }
    }

    return root;
}

fn parseValue(allocator: std.mem.Allocator, raw: []const u8) anyerror!TomlValue {
    if (raw.len == 0) return error.EmptyValue;

    // String
    if (raw[0] == '"' and raw[raw.len - 1] == '"') {
        // Basic string handling (stripping quotes)
        return TomlValue{ .string = try allocator.dupe(u8, raw[1 .. raw.len - 1]) };
    }

    // Boolean
    if (std.mem.eql(u8, raw, "true")) return TomlValue{ .boolean = true };
    if (std.mem.eql(u8, raw, "false")) return TomlValue{ .boolean = false };

    // Integer
    if (std.fmt.parseInt(i64, raw, 10) catch null) |i| {
        return TomlValue{ .int = i };
    }

    // Inline Table { k=v, ... }
    if (raw[0] == '{' and raw[raw.len - 1] == '}') {
        var table = std.StringHashMap(TomlValue).init(allocator);
        errdefer {
            var it = table.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(allocator);
            }
            table.deinit();
        }

        const content = raw[1 .. raw.len - 1];

        // Split by comma, respecting quotes
        var start: usize = 0;
        var in_quote = false;
        var i: usize = 0;

        while (i < content.len) : (i += 1) {
            const c = content[i];
            if (c == '"') {
                in_quote = !in_quote;
            } else if (c == ',' and !in_quote) {
                // Found split
                try processInlinePair(allocator, &table, content[start..i]);
                start = i + 1;
            }
        }
        // Last one
        if (start < content.len) {
            try processInlinePair(allocator, &table, content[start..]);
        }

        return TomlValue{ .table = table };
    }

    return error.InvalidValue;
}

fn processInlinePair(allocator: std.mem.Allocator, table: *std.StringHashMap(TomlValue), pair_raw: []const u8) !void {
    const pair = std.mem.trim(u8, pair_raw, " ");
    if (pair.len == 0) return;

    if (std.mem.indexOf(u8, pair, "=")) |eq| {
        const k = std.mem.trim(u8, pair[0..eq], " ");
        const v = std.mem.trim(u8, pair[eq + 1 ..], " ");

        const key_dup = try allocator.dupe(u8, k);
        errdefer allocator.free(key_dup);

        const val_parsed = try parseValue(allocator, v);
        try table.put(key_dup, val_parsed);
    }
}

test "parse basic toml" {
    const input =
        \\title = "Template"
        \\version = 1
        \\[owner]
        \\name = "Evan"
        \\active = true
    ;

    var root = try parse(std.testing.allocator, input);
    defer {
        var it = root.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(std.testing.allocator);
        }
        root.deinit();
    }

    try std.testing.expectEqualStrings("Template", root.get("title").?.string);
    try std.testing.expectEqual(@as(i64, 1), root.get("version").?.int);

    const owner = root.get("owner").?.table;
    try std.testing.expectEqualStrings("Evan", owner.get("name").?.string);
    try std.testing.expectEqual(true, owner.get("active").?.boolean);
}

test "parse inline table" {
    const input =
        \\user = { name = "Bob", age = 40 }
    ;
    var root = try parse(std.testing.allocator, input);
    defer {
        var it = root.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(std.testing.allocator);
        }
        root.deinit();
    }

    const user = root.get("user").?.table;
    try std.testing.expectEqualStrings("Bob", user.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 40), user.get("age").?.int);
}
