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

/// Result of filling tag links in content
pub const FillResult = struct {
    content: []const u8,
    tags_filled: usize,
};

/// Fill tag links in markdown content.
/// Converts `[[t/tag_name]]` to `[[t/tag_name]](relative/path/to/tags/tag_name.md)`
/// Only fills tags that don't already have a link (i.e., not followed by `](`).
///
/// Parameters:
/// - allocator: Allocator for the result
/// - content: The markdown content to process
/// - source_path_in_art: Path of the source file relative to art/ (e.g., "notes.md" or "deep/notes.md")
///
/// Returns the new content with filled links, or null if no changes were made.
pub fn fillTagLinks(allocator: std.mem.Allocator, content: []const u8, source_path_in_art: []const u8) !FillResult {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var tags_filled: usize = 0;
    var state: ParserState = .normal;
    var pos: usize = 0;
    var last_copy_pos: usize = 0;

    // Skip UTF-8 BOM if present
    if (content.len >= 3 and std.mem.eql(u8, content[0..3], UTF8_BOM)) {
        pos = 3;
        try result.appendSlice(allocator, UTF8_BOM);
        last_copy_pos = 3;
    }

    // Calculate the relative path prefix from source file to art/index/tags/
    // Source is at art/<source_path_in_art>, target is at art/index/tags/<tag>.md
    const depth = countPathDepth(source_path_in_art);
    var path_prefix: std.ArrayList(u8) = .empty;
    defer path_prefix.deinit(allocator);
    for (0..depth) |_| {
        try path_prefix.appendSlice(allocator, "../");
    }
    try path_prefix.appendSlice(allocator, "index/tags/");

    while (pos < content.len) {
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
                    const tag_name_start = pos;

                    // Scan for closing ]]
                    while (pos < content.len and !startsWithAt(content, pos, "]]")) {
                        pos += 1;
                    }

                    if (pos < content.len) {
                        const tag_name = content[tag_name_start..pos];
                        pos += 2; // skip "]]"

                        // Check if already linked (the second ] followed by `(`)
                        // In [[t/tag]](url), the link is formed by ]( at positions 8-9
                        // After pos += 2, pos is at 10, so we check pos-1 for ](
                        const already_linked = pos > 0 and pos < content.len and startsWithAt(content, pos - 1, "](");

                        if (!already_linked and isValidTagName(tag_name) == .valid) {
                            // Copy everything up to and including the tag, minus one ']'
                            // Input: [[t/tag]]  -> Output: [[t/tag]](path.md)
                            // We copy [[t/tag] (pos-1) then add ](path)
                            try result.appendSlice(allocator, content[last_copy_pos .. pos - 1]);

                            // Add the link (this provides the closing ] and the url)
                            try result.appendSlice(allocator, "](");
                            try result.appendSlice(allocator, path_prefix.items);
                            try result.appendSlice(allocator, tag_name);
                            try result.appendSlice(allocator, ".md)");

                            last_copy_pos = pos;
                            tags_filled += 1;
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
                // Check if this line ends fenced block
                const line_content = content[line_start..pos];
                const trimmed = std.mem.trimLeft(u8, line_content, " \t");
                if (std.mem.startsWith(u8, trimmed, "```")) {
                    state = .normal;
                }
                if (pos < content.len) {
                    pos += 1; // skip newline
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

    // If no changes were made, return original content
    if (tags_filled == 0) {
        return .{ .content = try allocator.dupe(u8, content), .tags_filled = 0 };
    }

    // Copy remaining content
    try result.appendSlice(allocator, content[last_copy_pos..]);

    return .{ .content = try result.toOwnedSlice(allocator), .tags_filled = tags_filled };
}

/// Count the depth of a path (number of directory levels)
fn countPathDepth(path: []const u8) usize {
    var depth: usize = 0;
    for (path) |c| {
        if (c == '/' or c == '\\') depth += 1;
    }
    return depth;
}

/// Fill tag links in a file and write back if changed.
/// Returns the number of tags filled.
pub fn fillTagLinksInFile(
    allocator: std.mem.Allocator,
    art_path: []const u8,
    file_path_in_art: []const u8,
    stdout: anytype,
    quiet: bool,
) !usize {
    // Build full path
    const full_path = try std.fs.path.join(allocator, &.{ art_path, file_path_in_art });
    defer allocator.free(full_path);

    // Read file
    const content = switch (fs.readFile(allocator, full_path)) {
        .ok => |c| c,
        .err => return 0,
    };
    defer allocator.free(content);

    // Fill tags
    const fill_result = try fillTagLinks(allocator, content, file_path_in_art);
    defer allocator.free(fill_result.content);

    if (fill_result.tags_filled > 0) {
        // Write back
        try writeFile(full_path, fill_result.content);
        if (!quiet) {
            try stdout.print("filled {d} tag(s): {s}\n", .{ fill_result.tags_filled, full_path });
        }
    }

    return fill_result.tags_filled;
}

/// Fill tag links in all markdown files in an art directory.
/// Returns total number of tags filled.
pub fn fillAllTagLinks(
    allocator: std.mem.Allocator,
    art_path: []const u8,
    follow_symlinks: bool,
    ignore_patterns: []const []const u8,
    stdout: anytype,
    quiet: bool,
) !usize {
    var total_filled: usize = 0;

    var dir = std.fs.cwd().openDir(art_path, .{ .iterate = true }) catch {
        return 0;
    };
    defer dir.close();

    var walker = dir.walk(allocator) catch return 0;
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

        // Fill tags in this file
        const filled = try fillTagLinksInFile(allocator, art_path, entry.path, stdout, quiet);
        total_filled += filled;
    }

    return total_filled;
}

/// Check if content at position starts with prefix
fn startsWithAt(content: []const u8, pos: usize, prefix: []const u8) bool {
    if (pos + prefix.len > content.len) return false;
    return std.mem.eql(u8, content[pos..][0..prefix.len], prefix);
}

/// Sort a slice of strings lexicographically in-place.
/// Used throughout for deterministic index output.
fn sortStrings(slice: [][]const u8) void {
    std.mem.sort([]const u8, slice, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
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
        // Avoid duplicates
        for (entry.value_ptr.items) |existing| {
            if (std.mem.eql(u8, existing, file_path)) {
                return;
            }
        }
        // Add file path (copy it)
        const path_copy = try self.allocator.dupe(u8, file_path);
        try entry.value_ptr.append(self.allocator, path_copy);
    }

    /// Remove a file path from all tags. Prunes empty tags.
    pub fn removeFile(self: *TagMap, allocator: std.mem.Allocator, file_path: []const u8) void {
        var tags_to_remove: std.ArrayList([]const u8) = .empty;
        defer tags_to_remove.deinit(allocator);

        var it = self.map.iterator();
        while (it.next()) |entry| {
            var idx: usize = 0;
            while (idx < entry.value_ptr.items.len) {
                if (std.mem.eql(u8, entry.value_ptr.items[idx], file_path)) {
                    self.allocator.free(entry.value_ptr.items[idx]);
                    _ = entry.value_ptr.orderedRemove(idx);
                } else {
                    idx += 1;
                }
            }
            if (entry.value_ptr.items.len == 0) {
                tags_to_remove.append(allocator, entry.key_ptr.*) catch {};
            }
        }

        for (tags_to_remove.items) |tag| {
            if (self.map.fetchRemove(tag)) |kv| {
                self.allocator.free(kv.key);
                var value = kv.value;
                value.deinit(self.allocator);
            }
        }
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
        sortStrings(slice);
        return slice;
    }

    /// Get sorted file paths for a tag
    pub fn getSortedFiles(self: *const TagMap, tag: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
        const files = self.map.get(tag) orelse return &[_][]const u8{};

        const result = try allocator.alloc([]const u8, files.items.len);
        @memcpy(result, files.items);
        sortStrings(result);
        return result;
    }
};

/// Result counts for pruning tag indexes
pub const PruneResult = struct {
    pruned_entries: usize = 0,
    pruned_tags: usize = 0,
};

/// Stats returned by a global rebuild
pub const RebuildStats = struct {
    repos_processed: usize = 0,
    tags_written: usize = 0,
    files_indexed: usize = 0,
};

/// Parse tags from a tag index file (ligi_tags.md content)
fn parseTagListFromIndex(allocator: std.mem.Allocator, content: []const u8) ![][]const u8 {
    var tags: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (tags.items) |t| allocator.free(t);
        tags.deinit(allocator);
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "- ")) continue;

        const start = std.mem.indexOf(u8, trimmed, "[");
        const end = std.mem.indexOf(u8, trimmed, "]");
        if (start != null and end != null and end.? > start.? + 1) {
            const tag = trimmed[start.? + 1 .. end.?];
            if (!seen.contains(tag)) {
                const tag_copy = try allocator.dupe(u8, tag);
                try seen.put(tag_copy, {});
                try tags.append(allocator, tag_copy);
            }
            continue;
        }

        // Fallback: "- tag"
        const tag = std.mem.trim(u8, trimmed[2..], " \t");
        if (tag.len == 0) continue;
        if (!seen.contains(tag)) {
            const tag_copy = try allocator.dupe(u8, tag);
            try seen.put(tag_copy, {});
            try tags.append(allocator, tag_copy);
        }
    }

    return tags.toOwnedSlice(allocator);
}

pub fn freeTagList(allocator: std.mem.Allocator, tags: [][]const u8) void {
    for (tags) |t| allocator.free(t);
    allocator.free(tags);
}

/// Load tag names from the local tag index (art/index/ligi_tags.md).
/// Returns an allocated slice (possibly empty).
pub fn loadTagListFromIndex(
    allocator: std.mem.Allocator,
    art_path: []const u8,
    stderr: anytype,
) ![][]const u8 {
    const tag_index_path = try std.fs.path.join(allocator, &.{ art_path, "index", "ligi_tags.md" });
    defer allocator.free(tag_index_path);

    if (!fs.fileExists(tag_index_path)) {
        return try allocator.alloc([]const u8, 0);
    }

    const content = switch (fs.readFile(allocator, tag_index_path)) {
        .ok => |c| c,
        .err => {
            try stderr.print("warning: cannot read tag index: {s}\n", .{tag_index_path});
            return try allocator.alloc([]const u8, 0);
        },
    };
    defer allocator.free(content);

    return parseTagListFromIndex(allocator, content);
}

/// Load an existing tag map from local index files
pub fn loadTagMapFromIndexes(
    allocator: std.mem.Allocator,
    art_path: []const u8,
    stderr: anytype,
) !TagMap {
    var tag_map = TagMap.init(allocator);
    errdefer tag_map.deinit();

    const tag_index_path = try std.fs.path.join(allocator, &.{ art_path, "index", "ligi_tags.md" });
    defer allocator.free(tag_index_path);

    if (!fs.fileExists(tag_index_path)) {
        return tag_map;
    }

    const content = switch (fs.readFile(allocator, tag_index_path)) {
        .ok => |c| c,
        .err => {
            try stderr.print("warning: cannot read tag index: {s}\n", .{tag_index_path});
            return tag_map;
        },
    };
    defer allocator.free(content);

    const tags = try parseTagListFromIndex(allocator, content);
    defer freeTagList(allocator, tags);

    for (tags) |tag| {
        const tag_file_path = try std.fs.path.join(allocator, &.{ art_path, "index", "tags", tag });
        defer allocator.free(tag_file_path);

        const full_path = try std.fmt.allocPrint(allocator, "{s}.md", .{tag_file_path});
        defer allocator.free(full_path);

        const files = readTagIndex(allocator, full_path) catch |err| {
            if (err == error.FileNotFound) {
                continue;
            }
            return err;
        };
        defer {
            for (files) |f| allocator.free(f);
            allocator.free(files);
        }

        for (files) |file| {
            try tag_map.addFile(tag, file);
        }
    }

    return tag_map;
}

/// Update tag map for a single file (used by `ligi index --file`)
pub fn updateTagMapForFile(
    allocator: std.mem.Allocator,
    tag_map: *TagMap,
    art_path: []const u8,
    repo_relative_path: []const u8,
    stderr: anytype,
) !void {
    tag_map.removeFile(allocator, repo_relative_path);

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

fn stripArtPrefix(path: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, path, "art/")) {
        return path[4..];
    }
    if (std.mem.startsWith(u8, path, "art\\")) {
        return path[4..];
    }
    return null;
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

fn renderTagIndexFromTags(allocator: std.mem.Allocator, tags: []const []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writer.writeAll(TAG_INDEX_HEADER);

    const sorted = try allocator.alloc([]const u8, tags.len);
    defer allocator.free(sorted);
    @memcpy(sorted, tags);
    sortStrings(sorted);

    for (sorted) |tag| {
        try writer.print("- [{s}](tags/{s}.md)\n", .{ tag, tag });
    }

    return output.toOwnedSlice(allocator);
}

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

/// Render a per-tag index file (local version with relative links)
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
    sortStrings(sorted);

    // Count depth of tag (for nested tags like foo/bar)
    var tag_depth: usize = 0;
    for (tag) |c| {
        if (c == '/') tag_depth += 1;
    }

    for (sorted) |file| {
        // For local indexes, files are repo-relative (e.g., "art/path/file.md")
        // Tag index is at art/index/tags/<tag>.md
        // We need to compute relative path from tag index to file
        //
        // From art/index/tags/<tag>.md to art/path/file.md:
        // - Go up: ../ for each segment in tag (nested tags) + ../../ (tags -> index -> art)
        // - Then append path without "art/" prefix
        if (std.mem.startsWith(u8, file, "art/")) {
            const file_path = file[4..]; // Remove "art/" prefix
            // Base depth: 2 (tags -> index -> art) + tag_depth (nested tag dirs)
            const base_depth = 2 + tag_depth;
            // Build relative path prefix
            var rel_prefix: std.ArrayList(u8) = .empty;
            defer rel_prefix.deinit(allocator);
            for (0..base_depth) |_| {
                try rel_prefix.appendSlice(allocator, "../");
            }
            try writer.print("- [{s}]({s}{s})\n", .{ file, rel_prefix.items, file_path });
        } else {
            // For non-art paths (shouldn't happen in local indexes), just list as-is
            try writer.print("- {s}\n", .{file});
        }
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

    // Write ligi_tags.md (capture existing tags for pruning)
    const tag_index_path = try std.fs.path.join(allocator, &.{ art_path, "index", "ligi_tags.md" });
    defer allocator.free(tag_index_path);

    var existing_tags: [][]const u8 = &[_][]const u8{};
    if (fs.fileExists(tag_index_path)) {
        const existing_content = switch (fs.readFile(allocator, tag_index_path)) {
            .ok => |c| c,
            .err => null,
        };
        if (existing_content) |c| {
            defer allocator.free(c);
            existing_tags = try parseTagListFromIndex(allocator, c);
        }
    }
    defer {
        if (existing_tags.len > 0) {
            freeTagList(allocator, existing_tags);
        }
    }

    const existed = fs.fileExists(tag_index_path);
    const tag_index_content = try renderTagIndex(allocator, tag_map);
    defer allocator.free(tag_index_content);

    switch (fs.writeFileIfChanged(tag_index_path, tag_index_content, allocator)) {
        .ok => |was_written| {
            if (was_written) {
                if (!quiet) {
                    if (existed) {
                        try stdout.print("updated: {s}\n", .{tag_index_path});
                        updated += 1;
                    } else {
                        try stdout.print("created: {s}\n", .{tag_index_path});
                        created += 1;
                    }
                }
            }
        },
        .err => |e| {
            std.debug.print("error: cannot write index file: {s}: {s}\n", .{ tag_index_path, e.context.message });
            return error.WriteError;
        },
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

        switch (fs.writeFileIfChanged(full_path, content, allocator)) {
            .ok => |was_written| {
                if (was_written) {
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
            },
            .err => |e| {
                std.debug.print("error: cannot write index file: {s}: {s}\n", .{ full_path, e.context.message });
            },
        }
    }

    // Prune tags that were removed (write empty per-tag index)
    if (existing_tags.len > 0) {
        for (existing_tags) |old_tag| {
            if (tag_map.map.contains(old_tag)) continue;

            const tag_file_path = try std.fs.path.join(allocator, &.{ art_path, "index", "tags", old_tag });
            defer allocator.free(tag_file_path);

            const full_path = try std.fmt.allocPrint(allocator, "{s}.md", .{tag_file_path});
            defer allocator.free(full_path);

            // Ensure parent directory exists (for nested tags)
            if (std.fs.path.dirname(full_path)) |parent| {
                std.fs.cwd().makePath(parent) catch {};
            }

            const empty = try renderPerTagIndex(allocator, old_tag, &[_][]const u8{});
            defer allocator.free(empty);

            const tag_existed = fs.fileExists(full_path);
            switch (fs.writeFileIfChanged(full_path, empty, allocator)) {
                .ok => |was_written| {
                    if (was_written) {
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
                },
                .err => |e| {
                    std.debug.print("error: cannot write index file: {s}: {s}\n", .{ full_path, e.context.message });
                },
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

    var existing_tags: [][]const u8 = &[_][]const u8{};
    if (fs.fileExists(global_tag_index_path)) {
        const content = switch (fs.readFile(allocator, global_tag_index_path)) {
            .ok => |c| c,
            .err => null,
        };
        if (content) |c| {
            defer allocator.free(c);
            existing_tags = try parseTagListFromIndex(allocator, c);
        }
    }
    defer {
        if (existing_tags.len > 0) {
            freeTagList(allocator, existing_tags);
        }
    }

    // Build union of existing tags and current repo tags
    var tag_set = std.StringHashMap(void).init(allocator);
    defer {
        var kit = tag_set.keyIterator();
        while (kit.next()) |key| {
            allocator.free(key.*);
        }
        tag_set.deinit();
    }

    for (existing_tags) |tag| {
        if (!tag_set.contains(tag)) {
            const tag_copy = try allocator.dupe(u8, tag);
            try tag_set.put(tag_copy, {});
        }
    }

    const tags = try tag_map.getSortedTags(allocator);
    defer allocator.free(tags);
    for (tags) |tag| {
        if (!tag_set.contains(tag)) {
            const tag_copy = try allocator.dupe(u8, tag);
            try tag_set.put(tag_copy, {});
        }
    }

    const sep: u8 = std.fs.path.sep;
    const repo_prefix = try std.fmt.allocPrint(allocator, "{s}{c}", .{ abs_repo, sep });
    defer allocator.free(repo_prefix);

    // Track tags that still have files after update
    var global_tag_list: std.ArrayList([]const u8) = .empty;
    defer global_tag_list.deinit(allocator);

    var it = tag_set.keyIterator();
    while (it.next()) |key| {
        const tag = key.*;

        // Build global path
        const tag_file_path = try std.fs.path.join(allocator, &.{ global_art, "index", "tags", tag });
        defer allocator.free(tag_file_path);

        const full_path = try std.fmt.allocPrint(allocator, "{s}.md", .{tag_file_path});
        defer allocator.free(full_path);

        // Ensure parent directory exists
        if (std.fs.path.dirname(full_path)) |parent| {
            std.fs.cwd().makePath(parent) catch {};
        }

        var files_set = std.StringHashMap(void).init(allocator);
        defer {
            var fit = files_set.keyIterator();
            while (fit.next()) |f| {
                allocator.free(f.*);
            }
            files_set.deinit();
        }

        // Load existing files if any
        const existing_files = readTagIndex(allocator, full_path) catch |err| blk: {
            if (err == error.FileNotFound) {
                break :blk try allocator.alloc([]const u8, 0);
            }
            return err;
        };
        defer {
            for (existing_files) |f| allocator.free(f);
            allocator.free(existing_files);
        }

        for (existing_files) |file| {
            if (std.mem.eql(u8, file, abs_repo) or std.mem.startsWith(u8, file, repo_prefix)) {
                continue;
            }
            if (!files_set.contains(file)) {
                const file_copy = try allocator.dupe(u8, file);
                try files_set.put(file_copy, {});
            }
        }

        // Add files from this repo (with absolute paths)
        const repo_files = tag_map.map.get(tag);
        if (repo_files) |files| {
            for (files.items) |file| {
                const abs_file = try std.fs.path.join(allocator, &.{ abs_repo, file });
                defer allocator.free(abs_file);
                if (!files_set.contains(abs_file)) {
                    const file_copy = try allocator.dupe(u8, abs_file);
                    try files_set.put(file_copy, {});
                }
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

        var fit = files_set.keyIterator();
        while (fit.next()) |f| {
            try file_list.append(allocator, f.*);
        }
        sortStrings(file_list.items);

        for (file_list.items) |file| {
            try tag_writer.print("- {s}\n", .{file});
        }

        const tag_existed = fs.fileExists(full_path);
        switch (fs.writeFileIfChanged(full_path, tag_output.items, allocator)) {
            .ok => |was_written| {
                if (was_written and !quiet) {
                    if (tag_existed) {
                        try stdout.print("updated: {s}\n", .{full_path});
                    } else {
                        try stdout.print("created: {s}\n", .{full_path});
                    }
                }
            },
            .err => |e| {
                std.debug.print("error: cannot write global index file: {s}: {s}\n", .{ full_path, e.context.message });
            },
        }

        if (file_list.items.len > 0) {
            try global_tag_list.append(allocator, tag);
        }
    }

    // Render and write global tag index (only tags with files)
    sortStrings(global_tag_list.items);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writer.writeAll(TAG_INDEX_HEADER);
    for (global_tag_list.items) |tag| {
        try writer.print("- [{s}](tags/{s}.md)\n", .{ tag, tag });
    }

    const global_existed = fs.fileExists(global_tag_index_path);
    switch (fs.writeFileIfChanged(global_tag_index_path, output.items, allocator)) {
        .ok => |was_written| {
            if (was_written and !quiet) {
                if (global_existed) {
                    try stdout.print("updated: {s}\n", .{global_tag_index_path});
                } else {
                    try stdout.print("created: {s}\n", .{global_tag_index_path});
                }
            }
        },
        .err => |e| {
            std.debug.print("error: cannot write global index: {s}\n", .{e.context.message});
        },
    }
}

/// Write global index files authoritatively at a specific global art path.
/// Rewrites the global tag list and per-tag files.
pub fn writeGlobalIndexesAuthoritative(
    allocator: std.mem.Allocator,
    tag_map: *const TagMap,
    global_art_path: []const u8,
    stdout: anytype,
    quiet: bool,
) !void {
    const global_tags_dir = try std.fs.path.join(allocator, &.{ global_art_path, "index", "tags" });
    defer allocator.free(global_tags_dir);

    std.fs.cwd().makePath(global_tags_dir) catch |err| {
        std.debug.print("error: cannot create global index directory: {s}: {s}\n", .{ global_tags_dir, @errorName(err) });
        return err;
    };

    const global_tag_index_path = try std.fs.path.join(allocator, &.{ global_art_path, "index", "ligi_tags.md" });
    defer allocator.free(global_tag_index_path);

    // Track existing tags for pruning
    var existing_tags: [][]const u8 = &[_][]const u8{};
    if (fs.fileExists(global_tag_index_path)) {
        const existing_content = switch (fs.readFile(allocator, global_tag_index_path)) {
            .ok => |c| c,
            .err => null,
        };
        if (existing_content) |c| {
            defer allocator.free(c);
            existing_tags = try parseTagListFromIndex(allocator, c);
        }
    }
    defer {
        if (existing_tags.len > 0) {
            freeTagList(allocator, existing_tags);
        }
    }

    // Write tag list
    const tag_index_content = try renderTagIndex(allocator, tag_map);
    defer allocator.free(tag_index_content);

    const tag_index_existed = fs.fileExists(global_tag_index_path);
    switch (fs.writeFileIfChanged(global_tag_index_path, tag_index_content, allocator)) {
        .ok => |was_written| {
            if (was_written and !quiet) {
                if (tag_index_existed) {
                    try stdout.print("updated: {s}\n", .{global_tag_index_path});
                } else {
                    try stdout.print("created: {s}\n", .{global_tag_index_path});
                }
            }
        },
        .err => |e| {
            std.debug.print("error: cannot write global index: {s}\n", .{e.context.message});
        },
    }

    // Write per-tag index files
    const tags = try tag_map.getSortedTags(allocator);
    defer allocator.free(tags);

    for (tags) |tag| {
        const files = tag_map.map.get(tag) orelse continue;

        const tag_file_path = try std.fs.path.join(allocator, &.{ global_art_path, "index", "tags", tag });
        defer allocator.free(tag_file_path);

        const full_path = try std.fmt.allocPrint(allocator, "{s}.md", .{tag_file_path});
        defer allocator.free(full_path);

        if (std.fs.path.dirname(full_path)) |parent| {
            std.fs.cwd().makePath(parent) catch {};
        }

        const content = try renderPerTagIndex(allocator, tag, files.items);
        defer allocator.free(content);

        const tag_existed = fs.fileExists(full_path);
        switch (fs.writeFileIfChanged(full_path, content, allocator)) {
            .ok => |was_written| {
                if (was_written and !quiet) {
                    if (tag_existed) {
                        try stdout.print("updated: {s}\n", .{full_path});
                    } else {
                        try stdout.print("created: {s}\n", .{full_path});
                    }
                }
            },
            .err => |e| {
                std.debug.print("error: cannot write global tag index: {s}\n", .{e.context.message});
            },
        }
    }

    // Prune tags not in the new map (write empty per-tag files)
    if (existing_tags.len > 0) {
        for (existing_tags) |old_tag| {
            if (tag_map.map.contains(old_tag)) continue;

            const tag_file_path = try std.fs.path.join(allocator, &.{ global_art_path, "index", "tags", old_tag });
            defer allocator.free(tag_file_path);

            const full_path = try std.fmt.allocPrint(allocator, "{s}.md", .{tag_file_path});
            defer allocator.free(full_path);

            if (std.fs.path.dirname(full_path)) |parent| {
                std.fs.cwd().makePath(parent) catch {};
            }

            const empty = try renderPerTagIndex(allocator, old_tag, &[_][]const u8{});
            defer allocator.free(empty);

            const tag_existed = fs.fileExists(full_path);
            switch (fs.writeFileIfChanged(full_path, empty, allocator)) {
                .ok => |was_written| {
                    if (was_written and !quiet) {
                        if (tag_existed) {
                            try stdout.print("updated: {s}\n", .{full_path});
                        } else {
                            try stdout.print("created: {s}\n", .{full_path});
                        }
                    }
                },
                .err => |e| {
                    std.debug.print("error: cannot write global tag index: {s}\n", .{e.context.message});
                },
            }
        }
    }
}

fn pathBelongsToRepo(path: []const u8, repo_roots: []const []const u8) bool {
    const sep = std.fs.path.sep;
    for (repo_roots) |repo| {
        if (std.mem.eql(u8, path, repo)) return true;
        if (path.len > repo.len and std.mem.startsWith(u8, path, repo) and path[repo.len] == sep) {
            return true;
        }
    }
    return false;
}

/// Prune broken entries from a local tag index (art/index).
pub fn pruneLocalTagIndexes(
    allocator: std.mem.Allocator,
    art_path: []const u8,
    stderr: anytype,
) !PruneResult {
    var result: PruneResult = .{};

    const tag_index_path = try std.fs.path.join(allocator, &.{ art_path, "index", "ligi_tags.md" });
    defer allocator.free(tag_index_path);

    if (!fs.fileExists(tag_index_path)) {
        return result;
    }

    const content = switch (fs.readFile(allocator, tag_index_path)) {
        .ok => |c| c,
        .err => return result,
    };
    defer allocator.free(content);

    const tags = parseTagListFromIndex(allocator, content) catch {
        try stderr.print("warning: failed to parse tag index: {s}\n", .{tag_index_path});
        return result;
    };
    defer freeTagList(allocator, tags);

    const tags_dir = try std.fs.path.join(allocator, &.{ art_path, "index", "tags" });
    defer allocator.free(tags_dir);
    std.fs.cwd().makePath(tags_dir) catch {};

    var kept_tags: std.ArrayList([]const u8) = .empty;
    defer kept_tags.deinit(allocator);

    for (tags) |tag| {
        const tag_file_path = try std.fs.path.join(allocator, &.{ art_path, "index", "tags", tag });
        defer allocator.free(tag_file_path);

        const full_path = try std.fmt.allocPrint(allocator, "{s}.md", .{tag_file_path});
        defer allocator.free(full_path);

        const files = readTagIndex(allocator, full_path) catch |err| {
            if (err == error.FileNotFound) {
                result.pruned_tags += 1;
                continue;
            }
            try stderr.print("warning: failed to read tag index: {s}\n", .{full_path});
            result.pruned_tags += 1;
            continue;
        };
        defer allocator.free(files);

        var kept_files: std.ArrayList([]const u8) = .empty;
        defer kept_files.deinit(allocator);

        for (files) |file| {
            const relative = stripArtPrefix(file) orelse {
                allocator.free(file);
                result.pruned_entries += 1;
                continue;
            };

            const full_file_path = try std.fs.path.join(allocator, &.{ art_path, relative });
            defer allocator.free(full_file_path);

            if (!fs.fileExists(full_file_path)) {
                allocator.free(file);
                result.pruned_entries += 1;
                continue;
            }

            try kept_files.append(allocator, file);
        }

        const content_out = try renderPerTagIndex(allocator, tag, kept_files.items);
        defer allocator.free(content_out);

        if (std.fs.path.dirname(full_path)) |parent| {
            std.fs.cwd().makePath(parent) catch {};
        }
        switch (fs.writeFileIfChanged(full_path, content_out, allocator)) {
            .ok => {},
            .err => |e| {
                std.debug.print("error: cannot write tag index: {s}\n", .{e.context.message});
            },
        }

        if (kept_files.items.len > 0) {
            try kept_tags.append(allocator, tag);
        } else {
            result.pruned_tags += 1;
        }

        for (kept_files.items) |file| {
            allocator.free(file);
        }
    }

    const tag_index_content = try renderTagIndexFromTags(allocator, kept_tags.items);
    defer allocator.free(tag_index_content);
    switch (fs.writeFileIfChanged(tag_index_path, tag_index_content, allocator)) {
        .ok => {},
        .err => |e| {
            std.debug.print("error: cannot write tag index: {s}\n", .{e.context.message});
        },
    }

    return result;
}

/// Prune broken entries from a global tag index (~/.ligi/art/index).
pub fn pruneGlobalTagIndexes(
    allocator: std.mem.Allocator,
    global_art_path: []const u8,
    repo_roots: []const []const u8,
    stderr: anytype,
) !PruneResult {
    var result: PruneResult = .{};

    const tag_index_path = try std.fs.path.join(allocator, &.{ global_art_path, "index", "ligi_tags.md" });
    defer allocator.free(tag_index_path);

    if (!fs.fileExists(tag_index_path)) {
        return result;
    }

    const content = switch (fs.readFile(allocator, tag_index_path)) {
        .ok => |c| c,
        .err => return result,
    };
    defer allocator.free(content);

    const tags = parseTagListFromIndex(allocator, content) catch {
        try stderr.print("warning: failed to parse global tag index: {s}\n", .{tag_index_path});
        return result;
    };
    defer freeTagList(allocator, tags);

    const tags_dir = try std.fs.path.join(allocator, &.{ global_art_path, "index", "tags" });
    defer allocator.free(tags_dir);
    std.fs.cwd().makePath(tags_dir) catch {};

    var kept_tags: std.ArrayList([]const u8) = .empty;
    defer kept_tags.deinit(allocator);

    for (tags) |tag| {
        const tag_file_path = try std.fs.path.join(allocator, &.{ global_art_path, "index", "tags", tag });
        defer allocator.free(tag_file_path);

        const full_path = try std.fmt.allocPrint(allocator, "{s}.md", .{tag_file_path});
        defer allocator.free(full_path);

        const files = readTagIndex(allocator, full_path) catch |err| {
            if (err == error.FileNotFound) {
                result.pruned_tags += 1;
                continue;
            }
            try stderr.print("warning: failed to read global tag index: {s}\n", .{full_path});
            result.pruned_tags += 1;
            continue;
        };
        defer allocator.free(files);

        var kept_files: std.ArrayList([]const u8) = .empty;
        defer kept_files.deinit(allocator);

        for (files) |file| {
            if (!std.fs.path.isAbsolute(file)) {
                allocator.free(file);
                result.pruned_entries += 1;
                continue;
            }

            if (!fs.fileExists(file) or !pathBelongsToRepo(file, repo_roots)) {
                allocator.free(file);
                result.pruned_entries += 1;
                continue;
            }

            try kept_files.append(allocator, file);
        }

        const content_out = try renderPerTagIndex(allocator, tag, kept_files.items);
        defer allocator.free(content_out);

        if (std.fs.path.dirname(full_path)) |parent| {
            std.fs.cwd().makePath(parent) catch {};
        }
        switch (fs.writeFileIfChanged(full_path, content_out, allocator)) {
            .ok => {},
            .err => |e| {
                std.debug.print("error: cannot write global tag index: {s}\n", .{e.context.message});
            },
        }

        if (kept_files.items.len > 0) {
            try kept_tags.append(allocator, tag);
        } else {
            result.pruned_tags += 1;
        }

        for (kept_files.items) |file| {
            allocator.free(file);
        }
    }

    const tag_index_content = try renderTagIndexFromTags(allocator, kept_tags.items);
    defer allocator.free(tag_index_content);
    switch (fs.writeFileIfChanged(tag_index_path, tag_index_content, allocator)) {
        .ok => {},
        .err => |e| {
            std.debug.print("error: cannot write global tag index: {s}\n", .{e.context.message});
        },
    }

    return result;
}

/// Rebuild global tag indexes from a list of repo roots.
pub fn rebuildGlobalTagIndexesFromRepos(
    allocator: std.mem.Allocator,
    repos: []const []const u8,
    global_art_path: []const u8,
    update_local: bool,
    follow_symlinks: bool,
    ignore_patterns: []const []const u8,
    stdout: anytype,
    stderr: anytype,
    quiet: bool,
) !RebuildStats {
    var stats: RebuildStats = .{};
    var global_map = TagMap.init(allocator);
    defer global_map.deinit();

    for (repos) |repo_path| {
        if (!fs.dirExists(repo_path)) {
            try stderr.print("warning: repo missing: {s}\n", .{repo_path});
            continue;
        }

        const art_path = try std.fs.path.join(allocator, &.{ repo_path, "art" });
        defer allocator.free(art_path);

        if (!fs.dirExists(art_path)) {
            try stderr.print("warning: art directory missing: {s}\n", .{art_path});
            continue;
        }

        if (!quiet) {
            try stdout.print("indexing: {s}\n", .{repo_path});
        }

        var repo_tag_map = try collectTags(
            allocator,
            art_path,
            null,
            follow_symlinks,
            ignore_patterns,
            stderr,
        );
        defer repo_tag_map.deinit();

        if (update_local) {
            _ = try writeLocalIndexes(allocator, art_path, &repo_tag_map, stdout, quiet);
        }

        var it = repo_tag_map.map.iterator();
        while (it.next()) |entry| {
            const tag = entry.key_ptr.*;
            for (entry.value_ptr.items) |file| {
                const abs_file = try std.fs.path.join(allocator, &.{ repo_path, file });
                defer allocator.free(abs_file);
                try global_map.addFile(tag, abs_file);
            }
        }

        stats.repos_processed += 1;
    }

    stats.tags_written = global_map.map.count();

    var file_count: usize = 0;
    var global_it = global_map.map.iterator();
    while (global_it.next()) |entry| {
        file_count += entry.value_ptr.items.len;
    }
    stats.files_indexed = file_count;

    try writeGlobalIndexesAuthoritative(allocator, &global_map, global_art_path, stdout, quiet);

    return stats;
}

/// Write content to a file, overwriting if it exists.
/// Note: This is not atomic (no temp file + rename). For ligi's use case
/// (regenerating indexes that can be rebuilt), this is acceptable.
fn writeFile(path: []const u8, content: []const u8) !void {
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
            const item = std.mem.trim(u8, trimmed[2..], " \t");
            if (item.len == 0) continue;

            // Handle both formats:
            // New: "- [art/file.md](../../file.md)" -> extract "art/file.md" from label
            // Old: "- art/file.md" -> use as-is
            var path: []const u8 = item;
            if (std.mem.startsWith(u8, item, "[")) {
                // Find closing bracket to extract label
                if (std.mem.indexOf(u8, item, "](")) |bracket_pos| {
                    path = item[1..bracket_pos];
                }
            }

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

test "index --file preserves other tags" {
    const allocator = std.testing.allocator;
    const fixtures = @import("../testing/fixtures.zig");

    var tmp = try fixtures.TempDir.create(allocator);
    defer tmp.cleanup();

    var dir = tmp.dir();
    try dir.makePath("art");

    const writeTestFile = struct {
        fn write(dir_handle: std.fs.Dir, path: []const u8, content: []const u8) !void {
            var file = try dir_handle.createFile(path, .{ .truncate = true });
            defer file.close();
            try file.writeAll(content);
        }
    }.write;

    try writeTestFile(dir, "art/a.md", "[[t/alpha]]\n");
    try writeTestFile(dir, "art/b.md", "[[t/beta]]\n");

    const art_path = try std.fs.path.join(allocator, &.{ tmp.path, "art" });
    defer allocator.free(art_path);

    var tag_map = try collectTags(allocator, art_path, null, false, &.{}, std.io.null_writer);
    defer tag_map.deinit();
    _ = try writeLocalIndexes(allocator, art_path, &tag_map, std.io.null_writer, true);

    // Update a.md and index only that file
    try writeTestFile(dir, "art/a.md", "[[t/gamma]]\n");

    var incremental = try loadTagMapFromIndexes(allocator, art_path, std.io.null_writer);
    defer incremental.deinit();
    try updateTagMapForFile(allocator, &incremental, art_path, "art/a.md", std.io.null_writer);
    _ = try writeLocalIndexes(allocator, art_path, &incremental, std.io.null_writer, true);

    // beta should remain
    const beta_index = try std.fs.path.join(allocator, &.{ art_path, "index", "tags", "beta.md" });
    defer allocator.free(beta_index);
    const beta_files = try readTagIndex(allocator, beta_index);
    defer {
        for (beta_files) |f| allocator.free(f);
        allocator.free(beta_files);
    }
    try std.testing.expectEqual(@as(usize, 1), beta_files.len);
    try std.testing.expectEqualStrings("art/b.md", beta_files[0]);

    // gamma should be added
    const gamma_index = try std.fs.path.join(allocator, &.{ art_path, "index", "tags", "gamma.md" });
    defer allocator.free(gamma_index);
    const gamma_files = try readTagIndex(allocator, gamma_index);
    defer {
        for (gamma_files) |f| allocator.free(f);
        allocator.free(gamma_files);
    }
    try std.testing.expectEqual(@as(usize, 1), gamma_files.len);
    try std.testing.expectEqualStrings("art/a.md", gamma_files[0]);

    // alpha should be empty
    const alpha_index = try std.fs.path.join(allocator, &.{ art_path, "index", "tags", "alpha.md" });
    defer allocator.free(alpha_index);
    const alpha_files = try readTagIndex(allocator, alpha_index);
    defer {
        for (alpha_files) |f| allocator.free(f);
        allocator.free(alpha_files);
    }
    try std.testing.expectEqual(@as(usize, 0), alpha_files.len);
}

test "pruneLocalTagIndexes removes broken entries and tags" {
    const allocator = std.testing.allocator;
    const fixtures = @import("../testing/fixtures.zig");

    var tmp = try fixtures.TempDir.create(allocator);
    defer tmp.cleanup();

    var dir = tmp.dir();
    try dir.makePath("repo/art/index/tags");

    const writeTestFile = struct {
        fn write(dir_handle: std.fs.Dir, path: []const u8, content: []const u8) !void {
            var file = try dir_handle.createFile(path, .{ .truncate = true });
            defer file.close();
            try file.writeAll(content);
        }
    }.write;

    try writeTestFile(dir, "repo/art/a.md", "[[t/alpha]]\n");
    try writeTestFile(dir, "repo/art/b.md", "[[t/beta]]\n");

    const tag_list =
        \\# Ligi Tag Index
        \\
        \\This file is auto-maintained by ligi. Each tag links to its index file.
        \\
        \\## Tags
        \\
        \\- [alpha](tags/alpha.md)
        \\- [beta](tags/beta.md)
        \\- [gamma](tags/gamma.md)
        \\
    ;
    try writeTestFile(dir, "repo/art/index/ligi_tags.md", tag_list);

    const alpha_content = try renderPerTagIndex(allocator, "alpha", &[_][]const u8{
        "art/a.md",
        "art/missing.md",
        "outside.md",
    });
    defer allocator.free(alpha_content);
    try writeTestFile(dir, "repo/art/index/tags/alpha.md", alpha_content);

    const beta_content = try renderPerTagIndex(allocator, "beta", &[_][]const u8{ "art/b.md" });
    defer allocator.free(beta_content);
    try writeTestFile(dir, "repo/art/index/tags/beta.md", beta_content);

    const art_path = try std.fs.path.join(allocator, &.{ tmp.path, "repo", "art" });
    defer allocator.free(art_path);

    const result = try pruneLocalTagIndexes(allocator, art_path, std.io.null_writer);
    try std.testing.expectEqual(@as(usize, 2), result.pruned_entries);
    try std.testing.expectEqual(@as(usize, 1), result.pruned_tags);

    const alpha_index = try std.fs.path.join(allocator, &.{ art_path, "index", "tags", "alpha.md" });
    defer allocator.free(alpha_index);
    const alpha_files = try readTagIndex(allocator, alpha_index);
    defer {
        for (alpha_files) |f| allocator.free(f);
        allocator.free(alpha_files);
    }
    try std.testing.expectEqual(@as(usize, 1), alpha_files.len);
    try std.testing.expectEqualStrings("art/a.md", alpha_files[0]);

    const tag_index_path = try std.fs.path.join(allocator, &.{ art_path, "index", "ligi_tags.md" });
    defer allocator.free(tag_index_path);
    const tag_content = switch (fs.readFile(allocator, tag_index_path)) {
        .ok => |c| c,
        .err => return error.TestExpectedEqual,
    };
    defer allocator.free(tag_content);
    try std.testing.expect(std.mem.indexOf(u8, tag_content, "gamma") == null);
}

test "pruneGlobalTagIndexes removes missing repo entries" {
    const allocator = std.testing.allocator;
    const fixtures = @import("../testing/fixtures.zig");

    var tmp = try fixtures.TempDir.create(allocator);
    defer tmp.cleanup();

    var dir = tmp.dir();
    try dir.makePath("repo1/art");
    try dir.makePath("repo2/art");
    try dir.makePath("global_art/index/tags");

    const writeTestFile = struct {
        fn write(dir_handle: std.fs.Dir, path: []const u8, content: []const u8) !void {
            var file = try dir_handle.createFile(path, .{ .truncate = true });
            defer file.close();
            try file.writeAll(content);
        }
    }.write;

    try writeTestFile(dir, "repo1/art/a.md", "[[t/alpha]]\n");
    try writeTestFile(dir, "repo2/art/b.md", "[[t/beta]]\n");

    const repo1_path = try std.fs.path.join(allocator, &.{ tmp.path, "repo1" });
    defer allocator.free(repo1_path);
    const repo2_path = try std.fs.path.join(allocator, &.{ tmp.path, "repo2" });
    defer allocator.free(repo2_path);
    const global_art_path = try std.fs.path.join(allocator, &.{ tmp.path, "global_art" });
    defer allocator.free(global_art_path);

    const repo1_file = try std.fs.path.join(allocator, &.{ repo1_path, "art", "a.md" });
    defer allocator.free(repo1_file);
    const repo2_file = try std.fs.path.join(allocator, &.{ repo2_path, "art", "b.md" });
    defer allocator.free(repo2_file);

    const tag_list =
        \\# Ligi Tag Index
        \\
        \\This file is auto-maintained by ligi. Each tag links to its index file.
        \\
        \\## Tags
        \\
        \\- [alpha](tags/alpha.md)
        \\- [beta](tags/beta.md)
        \\
    ;
    try writeTestFile(dir, "global_art/index/ligi_tags.md", tag_list);

    const alpha_content = try renderPerTagIndex(allocator, "alpha", &[_][]const u8{
        repo1_file,
        repo2_file,
    });
    defer allocator.free(alpha_content);
    try writeTestFile(dir, "global_art/index/tags/alpha.md", alpha_content);

    const beta_content = try renderPerTagIndex(allocator, "beta", &[_][]const u8{ repo2_file });
    defer allocator.free(beta_content);
    try writeTestFile(dir, "global_art/index/tags/beta.md", beta_content);

    const result = try pruneGlobalTagIndexes(allocator, global_art_path, &.{repo1_path}, std.io.null_writer);
    try std.testing.expectEqual(@as(usize, 2), result.pruned_entries);
    try std.testing.expectEqual(@as(usize, 1), result.pruned_tags);

    const alpha_index = try std.fs.path.join(allocator, &.{ global_art_path, "index", "tags", "alpha.md" });
    defer allocator.free(alpha_index);
    const alpha_files = try readTagIndex(allocator, alpha_index);
    defer {
        for (alpha_files) |f| allocator.free(f);
        allocator.free(alpha_files);
    }
    try std.testing.expectEqual(@as(usize, 1), alpha_files.len);
    try std.testing.expectEqualStrings(repo1_file, alpha_files[0]);

    const tag_index_path = try std.fs.path.join(allocator, &.{ global_art_path, "index", "ligi_tags.md" });
    defer allocator.free(tag_index_path);
    const tag_content = switch (fs.readFile(allocator, tag_index_path)) {
        .ok => |c| c,
        .err => return error.TestExpectedEqual,
    };
    defer allocator.free(tag_content);
    try std.testing.expect(std.mem.indexOf(u8, tag_content, "beta") == null);
}

test "rebuildGlobalTagIndexesFromRepos builds global and local indexes" {
    const allocator = std.testing.allocator;
    const fixtures = @import("../testing/fixtures.zig");

    var tmp = try fixtures.TempDir.create(allocator);
    defer tmp.cleanup();

    var dir = tmp.dir();
    try dir.makePath("repo1/art");
    try dir.makePath("repo2/art");

    const writeTestFile = struct {
        fn write(dir_handle: std.fs.Dir, path: []const u8, content: []const u8) !void {
            var file = try dir_handle.createFile(path, .{ .truncate = true });
            defer file.close();
            try file.writeAll(content);
        }
    }.write;

    try writeTestFile(dir, "repo1/art/a.md", "[[t/alpha]] [[t/shared]]\n");
    try writeTestFile(dir, "repo2/art/b.md", "[[t/beta]] [[t/shared]]\n");

    const repo1_path = try std.fs.path.join(allocator, &.{ tmp.path, "repo1" });
    defer allocator.free(repo1_path);
    const repo2_path = try std.fs.path.join(allocator, &.{ tmp.path, "repo2" });
    defer allocator.free(repo2_path);
    const global_art_path = try std.fs.path.join(allocator, &.{ tmp.path, "global_art" });
    defer allocator.free(global_art_path);

    const stats = try rebuildGlobalTagIndexesFromRepos(
        allocator,
        &.{ repo1_path, repo2_path },
        global_art_path,
        true,
        false,
        &.{},
        std.io.null_writer,
        std.io.null_writer,
        true,
    );

    try std.testing.expectEqual(@as(usize, 2), stats.repos_processed);
    try std.testing.expectEqual(@as(usize, 3), stats.tags_written);
    try std.testing.expectEqual(@as(usize, 4), stats.files_indexed);

    const tag_index_path = try std.fs.path.join(allocator, &.{ global_art_path, "index", "ligi_tags.md" });
    defer allocator.free(tag_index_path);
    const tag_content = switch (fs.readFile(allocator, tag_index_path)) {
        .ok => |c| c,
        .err => return error.TestExpectedEqual,
    };
    defer allocator.free(tag_content);
    try std.testing.expect(std.mem.indexOf(u8, tag_content, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, tag_content, "beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, tag_content, "shared") != null);
    const alpha_pos = std.mem.indexOf(u8, tag_content, "alpha").?;
    const beta_pos = std.mem.indexOf(u8, tag_content, "beta").?;
    const shared_pos = std.mem.indexOf(u8, tag_content, "shared").?;
    try std.testing.expect(alpha_pos < beta_pos);
    try std.testing.expect(beta_pos < shared_pos);

    const shared_path = try std.fs.path.join(allocator, &.{ global_art_path, "index", "tags", "shared.md" });
    defer allocator.free(shared_path);
    const shared_content = switch (fs.readFile(allocator, shared_path)) {
        .ok => |c| c,
        .err => return error.TestExpectedEqual,
    };
    defer allocator.free(shared_content);
    const repo1_file = try std.fs.path.join(allocator, &.{ repo1_path, "art", "a.md" });
    defer allocator.free(repo1_file);
    const repo2_file = try std.fs.path.join(allocator, &.{ repo2_path, "art", "b.md" });
    defer allocator.free(repo2_file);
    try std.testing.expect(std.mem.indexOf(u8, shared_content, repo1_file) != null);
    try std.testing.expect(std.mem.indexOf(u8, shared_content, repo2_file) != null);
    const repo1_pos = std.mem.indexOf(u8, shared_content, repo1_file).?;
    const repo2_pos = std.mem.indexOf(u8, shared_content, repo2_file).?;
    if (std.mem.order(u8, repo1_file, repo2_file) == .lt) {
        try std.testing.expect(repo1_pos < repo2_pos);
    } else {
        try std.testing.expect(repo2_pos < repo1_pos);
    }

    const repo1_local_index = try std.fs.path.join(allocator, &.{ repo1_path, "art", "index", "ligi_tags.md" });
    defer allocator.free(repo1_local_index);
    try std.testing.expect(fs.fileExists(repo1_local_index));
    const repo2_local_index = try std.fs.path.join(allocator, &.{ repo2_path, "art", "index", "ligi_tags.md" });
    defer allocator.free(repo2_local_index);
    try std.testing.expect(fs.fileExists(repo2_local_index));
}

test "rebuildGlobalTagIndexesFromRepos respects no-local" {
    const allocator = std.testing.allocator;
    const fixtures = @import("../testing/fixtures.zig");

    var tmp = try fixtures.TempDir.create(allocator);
    defer tmp.cleanup();

    var dir = tmp.dir();
    try dir.makePath("repo/art");

    const writeTestFile = struct {
        fn write(dir_handle: std.fs.Dir, path: []const u8, content: []const u8) !void {
            var file = try dir_handle.createFile(path, .{ .truncate = true });
            defer file.close();
            try file.writeAll(content);
        }
    }.write;

    try writeTestFile(dir, "repo/art/a.md", "[[t/alpha]]\n");

    const repo_path = try std.fs.path.join(allocator, &.{ tmp.path, "repo" });
    defer allocator.free(repo_path);
    const global_art_path = try std.fs.path.join(allocator, &.{ tmp.path, "global_art" });
    defer allocator.free(global_art_path);

    _ = try rebuildGlobalTagIndexesFromRepos(
        allocator,
        &.{repo_path},
        global_art_path,
        false,
        false,
        &.{},
        std.io.null_writer,
        std.io.null_writer,
        true,
    );

    const repo_local_index = try std.fs.path.join(allocator, &.{ repo_path, "art", "index", "ligi_tags.md" });
    defer allocator.free(repo_local_index);
    try std.testing.expect(!fs.fileExists(repo_local_index));
}

test "renderPerTagIndex: produces links to files" {
    const allocator = std.testing.allocator;
    const files = &[_][]const u8{ "art/z.md", "art/a.md" };

    const output = try renderPerTagIndex(allocator, "mytag", files);
    defer allocator.free(output);

    // Check for link format: - [art/a.md](../../a.md)
    try std.testing.expect(std.mem.indexOf(u8, output, "[art/a.md](../../a.md)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[art/z.md](../../z.md)") != null);
}

test "renderPerTagIndex: handles nested file paths" {
    const allocator = std.testing.allocator;
    const files = &[_][]const u8{"art/deep/nested/file.md"};

    const output = try renderPerTagIndex(allocator, "mytag", files);
    defer allocator.free(output);

    // Check for link format: - [art/deep/nested/file.md](../../deep/nested/file.md)
    try std.testing.expect(std.mem.indexOf(u8, output, "[art/deep/nested/file.md](../../deep/nested/file.md)") != null);
}

test "renderPerTagIndex: handles nested tags" {
    const allocator = std.testing.allocator;
    const files = &[_][]const u8{"art/file.md"};

    // Nested tag like "foo/bar" is stored at art/index/tags/foo/bar.md
    // So path to file needs extra ../
    const output = try renderPerTagIndex(allocator, "foo/bar", files);
    defer allocator.free(output);

    // Should have 3 ../ segments (tags -> index -> art + 1 for foo/)
    try std.testing.expect(std.mem.indexOf(u8, output, "[art/file.md](../../../file.md)") != null);
}

test "fillTagLinks: basic tag filling" {
    const allocator = std.testing.allocator;
    const content = "Some text [[t/alpha]] more text";

    const result = try fillTagLinks(allocator, content, "notes.md");
    defer allocator.free(result.content);

    try std.testing.expectEqual(@as(usize, 1), result.tags_filled);
    try std.testing.expectEqualStrings("Some text [[t/alpha]](index/tags/alpha.md) more text", result.content);
}

test "fillTagLinks: multiple tags" {
    const allocator = std.testing.allocator;
    const content = "[[t/alpha]] and [[t/beta]]";

    const result = try fillTagLinks(allocator, content, "notes.md");
    defer allocator.free(result.content);

    try std.testing.expectEqual(@as(usize, 2), result.tags_filled);
    try std.testing.expectEqualStrings("[[t/alpha]](index/tags/alpha.md) and [[t/beta]](index/tags/beta.md)", result.content);
}

test "fillTagLinks: respects file depth" {
    const allocator = std.testing.allocator;
    const content = "[[t/alpha]]";

    // File is at art/deep/notes.md, so need ../ to reach art/
    const result = try fillTagLinks(allocator, content, "deep/notes.md");
    defer allocator.free(result.content);

    try std.testing.expectEqual(@as(usize, 1), result.tags_filled);
    try std.testing.expectEqualStrings("[[t/alpha]](../index/tags/alpha.md)", result.content);
}

test "fillTagLinks: deeply nested file" {
    const allocator = std.testing.allocator;
    const content = "[[t/alpha]]";

    // File is at art/a/b/c/notes.md
    const result = try fillTagLinks(allocator, content, "a/b/c/notes.md");
    defer allocator.free(result.content);

    try std.testing.expectEqual(@as(usize, 1), result.tags_filled);
    try std.testing.expectEqualStrings("[[t/alpha]](../../../index/tags/alpha.md)", result.content);
}

test "fillTagLinks: skips already linked tags" {
    const allocator = std.testing.allocator;
    const content = "[[t/alpha]](existing/path.md) and [[t/beta]]";

    const result = try fillTagLinks(allocator, content, "notes.md");
    defer allocator.free(result.content);

    // Only beta should be filled, alpha is already linked
    try std.testing.expectEqual(@as(usize, 1), result.tags_filled);
    try std.testing.expectEqualStrings("[[t/alpha]](existing/path.md) and [[t/beta]](index/tags/beta.md)", result.content);
}

test "fillTagLinks: ignores tags in code blocks" {
    const allocator = std.testing.allocator;
    const content =
        \\```
        \\[[t/ignored]]
        \\```
        \\[[t/found]]
    ;

    const result = try fillTagLinks(allocator, content, "notes.md");
    defer allocator.free(result.content);

    try std.testing.expectEqual(@as(usize, 1), result.tags_filled);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "[[t/found]](index/tags/found.md)") != null);
    // The ignored tag should remain unchanged (no link added)
    try std.testing.expect(std.mem.indexOf(u8, result.content, "[[t/ignored]](") == null);
}

test "fillTagLinks: ignores tags in inline code" {
    const allocator = std.testing.allocator;
    const content = "`[[t/ignored]]` [[t/found]]";

    const result = try fillTagLinks(allocator, content, "notes.md");
    defer allocator.free(result.content);

    try std.testing.expectEqual(@as(usize, 1), result.tags_filled);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "[[t/found]](index/tags/found.md)") != null);
}

test "fillTagLinks: no changes returns original content" {
    const allocator = std.testing.allocator;
    const content = "No tags here";

    const result = try fillTagLinks(allocator, content, "notes.md");
    defer allocator.free(result.content);

    try std.testing.expectEqual(@as(usize, 0), result.tags_filled);
    try std.testing.expectEqualStrings("No tags here", result.content);
}

test "fillTagLinks: handles nested tag names" {
    const allocator = std.testing.allocator;
    const content = "[[t/category/subtag]]";

    const result = try fillTagLinks(allocator, content, "notes.md");
    defer allocator.free(result.content);

    try std.testing.expectEqual(@as(usize, 1), result.tags_filled);
    try std.testing.expectEqualStrings("[[t/category/subtag]](index/tags/category/subtag.md)", result.content);
}

test "fillTagLinks: idempotent (running twice produces same result)" {
    const allocator = std.testing.allocator;
    const content = "[[t/alpha]]";

    const result1 = try fillTagLinks(allocator, content, "notes.md");
    defer allocator.free(result1.content);

    const result2 = try fillTagLinks(allocator, result1.content, "notes.md");
    defer allocator.free(result2.content);

    // Second run should fill nothing (already linked)
    try std.testing.expectEqual(@as(usize, 0), result2.tags_filled);
    try std.testing.expectEqualStrings(result1.content, result2.content);
}

test "countPathDepth: counts slashes" {
    try std.testing.expectEqual(@as(usize, 0), countPathDepth("file.md"));
    try std.testing.expectEqual(@as(usize, 1), countPathDepth("dir/file.md"));
    try std.testing.expectEqual(@as(usize, 2), countPathDepth("a/b/file.md"));
    try std.testing.expectEqual(@as(usize, 3), countPathDepth("a/b/c/file.md"));
}
