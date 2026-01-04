//! Template parser - extracts frontmatter and body from template files.

const std = @import("std");
const toml = @import("toml.zig");

pub const TemplateField = struct {
    name: []const u8,
    type_name: []const u8,
    default_value: ?[]const u8,
};

pub const Template = struct {
    fields: []TemplateField,
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: Template) void {
        for (self.fields) |f| {
            self.allocator.free(f.name);
            self.allocator.free(f.type_name);
            if (f.default_value) |v| self.allocator.free(v);
        }
        self.allocator.free(self.fields);
    }
};

pub const ParseError = error{
    MissingFrontmatterStart,
    MissingTomlBlock,
    MissingFrontmatterEnd,
    InvalidFieldFormat,
    InvalidType,
    OutOfMemory,
    DuplicateKeyTypeMismatch,
    EmptyValue,
    InvalidValue,
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8) !Template {
    // 1. Find "# front"
    const front_idx = std.mem.indexOf(u8, input, "# front") orelse return ParseError.MissingFrontmatterStart;

    // 2. Find "```toml" after front
    const toml_start_search = input[front_idx..];
    const code_block_start_marker = "```toml";
    const cb_start_idx = std.mem.indexOf(u8, toml_start_search, code_block_start_marker) orelse return ParseError.MissingTomlBlock;

    // Absolute index of start of ```toml
    const abs_cb_start = front_idx + cb_start_idx;
    // Content starts after ```toml\n (or just ```toml)
    // We scan for newline after ```toml
    var content_start = abs_cb_start + code_block_start_marker.len;
    while (content_start < input.len and input[content_start] != '\n') : (content_start += 1) {}
    if (content_start < input.len) content_start += 1; // skip \n

    // 3. Find closing ```
    const after_start = input[content_start..];
    const cb_end_idx = std.mem.indexOf(u8, after_start, "```") orelse return ParseError.MissingTomlBlock;
    const abs_cb_end = content_start + cb_end_idx;

    const toml_content = input[content_start..abs_cb_end];

    // 4. Find "# Document"
    const doc_marker = "# Document";
    const doc_idx = std.mem.indexOf(u8, input, doc_marker) orelse return ParseError.MissingFrontmatterEnd;

    // Body starts after # Document line
    var body_start = doc_idx + doc_marker.len;
    while (body_start < input.len and input[body_start] != '\n') : (body_start += 1) {}
    if (body_start < input.len) body_start += 1; // skip \n

    const body = input[body_start..];

    // 5. Parse TOML
    var toml_root = try toml.parse(allocator, toml_content);
    defer {
        var it = toml_root.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        toml_root.deinit();
    }

    var fields = try std.ArrayList(TemplateField).initCapacity(allocator, 0);
    errdefer {
        for (fields.items) |f| {
            allocator.free(f.name);
            allocator.free(f.type_name);
            if (f.default_value) |v| allocator.free(v);
        }
        fields.deinit(allocator);
    }

    // Convert TOML to TemplateField
    var it = toml_root.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;

        var type_name: []const u8 = undefined;
        var default_val: ?[]const u8 = null;

        switch (val) {
            .string => |s| {
                type_name = try allocator.dupe(u8, "string");
                default_val = try allocator.dupe(u8, s);
            },
            .int => |i| {
                type_name = try allocator.dupe(u8, "int");
                default_val = try std.fmt.allocPrint(allocator, "{d}", .{i});
            },
            .boolean => |b| {
                // Map boolean to string "true"/"false" and type "string"
                type_name = try allocator.dupe(u8, "string");
                default_val = try allocator.dupe(u8, if (b) "true" else "false");
            },
            .table => |*t| {
                // Look for type and default
                const type_entry = t.get("type");
                const default_entry = t.get("default");

                if (type_entry) |te| {
                    if (te == .string) {
                        const t_str = te.string;
                        if (!std.mem.eql(u8, t_str, "string") and !std.mem.eql(u8, t_str, "int")) {
                            return ParseError.InvalidType;
                        }
                        type_name = try allocator.dupe(u8, t_str);
                    } else {
                        return ParseError.InvalidType;
                    }
                } else if (default_entry) |de| {
                    // Infer type
                    switch (de) {
                        .string => type_name = try allocator.dupe(u8, "string"),
                        .int => type_name = try allocator.dupe(u8, "int"),
                        .boolean => type_name = try allocator.dupe(u8, "string"),
                        else => return ParseError.InvalidType,
                    }
                } else {
                    // No type, no default?
                    return ParseError.InvalidFieldFormat;
                }

                if (default_entry) |de| {
                    switch (de) {
                        .string => |s| default_val = try allocator.dupe(u8, s),
                        .int => |i| default_val = try std.fmt.allocPrint(allocator, "{d}", .{i}),
                        .boolean => |b| default_val = try allocator.dupe(u8, if (b) "true" else "false"),
                        else => {}, // table in default? Not supported
                    }
                }
            },
        }

        try fields.append(allocator, .{
            .name = try allocator.dupe(u8, key),
            .type_name = type_name,
            .default_value = default_val,
        });
    }

    return Template{
        .fields = try fields.toOwnedSlice(allocator),
        .body = body,
        .allocator = allocator,
    };
}

test "parser valid toml" {
    const input =
        \\# front
        \\
        \\```toml
        \\name = "Alice"
        \\age = { type = "int", default = 30 }
        \\role = { type = "string" }
        \\```
        \\
        \\# Document
        \\
        \\Hello {{name}}, you are {{age}}.
    ;

    const template = try parse(std.testing.allocator, input);
    defer template.deinit();

    try std.testing.expectEqual(template.fields.len, 3);

    // Order is not guaranteed due to HashMap, find them
    var found_name = false;
    var found_age = false;
    var found_role = false;

    for (template.fields) |f| {
        if (std.mem.eql(u8, f.name, "name")) {
            found_name = true;
            try std.testing.expectEqualStrings("string", f.type_name);
            try std.testing.expectEqualStrings("Alice", f.default_value.?);
        } else if (std.mem.eql(u8, f.name, "age")) {
            found_age = true;
            try std.testing.expectEqualStrings("int", f.type_name);
            try std.testing.expectEqualStrings("30", f.default_value.?);
        } else if (std.mem.eql(u8, f.name, "role")) {
            found_role = true;
            try std.testing.expectEqualStrings("string", f.type_name);
            try std.testing.expect(f.default_value == null);
        }
    }

    try std.testing.expect(found_name);
    try std.testing.expect(found_age);
    try std.testing.expect(found_role);

    try std.testing.expectEqualStrings("\nHello {{name}}, you are {{age}}.", template.body);
}

test "parser section style" {
    const input =
        \\# front
        \\
        \\```toml
        \\[user]
        \\type = "string"
        \\default = "Bob"
        \\```
        \\
        \\# Document
        \\Hi
    ;
    const template = try parse(std.testing.allocator, input);
    defer template.deinit();

    try std.testing.expectEqual(template.fields.len, 1);
    try std.testing.expectEqualStrings("user", template.fields[0].name);
    try std.testing.expectEqualStrings("string", template.fields[0].type_name);
    try std.testing.expectEqualStrings("Bob", template.fields[0].default_value.?);
}
