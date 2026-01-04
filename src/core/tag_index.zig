//! Tag indexing system for ligi.
//!
//! This module provides tag parsing, collection, and index management for the
//! tagging system. Tags use wiki-style syntax: `[[t/tag_name]]`

const std = @import("std");
const errors = @import("errors.zig");
const paths = @import("paths.zig");
const fs = @import("fs.zig");

/// Maximum allowed tag name length (filesystem path limit)
pub const MAX_TAG_NAME_LEN = 255;

/// UTF-8 BOM sequence
const UTF8_BOM = "\xef\xbb\xbf";

/// Parser state machine states
const ParserState = enum {
    normal,
    in_fenced_code,
    in_inline_code,
    in_html_comment,
};

/// A parsed tag with its location info
pub const Tag = struct {
    name: []const u8,
    line: usize = 0,
};

/// Result of tag name validation
pub const ValidationResult = union(enum) {
    valid,
    empty,
    too_long,
    path_traversal,
    invalid_char: u8,
};

/// Validate a tag name according to the spec
/// Allowed: A-Z, a-z, 0-9, _, -, ., /
pub fn isValidTagName(name: []const u8) ValidationResult {
    if (name.len == 0) {
        return .empty;
    }
    if (name.len > MAX_TAG_NAME_LEN) {
        return .too_long;
    }
    // Check for path traversal
    if (std.mem.indexOf(u8, name, "..") != null) {
        return .path_traversal;
    }
    for (name) |c| {
        const valid = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-' or c == '.' or c == '/';
        if (!valid) {
            return .{ .invalid_char = c };
        }
    }
    return .valid;
}

/// Parse tags from markdown content using a state machine.
/// Returns a list of unique tag names. Tags inside code blocks/comments are ignored.
pub fn parseTagsFromContent(allocator: std.mem.Allocator, content: []const u8) ![]Tag {
    var tags: std.ArrayList(Tag) = .empty;
    errdefer tags.deinit(allocator);

    // Track seen tags for deduplication
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var state: ParserState = .normal;
    var pos: usize = 0;
    var line: usize = 1;

    // Skip UTF-8 BOM if present
    if (content.len >= 3 and std.mem.eql(u8, content[0..3], UTF8_BOM)) {
        pos = 3;
    }

    while (pos < content.len) {
        // Track line numbers
        if (content[pos] == '\n') {
            line += 1;
        }

        switch (state) {
            .normal => {
                // Check for fenced code block start
                if (startsWithAt(content, pos, "```")) {
                    state = .in_fenced_code;
                    pos += 3;
                    continue;
                }
                // Check for HTML comment start
                if (startsWithAt(content, pos, "<!--")) {
                    state = .in_html_comment;
                    pos += 4;
                    continue;
                }
                // Check for inline code start
                if (content[pos] == '`') {
                    state = .in_inline_code;
                    pos += 1;
                    continue;
                }
                // Check for tag
                if (startsWithAt(content, pos, "[[t/")) {
                    pos += 4; // skip "[[t/"
                    const tag_start = pos;

                    // Scan for closing ]]
                    while (pos < content.len and !startsWithAt(content, pos, "]]")) {
                        pos += 1;
                    }

                    if (pos < content.len) {
                        const tag_name = content[tag_start..pos];
                        pos += 2; // skip "]]"

                        // Add if valid and not seen before
                        if (isValidTagName(tag_name) == .valid) {
                            if (!seen.contains(tag_name)) {
                                const name_copy = try allocator.dupe(u8, tag_name);
                                try seen.put(name_copy, {});
                                try tags.append(allocator, .{ .name = name_copy, .line = line });
                            }
                        }
                    }
                    continue;
                }
                pos += 1;
            },
            .in_fenced_code => {
                // Scan to end of line
                const line_start = pos;
                while (pos < content.len and content[pos] != '\n') {
                    pos += 1;
                }
                // Check if this line starts/ends fenced block
                const line_content = content[line_start..pos];
                const trimmed = std.mem.trimLeft(u8, line_content, " \t");
                if (std.mem.startsWith(u8, trimmed, "```")) {
                    state = .normal;
                }
                if (pos < content.len) {
                    pos += 1; // skip newline
                    line += 1;
                }
            },
            .in_inline_code => {
                if (content[pos] == '`') {
                    state = .normal;
                }
                pos += 1;
            },
            .in_html_comment => {
                if (startsWithAt(content, pos, "-->")) {
                    state = .normal;
                    pos += 3;
                } else {
                    pos += 1;
                }
            },
        }
    }

    return tags.toOwnedSlice(allocator);
}

/// Free tags allocated by parseTagsFromContent
pub fn freeTags(allocator: std.mem.Allocator, tags: []Tag) void {
    for (tags) |tag| {
        allocator.free(tag.name);
    }
    allocator.free(tags);
}

/// Check if content at position starts with prefix
fn startsWithAt(content: []const u8, pos: usize, prefix: []const u8) bool {
    if (pos + prefix.len > content.len) return false;
    return std.mem.eql(u8, content[pos..][0..prefix.len], prefix);
}

/// Represents a mapping from tags to files
pub const TagMap = struct {
    /// Maps tag name -> list of file paths
    map: std.StringHashMap(std.ArrayList([]const u8)),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TagMap {
        return .{
            .map = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TagMap) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            // Free file paths
            for (entry.value_ptr.items) |path| {
                self.allocator.free(path);
            }
            entry.value_ptr.deinit(self.allocator);
            // Free tag name
            self.allocator.free(entry.key_ptr.*);
        }
        self.map.deinit();
    }

    /// Add a file to a tag
    pub fn addFile(self: *TagMap, tag: []const u8, file_path: []const u8) !void {
        const entry = try self.map.getOrPut(tag);
        if (!entry.found_existing) {
            // New tag - copy the key and create list
            entry.key_ptr.* = try self.allocator.dupe(u8, tag);
            entry.value_ptr.* = .empty;
        }
        // Add file path (copy it)
        const path_copy = try self.allocator.dupe(u8, file_path);
        try entry.value_ptr.append(self.allocator, path_copy);
    }

    /// Get sorted tag names
    pub fn getSortedTags(self: *const TagMap, allocator: std.mem.Allocator) ![][]const u8 {
        var keys: std.ArrayList([]const u8) = .empty;
        errdefer keys.deinit(allocator);

        var it = self.map.iterator();
        while (it.next()) |entry| {
            try keys.append(allocator, entry.key_ptr.*);
        }

        const slice = try keys.toOwnedSlice(allocator);
        std.mem.sort([]const u8, slice, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
        return slice;
    }

    /// Get sorted file paths for a tag
    pub fn getSortedFiles(self: *const TagMap, tag: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
        const files = self.map.get(tag) orelse return &[_][]const u8{};

        const result = try allocator.alloc([]const u8, files.items.len);
        @memcpy(result, files.items);

        std.mem.sort([]const u8, result, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
        return result;
    }
};

/// Collect tags from all markdown files in an art directory.
/// Excludes art/index/ subdirectory.
/// Returns a TagMap mapping tags to file paths.
pub fn collectTags(
    allocator: std.mem.Allocator,
    art_path: []const u8,
    single_file: ?[]const u8,
    follow_symlinks: bool,
    ignore_patterns: []const []const u8,
    stderr: anytype,
) !TagMap {
    var tag_map = TagMap.init(allocator);
    errdefer tag_map.deinit();

    if (single_file) |file| {
        // Index only a single file
        try processFile(allocator, &tag_map, art_path, file, stderr);
    } else {
        // Walk the art directory
        try walkArtDirectory(allocator, &tag_map, art_path, follow_symlinks, ignore_patterns, stderr);
    }

    return tag_map;
}

/// Walk the art directory and collect tags from all markdown files
fn walkArtDirectory(
    allocator: std.mem.Allocator,
    tag_map: *TagMap,
    art_path: []const u8,
    follow_symlinks: bool,
    ignore_patterns: []const []const u8,
    stderr: anytype,
) !void {
    var dir = std.fs.cwd().openDir(art_path, .{ .iterate = true }) catch {
        return;
    };
    defer dir.close();

    var walker = dir.walk(allocator) catch return;
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        // Skip directories
        if (entry.kind == .directory) continue;

        // Skip symlinks if not following
        if (entry.kind == .sym_link and !follow_symlinks) {
            continue;
        }

        // Only process .md files
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;

        // Skip files in index/ subdirectory
        if (std.mem.startsWith(u8, entry.path, "index/") or
            std.mem.startsWith(u8, entry.path, "index\\"))
        {
            continue;
        }

        // Check ignore patterns
        var should_ignore = false;
        for (ignore_patterns) |pattern| {
            if (matchGlob(entry.basename, pattern)) {
                should_ignore = true;
                break;
            }
        }
        if (should_ignore) continue;

        // Build full path for reading
        const full_path = try std.fs.path.join(allocator, &.{ art_path, entry.path });
        defer allocator.free(full_path);

        // Build repo-relative path (art/...)
        const repo_path = try std.fs.path.join(allocator, &.{ "art", entry.path });
        defer allocator.free(repo_path);

        try processFile(allocator, tag_map, art_path, repo_path, stderr);
    }
}

/// Process a single file and add its tags to the map
fn processFile(
    allocator: std.mem.Allocator,
    tag_map: *TagMap,
    art_path: []const u8,
    repo_relative_path: []const u8,
    stderr: anytype,
) !void {
    // Remove "art/" prefix if present to get path relative to art_path
    const relative_to_art = if (std.mem.startsWith(u8, repo_relative_path, "art/"))
        repo_relative_path[4..]
    else if (std.mem.startsWith(u8, repo_relative_path, "art\\"))
        repo_relative_path[4..]
    else
        repo_relative_path;

    // Build full path
    const full_path = try std.fs.path.join(allocator, &.{ art_path, relative_to_art });
    defer allocator.free(full_path);

    // Read file
    const content = switch (fs.readFile(allocator, full_path)) {
        .ok => |c| c,
        .err => {
            try stderr.print("warning: cannot read file: {s}\n", .{full_path});
            return;
        },
    };
    defer allocator.free(content);

    // Parse tags
    const tags = parseTagsFromContent(allocator, content) catch {
        try stderr.print("warning: failed to parse tags in: {s}\n", .{full_path});
        return;
    };
    defer freeTags(allocator, tags);

    // Add to tag map
    for (tags) |tag| {
        try tag_map.addFile(tag.name, repo_relative_path);
    }
}

/// Simple glob matching for ignore patterns
fn matchGlob(name: []const u8, pattern: []const u8) bool {
    // Handle simple wildcards: *.ext, prefix*, *suffix*
    if (std.mem.startsWith(u8, pattern, "*.")) {
        // Match extension
        return std.mem.endsWith(u8, name, pattern[1..]);
    }
    if (std.mem.endsWith(u8, pattern, "*")) {
        // Match prefix
        return std.mem.startsWith(u8, name, pattern[0 .. pattern.len - 1]);
    }
    // Exact match
    return std.mem.eql(u8, name, pattern);
}

/// Content for the main tag index file
pub const TAG_INDEX_HEADER =
    \\# Ligi Tag Index
    \\
    \\This file is auto-maintained by ligi. Each tag links to its index file.
    \\
    \\## Tags
    \\
;

/// Render the main tag index file (ligi_tags.md)
pub fn renderTagIndex(allocator: std.mem.Allocator, tag_map: *const TagMap) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writer.writeAll(TAG_INDEX_HEADER);

    const tags = try tag_map.getSortedTags(allocator);
    defer allocator.free(tags);

    for (tags) |tag| {
        // Convert tag to file path: foo/bar -> tags/foo/bar.md
        try writer.print("- [{s}](tags/{s}.md)\n", .{ tag, tag });
    }

    return output.toOwnedSlice(allocator);
}

/// Render a per-tag index file
pub fn renderPerTagIndex(allocator: std.mem.Allocator, tag: []const u8, files: []const []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writer.print("# Tag: {s}\n\n", .{tag});
    try writer.writeAll("This file is auto-maintained by ligi.\n\n");
    try writer.writeAll("## Files\n\n");

    // Sort files
    const sorted = try allocator.alloc([]const u8, files.len);
    defer allocator.free(sorted);
    @memcpy(sorted, files);

    std.mem.sort([]const u8, sorted, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    for (sorted) |file| {
        try writer.print("- {s}\n", .{file});
    }

    return output.toOwnedSlice(allocator);
}

/// Write local index files (ligi_tags.md and per-tag files)
pub fn writeLocalIndexes(
    allocator: std.mem.Allocator,
    art_path: []const u8,
    tag_map: *const TagMap,
    stdout: anytype,
    quiet: bool,
) !struct { created: usize, updated: usize } {
    var created: usize = 0;
    var updated: usize = 0;

    // Ensure art/index/tags/ exists
    const tags_dir = try std.fs.path.join(allocator, &.{ art_path, "index", "tags" });
    defer allocator.free(tags_dir);

    std.fs.cwd().makePath(tags_dir) catch |err| {
        std.debug.print("error: cannot create index directory: {s}: {s}\n", .{ tags_dir, @errorName(err) });
        return err;
    };

    // Write ligi_tags.md
    const tag_index_path = try std.fs.path.join(allocator, &.{ art_path, "index", "ligi_tags.md" });
    defer allocator.free(tag_index_path);

    const existed = fs.fileExists(tag_index_path);
    const tag_index_content = try renderTagIndex(allocator, tag_map);
    defer allocator.free(tag_index_content);

    try writeFileAtomic(tag_index_path, tag_index_content);
    if (!quiet) {
        if (existed) {
            try stdout.print("updated: {s}\n", .{tag_index_path});
            updated += 1;
        } else {
            try stdout.print("created: {s}\n", .{tag_index_path});
            created += 1;
        }
    }

    // Write per-tag index files
    const tags = try tag_map.getSortedTags(allocator);
    defer allocator.free(tags);

    for (tags) |tag| {
        // Get files for this tag
        const files = tag_map.map.get(tag) orelse continue;

        // Build path: art/index/tags/<tag>.md
        const tag_file_path = try std.fs.path.join(allocator, &.{ art_path, "index", "tags", tag });
        defer allocator.free(tag_file_path);

        const full_path = try std.fmt.allocPrint(allocator, "{s}.md", .{tag_file_path});
        defer allocator.free(full_path);

        // Ensure parent directory exists (for nested tags like foo/bar)
        if (std.fs.path.dirname(full_path)) |parent| {
            std.fs.cwd().makePath(parent) catch {};
        }

        const tag_existed = fs.fileExists(full_path);
        const content = try renderPerTagIndex(allocator, tag, files.items);
        defer allocator.free(content);

        try writeFileAtomic(full_path, content);
        if (!quiet) {
            if (tag_existed) {
                try stdout.print("updated: {s}\n", .{full_path});
                updated += 1;
            } else {
                try stdout.print("created: {s}\n", .{full_path});
                created += 1;
            }
        }
    }

    return .{ .created = created, .updated = updated };
}

/// Write global index files
pub fn writeGlobalIndexes(
    allocator: std.mem.Allocator,
    tag_map: *const TagMap,
    repo_root: []const u8,
    stdout: anytype,
    quiet: bool,
) !void {
    // Get global art path
    const global_art = switch (paths.getGlobalArtPath(allocator)) {
        .ok => |p| p,
        .err => {
            std.debug.print("error: global home directory not accessible: ~/.ligi/\n", .{});
            return error.GlobalHomeNotAccessible;
        },
    };
    defer allocator.free(global_art);

    // Ensure global tags directory exists
    const global_tags_dir = try std.fs.path.join(allocator, &.{ global_art, "index", "tags" });
    defer allocator.free(global_tags_dir);

    std.fs.cwd().makePath(global_tags_dir) catch |err| {
        std.debug.print("error: cannot create global index directory: {s}: {s}\n", .{ global_tags_dir, @errorName(err) });
        return err;
    };

    // Get absolute repo root
    const abs_repo = std.fs.cwd().realpathAlloc(allocator, repo_root) catch |err| {
        std.debug.print("error: cannot resolve repo path: {s}: {s}\n", .{ repo_root, @errorName(err) });
        return err;
    };
    defer allocator.free(abs_repo);

    // Load or create global tag index
    const global_tag_index_path = try std.fs.path.join(allocator, &.{ global_art, "index", "ligi_tags.md" });
    defer allocator.free(global_tag_index_path);

    var global_tags = std.StringHashMap(void).init(allocator);
    defer {
        var it = global_tags.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        global_tags.deinit();
    }

    // Read existing global tags if file exists
    if (fs.fileExists(global_tag_index_path)) {
        const content = switch (fs.readFile(allocator, global_tag_index_path)) {
            .ok => |c| c,
            .err => null,
        };
        if (content) |c| {
            defer allocator.free(c);
            // Parse existing tags from content
            var lines = std.mem.splitScalar(u8, c, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "- [")) {
                    // Extract tag name from "- [tag](tags/tag.md)"
                    const start = std.mem.indexOf(u8, line, "[") orelse continue;
                    const end = std.mem.indexOf(u8, line, "]") orelse continue;
                    if (end > start + 1) {
                        const tag = line[start + 1 .. end];
                        if (!global_tags.contains(tag)) {
                            const tag_copy = try allocator.dupe(u8, tag);
                            try global_tags.put(tag_copy, {});
                        }
                    }
                }
            }
        }
    }

    // Add new tags from this repo
    const tags = try tag_map.getSortedTags(allocator);
    defer allocator.free(tags);

    for (tags) |tag| {
        if (!global_tags.contains(tag)) {
            const tag_copy = try allocator.dupe(u8, tag);
            try global_tags.put(tag_copy, {});
        }
    }

    // Render and write global tag index
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writer.writeAll(TAG_INDEX_HEADER);

    // Sort global tags
    var global_tag_list: std.ArrayList([]const u8) = .empty;
    defer global_tag_list.deinit(allocator);

    var it = global_tags.keyIterator();
    while (it.next()) |key| {
        try global_tag_list.append(allocator, key.*);
    }

    std.mem.sort([]const u8, global_tag_list.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    for (global_tag_list.items) |tag| {
        try writer.print("- [{s}](tags/{s}.md)\n", .{ tag, tag });
    }

    const global_existed = fs.fileExists(global_tag_index_path);
    try writeFileAtomic(global_tag_index_path, output.items);
    if (!quiet) {
        if (global_existed) {
            try stdout.print("updated: {s}\n", .{global_tag_index_path});
        } else {
            try stdout.print("created: {s}\n", .{global_tag_index_path});
        }
    }

    // Update per-tag global index files
    for (tags) |tag| {
        const files = tag_map.map.get(tag) orelse continue;

        // Build global path
        const tag_file_path = try std.fs.path.join(allocator, &.{ global_art, "index", "tags", tag });
        defer allocator.free(tag_file_path);

        const full_path = try std.fmt.allocPrint(allocator, "{s}.md", .{tag_file_path});
        defer allocator.free(full_path);

        // Ensure parent directory exists
        if (std.fs.path.dirname(full_path)) |parent| {
            std.fs.cwd().makePath(parent) catch {};
        }

        // Load existing files if any
        var existing_files = std.StringHashMap(void).init(allocator);
        defer {
            var eit = existing_files.keyIterator();
            while (eit.next()) |key| {
                allocator.free(key.*);
            }
            existing_files.deinit();
        }

        if (fs.fileExists(full_path)) {
            const content = switch (fs.readFile(allocator, full_path)) {
                .ok => |c| c,
                .err => null,
            };
            if (content) |c| {
                defer allocator.free(c);
                var lines = std.mem.splitScalar(u8, c, '\n');
                while (lines.next()) |line| {
                    if (std.mem.startsWith(u8, line, "- ")) {
                        const path = std.mem.trim(u8, line[2..], " \t\r");
                        if (path.len > 0 and !existing_files.contains(path)) {
                            const path_copy = try allocator.dupe(u8, path);
                            try existing_files.put(path_copy, {});
                        }
                    }
                }
            }
        }

        // Add files from this repo (with absolute paths)
        for (files.items) |file| {
            const abs_file = try std.fs.path.join(allocator, &.{ abs_repo, file });
            defer allocator.free(abs_file);

            if (!existing_files.contains(abs_file)) {
                const file_copy = try allocator.dupe(u8, abs_file);
                try existing_files.put(file_copy, {});
            }
        }

        // Render global per-tag index
        var tag_output: std.ArrayList(u8) = .empty;
        defer tag_output.deinit(allocator);
        const tag_writer = tag_output.writer(allocator);

        try tag_writer.print("# Tag: {s}\n\n", .{tag});
        try tag_writer.writeAll("This file is auto-maintained by ligi.\n\n");
        try tag_writer.writeAll("## Files\n\n");

        // Sort files
        var file_list: std.ArrayList([]const u8) = .empty;
        defer file_list.deinit(allocator);

        var fit = existing_files.keyIterator();
        while (fit.next()) |key| {
            try file_list.append(allocator, key.*);
        }

        std.mem.sort([]const u8, file_list.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        for (file_list.items) |file| {
            try tag_writer.print("- {s}\n", .{file});
        }

        const tag_existed = fs.fileExists(full_path);
        try writeFileAtomic(full_path, tag_output.items);
        if (!quiet) {
            if (tag_existed) {
                try stdout.print("updated: {s}\n", .{full_path});
            } else {
                try stdout.print("created: {s}\n", .{full_path});
            }
        }
    }
}

/// Write a file atomically (write to temp, then rename)
fn writeFileAtomic(path: []const u8, content: []const u8) !void {
    const file = std.fs.cwd().createFile(path, .{}) catch |err| {
        std.debug.print("error: cannot write index file: {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer file.close();
    file.writeAll(content) catch |err| {
        std.debug.print("error: cannot write index file: {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
}

/// Check if index is stale (any source file newer than index)
pub fn isIndexStale(allocator: std.mem.Allocator, art_path: []const u8) !bool {
    const tag_index_path = try std.fs.path.join(allocator, &.{ art_path, "index", "ligi_tags.md" });
    defer allocator.free(tag_index_path);

    // If index doesn't exist, it's stale
    const index_stat = std.fs.cwd().statFile(tag_index_path) catch {
        return true;
    };
    const index_mtime = index_stat.mtime;

    // Check if any markdown file is newer
    var dir = std.fs.cwd().openDir(art_path, .{ .iterate = true }) catch {
        return true;
    };
    defer dir.close();

    var walker = dir.walk(allocator) catch return true;
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        if (entry.kind == .directory) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;
        if (std.mem.startsWith(u8, entry.path, "index/")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ art_path, entry.path });
        defer allocator.free(full_path);

        const file_stat = std.fs.cwd().statFile(full_path) catch continue;
        if (file_stat.mtime > index_mtime) {
            return true;
        }
    }

    return false;
}

/// Read a per-tag index file and return the list of file paths
pub fn readTagIndex(allocator: std.mem.Allocator, tag_index_path: []const u8) ![][]const u8 {
    const content = switch (fs.readFile(allocator, tag_index_path)) {
        .ok => |c| c,
        .err => return error.FileNotFound,
    };
    defer allocator.free(content);

    var files: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    var in_files_section = false;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "## Files")) {
            in_files_section = true;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "## ") or std.mem.startsWith(u8, trimmed, "# ")) {
            in_files_section = false;
            continue;
        }
        if (in_files_section and std.mem.startsWith(u8, trimmed, "- ")) {
            const path = std.mem.trim(u8, trimmed[2..], " \t");
            if (path.len > 0) {
                const path_copy = try allocator.dupe(u8, path);
                try files.append(allocator, path_copy);
            }
        }
    }

    return files.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "isValidTagName: valid names" {
    try std.testing.expectEqual(ValidationResult.valid, isValidTagName("alpha"));
    try std.testing.expectEqual(ValidationResult.valid, isValidTagName("foo_bar"));
    try std.testing.expectEqual(ValidationResult.valid, isValidTagName("foo-bar"));
    try std.testing.expectEqual(ValidationResult.valid, isValidTagName("foo.bar"));
    try std.testing.expectEqual(ValidationResult.valid, isValidTagName("foo/bar"));
    try std.testing.expectEqual(ValidationResult.valid, isValidTagName("ABC123"));
}

test "isValidTagName: empty name" {
    try std.testing.expectEqual(ValidationResult.empty, isValidTagName(""));
}

test "isValidTagName: path traversal" {
    try std.testing.expectEqual(ValidationResult.path_traversal, isValidTagName("../secret"));
    try std.testing.expectEqual(ValidationResult.path_traversal, isValidTagName("foo/../bar"));
}

test "isValidTagName: invalid characters" {
    const result = isValidTagName("foo bar");
    switch (result) {
        .invalid_char => |c| try std.testing.expectEqual(@as(u8, ' '), c),
        else => return error.TestExpectedEqual,
    }
}

test "parseTagsFromContent: basic detection" {
    const allocator = std.testing.allocator;
    const content = "Some text [[t/alpha]] more text";
    const tags = try parseTagsFromContent(allocator, content);
    defer freeTags(allocator, tags);

    try std.testing.expectEqual(@as(usize, 1), tags.len);
    try std.testing.expectEqualStrings("alpha", tags[0].name);
}

test "parseTagsFromContent: multiple tags" {
    const allocator = std.testing.allocator;
    const content = "[[t/alpha]] foo [[t/beta]] bar [[t/gamma]]";
    const tags = try parseTagsFromContent(allocator, content);
    defer freeTags(allocator, tags);

    try std.testing.expectEqual(@as(usize, 3), tags.len);
}

test "parseTagsFromContent: duplicate tags deduplicated" {
    const allocator = std.testing.allocator;
    const content = "[[t/alpha]] [[t/alpha]] [[t/alpha]]";
    const tags = try parseTagsFromContent(allocator, content);
    defer freeTags(allocator, tags);

    try std.testing.expectEqual(@as(usize, 1), tags.len);
}

test "parseTagsFromContent: ignores fenced code" {
    const allocator = std.testing.allocator;
    const content =
        \\Some text
        \\```
        \\[[t/ignored]]
        \\```
        \\[[t/found]]
    ;
    const tags = try parseTagsFromContent(allocator, content);
    defer freeTags(allocator, tags);

    try std.testing.expectEqual(@as(usize, 1), tags.len);
    try std.testing.expectEqualStrings("found", tags[0].name);
}

test "parseTagsFromContent: ignores inline code" {
    const allocator = std.testing.allocator;
    const content = "Some `[[t/ignored]]` text [[t/found]]";
    const tags = try parseTagsFromContent(allocator, content);
    defer freeTags(allocator, tags);

    try std.testing.expectEqual(@as(usize, 1), tags.len);
    try std.testing.expectEqualStrings("found", tags[0].name);
}

test "parseTagsFromContent: ignores HTML comments" {
    const allocator = std.testing.allocator;
    const content = "<!-- [[t/ignored]] --> [[t/found]]";
    const tags = try parseTagsFromContent(allocator, content);
    defer freeTags(allocator, tags);

    try std.testing.expectEqual(@as(usize, 1), tags.len);
    try std.testing.expectEqualStrings("found", tags[0].name);
}

test "parseTagsFromContent: handles UTF-8 BOM" {
    const allocator = std.testing.allocator;
    const content = UTF8_BOM ++ "[[t/alpha]]";
    const tags = try parseTagsFromContent(allocator, content);
    defer freeTags(allocator, tags);

    try std.testing.expectEqual(@as(usize, 1), tags.len);
    try std.testing.expectEqualStrings("alpha", tags[0].name);
}

test "parseTagsFromContent: ignores invalid tags" {
    const allocator = std.testing.allocator;
    const content = "[[t/valid]] [[t/invalid tag]] [[t/also_valid]]";
    const tags = try parseTagsFromContent(allocator, content);
    defer freeTags(allocator, tags);

    try std.testing.expectEqual(@as(usize, 2), tags.len);
}

test "parseTagsFromContent: unclosed tag ignored" {
    const allocator = std.testing.allocator;
    const content = "[[t/unclosed";
    const tags = try parseTagsFromContent(allocator, content);
    defer freeTags(allocator, tags);

    try std.testing.expectEqual(@as(usize, 0), tags.len);
}

test "parseTagsFromContent: empty tag ignored" {
    const allocator = std.testing.allocator;
    const content = "[[t/]] [[t/valid]]";
    const tags = try parseTagsFromContent(allocator, content);
    defer freeTags(allocator, tags);

    try std.testing.expectEqual(@as(usize, 1), tags.len);
    try std.testing.expectEqualStrings("valid", tags[0].name);
}

test "TagMap: basic operations" {
    const allocator = std.testing.allocator;
    var tag_map = TagMap.init(allocator);
    defer tag_map.deinit();

    try tag_map.addFile("alpha", "art/file1.md");
    try tag_map.addFile("alpha", "art/file2.md");
    try tag_map.addFile("beta", "art/file1.md");

    const tags = try tag_map.getSortedTags(allocator);
    defer allocator.free(tags);

    try std.testing.expectEqual(@as(usize, 2), tags.len);
    try std.testing.expectEqualStrings("alpha", tags[0]);
    try std.testing.expectEqualStrings("beta", tags[1]);
}

test "renderTagIndex: produces valid markdown" {
    const allocator = std.testing.allocator;
    var tag_map = TagMap.init(allocator);
    defer tag_map.deinit();

    try tag_map.addFile("zebra", "art/z.md");
    try tag_map.addFile("alpha", "art/a.md");

    const output = try renderTagIndex(allocator, &tag_map);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "# Ligi Tag Index") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "## Tags") != null);
    // Check alphabetical order
    const alpha_pos = std.mem.indexOf(u8, output, "alpha").?;
    const zebra_pos = std.mem.indexOf(u8, output, "zebra").?;
    try std.testing.expect(alpha_pos < zebra_pos);
}

test "renderPerTagIndex: produces valid markdown" {
    const allocator = std.testing.allocator;
    const files = &[_][]const u8{ "art/z.md", "art/a.md" };

    const output = try renderPerTagIndex(allocator, "mytag", files);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "# Tag: mytag") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "## Files") != null);
    // Check files are sorted
    const a_pos = std.mem.indexOf(u8, output, "art/a.md").?;
    const z_pos = std.mem.indexOf(u8, output, "art/z.md").?;
    try std.testing.expect(a_pos < z_pos);
}

test "matchGlob: extension matching" {
    try std.testing.expect(matchGlob("file.tmp", "*.tmp"));
    try std.testing.expect(!matchGlob("file.md", "*.tmp"));
}

test "matchGlob: prefix matching" {
    try std.testing.expect(matchGlob("testfile.md", "test*"));
    try std.testing.expect(!matchGlob("prodfile.md", "test*"));
}
