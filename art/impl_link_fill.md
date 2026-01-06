[[t/TODO]](index/tags/TODO.md) [[t/partial]](index/tags/partial.md)

# Ligi Link Filling Implementation Plan

## Status

| Feature | Status |
|---------|--------|
| `[[t/tag_name]]` tag links | ✅ Complete |
| `[[Title of Note]]` exact title links | ❌ Not started |
| `[[f/search query]]` fuzzy links | ❌ Not started |

## Executive Summary

This document specifies the "Link Filling" feature for the `ligi index` command. The goal is to automatically convert high-level, human-readable wiki-style links into standard, working Markdown relative links. This improves the portability of the notes (they work in any Markdown viewer) while maintaining the ease of writing provided by Ligi.

## Goals

1.  **Auto-resolution**: Convert `[[t/tag]]`, `[[Title]]`, and `[[f/Fuzzy Search]]` into standard `[Label](path/to/file.md)` links.
2.  **Standardization**: Ensure the output is standard Markdown, usable by GitHub, VS Code, Obsidian, etc.
3.  **Performance**: Perform replacements efficiently during the indexing phase.
4.  **Safety**: Only modify files when a link is successfully resolved. Warn on ambiguity or failure.

## 1. Syntax and Resolution Rules

The system scans for tokens enclosed in double square brackets `[[...]]`. It attempts to resolve them to a file path relative to the current file.

### 1.1 Tag Links: `[[t/tag_name]]`
*   **Input**: `[[t/project-alpha]]`
*   **Resolution**: Look up `project-alpha` in the Tag Index.
*   **Target**: The specific index file for that tag: `art/index/tags/project-alpha.md`.
*   **Output**: `[[t/project-alpha]](../index/tags/project-alpha.md)` (path is relative to the source file).
*   **Note**: The label retains the `t/` prefix and a set of brackets so that it renders as `[t/project-alpha]` in standard Markdown viewers.
*   **Constraint**: If the tag index doesn't exist yet, it should be created or the link remains (or warns). Since `ligi index` creates tags, we can assume the path *will* exist.

### 1.2 Exact Title Links: `[[Title of Note]]`
*   **Input**: `[[Meeting Notes 2023]]`
*   **Resolution**: Look for a file named `Meeting Notes 2023.md` anywhere in the `art/` directory.
*   **Target**: `art/meetings/Meeting Notes 2023.md`.
*   **Output**: `[Meeting Notes 2023](../meetings/Meeting Notes 2023.md)`.
*   **Ambiguity**: If multiple files have the same name (e.g., `art/a/Note.md` and `art/b/Note.md`), warn the user and do not replace.

### 1.3 Fuzzy/Search Links: `[[f/search query]]`
*   **Input**: `[[f/architecture diagram]]`
*   **Resolution**: Perform a fuzzy search or "smart match" against all filenames in `art/`.
    *   Prioritize exact substring matches.
    *   Prioritize files where the query matches the "stem" (filename without extension).
*   **Target**: The best matching file, e.g., `art/docs/system_architecture_diagram.md`.
*   **Output**: `[system_architecture_diagram](../docs/system_architecture_diagram.md)` (uses the found filename as label) OR `[architecture diagram](../docs/system_architecture_diagram.md)` (preserves query as label).
    *   *Decision*: Preserve the query as the label for context: `[architecture diagram](../docs/system_architecture_diagram.md)`.
*   **Threshold**: If no match exceeds a confidence threshold, or if there are multiple equally good matches, warn and do not replace.

## 2. Integration with `ligi index`

Link filling happens **during** the `ligi index` process.

1.  **Phase 1: Discovery**
    *   Scan all files to build the file map (Path -> FileInfo) and Tag Map.
    *   This is already done by the existing/planned `tag_index.collectTags`.
    *   *New*: Also build a `FilenameIndex` (Filename -> List<Path>) to speed up Title resolution.

2.  **Phase 2: Processing (The "Fill" Pass)**
    *   Iterate through all markdown files in `art/`.
    *   Read content.
    *   Scan for `[[...]]` tokens.
    *   For each token:
        *   Analyze type (`t/`, `f/`, or implicit title).
        *   Attempt to resolve to a target path.
        *   If resolved: Calculate relative path from source file to target file.
        *   Construct replacement string.
    *   If changes were made:
        *   Write updated content back to disk (atomic write).
        *   Log: `filled: [[...]] -> [Label](path)`

## 3. Implementation Details

### 3.1 Data Structures

```zig
const FileIndex = struct {
    // fast lookup for exact filename matching
    by_name: std.StringHashMap([]const u8), 
    // list of all paths for fuzzy search
    all_paths: std.ArrayList([]const u8),
};
```

### 3.2 Resolution Logic

```zig
fn resolveLink(
    allocator: std.mem.Allocator, 
    source_path: []const u8, 
    link_text: []const u8, 
    file_index: *FileIndex
) !?[]const u8 {
    if (std.mem.startsWith(u8, link_text, "t/")) {
        // Tag resolution
        const tag_name = link_text[2..];
        // Construct path to art/index/tags/<tag_name>.md relative to source_path
        return resolveTagPath(source_path, tag_name);
    } else if (std.mem.startsWith(u8, link_text, "f/")) {
        // Fuzzy resolution
        const query = link_text[2..];
        return findFuzzyMatch(file_index, query);
    } else {
        // Exact Title resolution
        return file_index.by_name.get(link_text);
    }
}
```

### 3.3 Safety & Configuration

*   **Idempotency**: The system must not mangle already converted links. Since `[...](...)` is different from `[[...]]`, this is naturally handled.
*   **Confirmation**: By default, `ligi index` is non-interactive. We assume "Fill" is a desired side-effect of "Index" per the prompt. 
    *   *Future*: Add `--dry-run` to see what would change without writing.

## 4. Work Breakdown

1.  **Extend `src/core/mod.zig` (or new module `src/core/link_resolver.zig`)**:
    *   Implement `FileIndex` structure.
    *   Implement `resolveLink` logic.
    *   Implement `findFuzzyMatch` (simple substring/levenshtein).

2.  **Update `src/cli/commands/index.zig`**:
    *   After the initial tag collection (Phase 1), trigger Phase 2.
    *   Ensure the `FileIndex` is populated before processing.

3.  **Testing**:
    *   Unit tests for `resolveLink` (mocking the file index).
    *   Integration test: Create a file with `[[t/foo]]` and `[[ExistingDoc]]`, run `ligi i`, verify file content is updated.

## 5. Example Transformations

| Source File | Content | Target File | Result |
| :--- | :--- | :--- | :--- |
| `art/notes.md` | `See [[t/design]]` | `art/index/tags/design.md` | `See [[t/design]](../index/tags/design.md)` |
| `art/notes.md` | `Ref [[Architecture]]` | `art/docs/Architecture.md` | `Ref [Architecture](../docs/Architecture.md)` |
| `art/deep/a.md` | `[[f/arch]]` | `art/docs/Architecture.md` | `[arch](../../docs/Architecture.md)` |
