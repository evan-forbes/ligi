# Helix completion ("tab autocomplete") report

This report documents how Helix completion works today (including the role of Tab), and what needs to change to support:

- Markdown link completion for local files.
- Custom Markdown pattern completion (e.g., `[[t/` for tags).
- An AI-based completion provider.

All references below point to the current codebase.

## 1) What "tab autocomplete" means in Helix today

**Tab does *not* trigger completion by default.** In Insert mode, `tab` runs `smart_tab`, which either inserts indentation, moves to a snippet tabstop, or does a tree-sitter parent node movement. Completion is triggered automatically (on a timer) or manually via `C-x`. Tab only *navigates* the completion menu when it is already open.

Key facts and locations:

- **Insert-mode keymap:** `tab` → `smart_tab`, `C-x` → `completion`, `S-tab` → `insert_tab`. See `helix-term/src/keymap/default.rs`. The command table also documents this in `book/src/generated/static-cmd.md`.
- **`smart_tab` behavior:** implemented in `helix-term/src/commands.rs` (`smart_tab` function). It checks whitespace and either inserts a tab, moves to snippet tabstop, or `move_parent_node_end`.
- **Completion menu navigation:** `Tab`/`Shift-Tab` move selection inside the completion popup menu, `Enter` accepts, `Esc`/`Ctrl-C` cancels. See `helix-term/src/ui/menu.rs`.
- **Supertab interaction:** if `editor.smart_tab.supersede_menu = true`, the completion menu ignores Tab so `smart_tab` can be used even with a completion popup open (`helix-term/src/ui/menu.rs`, `helix-view/src/editor.rs`).

**Implication:** if you want Tab to *trigger* completion, you must either remap keys (e.g., bind `tab` to the `completion` command) or modify `smart_tab` to call the completion command when not indenting.

## 2) Current completion flow (exact path)

### 2.1 Triggering a completion

Triggers are handled in `helix-term/src/handlers/completion.rs`:

- `trigger_auto_completion(editor, trigger_char_only)` decides when to request completions.
- **Trigger sources:**
  - **Trigger characters** from LSP server capabilities (if the cursor text ends with any `CompletionOptions.trigger_characters`).
  - **Path trigger** when the last typed character is `/` (or `\` on Windows) *and* path completion is enabled.
  - **Auto trigger** when the last `editor.completion_trigger_len` characters are `char_is_word` (word chars).

These trigger paths emit a `CompletionEvent` sent to the completion handler (see `helix-view/src/handlers/completion.rs`).

### 2.2 Debounce and request scheduling

`helix-term/src/handlers/completion/request.rs` owns debouncing and the request pipeline:

- `CompletionHandler` tracks an active trigger and debounces auto-triggered requests.
- Manual triggers (`C-x`) are sent immediately.
- Auto triggers wait for `editor.completion_timeout` (default 250ms) before request dispatch.

### 2.3 Completion sources (providers)

Completion items currently come from **three** sources only (no tree-sitter provider):

1. **LSP** (Language Server Protocol)
   - Requested in `request_completions_from_language_server`.
   - Only servers that support the **Completion** feature are used.
   - Uses `CompletionContext` with appropriate `trigger_kind`.
   - Items are sorted by `sort_text` or `label`.

2. **Path completion**
   - Implemented in `helix-term/src/handlers/completion/path.rs`.
   - Uses `helix-stdx/src/path.rs` (`get_path_suffix`) to detect path-like text just before the cursor.
   - Lists files and directories in the resolved path and generates `CompletionItem::Other` transactions.

3. **Word completion**
   - Implemented in `helix-term/src/handlers/completion/word.rs`.
   - Uses a word index built from open buffers (`helix-view/src/handlers/word_index.rs`).
   - Triggered only when the typed word reaches `word_completion.trigger_length`.

The enum `CompletionProvider` is defined in `helix-core/src/completion.rs` and currently only includes `Lsp`, `Path`, and `Word`.

### 2.4 Merging and displaying results

`request_completions` (in `helix-term/src/handlers/completion/request.rs`) collects results from all providers:

- Results are merged into a single list for the UI.
- A `ResponseContext` (priority, savepoint, incomplete flag) is recorded per provider.
- The UI uses `helix-term/src/ui/completion.rs` to render the menu and optional doc popup.

### 2.5 Applying / previewing completions

`helix-term/src/ui/completion.rs` handles preview and acceptance:

- **Preview insert** (`editor.preview_completion_insert = true`) uses a ghost transaction and savepoints so LSP sync isn’t broken.
- **Acceptance** is via `Enter` (PromptEvent::Validate). It restores the savepoint, applies the transaction, inserts snippets if needed, and applies any LSP additional edits.
- It may immediately retrigger completion after apply (useful for chained completions).

### 2.6 Filtering behavior while typing

When a completion menu is open:

- Each character typed updates the completion filter (`update_completion_filter` in `helix-term/src/handlers/completion.rs`).
- If a non-word character is typed, the completion popup is cleared and a new trigger is attempted.
- This is why `[[t/` (with `/`) will *clear* an open completion list unless there is a trigger character that immediately reopens it.

## 3) What to change to support the requested features

### 3.1 Markdown link completion (local files)

**Best path: use an LSP server.** Helix already consults LSP completion if the server supports the Completion feature and its trigger characters. You can:

- Add/replace the Markdown language server in `languages.toml` (or user config).
- Implement a custom Markdown LSP that offers `textDocument/completion` for link targets (e.g., `](` or `[[` link syntax).
- Configure LSP trigger characters to include `[` or `(` so completions show up without manual `C-x`.

If you want a built-in (non-LSP) integration, the minimal change is:

1. **Add a new provider**
   - Extend `CompletionProvider` in `helix-core/src/completion.rs` (e.g., `MarkdownLink`).

2. **Add a new request in the completion pipeline**
   - In `helix-term/src/handlers/completion/request.rs`, call a new `markdown_link_completion(...)` alongside `path_completion` and `word::completion`.
   - Have it return `CompletionItems::Other` with `CompletionItem::Other(helix_core::CompletionItem)` entries, built using `Transaction::change_by_selection` (see `path.rs` and `word.rs`).

3. **Detect link context**
   - Use tree-sitter to detect that the cursor is inside a Markdown link destination, or do a simpler text-based detection.
   - The tree-sitter grammar for Markdown already exists (`runtime/grammars` and `languages.toml`). There is no completion logic that uses tree-sitter today, so you need to add this yourself.

4. **Collect local markdown files**
   - Use workspace roots and the filesystem to find `.md` files.
   - You can reuse `doc.path()` and project roots (see `languages.toml` roots or file picker logic) to resolve relative paths.

5. **Trigger**
   - Add a trigger character in `trigger_auto_completion` for `[` or `(` *or* rely on manual `C-x` completion.
   - Alternatively, detect patterns in `trigger_auto_completion` and call `CompletionEvent::TriggerChar` for Markdown links (e.g., `text.ends_with("]("))`).

**Low-effort alternative:** extend existing `path_completion` to allow markdown-specific pattern triggers and filtering to `.md` files. It already parses path-like suffixes (`get_path_suffix`). But it currently triggers only on `/` (or manual completion), so you’d still need to add a Markdown-specific trigger.

### 3.2 Custom Markdown integration for patterns like `[[t/` → tag completions

There are two viable approaches.

**A) Custom LSP server (recommended for flexibility)**

- Implement a Markdown LSP that recognizes `[[t/` and returns tag completions.
- Set trigger characters to `[` and `/` so Helix will request completions as soon as the pattern appears.
- Helix will treat the results as normal LSP items, so you’ll automatically get snippets, docs, and additional edits.

**B) Add a built-in provider**

- Add a new provider in `CompletionProvider` and a corresponding request in `request_completions`.
- Use tree-sitter to detect that the cursor is inside a tag context (`[[...]]`), and then return a list of tag completions.
- For each completion, construct a `Transaction` that replaces just the typed suffix (e.g., `t/` or `[[t/` depending on how you want it applied).

**Important behavior to account for:**

- Typing `/` is a non-word character, so the completion filter is cleared unless your provider is retriggered. (`update_completion_filter` in `helix-term/src/handlers/completion.rs`).
- To keep the menu active on `/`, you either:
  - Make `/` a trigger character (LSP or custom trigger), or
  - Change `update_completion_filter` logic to allow specific non-word characters for specific providers.

### 3.3 AI completion provider (local or remote)

Helix has no built-in AI completion provider. You have two options:

**A) AI as an LSP server**

- Implement an LSP server that provides completions from your AI model.
- Add it to `languages.toml` and ensure it supports Completion.
- Helix already handles LSP completion items, snippets, and additional edits.

**B) Native provider**

- Add a new `CompletionProvider` (e.g., `Ai`) and a new request in `request_completions` that:
  - Calls your model (local or remote) asynchronously.
  - Converts its result into `CompletionItems::Other` with `Transaction`s.

**Notes about the current pipeline:**

- The completion pipeline uses `JoinSet` and assumes discrete, finite completion results.
- There is no streaming UI for partial updates. If you want streaming, you must extend `CompletionResponse` and menu update logic.
- Completion items are filtered by fuzzy match of their label (`ui/completion.rs`). You can encode a compact label and put the full suggestion in the inserted text.

## 4) Suggested modification map (minimal change list)

If you plan to implement built-in Markdown or AI completions, these are the main files to touch:

- `helix-core/src/completion.rs`
  - Add a new `CompletionProvider` variant.

- `helix-term/src/handlers/completion/request.rs`
  - Add a new completion request function and include it in `request_completions`.

- `helix-term/src/handlers/completion/item.rs`
  - No structural change needed, but ensure `provider_priority` or sorting behavior is adjusted if you want AI to appear above/below LSP/path/word.

- `helix-term/src/handlers/completion.rs`
  - Add trigger logic for new patterns if you want auto popup for `[[`/`(` or tag patterns.
  - Consider allowing non-word characters in `update_completion_filter` for specific providers.

- `helix-term/src/ui/completion.rs`
  - Usually no change, unless you want special rendering for AI items or custom docs.

- `languages.toml` or user config
  - Register any new Markdown LSP or additional server needed for completions.

## 5) Quick decision guide

- **If you just want link + tag completion with no Helix core changes:** build a custom Markdown LSP and add it to `languages.toml`.
- **If you want full local behavior without an LSP:** add a new internal provider and integrate it into `request_completions`.
- **If you want AI completions:** LSP is the fastest path; native provider requires changes in completion plumbing and possibly UI if you want streaming.

---

If you want, I can turn this report into a concrete implementation plan or start wiring up a Markdown link/tag provider directly in the code.
