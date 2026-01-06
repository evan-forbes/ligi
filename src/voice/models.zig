//! Model metadata for whisper.cpp models.

const std = @import("std");

pub const upstream_tag = "v1.8.2";

pub const base_url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main";

pub const ModelSize = enum {
    tiny,
    base,
    small,
    medium,
    large,
    tiny_en,
    base_en,
    small_en,
    medium_en,
};

pub const ModelEntry = struct {
    size: ModelSize,
    filename: []const u8,
    english_only: bool,
};

pub const model_entries = [_]ModelEntry{
    .{ .size = .tiny, .filename = "ggml-tiny.bin", .english_only = false },
    .{ .size = .tiny_en, .filename = "ggml-tiny.en.bin", .english_only = true },
    .{ .size = .base, .filename = "ggml-base.bin", .english_only = false },
    .{ .size = .base_en, .filename = "ggml-base.en.bin", .english_only = true },
    .{ .size = .small, .filename = "ggml-small.bin", .english_only = false },
    .{ .size = .small_en, .filename = "ggml-small.en.bin", .english_only = true },
    .{ .size = .medium, .filename = "ggml-medium.bin", .english_only = false },
    .{ .size = .medium_en, .filename = "ggml-medium.en.bin", .english_only = true },
    .{ .size = .large, .filename = "ggml-large-v3.bin", .english_only = false },
};

pub fn parseModelSize(value: []const u8) ?ModelSize {
    if (std.mem.eql(u8, value, "tiny")) return .tiny;
    if (std.mem.eql(u8, value, "base")) return .base;
    if (std.mem.eql(u8, value, "small")) return .small;
    if (std.mem.eql(u8, value, "medium")) return .medium;
    if (std.mem.eql(u8, value, "large")) return .large;
    if (std.mem.eql(u8, value, "tiny.en")) return .tiny_en;
    if (std.mem.eql(u8, value, "base.en")) return .base_en;
    if (std.mem.eql(u8, value, "small.en")) return .small_en;
    if (std.mem.eql(u8, value, "medium.en")) return .medium_en;
    return null;
}

pub fn entryFor(size: ModelSize) ModelEntry {
    for (model_entries) |entry| {
        if (entry.size == size) return entry;
    }
    unreachable;
}

pub fn sizeToString(size: ModelSize) []const u8 {
    return switch (size) {
        .tiny => "tiny",
        .base => "base",
        .small => "small",
        .medium => "medium",
        .large => "large",
        .tiny_en => "tiny.en",
        .base_en => "base.en",
        .small_en => "small.en",
        .medium_en => "medium.en",
    };
}

pub fn isEnglishOnly(size: ModelSize) bool {
    return entryFor(size).english_only;
}

// ============================================================================
// Tests
// ============================================================================

test "parseModelSize recognizes sizes" {
    try std.testing.expect(parseModelSize("tiny") == .tiny);
    try std.testing.expect(parseModelSize("base.en") == .base_en);
    try std.testing.expect(parseModelSize("unknown") == null);
}
