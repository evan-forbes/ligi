const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

test "integration: pdf command renders recursive markdown using browser override" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root_path);

    try tmp_dir.dir.makePath("art/docs");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "art/main.md",
        .data =
        \\# Main
        \\
        \\Go to [child](docs/child.md).
        ,
    });
    try tmp_dir.dir.writeFile(.{
        .sub_path = "art/docs/child.md",
        .data = "# Child\n\nLinked from main.",
    });

    const fake_browser_script =
        \\#!/bin/sh
        \\out=""
        \\for arg in "$@"; do
        \\  case "$arg" in
        \\    --print-to-pdf=*) out="${arg#--print-to-pdf=}" ;;
        \\  esac
        \\done
        \\if [ -z "$out" ]; then
        \\  exit 2
        \\fi
        \\mkdir -p "$(dirname "$out")"
        \\printf '%s\n' '%PDF-1.4 fake' > "$out"
        \\exit 0
        \\
    ;

    var script_file = try tmp_dir.dir.createFile("fake-chromium.sh", .{});
    defer script_file.close();
    try script_file.writeAll(fake_browser_script);

    const browser_abs = try tmp_dir.dir.realpathAlloc(allocator, "fake-chromium.sh");
    defer allocator.free(browser_abs);

    const bin_rel_path = try std.fs.path.join(allocator, &.{ "zig-out", "bin", "ligi" });
    defer allocator.free(bin_rel_path);
    std.fs.cwd().access(bin_rel_path, .{}) catch {
        std.debug.print("\nSkipping integration test: ligi binary not found at {s}\n", .{bin_rel_path});
        return;
    };
    const bin_path = try std.fs.cwd().realpathAlloc(allocator, bin_rel_path);
    defer allocator.free(bin_path);

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    const browser_cmd = try std.fmt.allocPrint(allocator, "sh {s}", .{browser_abs});
    defer allocator.free(browser_cmd);
    try env_map.put("LIGI_PDF_BROWSER", browser_cmd);

    const run_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            bin_path,
            "pdf",
            "art/main.md",
            "-r",
            "-o",
            "art/output.pdf",
        },
        .cwd = root_path,
        .env_map = &env_map,
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    switch (run_result.term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("\npdf stdout:\n{s}\n", .{run_result.stdout});
                std.debug.print("pdf stderr:\n{s}\n", .{run_result.stderr});
            }
            try testing.expectEqual(@as(u8, 0), code);
        },
        else => return error.TestUnexpectedProcessTermination,
    }

    const out_file = try tmp_dir.dir.openFile("art/output.pdf", .{});
    defer out_file.close();

    const stat = try out_file.stat();
    try testing.expect(stat.size > 0);
}
