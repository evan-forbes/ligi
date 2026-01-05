# Ligi Global Rebuild Tag Indexes Implementation Plan

## Executive Summary

This document specifies a full rebuild of global tag indexes under `~/.ligi/art/index/`, using all repos listed in the global index. The rebuild produces authoritative tag lists and per-tag files, and can optionally refresh each repo's local tag indexes.

---

## Part 1: Decisions (Finalized)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Command | `ligi index --global` |
| 2 | Strategy | Full rebuild from source files (scan `art/`) |
| 3 | Local indexes | Rebuild local tag indexes by default |
| 4 | Output | Deterministic sorted output |
| 5 | Missing repos | Skip with warning |
| 6 | Authoritative | Global indexes are rewritten from scratch |

---

## Part 2: Command Behavior

### 2.1 Usage

```
ligi index --global
```

Optional flags:
- `-q, --quiet` (existing)
- `--no-local` (new): do not touch local tag indexes

### 2.2 Output

- Print per-repo progress unless `--quiet`.
- Print totals:
  - `repos processed: N`
  - `tags written: M`
  - `files indexed: K`

---

## Part 3: Inputs and Outputs

### 3.1 Inputs

- Global repo index: `~/.ligi/art/index/ligi_global_index.md`
- Repo art trees: `<repo>/art/**.md`

### 3.2 Outputs

Global:
```
~/.ligi/art/index/ligi_tags.md
~/.ligi/art/index/tags/<tag>.md
```

Local (default):
```
<repo>/art/index/ligi_tags.md
<repo>/art/index/tags/<tag>.md
```

---

## Part 4: Algorithm (High Level)

1. Load global repo list.
2. For each repo:
   - Validate that repo and `<repo>/art/` exist.
   - Scan all `art/**/*.md` (excluding `art/index/`).
   - Parse tags using the standard tag parser.
   - Build a local `TagMap`.
   - (Optional) Write local tag indexes.
   - Merge into global `TagMap` using absolute paths.
3. Write global tag index files based on the global `TagMap`.

---

## Part 5: Detailed Steps

### 5.1 Load Global Repo List

- Parse `ligi_global_index.md` under `~/.ligi/art/index/`.
- Ignore invalid lines.
- Preserve order only for logging; global indexes must be sorted.

### 5.2 For Each Repo

1. Resolve repo root and `<repo>/art/`.
2. If missing, log warning and continue.
3. Use `tag_index.collectTags(...)` to build a `TagMap`.
4. If `--no-local` is not set:
   - Write local indexes (`writeLocalIndexes`).
5. Merge into global `TagMap`:
   - Convert `art/...` to absolute paths.
   - Deduplicate (global map should not contain duplicates).

### 5.3 Write Global Indexes

1. For each tag:
   - Write `~/.ligi/art/index/tags/<tag>.md` with all absolute file paths.
2. Write `~/.ligi/art/index/ligi_tags.md`:
   - Only include tags that have at least one file.
   - Sorted lexicographically.

---

## Part 6: Data Structures

### 6.1 Global TagMap

Reuse `TagMap` to map:
```
tag -> list of absolute file paths
```

### 6.2 Deduplication

Ensure `TagMap.addFile(...)` checks for duplicates to keep output clean.

---

## Part 7: Changes Required

1. Add `--global` and `--no-local` flags to `ligi index`.
2. Add a global rebuild code path:
   - Load global index file.
   - Loop all repos and build a global `TagMap`.
3. Add a new writer:
   - `writeGlobalIndexesAuthoritative(tag_map)`
   - Writes from scratch, no append/merge.

---

## Part 8: Error Handling

- Missing repo: warn and continue.
- Missing art dir: warn and continue.
- Parse errors: warn and continue; do not abort global rebuild.

---

## Part 9: Performance Notes

- Use existing ignore patterns and symlink settings from config.
- Avoid reading any file twice when possible.
- Global rebuild is I/O bound; no need for parallelism in v1.

---

## Part 10: Testing Checklist

1. Rebuild writes global tags from multiple repos.
2. Rebuild omits missing repos.
3. Global tag index is sorted and deterministic.
4. Local indexes are updated unless `--no-local` is set.
5. No duplicate paths in per-tag files.
