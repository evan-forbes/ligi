[[t/DONE]]

# Ligi Tagging System Implementation Plan

## Executive Summary

This document specifies how the tagging system works end-to-end, including indexing (`ligi i` / `ligi index`) and querying (`ligi q` / `ligi query`). It defines the tag syntax, file formats, directory layout, parsing rules, and step-by-step implementation tasks. The plan is intentionally detailed so a junior developer can implement it safely and predictably.

---

## Part 1: Decisions (Finalized)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Tag syntax | `[[t/tag_name]]` (wiki-style) |
| 2 | Tag name charset | ASCII letters, digits, `_`, `-`, `.`, and `/` (no spaces) |
| 3 | Local tag index location | `<repo>/art/index/ligi_tags.md` |
| 4 | Per-tag index location (local) | `<repo>/art/index/tags/<tag_path>.md` |
| 5 | Global tag index location | `~/.ligi/art/index/ligi_tags.md` |
| 6 | Per-tag index location (global) | `~/.ligi/art/index/tags/<tag_path>.md` |
| 7 | Indexing strategy | Full rebuild by default (scan all relevant files) |
| 8 | Query strategy | Read per-tag index file; index first if stale or missing |
| 9 | Tag comparisons | Case-sensitive (no normalization) |
| 10 | Index stability | Sorted lexicographically for deterministic output |

---

## Part 2: Tag Syntax and Parsing Rules

### 2.1 Tag Syntax

- A tag is written as a wiki-style token in markdown: `[[t/tag_name]]`.
- `tag_name` is everything after `t/` up to the closing `]]`.
- `tag_name` is case-sensitive.
- Allowed characters in `tag_name`:
  - `A-Z`, `a-z`, `0-9`, `_`, `-`, `.`, `/`
- Any tag containing disallowed characters is ignored and logged as a warning.

### 2.2 Parsing Rules

- Tags inside fenced code blocks (```) are ignored.
- Tags inside inline code spans (single backticks) are ignored.
- Tags inside HTML comments (`<!-- ... -->`) are ignored.
- Tags are detected even if multiple appear on the same line.
- Duplicate tags within the same file are de-duplicated (only one entry per tag per file).

### 2.3 Parser Implementation (Suggested)

Use a lightweight state machine over raw bytes:

- States: `Normal`, `InFencedCode`, `InInlineCode`, `InHtmlComment`.
- Toggle `InFencedCode` when a line starts with ``` (triple backticks).
- Toggle `InInlineCode` when encountering a single backtick in `Normal` state.
- Toggle `InHtmlComment` when encountering `<!--` and exit on `-->`.
- In `Normal`, scan for `[[t/` and capture until `]]`.

#### State Machine Pseudocode

```
state = Normal
pos = 0
tags = empty set

while pos < content.len:
    switch state:
        case Normal:
            if content[pos..].startsWith("```"):
                state = InFencedCode
                pos += 3
            else if content[pos..].startsWith("<!--"):
                state = InHtmlComment
                pos += 4
            else if content[pos] == '`':
                state = InInlineCode
                pos += 1
            else if content[pos..].startsWith("[[t/"):
                pos += 4  # skip "[[t/"
                tag_start = pos
                # scan for closing ]]
                while pos < content.len and not content[pos..].startsWith("]]"):
                    pos += 1
                if pos < content.len:
                    tag_name = content[tag_start..pos]
                    if isValidTagName(tag_name):
                        tags.add(tag_name)
                    else:
                        warn("invalid tag name: {tag_name}")
                    pos += 2  # skip "]]"
            else:
                pos += 1

        case InFencedCode:
            # scan to end of line
            line_start = pos
            while pos < content.len and content[pos] != '\n':
                pos += 1
            # check if this line starts with ```
            if content[line_start..pos].trimStart().startsWith("```"):
                state = Normal
            pos += 1  # skip newline

        case InInlineCode:
            if content[pos] == '`':
                state = Normal
            pos += 1

        case InHtmlComment:
            if content[pos..].startsWith("-->"):
                state = Normal
                pos += 3
            else:
                pos += 1

return tags
```

#### Tag Name Validation

```
fn isValidTagName(name: []const u8) -> bool:
    if name.len == 0:
        return false
    if name contains "..":  # prevent path traversal
        return false
    for c in name:
        if c not in [A-Za-z0-9_\-./]:
            return false
    return true
```

---

## Part 3: Directory Layout

### 3.1 Local (per-repo)

```
<repo>/art/
├── index/
│   ├── ligi_tags.md          # Local tag list
│   └── tags/
│       ├── tag_name.md       # Per-tag index (files in this repo)
│       └── foo/bar.md        # Nested tag path example
```

### 3.2 Global

```
~/.ligi/
└── art/
    └── index/
        ├── ligi_tags.md      # Global tag list
        └── tags/
            ├── tag_name.md   # Per-tag index (files across all repos)
            └── foo/bar.md
```

---

## Part 4: File Formats

### 4.1 Local Tag Index (`art/index/ligi_tags.md`)

```md
# Ligi Tag Index

This file is auto-maintained by ligi. Each tag links to its index file.

## Tags

- [project](tags/project.md)
- [release/notes](tags/release/notes.md)
```

### 4.2 Local Per-Tag Index (`art/index/tags/<tag>.md`)

```md
# Tag: project

This file is auto-maintained by ligi.

## Files

- art/meeting_notes.md
- art/designs/proj_overview.md
```

### 4.3 Global Tag Index (`~/.ligi/art/index/ligi_tags.md`)

Same format as local; tags link to global per-tag index files under `~/.ligi/art/index/tags/`.

### 4.4 Global Per-Tag Index (`~/.ligi/art/index/tags/<tag>.md`)

```md
# Tag: project

This file is auto-maintained by ligi.

## Files

- /abs/path/to/repo1/art/meeting_notes.md
- /abs/path/to/repo2/art/designs/proj_overview.md
```

---

## Part 5: `ligi index` (Indexing Workflow)

### 5.1 CLI Surface

- Canonical: `ligi index`
- Alias: `ligi i`
- Options:
  - `-r, --root <path>`: repo root (default `.`)
  - `-f, --file <path>`: index a single file (optional; if omitted, index all)
  - `-q, --quiet`: suppress non-error output

Note: If `--file` is provided, it must be inside `<root>/art/`.

### 5.2 File Discovery

When indexing all files:

1. Resolve `<root>/art/`.
2. Load config from `<root>/art/config/ligi.toml` (use defaults if missing).
3. Recursively walk the directory.
4. Include files ending in `.md`.
5. Exclude everything under `<root>/art/index/` (index files never index themselves).
6. Apply config ignore patterns (`config.index.ignore_patterns`, default: `["*.tmp", "*.bak"]`).
7. Handle symlinks according to `config.index.follow_symlinks` (default: `false`):
   - If `false`: skip symlinked files and directories entirely.
   - If `true`: follow symlinks but guard against infinite loops (track visited inodes).
8. Skip files that are unreadable (log warning, continue with next file).

### 5.3 Building the Tag Map

- For each markdown file found:
  - Parse tags using the rules in Part 2.
  - For each tag, add the file path to a map: `tag -> set<file_path>`.
- Store paths as repo-relative (e.g. `art/foo.md`).
- De-duplicate file entries per tag using a set, then sort for stable output.

### 5.4 Writing Local Index Files

1. Ensure `<root>/art/index/tags/` exists (create dirs as needed).
2. Write `<root>/art/index/ligi_tags.md`:
   - Header + `## Tags` section
   - Sorted list of tags
   - Link each tag to `tags/<tag_path>.md`
3. For each tag:
   - Ensure subdirectories for `tag_path` exist under `art/index/tags/`
   - Write `art/index/tags/<tag_path>.md` with the list of files

### 5.5 Writing Global Index Files

1. Ensure `~/.ligi/art/index/tags/` exists (create dirs as needed).
2. Load the global tag index file (`~/.ligi/art/index/ligi_tags.md`) or create it if missing.
3. Merge in all tags discovered in this repo:
   - Add new tags if missing (no removal for now).
4. For each tag discovered in this repo:
   - Update the global per-tag index file to include the absolute paths for files in this repo.
   - If the file already exists in the list, keep it once.

### 5.6 Output

- If not `--quiet`, print:
  - summary: number of files scanned, number of unique tags found
  - per-file notifications for any index files created or updated:
    - `created: art/index/ligi_tags.md`
    - `updated: art/index/tags/<tag>.md`
    - `created: ~/.ligi/art/index/tags/<tag>.md`

### 5.7 Error Handling

- If `<root>/art/` does not exist: print error and exit code 1.
- If file is outside `<root>/art/`: print error and exit code 1.
- If a tag contains invalid characters: print warning, skip that tag.

### 5.8 Error and Warning Message Templates

Use these exact message formats for consistency:

**Errors (stderr, exit code 1):**
```
error: art directory not found: <root>/art/
error: file outside art directory: <path> (must be under <root>/art/)
error: cannot create index directory: <path>: <os_error>
error: cannot write index file: <path>: <os_error>
error: global home directory not accessible: ~/.ligi/
```

**Warnings (stderr, continue processing):**
```
warning: invalid tag '<tag_name>' in <file>:<line> - <reason>
warning: cannot read file: <path>: <os_error>
warning: skipping symlink (follow_symlinks=false): <path>
```

Where `<reason>` is one of:
- `empty tag name`
- `contains invalid character '<char>'`
- `contains path traversal (..)`

**Info (stdout, unless --quiet):**
```
indexed <N> files, found <M> unique tags
created: <path>
updated: <path>
```

---

## Part 6: `ligi query` (Query Workflow)

### 6.1 CLI Surface

- Canonical: `ligi query`
- Alias: `ligi q`
- Tag query subcommand or shorthand:
  - `ligi q t <tag>` (alias for `ligi query tag <tag>`)
- Options:
  - `-r, --root <path>`: repo root (default `.`)
  - `-a, --absolute`: output absolute paths (default false)
  - `-o, --output <text|json>`: output format (default from config)
  - `-c, --clipboard`: copy output to system clipboard (default false)
  - `--index <true|false>`: enable/disable auto-indexing (default true)

Note: Clipboard functionality reuses the existing `src/template/clipboard.zig` module.

### 6.2 Auto-Index (When Query Triggers Indexing)

Query should automatically run `ligi index` logic if any of the following are true (unless `--index false` is set):

- Local tag index file missing (`art/index/ligi_tags.md`).
- The specific tag index file missing (`art/index/tags/<tag>.md`).
- Any markdown file in `<root>/art/` (excluding `art/index/`) has an mtime newer than the tag index file.

If auto-indexing creates or updates any index files, it must print the same per-file notifications as `ligi index` (unless `--quiet` is set).

### 6.3 Query Evaluation

Single tag:

1. Ensure index is present and fresh (Section 6.2).
2. Read `art/index/tags/<tag>.md`.
3. Parse the `## Files` list into a set of paths.
4. Output those paths.

Multiple tags with operators:

- Support `&` (AND) and `|` (OR):
  - Example: `ligi q t tag1 \& tag2` (shell-escaped)
  - Example: `ligi q t tag1 \| tag2`
- Parse into tokens and evaluate left-to-right:
  - Start with the first tag’s set.
  - For `&`, intersect with next tag’s set.
  - For `|`, union with next tag’s set.

### 6.4 Output Formats

Text output (default):

```
art/file_1.md
art/file_2.md
```

JSON output:

```json
{"tag":"project","results":["art/file_1.md","art/file_2.md"]}
```

If `-a, --absolute` is set, convert each repo-relative path to an absolute path using the resolved `--root`.

---

## Part 7: Concrete Tasks and Checklists

This section lists implementation tasks in concrete, actionable units. Each task includes a checklist and the properties that must be validated by tests.

### 7.1 Core Tag Parsing (new `src/core/tag_index.zig`)

Tasks:
- Implement tag name validation (allowed charset and non-empty).
- Implement parser state machine (normal, fenced code, inline code, HTML comment).
- Provide `parseTagsFromContent` that returns unique tags in a file.
- Add helper to normalize tag paths to file paths (`tags/<tag_path>.md`).

Checklist:
- [ ] Parser ignores fenced code blocks.
- [ ] Parser ignores inline code spans.
- [ ] Parser ignores HTML comments.
- [ ] Parser detects multiple tags on a single line.
- [ ] Parser de-duplicates tags within a file.
- [ ] Parser rejects invalid tag names with a warning.

Tests (unit):
- **Property:** Tags are found in plain text.
- **Property:** No tags extracted from fenced code or inline code.
- **Property:** Invalid tags are rejected.
- **Property:** Duplicate tags in the same file return a single tag.

### 7.2 Tag Map Collection (new `tag_index.collectTags`)

Tasks:
- Implement recursive walk under `<root>/art/`.
- Filter to `.md` files only.
- Exclude `art/index/` subtree.
- Apply ignore patterns from config (`index.ignore_patterns`).
- Build map: `tag -> set<repo-relative path>`.

Checklist:
- [ ] Files in `art/index/` are excluded.
- [ ] Ignore patterns skip matching files.
- [ ] All paths are stored as repo-relative `art/...`.
- [ ] Tag map keys are stable-sorted before rendering.

Tests (unit/integration):
- **Property:** Files under `art/index/` are never indexed.
- **Property:** Ignore patterns remove expected files.
- **Property:** Map contains correct tag->files associations.

### 7.3 Local Index Rendering (new `tag_index.writeLocalIndexes`)

Tasks:
- Ensure `art/index/tags/` directory exists.
- Write `art/index/ligi_tags.md` with sorted tag list.
- Write per-tag index file with sorted file paths.
- Overwrite files on each run (full rebuild).

Checklist:
- [ ] `art/index/ligi_tags.md` always reflects current tags.
- [ ] Each tag has a `tags/<tag_path>.md` file.
- [ ] Tag list and file lists are sorted lexicographically.

Tests (unit/integration):
- **Property:** `ligi_tags.md` includes all tags and correct links.
- **Property:** Per-tag file contains correct file list.
- **Property:** Output is deterministic across repeated runs.

### 7.4 Global Index Update (new `tag_index.updateGlobalIndexes`)

Tasks:
- Ensure `~/.ligi/art/index/tags/` directory exists.
- Create `~/.ligi/art/index/ligi_tags.md` if missing.
- Merge new tags from current repo (no deletions).
- Update per-tag global index files with absolute paths for this repo.

Checklist:
- [ ] Global tag list grows when new tags appear.
- [ ] Global per-tag index includes absolute paths from current repo.
- [ ] Duplicate entries are not added.

Tests (integration):
- **Property:** New tags appear in global index after indexing.
- **Property:** Global per-tag index includes absolute path to file.
- **Property:** Re-running index does not duplicate entries.

### 7.5 `ligi index` Command (`src/cli/commands/index.zig`)

Tasks:
- Add CLI args: `--root`, `--file`, `--quiet`.
- Validate `--file` resides under `<root>/art/`.
- Load config for `ignore_patterns` and `follow_symlinks`.
- Handle existing `art/index/ligi_tags.md` (created by `ligi init`) - update, don't error.
- Call tag map collection and local/global index writers.
- Use atomic writes (write to temp file, then rename).
- Print summary (unless `--quiet`).
- Return non-zero on errors.

Checklist:
- [ ] `ligi i` aliases `ligi index`.
- [ ] `--file` indexes only the given file.
- [ ] Errors are printed to stderr with exit code 1.
- [ ] Created/updated index files are reported unless `--quiet`.
- [ ] Existing `art/index/ligi_tags.md` is updated correctly.
- [ ] Symlinks are handled according to config.
- [ ] Unreadable files produce warnings, not errors.

Tests (integration/smoke):
- **Property:** `ligi index` creates local index files.
- **Property:** `ligi index --file` only touches tags from that file.
- **Property:** Invalid `--file` path errors and exits 1.
- **Property:** Pre-existing `ligi_tags.md` is updated without error.

### 7.6 `ligi query` Command (`src/cli/commands/query.zig`)

Tasks:
- Add CLI args: `t`/`tag` subcommand, `--root`, `--absolute`, `--output`, `--clipboard`, `--index`.
- Implement staleness check logic.
- Read per-tag index file and parse file list.
- Implement `&` and `|` operators with left-to-right evaluation.
- Support text and JSON output.
- Implement clipboard copy using `template.clipboard.copyToClipboard()`.

Checklist:
- [ ] Query triggers indexing when indexes are missing or stale.
- [ ] `--absolute` prints absolute paths.
- [ ] JSON output matches documented format.
- [ ] `--clipboard` copies output to system clipboard.
- [ ] Auto-indexing reports created/updated index files unless quiet.
- [ ] `--index false` skips auto-indexing even if stale.

Tests (integration/smoke):
- **Property:** Query returns correct files for a tag.
- **Property:** AND and OR operators produce correct set intersections/unions.
- **Property:** `--absolute` outputs absolute paths.
- **Property:** `--clipboard` copies result to clipboard (text and JSON).
- **Property:** Missing/stale index triggers auto-indexing.
- **Property:** Auto-indexing emits created/updated file notifications.
- **Property:** `--index false` skips auto-indexing and uses existing indexes.

### 7.7 Help Text and Registry Updates

Tasks:
- Update command descriptions if needed.
- Add new options to CLI registry and help output.

Checklist:
- [ ] `ligi --help` includes updated flags for index/query.
- [ ] `ligi index --help` and `ligi query --help` reflect new options.

Tests (smoke):
- **Property:** Help output includes new options.

---

## Part 8: Implementation Steps (Code Map)

### 7.1 New / Updated Files

- `src/cli/commands/index.zig`
  - Replace stub with full indexing implementation.
- `src/cli/commands/query.zig`
  - Replace stub with tag query implementation.
- `src/core/tag_index.zig` (new)
  - Tag parsing
  - Tag map builder
  - Tag index rendering/parsing helpers
- `src/core/mod.zig`
  - Export `tag_index` module.

### 7.2 Suggested Core APIs

- `tag_index.parseTagsFromContent(content: []const u8) -> []Tag`
- `tag_index.collectTags(root_art_path: []const u8, file_filter: ?[]const u8) -> TagMap`
- `tag_index.writeLocalIndexes(root_art_path: []const u8, tag_map: TagMap)`
- `tag_index.updateGlobalIndexes(tag_map: TagMap, root_path: []const u8)`
- `tag_index.isIndexStale(root_art_path: []const u8, tag_index_path: []const u8) -> bool`
- `tag_index.readTagIndex(tag_index_path: []const u8) -> []Path`

### 7.3 Integration with Existing Config

- Use `core.config` to read `index.ignore_patterns`.
- Optionally extend `LigiConfig.IndexConfig` with `ignore_dirs` later (not required).

---

## Part 9: Edge Cases

### 9.1 Tag Parsing Edge Cases

- **Tag includes `/`**: create subdirectories under `art/index/tags/`.
- **Duplicate tags in one file**: index only once.
- **Invalid tag name**: warn and ignore.
- **Empty tag name `[[t/]]`**: reject with warning "empty tag name".
- **Path traversal `[[t/../secret]]` or `[[t/foo/../bar]]`**: reject with warning "contains path traversal (..)".
- **Very long tag names (>255 chars)**: reject with warning (filesystem path length limit).
- **Tag with only invalid chars `[[t/!!!]]`**: reject with specific invalid character warning.
- **Unclosed tag `[[t/foo`**: ignore (no closing `]]` found).
- **Nested brackets `[[t/foo[[bar]]]]`**: first `]]` closes the tag, yields tag `foo[[bar`.

### 9.2 File System Edge Cases

- **File removed since last index**: full rebuild clears it from local index; global indexes are kept authoritative via `ligi check --prune` or `ligi index --global` (see [Pruning Broken Links Plan](impl_pruning_broken_links.md) and [Global Rebuild Tag Indexes Plan](impl_global_rebuild_tag_indexes.md)).
- **Empty tag index**: keep `## Tags` with empty list.
- **Symlinks**: respect `config.index.follow_symlinks` (default false = skip).
- **Symlink loops**: if following symlinks, track visited inodes to prevent infinite recursion.
- **Unreadable files**: warn and skip, don't fail entire index.
- **Binary files with `.md` extension**: parser handles gracefully (likely finds no valid tags).
- **Empty `.md` files**: no tags found, no error.
- **Files with BOM**: parser should handle UTF-8 BOM prefix (skip first 3 bytes if present).

### 9.3 Concurrent Access Edge Cases

- **Multiple `ligi index` processes**: use atomic writes (write to temp file, then rename) to prevent corruption.
- **Index file locked/in-use**: retry once, then fail with error.

### 9.4 Global Index Edge Cases

- **`$HOME` not set**: use fallback or error with clear message.
- **`~/.ligi/` doesn't exist**: create it (and all parent dirs).
- **`~/.ligi/` is read-only**: error with clear message.
- **Same file indexed from different repo paths**: global index stores absolute paths, so these are distinct entries.

### 9.5 Query Edge Cases

- **Tag not found**: return empty result (not an error), exit code 0.
- **Index file corrupted/malformed**: error with message, suggest re-running `ligi index`.
- **Query with empty operator `tag1 & & tag2`**: parse error, reject query.

---

## Part 10: Testing Plan (Detailed)

This section lists concrete tests by type and the exact properties they validate.

### 10.1 Unit Tests (fast, pure logic)

Target files:
- `src/core/tag_index.zig`

Tests and properties:
- **Tag parsing: basic detection**
  - Property: `parseTagsFromContent` returns `["alpha"]` for `[[t/alpha]]` in plain text.
- **Tag parsing: multiple tags**
  - Property: `[[t/a]] ... [[t/b]]` returns two tags.
- **Tag parsing: duplicates**
  - Property: `[[t/a]] [[t/a]]` returns one tag.
- **Tag parsing: invalid charset**
  - Property: `[[t/invalid tag]]` yields no tag and emits warning.
- **Tag parsing: fenced code**
  - Property: tags inside ``` fences are ignored.
- **Tag parsing: inline code**
  - Property: tags inside backticks are ignored.
- **Tag parsing: HTML comments**
  - Property: tags inside `<!-- -->` are ignored.
- **Tag parsing: empty tag name**
  - Property: `[[t/]]` yields no tag and emits warning.
- **Tag parsing: path traversal**
  - Property: `[[t/../secret]]` yields no tag and emits warning.
- **Tag parsing: unclosed tag**
  - Property: `[[t/foo` with no closing `]]` yields no tag.
- **Tag parsing: UTF-8 BOM**
  - Property: file starting with BOM parses correctly.
- **Tag name validation: length limit**
  - Property: tag name >255 chars is rejected.
- **Index rendering: local tag list**
  - Property: output contains sorted tags and correct `tags/<path>.md` links.
- **Index rendering: per-tag file**
  - Property: output contains sorted file paths.

### 10.2 Integration Tests (filesystem, temp dirs)

Target files:
- `src/cli/commands/index.zig`
- `src/cli/commands/query.zig`

Tests and properties:
- **Index all files**
  - Property: running `ligi index` creates `art/index/ligi_tags.md` and per-tag files from multiple markdown sources.
- **Index excludes index directory**
  - Property: tags in `art/index/*.md` do not appear in indexes.
- **Index single file**
  - Property: `ligi index --file art/a.md` only includes tags from that file.
- **Global index update**
  - Property: global tag list and per-tag files include absolute paths for the repo.
- **Query single tag**
  - Property: `ligi q t tag` returns expected file list.
- **Query AND/OR**
  - Property: `tag1 & tag2` returns intersection; `tag1 | tag2` returns union.
- **Query absolute**
  - Property: `--absolute` outputs absolute paths.
- **Query clipboard**
  - Property: `--clipboard` copies output to system clipboard.
- **Query non-existent tag**
  - Property: returns empty result, exit code 0.
- **Auto-index on staleness**
  - Property: touching a markdown file triggers indexing before query.
- **Index notifications**
  - Property: indexing prints created/updated index files (unless quiet).
- **Index flag**
  - Property: `--index false` prevents auto-indexing even when stale.
- **Symlink handling**
  - Property: symlinks skipped when `follow_symlinks=false`.
- **Unreadable file**
  - Property: warns and skips unreadable files, continues indexing.
- **Existing ligi_tags.md**
  - Property: indexer updates existing file without error.

### 10.3 Smoke Tests (CLI-level, `scripts/smoke_test.sh`)

Add or extend tests in `scripts/smoke_test.sh`:

- **Help output**
  - Property: `ligi index --help` and `ligi query --help` show new options.
- **Index workflow**
  - Property: `ligi index` creates local tag index in a temp repo and reports created files.
- **Query workflow**
  - Property: `ligi q t tag` returns expected output.

### 10.4 Test Data Fixtures

- Use temp directories created by existing test harnesses (`src/testing/fixtures.zig`).
- Create minimal markdown fixtures in `art/` with known tags:
  - `art/a.md` includes `[[t/alpha]]`
  - `art/b.md` includes `[[t/alpha]] [[t/beta]]`
  - `art/index/ignore.md` includes `[[t/ignored]]` (must be excluded)
  - `art/nested/c.md` includes `[[t/nested/deep]]` (tests nested tag paths)
  - `art/edge_cases.md` includes:
    - `[[t/]]` (empty tag - should warn)
    - `[[t/../traversal]]` (path traversal - should warn)
    - `` `[[t/in_code]]` `` (inline code - should ignore)
    - fenced code block with `[[t/in_fence]]` (should ignore)
  - `art/empty.md` (empty file - should produce no tags)
  - Symlink `art/link.md -> art/a.md` (tests symlink handling)

---

## Part 11: Implementation Order (Recommended)

1. Implement tag parser + unit tests in `src/core/tag_index.zig`.
2. Implement local indexing (scan files, build map, write local tag index files).
3. Implement `ligi index` command and CLI options.
4. Implement tag query logic, including staleness checks for auto-indexing.
5. Implement global tag index update.
6. Add integration tests in Zig (temp dirs) for index/query behavior.
7. Add smoke tests in `scripts/smoke_test.sh` for CLI flows.

---

## Part 12: Integration with Existing Codebase

This section maps plan components to existing ligi modules and patterns.

### 12.1 Existing Modules to Use

| Module | Location | Use For |
|--------|----------|---------|
| `core.fs` | `src/core/fs.zig` | `ensureDirRecursive()`, `readFile()`, `fileExists()`, `dirExists()` |
| `core.paths` | `src/core/paths.zig` | `getGlobalArtPath()`, `getLocalArtPath()`, `joinPath()`, `SPECIAL_DIRS` |
| `core.errors` | `src/core/errors.zig` | `Result(T)` union type, `LigiError.filesystem()`, `LigiError.usage()` |
| `core.config` | `src/core/config.zig` | `loadConfig()` for `index.ignore_patterns`, `index.follow_symlinks` |
| `core.global_index` | `src/core/global_index.zig` | Reference for markdown index file format patterns |
| `template.clipboard` | `src/template/clipboard.zig` | `copyToClipboard()` for query `-c` flag |
| `testing` | `src/testing/mod.zig` | `TempDir` fixture for integration tests |

### 12.2 Error Handling Pattern

All fallible operations should return `core.errors.Result(T)` instead of Zig errors:

```zig
const core = @import("../../core/mod.zig");
const Result = core.errors.Result;
const LigiError = core.errors.LigiError;

pub fn parseTagsFromFile(path: []const u8) Result([]Tag) {
    const content = core.fs.readFile(allocator, path) catch |err| {
        return .{ .err = LigiError.filesystem(
            "cannot read file",
            // ... error context
        ) };
    };
    // ...
    return .{ .ok = tags };
}
```

### 12.3 Memory Management Pattern

Use `ArenaAllocator` for operations that build temporary data structures:

```zig
pub fn runIndex(allocator: std.mem.Allocator, args: anytype, ...) !u8 {
    // Arena for all indexing allocations - freed at end of function
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Build tag map using arena (no individual frees needed)
    var tag_map = std.StringHashMap(std.ArrayList([]const u8)).init(arena_alloc);

    // Collect tags from all files
    const files = try discoverFiles(arena_alloc, root_path);
    for (files) |file| {
        const tags = try parseTagsFromContent(arena_alloc, content);
        for (tags) |tag| {
            const entry = try tag_map.getOrPut(tag);
            if (!entry.found_existing) {
                entry.value_ptr.* = std.ArrayList([]const u8).init(arena_alloc);
            }
            try entry.value_ptr.append(file);
        }
    }

    // Write indexes (arena still valid)
    try writeLocalIndexes(arena_alloc, root_path, tag_map);

    return 0;
    // arena.deinit() called here - all memory freed at once
}
```

### 12.4 Command Registration

The command stubs already exist in `src/cli/registry.zig`. The params are already defined:

```zig
// In registry.zig - already exists
const IndexParams = clap.parseParamsComptime(
    \\-h, --help         Show this help message
    \\-r, --root <str>   Repository root directory
    \\-f, --file <str>   Index single file only
    \\-q, --quiet        Suppress non-error output
    \\
);
```

Wire up the command handler:

```zig
// In registry.zig run() function
else if (std.mem.eql(u8, cmd.canonical, "index")) {
    return runIndexCommand(allocator, remaining_args, global_args.quiet != 0, stdout, stderr);
}
```

### 12.5 Existing File Created by `init`

Note: `ligi init` already creates `art/index/ligi_tags.md` with this content:

```markdown
# Ligi Tag Index

This file is auto-maintained by ligi. Each tag links to its index file.

## Tags

```

The indexer should **update** this file (not error on existing). Check if file exists and preserve any manual notes users may have added below the `## Tags` section.

### 12.6 Config Schema Reference

The config already defines these relevant fields in `src/core/config.zig`:

```zig
pub const IndexConfig = struct {
    ignore_patterns: []const []const u8 = &.{ "*.tmp", "*.bak" },
    follow_symlinks: bool = false,
};

pub const QueryConfig = struct {
    default_format: OutputFormat = .text,
    colors: bool = true,
};
```

Use `core.config.loadConfig()` to read these values.

### 12.7 Global Index Coexistence

The global `~/.ligi/art/index/` directory will contain:
- `ligi_global_index.md` - repo list (existing, from `global_index.zig`)
- `ligi_tags.md` - global tag list (new, from this feature)
- `tags/` - per-tag index files (new, from this feature)

These coexist without conflict.
