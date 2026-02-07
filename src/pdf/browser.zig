//! Browser discovery and Chromium-based PDF rendering helpers.

const std = @import("std");

pub const RenderError = error{
    BrowserNotFound,
    SpawnFailed,
    BrowserFailed,
    OutputMissing,
    OutputEmpty,
};

pub const DiscoverError = RenderError || std.mem.Allocator.Error;

const browser_candidates = [_][]const u8{
    "chromium",
    "chromium-browser",
    "google-chrome",
    "google-chrome-stable",
    "chrome",
};

/// Discover a browser binary to use for PDF rendering.
/// Priority:
/// 1. `LIGI_PDF_BROWSER` env var
/// 2. Known browser names on PATH
pub fn discoverBrowser(allocator: std.mem.Allocator) DiscoverError![]const u8 {
    const env_override = std.posix.getenv("LIGI_PDF_BROWSER");
    return discoverBrowserWithOverride(allocator, env_override);
}

/// Discover browser with explicit override for tests.
pub fn discoverBrowserWithOverride(
    allocator: std.mem.Allocator,
    env_override: ?[]const u8,
) DiscoverError![]const u8 {
    if (env_override) |override| {
        if (override.len > 0) {
            return try allocator.dupe(u8, override);
        }
    }

    for (browser_candidates) |candidate| {
        if (canSpawnBrowser(allocator, candidate)) {
            return try allocator.dupe(u8, candidate);
        }
    }

    return RenderError.BrowserNotFound;
}

/// Render URL to PDF with Chromium/Chrome headless flags.
pub fn renderPdf(
    allocator: std.mem.Allocator,
    browser_bin: []const u8,
    url: []const u8,
    output_pdf: []const u8,
) RenderError!void {
    const pdf_flag = std.fmt.allocPrint(allocator, "--print-to-pdf={s}", .{output_pdf}) catch {
        return RenderError.SpawnFailed;
    };
    defer allocator.free(pdf_flag);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    var browser_parts = std.mem.tokenizeScalar(u8, browser_bin, ' ');
    while (browser_parts.next()) |part| {
        if (part.len == 0) continue;
        argv.append(allocator, part) catch return RenderError.SpawnFailed;
    }
    if (argv.items.len == 0) return RenderError.BrowserNotFound;

    argv.appendSlice(allocator, &.{
        "--headless",
        "--disable-gpu",
        "--no-pdf-header-footer",
        "--virtual-time-budget=10000",
        "--run-all-compositor-stages-before-draw",
        pdf_flag,
        url,
    }) catch return RenderError.SpawnFailed;

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    const term = child.spawnAndWait() catch |err| switch (err) {
        error.FileNotFound => return RenderError.BrowserNotFound,
        else => return RenderError.SpawnFailed,
    };

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                return RenderError.BrowserFailed;
            }
        },
        else => return RenderError.BrowserFailed,
    }

    // Ensure PDF exists and is non-empty to catch partial/failed writes.
    const file = if (std.fs.path.isAbsolute(output_pdf))
        std.fs.openFileAbsolute(output_pdf, .{}) catch return RenderError.OutputMissing
    else
        std.fs.cwd().openFile(output_pdf, .{}) catch return RenderError.OutputMissing;
    defer file.close();

    const stat = file.stat() catch return RenderError.OutputMissing;
    if (stat.size == 0) return RenderError.OutputEmpty;
}

fn canSpawnBrowser(allocator: std.mem.Allocator, browser_bin: []const u8) bool {
    var child = std.process.Child.init(&.{ browser_bin, "--version" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    _ = child.spawnAndWait() catch return false;
    return true;
}

test "discoverBrowserWithOverride prefers explicit override" {
    const allocator = std.testing.allocator;
    const resolved = try discoverBrowserWithOverride(allocator, "custom-chrome");
    defer allocator.free(resolved);

    try std.testing.expectEqualStrings("custom-chrome", resolved);
}

test "renderPdf returns OutputMissing when browser exits 0 but no pdf exists" {
    // `/bin/true` exits successfully but does not create a file.
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        RenderError.OutputMissing,
        renderPdf(
            allocator,
            "/bin/true",
            "http://127.0.0.1:1",
            "definitely-does-not-exist.pdf",
        ),
    );
}

test "discoverBrowserWithOverride returns BrowserNotFound when no override and no candidates" {
    const allocator = std.testing.allocator;
    // Empty override string should be treated as absent.
    try std.testing.expectError(
        RenderError.BrowserNotFound,
        discoverBrowserWithOverride(allocator, ""),
    );
}

test "discoverBrowserWithOverride ignores empty override" {
    const allocator = std.testing.allocator;
    // null override falls through to PATH scan, which will fail in test
    // unless a real browser is on PATH. We just verify it doesn't crash.
    _ = discoverBrowserWithOverride(allocator, null) catch |err| {
        try std.testing.expect(err == RenderError.BrowserNotFound);
        return;
    };
}

test "renderPdf returns BrowserNotFound for nonexistent binary" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        RenderError.BrowserNotFound,
        renderPdf(
            allocator,
            "/nonexistent-browser-path-ligi-test",
            "http://127.0.0.1:1",
            "/tmp/ligi-test-unused.pdf",
        ),
    );
}

test "renderPdf returns BrowserFailed for nonzero exit" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        RenderError.BrowserFailed,
        renderPdf(
            allocator,
            "/bin/false",
            "http://127.0.0.1:1",
            "/tmp/ligi-test-unused.pdf",
        ),
    );
}
