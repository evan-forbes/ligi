//! Asset embedding and MIME type handling for the serve module.
//!
//! Embeds all static assets (HTML, JS, CSS, vendor libraries) into the binary
//! and provides content-type mapping for HTTP responses.

const std = @import("std");

/// MIME type definitions
pub const MimeType = struct {
    pub const html = "text/html; charset=utf-8";
    pub const css = "text/css; charset=utf-8";
    pub const javascript = "application/javascript; charset=utf-8";
    pub const json = "application/json; charset=utf-8";
    pub const plain = "text/plain; charset=utf-8";
    pub const png = "image/png";
    pub const jpeg = "image/jpeg";
    pub const gif = "image/gif";
    pub const svg = "image/svg+xml";
    pub const webp = "image/webp";
    pub const octet_stream = "application/octet-stream";
};

/// Get MIME type for a file extension
pub fn getMimeType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return MimeType.octet_stream;

    if (std.mem.eql(u8, ext, ".html") or std.mem.eql(u8, ext, ".htm")) {
        return MimeType.html;
    } else if (std.mem.eql(u8, ext, ".css")) {
        return MimeType.css;
    } else if (std.mem.eql(u8, ext, ".js")) {
        return MimeType.javascript;
    } else if (std.mem.eql(u8, ext, ".json")) {
        return MimeType.json;
    } else if (std.mem.eql(u8, ext, ".md") or std.mem.eql(u8, ext, ".markdown") or std.mem.eql(u8, ext, ".txt")) {
        return MimeType.plain;
    } else if (std.mem.eql(u8, ext, ".png")) {
        return MimeType.png;
    } else if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) {
        return MimeType.jpeg;
    } else if (std.mem.eql(u8, ext, ".gif")) {
        return MimeType.gif;
    } else if (std.mem.eql(u8, ext, ".svg")) {
        return MimeType.svg;
    } else if (std.mem.eql(u8, ext, ".webp")) {
        return MimeType.webp;
    }

    return MimeType.octet_stream;
}

// ============================================================================
// Embedded Assets
// ============================================================================

/// Main HTML shell
pub const index_html = @embedFile("assets/index.html");

/// Application JavaScript
pub const app_js = @embedFile("assets/app.js");

/// Application CSS
pub const styles_css = @embedFile("assets/styles.css");

/// Vendor libraries
pub const vendor = struct {
    pub const marked_js = @embedFile("assets/vendor/marked.min.js");
    pub const mermaid_js = @embedFile("assets/vendor/mermaid.min.js");
};

/// Asset lookup by path
pub fn getAsset(path: []const u8) ?[]const u8 {
    // Remove leading slash if present
    const clean_path = if (path.len > 0 and path[0] == '/') path[1..] else path;

    if (std.mem.eql(u8, clean_path, "") or std.mem.eql(u8, clean_path, "index.html")) {
        return index_html;
    } else if (std.mem.eql(u8, clean_path, "assets/app.js") or std.mem.eql(u8, clean_path, "app.js")) {
        return app_js;
    } else if (std.mem.eql(u8, clean_path, "assets/styles.css") or std.mem.eql(u8, clean_path, "styles.css")) {
        return styles_css;
    } else if (std.mem.eql(u8, clean_path, "assets/vendor/marked.min.js") or
        std.mem.eql(u8, clean_path, "vendor/marked.min.js"))
    {
        return vendor.marked_js;
    } else if (std.mem.eql(u8, clean_path, "assets/vendor/mermaid.min.js") or
        std.mem.eql(u8, clean_path, "vendor/mermaid.min.js"))
    {
        return vendor.mermaid_js;
    }

    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "getMimeType returns correct types for common extensions" {
    try std.testing.expectEqualStrings(MimeType.html, getMimeType("index.html"));
    try std.testing.expectEqualStrings(MimeType.css, getMimeType("styles.css"));
    try std.testing.expectEqualStrings(MimeType.javascript, getMimeType("app.js"));
    try std.testing.expectEqualStrings(MimeType.json, getMimeType("data.json"));
    try std.testing.expectEqualStrings(MimeType.plain, getMimeType("readme.md"));
    try std.testing.expectEqualStrings(MimeType.plain, getMimeType("readme.txt"));
}

test "getMimeType returns correct types for images" {
    try std.testing.expectEqualStrings(MimeType.png, getMimeType("image.png"));
    try std.testing.expectEqualStrings(MimeType.jpeg, getMimeType("image.jpg"));
    try std.testing.expectEqualStrings(MimeType.jpeg, getMimeType("image.jpeg"));
    try std.testing.expectEqualStrings(MimeType.gif, getMimeType("image.gif"));
    try std.testing.expectEqualStrings(MimeType.svg, getMimeType("image.svg"));
    try std.testing.expectEqualStrings(MimeType.webp, getMimeType("image.webp"));
}

test "getMimeType returns octet-stream for unknown extensions" {
    try std.testing.expectEqualStrings(MimeType.octet_stream, getMimeType("file.xyz"));
    try std.testing.expectEqualStrings(MimeType.octet_stream, getMimeType("noextension"));
}

test "getAsset returns index_html for root" {
    try std.testing.expect(getAsset("") != null);
    try std.testing.expect(getAsset("/") != null);
    try std.testing.expect(getAsset("index.html") != null);
}

test "getAsset returns app assets" {
    try std.testing.expect(getAsset("assets/app.js") != null);
    try std.testing.expect(getAsset("assets/styles.css") != null);
}

test "getAsset returns vendor assets" {
    try std.testing.expect(getAsset("assets/vendor/marked.min.js") != null);
    try std.testing.expect(getAsset("assets/vendor/mermaid.min.js") != null);
}

test "getAsset returns null for unknown paths" {
    try std.testing.expect(getAsset("nonexistent.js") == null);
    try std.testing.expect(getAsset("assets/unknown.css") == null);
}
