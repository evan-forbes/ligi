//! Integration test entrypoint.

test {
    _ = @import("serve.zig");
    _ = @import("pdf.zig");
}
