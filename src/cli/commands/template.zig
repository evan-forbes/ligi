//! Template fill command implementation.

const std = @import("std");
const template = @import("../../template/mod.zig");

/// Run the fill workflow
pub fn runFill(
    allocator: std.mem.Allocator,
    path_arg: ?[]const u8,
    clipboard: bool,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    // Resolve template path (launches fzf if null)
    const template_path = path_arg orelse {
        return resolveFzf(allocator, clipboard, stdout, stderr);
    };

    return runFillWithPath(allocator, template_path, clipboard, stdout, stderr);
}

/// Run fill with a resolved path
fn runFillWithPath(
    allocator: std.mem.Allocator,
    template_path: []const u8,
    clipboard: bool,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    // Resolve to absolute path
    const cwd = std.fs.cwd();
    const abs_path = cwd.realpathAlloc(allocator, template_path) catch |err| {
        try stderr.print("error: cannot resolve path '{s}': {}\n", .{ template_path, err });
        return 1;
    };
    defer allocator.free(abs_path);

    // Read template file
    const content = std.fs.cwd().readFileAlloc(allocator, abs_path, 1024 * 1024) catch |err| {
        try stderr.print("error: cannot read '{s}': {}\n", .{ abs_path, err });
        return 1;
    };
    defer allocator.free(content);

    // Parse template
    var tmpl = template.parser.parse(allocator, content) catch |err| {
        const msg = switch (err) {
            error.MissingFrontmatterStart => "template missing '# front' marker",
            error.MissingFrontmatterEnd => "template missing '# Document' marker",
            error.MissingTomlBlock => "template missing ```toml block",
            error.InvalidType => "invalid type in frontmatter (expected 'string' or 'int')",
            error.InvalidFieldFormat => "invalid field format in frontmatter",
            else => "invalid frontmatter",
        };
        try stderr.print("error: {s}\n", .{msg});
        return 1;
    };
    defer tmpl.deinit();

    // Print header
    try stderr.print("filling template {s} with:\n", .{template_path});

    // Prompt for values (using stdin/stderr for interactive IO)
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    var values = template.prompter.prompt(allocator, tmpl.fields, &stdin_reader.interface, stderr) catch |err| {
        try stderr.print("error: prompting failed: {}\n", .{err});
        return 1;
    };
    defer {
        var it = values.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        values.deinit();
    }

    // Process template with engine
    var output_list: std.ArrayList(u8) = .empty;
    defer output_list.deinit(allocator);

    const template_dir = std.fs.path.dirname(abs_path) orelse ".";

    template.engine.process(.{
        .values = values,
        .allocator = allocator,
        .cwd = template_dir,
    }, tmpl.body, output_list.writer(allocator), 0) catch |err| {
        if (err == error.RecursionLimitExceeded) {
            try stderr.writeAll("error: include recursion limit (10) exceeded\n");
        } else {
            try stderr.print("error: processing failed: {}\n", .{err});
        }
        return 1;
    };

    // Output result
    try stdout.writeAll(output_list.items);

    // Clipboard copy if requested
    if (clipboard) {
        template.clipboard.copy(allocator, output_list.items) catch |err| {
            if (err == error.ClipboardCopyFailed) {
                try stderr.writeAll("error: clipboard copy failed: no clipboard tool found (install xclip or xsel)\n");
            } else {
                try stderr.print("error: clipboard copy failed: {}\n", .{err});
            }
            return 1;
        };
    }

    return 0;
}

/// Launch fzf to select a template, then continue with fill
fn resolveFzf(
    allocator: std.mem.Allocator,
    clipboard: bool,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const home = std.posix.getenv("HOME") orelse {
        try stderr.writeAll("error: HOME not set\n");
        return 1;
    };
    _ = home; // Used in the shell command via $HOME

    // Spawn fzf with stdin/stdout connected to terminal for interactive use
    var child = std.process.Child.init(
        &.{ "sh", "-c", "find \"$HOME\" -type f -name '*.md' 2>/dev/null | fzf" },
        allocator,
    );

    // Inherit stdin/stderr so fzf is interactive
    child.stdin_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    // Capture stdout to get selected file
    child.stdout_behavior = .Pipe;

    child.spawn() catch |err| {
        if (err == error.FileNotFound) {
            try stderr.writeAll("error: fzf is not installed; install fzf or provide a template path\n");
            return 1;
        }
        try stderr.print("error: failed to spawn fzf: {}\n", .{err});
        return 1;
    };

    // Read selected path from fzf stdout
    var read_buf: [4096]u8 = undefined;
    var fzf_reader = child.stdout.?.reader(&read_buf);
    const selected = fzf_reader.interface.takeDelimiter('\n') catch |err| {
        _ = child.wait() catch {};
        try stderr.print("error: failed to read fzf output: {}\n", .{err});
        return 1;
    };

    if (selected == null) {
        // EOF - user cancelled fzf
        _ = child.wait() catch {};
        try stderr.writeAll("error: no template selected\n");
        return 1;
    }

    const result = child.wait() catch |err| {
        try stderr.print("error: fzf failed: {}\n", .{err});
        return 1;
    };

    if (result.Exited != 0) {
        try stderr.writeAll("error: no template selected\n");
        return 1;
    }

    // Now run fill with the selected path (selected is now guaranteed non-null)
    return runFillWithPath(allocator, selected.?, clipboard, stdout, stderr);
}

test "template command compiles" {
    // Basic compilation test
    _ = runFill;
}
