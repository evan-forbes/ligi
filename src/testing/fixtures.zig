//! Test fixtures and utilities.

const std = @import("std");

/// A temporary directory for testing that cleans up automatically.
pub const TempDir = struct {
    tmp_dir: std.testing.TmpDir,
    path: []const u8,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator) !TempDir {
        var tmp_dir = std.testing.tmpDir(.{});
        const path = try tmp_dir.dir.realpathAlloc(allocator, ".");
        return .{
            .tmp_dir = tmp_dir,
            .path = path,
            .allocator = allocator,
        };
    }

    pub fn cleanup(self: *TempDir) void {
        self.allocator.free(self.path);
        self.tmp_dir.cleanup();
    }

    pub fn dir(self: *TempDir) std.fs.Dir {
        return self.tmp_dir.dir;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "TempDir creates and cleans up" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.create(allocator);
    defer tmp.cleanup();

    // Verify path exists
    try std.testing.expect(tmp.path.len > 0);
}
