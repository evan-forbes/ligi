# Ligi Pruning Broken Links Implementation Plan

## Executive Summary

This document defines how `ligi check --prune` (`-p`) removes broken entries from ligi indexes while preserving user files. It covers:
- Global repo index pruning (missing/broken repos)
- Local tag index pruning (missing files, malformed entries)
- Global tag index pruning (missing files, removed repos)

The goal is to keep indexes authoritative without deleting or moving any user content under `art/`.

---

## Part 1: Decisions (Finalized)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Command | `ligi check --prune` (alias `-p`) |
| 2 | Scope | Prune global repo index + local/global tag indexes |
| 3 | Behavior | Remove broken entries; do not delete user files |
| 4 | Local tag pruning | Remove non-existent file paths; remove tags with zero files |
| 5 | Global tag pruning | Remove paths for missing repos; remove missing file paths |
| 6 | Index files | Always rewrite (sorted, deterministic) |
| 7 | Art safety | Do not delete or move any files under `art/` |

---

## Part 2: Definitions

### 2.1 Broken Repo

An entry in `~/.ligi/art/index/ligi_global_index.md` is **broken** if:
- The path does not exist, OR
- The path exists but `<repo>/art/` is missing.

### 2.2 Broken Tag Entry (Local)

An entry in `art/index/tags/<tag>.md` is **broken** if:
- The listed path does not exist on disk, OR
- The listed path is not under `<repo>/art/`.

### 2.3 Broken Tag Entry (Global)

An entry in `~/.ligi/art/index/tags/<tag>.md` is **broken** if:
- The file path does not exist, OR
- The file path is under a repo path that is no longer in the global repo index.

---

## Part 3: CLI Design

### 3.1 Command

```
ligi check --prune
ligi check -p
```

### 3.2 Output

- Default: still print the report (OK/BROKEN/MISSING_ART).
- When pruning, also print a summary:
  - `pruned repos: X`
  - `pruned local tag entries: Y`
  - `pruned global tag entries: Z`
  - `pruned tags: W` (tags removed from tag index)

### 3.3 Exit Codes

- Without `--prune`: current behavior (exit 1 if any broken).
- With `--prune`: return 0 if pruning succeeds, even if initial scan had errors.

---

## Part 4: Global Repo Index Pruning

### 4.1 Inputs

- Global index file: `~/.ligi/art/index/ligi_global_index.md`

### 4.2 Algorithm

1. Load global index entries (absolute repo roots).
2. For each repo:
   - If repo path missing -> mark broken.
   - Else if `<repo>/art/` missing -> mark broken.
3. If `--prune`:
   - Remove broken entries from the global index list.
   - Rewrite the global index file in sorted order.

### 4.3 Notes

- Do not delete any repo directories.
- Keep comments/notes section in the global index file intact if it exists (preserve "## Notes" block).

---

## Part 5: Local Tag Index Pruning

### 5.1 Inputs

- `art/index/ligi_tags.md`
- `art/index/tags/<tag>.md`

### 5.2 Algorithm

For each repo in the global index (or just the current repo if `--root` is specified):

1. Read `art/index/ligi_tags.md`.
2. Parse the tag list.
3. For each tag:
   - Read `art/index/tags/<tag>.md`.
   - Parse the `## Files` list.
   - Remove entries that do not exist on disk.
   - Remove entries that are not under `<repo>/art/`.
   - Rewrite the per-tag file with the filtered list.
4. Recompute the tag list:
   - Keep only tags whose per-tag list is non-empty.
   - Rewrite `art/index/ligi_tags.md` deterministically.

### 5.3 Safety

- Never delete files under `art/`.
- If a per-tag index file is missing, drop it from `ligi_tags.md` (it is broken).

---

## Part 6: Global Tag Index Pruning

### 6.1 Inputs

- `~/.ligi/art/index/ligi_tags.md`
- `~/.ligi/art/index/tags/<tag>.md`

### 6.2 Algorithm

1. Load global repo list (after pruning).
2. Load `~/.ligi/art/index/ligi_tags.md`.
3. For each global tag:
   - Read `~/.ligi/art/index/tags/<tag>.md`.
   - Filter entries:
     - Path must exist on disk.
     - Path must belong to a repo in the global index.
   - Rewrite the per-tag file.
4. Rewrite global tag index to include only tags with non-empty file lists.

---

## Part 7: Data Parsing Rules

- Local per-tag index files are parsed the same way as in `tag_index.readTagIndex`.
- Tag list parsing uses the existing `- [tag](tags/tag.md)` format.
- All output must be sorted for deterministic diffs.

---

## Part 8: Implementation Steps

1. Update CLI registry:
   - Add `-p, --prune` to `ligi check` options.
2. Extend `check` command:
   - Gather results as today.
   - If `--prune`, call pruning pipeline (sections 4-6).
3. Add pruning helpers:
   - `pruneGlobalIndex(...)`
   - `pruneLocalTagIndexes(...)`
   - `pruneGlobalTagIndexes(...)`
4. Add summary reporting for prune.
5. Tests:
   - Unit tests for parsing + pruning.
   - Integration-style test using temporary directories:
     - Broken repo removed from global index.
     - Missing file removed from local/global per-tag index.
     - Tag removed from tag list if empty.

---

## Part 9: Edge Cases

- Dangling symlinks: treat as broken (path does not resolve).
- Mixed path separators: normalize for comparisons when needed.
- Malformed tag index files: skip invalid lines, do not crash.

---

## Part 10: Testing Checklist

- `ligi check --prune` removes broken repo entries.
- Local `ligi_tags.md` drops tags whose per-tag file is missing.
- Per-tag files drop entries that point outside the repo.
- Global per-tag files drop entries from removed repos.
- Output is stable and sorted.
