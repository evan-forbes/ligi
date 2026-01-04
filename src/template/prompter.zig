//! Template prompter - prompts user for field values interactively.

const std = @import("std");
const parser = @import("parser.zig");
const Io = std.Io;

pub fn prompt(
    allocator: std.mem.Allocator,
    fields: []const parser.TemplateField,
    in_reader: *Io.Reader,
    out_writer: anytype,
) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = map.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        map.deinit();
    }

    for (fields) |field| {
        var valid_input = false;
        while (!valid_input) {
            // Construct prompt matching spec: "> foo (default \"x\"):" or "> foo:"
            if (field.default_value) |def| {
                try out_writer.print("> {s} (default \"{s}\"): ", .{ field.name, def });
            } else {
                try out_writer.print("> {s}: ", .{field.name});
            }

            // Read a line from input using Zig 0.15 API
            // takeDelimiter returns null on EOF, or slice up to delimiter (exclusive)
            const input_or_null = in_reader.takeDelimiter('\n') catch |err| switch (err) {
                error.ReadFailed => return err,
                error.StreamTooLong => return err,
            };

            if (input_or_null) |raw_input| {
                const trimmed = std.mem.trim(u8, raw_input, " \r");

                if (trimmed.len == 0) {
                    if (field.default_value) |def| {
                        try map.put(field.name, try allocator.dupe(u8, def));
                        valid_input = true;
                    } else {
                        // If no default, and empty input...
                        // If type is string, empty is valid.
                        // If type is int, invalid.
                        if (std.mem.eql(u8, field.type_name, "int")) {
                            try out_writer.print("error: expected integer for '{s}'\n", .{field.name});
                            continue;
                        }
                        try map.put(field.name, try allocator.dupe(u8, ""));
                        valid_input = true;
                    }
                } else {
                    // Valid input provided
                    if (std.mem.eql(u8, field.type_name, "int")) {
                        _ = std.fmt.parseInt(i64, trimmed, 10) catch {
                            try out_writer.print("error: expected integer for '{s}'\n", .{field.name});
                            continue;
                        };
                    }
                    try map.put(field.name, try allocator.dupe(u8, trimmed));
                    valid_input = true;
                }
            } else {
                // EOF
                if (field.default_value) |def| {
                    try map.put(field.name, try allocator.dupe(u8, def));
                    valid_input = true;
                } else {
                    // EOF on required field? Just use empty.
                    try map.put(field.name, try allocator.dupe(u8, ""));
                    valid_input = true;
                }
            }
        }
    }

    return map;
}

test "prompter interaction" {
    const allocator = std.testing.allocator;

    var fields = try std.ArrayList(parser.TemplateField).initCapacity(allocator, 2);
    defer fields.deinit(allocator);

    try fields.append(allocator, .{
        .name = "name",
        .type_name = "string",
        .default_value = null,
    });
    try fields.append(allocator, .{
        .name = "age",
        .type_name = "int",
        .default_value = "10",
    });

    // Mock IO using Zig 0.15 Reader.fixed()
    var input_reader = Io.Reader.fixed("Alice\n\n");

    // Output buffer
    var output_list = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer output_list.deinit(allocator);
    const writer = output_list.writer(allocator);

    var result = try prompt(allocator, fields.items, &input_reader, writer);
    defer {
        var it = result.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        result.deinit();
    }

    try std.testing.expectEqualStrings("Alice", result.get("name").?);
    try std.testing.expectEqualStrings("10", result.get("age").?);

    // Check prompts match new format
    const output = output_list.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "> name:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "> age (default \"10\"):") != null);
}

test "prompter validates int" {
    const allocator = std.testing.allocator;

    var fields = try std.ArrayList(parser.TemplateField).initCapacity(allocator, 1);
    defer fields.deinit(allocator);

    try fields.append(allocator, .{
        .name = "age",
        .type_name = "int",
        .default_value = null,
    });

    // Mock IO: "abc" (invalid) then "42" (valid)
    var input_reader = Io.Reader.fixed("abc\n42\n");

    var output_list = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer output_list.deinit(allocator);
    const writer = output_list.writer(allocator);

    var result = try prompt(allocator, fields.items, &input_reader, writer);
    defer {
        var it = result.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        result.deinit();
    }

    try std.testing.expectEqualStrings("42", result.get("age").?);

    // Check that we complained about the int
    const output = output_list.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "error: expected integer") != null);
}
