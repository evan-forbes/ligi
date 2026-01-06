//! Minimal LSP protocol structures for ligi completions.

pub const Position = struct {
    line: usize,
    character: usize,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const TextEdit = struct {
    range: Range,
    newText: []const u8,
};

pub const CompletionItem = struct {
    label: []const u8,
    kind: ?u8 = null,
    detail: ?[]const u8 = null,
    insertText: ?[]const u8 = null,
    textEdit: ?TextEdit = null,
};

pub const CompletionOptions = struct {
    triggerCharacters: []const []const u8,
};

pub const TextDocumentSyncKind = enum(u8) { none = 0, full = 1, incremental = 2 };

pub const TextDocumentSyncOptions = struct {
    openClose: bool,
    change: TextDocumentSyncKind,
};

pub const ServerCapabilities = struct {
    completionProvider: ?CompletionOptions = null,
    textDocumentSync: ?TextDocumentSyncOptions = null,
};

pub const InitializeResult = struct {
    capabilities: ServerCapabilities,
};
