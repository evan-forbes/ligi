//! Testing utilities module.

pub const fixtures = @import("fixtures.zig");
pub const assertions = @import("assertions.zig");

pub const TempDir = fixtures.TempDir;
pub const assertDirExists = assertions.assertDirExists;
pub const assertFileExists = assertions.assertFileExists;
pub const assertFileContains = assertions.assertFileContains;
