feature_name = "helix_ligi_integration"
feature_description = "Integrate ligi with the Helix editor to provide auto-completion for tags and files using the Language Server Protocol (LSP)."
cli_surface = "ligi lsp"

# Document

# Implementation Plan: helix_ligi_integration

## Executive Summary

This plan proposes implementing a lightweight Language Server Protocol (LSP) server within the `ligi` CLI (`ligi lsp`). This server will provide auto-completion capabilities to the Helix editor (and other LSP-compatible editors). It will intercept completion triggers like `[[` and `[[t/` to suggest file links and tags respectively, querying the existing `ligi` index. It also includes a small Helix fork change to make Tab behavior work with this completion flow per `art/info_how_to_modify_tab_auto_complete.md` in the Helix fork.

---

## Part 1: Motivation

### Problem Statement

Users writing in `ligi`-managed markdown repositories currently have no assistance when linking to other files or tagging content. They must manually memorize or look up filenames and tags, leading to friction and potential broken links.

### User Story

As a content creator using Helix, I want auto-completion when I type `[[` so that I can easily link to other notes, and when I type `[[t/` so that I can select from existing tags, ensuring my knowledge graph remains connected and consistent.

---

## Part 2: Design Decisions

| # | Decision | Choice | Alternatives Considered | Rationale |
|---|----------|--------|------------------------|-----------|
| 1 | Integration Method | LSP (Language Server Protocol) | Helix Fork / Plugins | LSP is the standard, future-proof way to integrate with Helix and allows reuse with VSCode, Neovim, etc. Modifying a Helix fork is high-maintenance. |
| 2 | Communication | Stdio (Standard Input/Output) | TCP/Sockets | Stdio is the simplest and most common method for single-client language servers started by the editor. |
| 3 | Protocol Scope | `textDocument/completion` only (initially) | Full LSP | Focusing only on completion solves the immediate user need without the overhead of a full semantic analysis server. |
| 4 | Data Source | `GlobalIndex` & `TagIndex` (Read-only) | Live Parsing | Re-using the existing index loaded in memory is fast and consistent with CLI operations. |

---

## Part 3: Specification

### Behavior Summary

`ligi lsp` will start a long-running process that listens for JSON-RPC 2.0 messages on stdin and responds on stdout.

- **Command**: `ligi lsp`
- **Input**: JSON-RPC messages (specifically `initialize`, `textDocument/completion`, `shutdown`, `exit`, plus `textDocument/didOpen` / `textDocument/didChange` to keep a live buffer).
- **Output**: JSON-RPC responses containing completion items.
- **Side effects**: None (read-only access to file system/index).

### Data Structures

**LSP Types (Minimal Subset)**:

```zig
// Simplified Zig structs representing LSP types
const InitializeParams = struct {
    rootUri: ?[]const u8,
    // ... other fields
};

const CompletionParams = struct {
    textDocument: TextDocumentIdentifier,
    position: Position,
    context: ?CompletionContext,
};

const CompletionItem = struct {
    label: []const u8,
    kind: ?CompletionItemKind, // 17 = File, 18 = Reference
    detail: ?[]const u8,
    insertText: ?[]const u8,
    textEdit: ?TextEdit, // use a range to replace the typed prefix reliably
};
```

**Data Flow (Mermaid)**:

```mermaid
flowchart LR
    A[Helix] -->|JSON-RPC Request| B[ligi lsp (Stdin)]
    B -->|Parse| C[LSP Router]
    C -->|Completion Request| D[Completion Handler]
    D -->|Query| E[GlobalIndex / TagIndex]
    E -->|Results| D
    D -->|JSON-RPC Response| B
    B -->|Stdout| A
```

### Error Messages

- `error: failed to start lsp: <system error>`
- JSON-RPC Error codes for protocol violations.

---

## Part 4: Implementation

### New/Modified Files

| File | Purpose |
|------|---------|
| `src/cli/commands/lsp.zig` | Implementation of the `ligi lsp` command and main loop. |
| `src/lsp/mod.zig` | Module definition for LSP logic. |
| `src/lsp/server.zig` | JSON-RPC handling and message dispatch. |
| `src/lsp/protocol.zig` | Definitions of LSP types (Request, Response, CompletionItem, etc.). |
| `src/cli/mod.zig` | Register the new command. |
| `../helix-editor/helix/...` | Small Helix fork change to Tab/completion behavior (see “Helix Fork Changes”). |

### Existing Touchpoints

| Touchpoint | Why It Matters |
|------------|----------------|
| `src/core/global_index.zig` | Source of truth for file paths (wikilinks). |
| `src/core/tag_index.zig` | Source of truth for existing tags. |
| `src/cli/commands/mod.zig` | Registration point for new commands. |

### Implementation Steps

#### Step 1: Scaffold LSP Command and Types

Define the basic structure for the `lsp` command and the necessary Zig structs to deserialize/serialize LSP JSON.

**File(s)**: `src/cli/commands/lsp.zig`, `src/lsp/protocol.zig`, `src/lsp/mod.zig`

**Tasks**:
- Create `src/lsp/` directory.
- Define `InitializeParams`, `CompletionParams`, `CompletionItem` structs in `protocol.zig` using `std.json`.
- Implement `run` function in `src/cli/commands/lsp.zig` that reads **Content-Length framed** messages (no line-based parsing).

**Checklist**:
- [ ] `ligi lsp` compiles and runs.
- [ ] Can parse a basic `initialize` request from stdin using Content-Length framing.

#### Step 2: Implement JSON-RPC Loop

Implement the main event loop that reads the `Content-Length` header, reads the body, parses the JSON, and delegates to a handler.

**File(s)**: `src/lsp/server.zig`

**Tasks**:
- Implement a buffered reader for stdin.
- Logic to parse HTTP-like headers (LSP uses `Content-Length: ...\r\n\r\n`).
- Dispatcher switch on `method` name (accept `id` as string or int).
- Handle `initialize` (return capabilities: `completionProvider: { triggerCharacters: ["[", "/"] }` and `textDocumentSync: { openClose: true, change: Full }`) and `shutdown`.
- Log to **stderr only** to avoid corrupting stdout JSON-RPC.

#### Step 3: Implement Completion Logic

Connect the `textDocument/completion` handler to `ligi`'s indices.

**File(s)**: `src/lsp/server.zig`

**Tasks**:
- Track open buffers via `didOpen`/`didChange` (Full sync for v1), and use the in-memory text to inspect the prefix before the cursor.
- In the `completion` handler:
    - Detect prefix within the current line (e.g. `[[` or `[[t/`).
    - If prefix is `[[t/` (or starts with it):
        - Load `TagIndex`.
        - Return list of tags as `CompletionItem`s with a `textEdit` replacing the typed suffix (avoid duplicate `t/`).
    - If prefix is `[[` (and not `t/`):
        - Load `GlobalIndex`.
        - Return list of known files as `CompletionItem`s with `textEdit` replacing the typed suffix.
- Use `std.json.stringify` to send the response and ensure UTF-8.

#### Step 4: Helix Configuration Guide

Document how to configure Helix to use this.

**File(s)**: `README.md` (or specific doc in `art/`)

**Tasks**:
- Add a section explaining how to add `ligi` to `languages.toml`.

#### Step 5: Helix Fork Changes (Tab / completion behavior)

Based on `helix/art/info_how_to_modify_tab_auto_complete.md`, Helix does **not** trigger completion on Tab by default; Tab runs `smart_tab` and only navigates the completion menu if it’s already open. To make Tab act as an ergonomic entry point for completions in Markdown:

**Modify Helix (fork):**
- `helix-term/src/commands.rs`: update `smart_tab` to call the `completion` command when:
  - the language is Markdown, **and**
  - there is a `[[`/`[[t/` prefix immediately before the cursor, **and**
  - there is no snippet tabstop or indentation action to perform.
- `helix-term/src/keymap/default.rs`: keep Tab bound to `smart_tab` (no keymap remap needed), since the logic above will trigger completions when appropriate.
- (Optional) `helix-term/src/handlers/completion.rs`: if you want auto-popup on `/`, ensure the LSP trigger characters include `[` and `/` (already in Step 2) so the menu reopens after typing `/`.

**Why this is needed:** Helix’s docs explicitly state that completion menu keybindings aren’t remappable; Tab does not open completion by itself. The minimal change is therefore in `smart_tab` rather than in the menu keymap.

### Integration with Existing Code

- **GlobalIndex**: Will be instantiated read-only within the LSP process.
- **Config**: Will use standard `ligi.toml` loading to know where the root is, with `rootUri` (or `workspaceFolders`) decoded to a filesystem path.

---

## Part 5: Known Limitations & Non-Goals

### Known Limitations

- **Single Root**: Will likely assume the CWD is the root of the knowledge base, or rely on `rootUri` from `initialize`.
- **Performance**: Re-scanning indices on every request might be slow for huge repos; caching strategies may be needed later (but `ligi` is fast, so maybe fine).

### Non-Goals

- **Go to Definition**: Not in V1 (though desirable later).
- **Diagnostics**: No linting for broken links in V1.
- **Renaming**: No refactoring support in V1.

---

## Part 6: Edge Cases

### Input Edge Cases

| Case | Input | Expected Behavior |
|------|-------|-------------------|
| Malformed JSON | `Content-Length: 5\r\n\r\n{abc` | Log error, ignore, or send ParseError response. |
| Unknown Method | `textDocument/didOpen` | Ignore gracefully (log warning). |
| Empty Index | `[[` in new repo | Return empty list (no crash). |
| Non-ASCII paths | `rootUri` contains percent-encoding | Decode to a valid filesystem path before indexing. |

### System Edge Cases

| Case | Condition | Expected Behavior |
|------|-----------|-------------------|
| Stdin Closed | Parent process exits | Terminate `ligi lsp` process immediately. |

---

## Part 7: Testing

### Testing Strategy

Use integration tests where we simulate an editor sending JSON-RPC messages to the `ligi lsp` stdin and assert on the stdout.

### Unit Tests

| Test | Property Verified |
|------|-------------------|
| `test_lsp_deserialize` | Can parse standard LSP JSON messages. |
| `test_lsp_completion_tags` | Returns correct tag list given a mocked index. |
| `test_lsp_textedit_ranges` | Completion replaces only the typed prefix (`[[` / `[[t/`). |

### Smoke Tests

```bash
test_helix_ligi_integration() {
    # Start ligi lsp in background or pipe input to it
    # Send initialize request
    # Send completion request
    # Verify output contains expected JSON
    echo "PASS: test_helix_ligi_integration"
}
```

---

## Part 8: Acceptance Criteria

- [ ] `ligi lsp` command exists.
- [ ] Helix can successfully attach to `ligi lsp` when opening a markdown file in a ligi repo.
- [ ] Typing `[[` in Helix shows a popup with file list.
- [ ] Typing `[[t/` in Helix shows a popup with tag list.
- [ ] Selecting an item inserts it correctly.

---

## Part 9: Examples

**Helix `languages.toml`**:

```toml
[[language]]
name = "markdown"
language-servers = [ "ligi-lsp" ]

[language-server.ligi-lsp]
command = "ligi"
args = ["lsp"]
```

**LSP Interaction**:

Input:
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "textDocument/completion",
  "params": { ... "context": { "triggerCharacter": "[" } ... }
}
```

Output:
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": [
    { "label": "founding_idea", "kind": 17 },
    { "label": "impl_init", "kind": 17 }
  ]
}
```

---

## Appendix A: Open Questions

- [ ] Does Helix support multiple LSPs for Markdown (e.g. `marksman` + `ligi`)? (Yes, it does via the `language-servers` array).

## Appendix B: Future Considerations

- **Go to Definition**: Implement `textDocument/definition` to jump to the file or tag definition.
- **Hover**: Show file preview or tag stats on hover.

## Appendix C: Implementation Order

1.  LSP Protocol Types definitions.
2.  Basic Server Loop (stdin/stdout).
3.  Integration with `GlobalIndex`.
4.  Integration with `TagIndex`.
5.  Integration testing.
