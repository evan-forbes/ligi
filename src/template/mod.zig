//! Template module root - re-exports template functionality.
//!
//! Provides template filling with interactive prompts from TOML frontmatter.

pub const parser = @import("parser.zig");
pub const prompter = @import("prompter.zig");
pub const engine = @import("engine.zig");
pub const clipboard = @import("clipboard.zig");

// Re-export commonly used types
pub const Template = parser.Template;
pub const TemplateField = parser.TemplateField;
pub const ParseError = parser.ParseError;
pub const EngineContext = engine.EngineContext;

test {
    _ = parser;
    _ = prompter;
    _ = engine;
    _ = clipboard;
}
