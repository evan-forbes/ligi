//! PDF generation orchestration for `ligi pdf`.

const std = @import("std");
const browser = @import("browser.zig");
const merge = @import("merge.zig");

pub const PdfConfig = struct {
    input_path: []const u8,
    output_path: ?[]const u8,
    recursive: bool,
};

pub fn run(
    allocator: std.mem.Allocator,
    config: PdfConfig,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const input_abs = resolveInputAbsolute(allocator, config.input_path, stderr) catch return 1;
    defer allocator.free(input_abs);

    const output_abs = resolveOutputAbsolute(allocator, input_abs, config.output_path, stderr) catch return 1;
    defer allocator.free(output_abs);

    const cwd_abs = std.fs.cwd().realpathAlloc(allocator, ".") catch {
        try stderr.writeAll("error: pdf: failed to resolve current working directory\n");
        return 1;
    };
    defer allocator.free(cwd_abs);

    var serve_root_abs: ?[]const u8 = null;
    var target_rel_path: ?[]const u8 = null;
    var tmp_merged_name: ?[]const u8 = null;

    defer if (serve_root_abs) |s| allocator.free(s);
    defer if (target_rel_path) |t| allocator.free(t);
    defer if (tmp_merged_name) |name| {
        if (serve_root_abs) |sra| {
            if (std.fs.openDirAbsolute(sra, .{})) |opened_dir| {
                var root_dir = opened_dir;
                defer root_dir.close();
                root_dir.deleteFile(name) catch {};
            } else |_| {}
        }
        allocator.free(name);
    };

    if (!config.recursive) {
        const input_dir = std.fs.path.dirname(input_abs) orelse ".";
        serve_root_abs = try allocator.dupe(u8, input_dir);

        const basename = std.fs.path.basename(input_abs);
        target_rel_path = try allocator.dupe(u8, basename);
    } else {
        const graph_root_abs = if (merge.isWithinRoot(cwd_abs, input_abs))
            cwd_abs
        else
            (std.fs.path.dirname(input_abs) orelse cwd_abs);

        var collected = merge.collectLinkedMarkdown(allocator, input_abs, graph_root_abs) catch {
            try stderr.writeAll("error: pdf: failed to build recursive markdown graph\n");
            return 1;
        };
        defer collected.deinit(allocator);

        for (collected.warnings) |warning| {
            try stderr.print("{s}\n", .{warning});
        }

        serve_root_abs = findCommonAncestorDir(allocator, collected.files) catch {
            try stderr.writeAll("error: pdf: failed to determine recursive serve root\n");
            return 1;
        };

        var merged_doc = merge.buildMergedMarkdown(allocator, collected.files, serve_root_abs.?) catch {
            try stderr.writeAll("error: pdf: failed to merge recursive markdown content\n");
            return 1;
        };
        defer merged_doc.deinit(allocator);

        const tmp_name = writeTempMergedMarkdown(allocator, serve_root_abs.?, merged_doc.markdown) catch {
            try stderr.writeAll("error: pdf: failed to write merged markdown file\n");
            return 1;
        };
        tmp_merged_name = tmp_name;

        target_rel_path = try allocator.dupe(u8, tmp_name);
    }

    const browser_bin = browser.discoverBrowser(allocator) catch |err| {
        if (err == browser.RenderError.BrowserNotFound) {
            try stderr.writeAll("error: pdf: could not find Chromium/Chrome. Run 'make pdf-deps' or set LIGI_PDF_BROWSER\n");
        } else {
            try stderr.writeAll("error: pdf: failed to discover browser binary\n");
        }
        return 1;
    };
    defer allocator.free(browser_bin);

    const port = findAvailablePort() catch {
        try stderr.writeAll("error: pdf: failed to start local render server\n");
        return 1;
    };

    const exe_path = std.fs.selfExePathAlloc(allocator) catch {
        try stderr.writeAll("error: pdf: failed to resolve ligi binary path\n");
        return 1;
    };
    defer allocator.free(exe_path);

    const port_arg = std.fmt.allocPrint(allocator, "{d}", .{port}) catch {
        try stderr.writeAll("error: pdf: failed to allocate server arguments\n");
        return 1;
    };
    defer allocator.free(port_arg);

    var serve_child = std.process.Child.init(
        &.{
            exe_path,
            "serve",
            "--root",
            serve_root_abs.?,
            "--host",
            "127.0.0.1",
            "--port",
            port_arg,
        },
        allocator,
    );
    serve_child.stdin_behavior = .Ignore;
    serve_child.stdout_behavior = .Ignore;
    serve_child.stderr_behavior = .Ignore;

    serve_child.spawn() catch {
        try stderr.writeAll("error: pdf: failed to start local render server\n");
        return 1;
    };
    defer {
        _ = serve_child.kill() catch {};
        _ = serve_child.wait() catch {};
    }

    const started = waitForServer(allocator, port, 5000) catch false;
    if (!started) {
        try stderr.writeAll("error: pdf: failed to start local render server\n");
        return 1;
    }

    const encoded_target = merge.encodeURIComponent(allocator, target_rel_path.?) catch {
        try stderr.writeAll("error: pdf: failed to encode render path\n");
        return 1;
    };
    defer allocator.free(encoded_target);

    const render_url = std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/?print=1&path={s}",
        .{ port, encoded_target },
    ) catch {
        try stderr.writeAll("error: pdf: failed to build render URL\n");
        return 1;
    };
    defer allocator.free(render_url);

    browser.renderPdf(allocator, browser_bin, render_url, output_abs) catch {
        try stderr.writeAll("error: pdf: browser process failed\n");
        return 1;
    };

    try stdout.print("wrote PDF: {s}\n", .{output_abs});
    return 0;
}

fn resolveInputAbsolute(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    stderr: anytype,
) ![]const u8 {
    if (input_path.len == 0) {
        try stderr.writeAll("error: pdf: missing input markdown file\n");
        return error.InvalidInput;
    }

    const ext = std.fs.path.extension(input_path);
    if (!(std.ascii.eqlIgnoreCase(ext, ".md") or std.ascii.eqlIgnoreCase(ext, ".markdown"))) {
        try stderr.print("error: pdf: unsupported file extension '{s}' (expected .md or .markdown)\n", .{ext});
        return error.InvalidInput;
    }

    return std.fs.cwd().realpathAlloc(allocator, input_path) catch {
        try stderr.print("error: pdf: file not found: {s}\n", .{input_path});
        return error.InvalidInput;
    };
}

fn resolveOutputAbsolute(
    allocator: std.mem.Allocator,
    input_abs: []const u8,
    output_path: ?[]const u8,
    stderr: anytype,
) ![]const u8 {
    const cwd_abs = std.fs.cwd().realpathAlloc(allocator, ".") catch {
        try stderr.writeAll("error: pdf: failed to resolve current working directory\n");
        return error.InvalidOutput;
    };
    defer allocator.free(cwd_abs);

    const out_abs = if (output_path) |out| blk: {
        if (std.fs.path.isAbsolute(out)) {
            break :blk try allocator.dupe(u8, out);
        }
        break :blk try std.fs.path.join(allocator, &.{ cwd_abs, out });
    } else blk: {
        const input_ext = std.fs.path.extension(input_abs);
        const stem = input_abs[0 .. input_abs.len - input_ext.len];
        break :blk try std.fmt.allocPrint(allocator, "{s}.pdf", .{stem});
    };
    errdefer allocator.free(out_abs);

    const out_dir = std.fs.path.dirname(out_abs) orelse ".";
    var dir = std.fs.openDirAbsolute(out_dir, .{}) catch {
        try stderr.print("error: pdf: output directory does not exist: {s}\n", .{out_dir});
        return error.InvalidOutput;
    };
    dir.close();

    return out_abs;
}

fn waitForServer(allocator: std.mem.Allocator, port: u16, timeout_ms: i64) !bool {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/api/health", .{port});
    defer allocator.free(url);

    const uri = std.Uri.parse(url) catch return false;

    const start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start < timeout_ms) {
        const result = client.fetch(.{
            .location = .{ .uri = uri },
            .method = .GET,
        }) catch {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        };

        if (result.status == .ok) return true;
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    return false;
}

fn findAvailablePort() !u16 {
    var port: u16 = 36101;
    while (port < 36999) : (port += 1) {
        const address = std.net.Address.parseIp4("127.0.0.1", port) catch continue;
        var listener = address.listen(.{ .reuse_address = true }) catch continue;
        listener.deinit();
        return port;
    }
    return error.NoAvailablePort;
}

fn findCommonAncestorDir(allocator: std.mem.Allocator, files_abs: []const []const u8) ![]const u8 {
    if (files_abs.len == 0) return error.EmptySet;

    var root = try allocator.dupe(u8, std.fs.path.dirname(files_abs[0]) orelse files_abs[0]);
    errdefer allocator.free(root);

    for (files_abs[1..]) |path| {
        const dir = std.fs.path.dirname(path) orelse path;
        while (!merge.isWithinRoot(root, dir)) {
            const parent = std.fs.path.dirname(root) orelse "/";
            if (std.mem.eql(u8, root, parent)) break;

            const next = try allocator.dupe(u8, parent);
            allocator.free(root);
            root = next;
        }
    }

    return root;
}

fn writeTempMergedMarkdown(
    allocator: std.mem.Allocator,
    serve_root_abs: []const u8,
    merged_markdown: []const u8,
) ![]const u8 {
    var root_dir = try std.fs.openDirAbsolute(serve_root_abs, .{});
    defer root_dir.close();

    var attempt: usize = 0;
    while (attempt < 16) : (attempt += 1) {
        const name = try std.fmt.allocPrint(
            allocator,
            ".ligi-pdf-merged-{d}-{d}.md",
            .{ std.time.milliTimestamp(), attempt },
        );
        errdefer allocator.free(name);

        const file = root_dir.createFile(name, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(name);
                continue;
            },
            else => return err,
        };
        defer file.close();

        try file.writeAll(merged_markdown);
        return name;
    }

    return error.CouldNotCreateTempFile;
}

test "findCommonAncestorDir returns nearest shared directory" {
    const allocator = std.testing.allocator;
    const root = try findCommonAncestorDir(
        allocator,
        &.{
            "/tmp/a/one/doc.md",
            "/tmp/a/two/other.md",
            "/tmp/a/two/nested/third.md",
        },
    );
    defer allocator.free(root);

    try std.testing.expectEqualStrings("/tmp/a", root);
}

test "resolveOutputAbsolute defaults to input stem with pdf extension" {
    const allocator = std.testing.allocator;
    var sink: [1]u8 = undefined;
    var stream = std.io.fixedBufferStream(&sink);
    const out = try resolveOutputAbsolute(allocator, "/tmp/example.md", null, stream.writer());
    defer allocator.free(out);

    try std.testing.expectEqualStrings("/tmp/example.pdf", out);
}
