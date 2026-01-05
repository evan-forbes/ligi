# Ligi Global Index Implementation Plan

## Executive Summary

This document defines the global index that lives under `~/.ligi/art/` and records only one datum per entry: the absolute path to a repo root that has been initialized with `ligi`. All structure is implied (`<repo>/art/...`). The global index must support fast existence checks and integrity validation via `ligi check`.

---

## Part 1: Decisions (Finalized)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Global index file name | `~/.ligi/art/index/ligi_global_index.md` |
| 2 | Data model | One entry = absolute repo root path |
| 3 | Format | Plain Markdown list (no quasi-YAML) |
| 4 | Update trigger | Always on `ligi init` (local) |
| 5 | Integrity check | `ligi check` validates entries and reports broken paths |
| 6 | Idempotency | No duplicates; update in-place |

---

## Part 2: Global Index Structure

### 2.1 File Location

```
~/.ligi/
└── art/
    └── index/
        └── ligi_global_index.md
```

### 2.2 Markdown Format

Only absolute repo roots are stored. All other paths are derived.

```md
# Ligi Global Index

This file is auto-maintained by ligi. It tracks all repositories initialized with ligi.

## Repositories

- /abs/path/to/repo
- /abs/path/to/other

## Notes

(Freeform, not parsed by ligi)
```

---

## Part 3: Update Rules

### 3.1 When `ligi init` runs in a repo

- Resolve repo root (default `.` or `--root`).
- Canonicalize the path: resolve `.`/`..` and follow symlinks to their real path. If a symlink is dangling, use the literal path and let `ligi check` catch it later.
- Ensure `~/.ligi/art/index/` directory and `ligi_global_index.md` file exist (create if missing).
- Upsert the repo root path in the list:
  - If present, leave as-is.
  - If missing, append under “## Repositories”.

### 3.2 When `ligi init --global` runs

- Ensure `~/.ligi/art/index/` directory and `ligi_global_index.md` file exist (create if missing).
- No repo entry is added because no local repo root is provided.

---

## Part 4: Integrity Checks (`ligi check`)

`ligi check` validates global index entries and all local markdown links by default. Its goal is that if it reports no broken links, then every link resolves to an existing document.

Default behavior:
- Validate every repo listed in the global index.
- For each repo, scan all markdown files under `<repo>/art/`.
- For each standard Markdown link (`[text](target)`), verify the target exists.
- For each tag (`[[t/tag_name]]`), verify the tag exists in:
  - The local tag index: `<repo>/art/index/ligi_tags.md`
  - The global tag index: `~/.ligi/art/index/ligi_tags.md`

Tag notes:
- Tags are the only supported wiki-style link syntax.
- Non-tag wiki links remain out of scope to preserve Markdown compatibility.

Output:
- Pretty-printed report grouped by status:
  - **OK**: path exists + `art/` exists
  - **BROKEN**: repo path missing
  - **MISSING_ART**: repo exists but `art/` missing

Example output:
```
OK:          /home/evan/projects/ligi
OK:          /home/evan/projects/other
MISSING_ART: /home/evan/old/legacy-project
BROKEN:      /home/evan/deleted/gone
```

Flags:
- `-o` / `--output json` emits machine-readable output (use this instead of `--json`).
- `-r` / `--root` limits scope to a specific root. Defaults to `*` (all known repos). Use `-r ~/.ligi` to check only the global index file.

---

## Part 5: Parsing Strategy

Parsing is line-based and minimal:
- Find “## Repositories”.
- Read all list items (`- ` prefix) until next header.
- Trim whitespace; ignore empty lines.
- Preserve any unknown sections and `## Notes` verbatim.

---

## Part 6: Implementation Sketch (Zig)

1. Ensure the global index file exists.
2. Read file contents.
3. Parse list items into a set of paths.
4. Add the current repo root if missing.
5. Render file:
   - Header
   - "## Repositories"
   - Sorted list of absolute paths (lexicographic, ascending)
   - Preserve existing "## Notes" block if present

---

## Part 7: Future Extensions (Non-blocking)

- `ligi check --prune` removes broken paths from the global index and prunes tag indexes. See [Pruning Broken Links Plan](impl_pruning_broken_links.md).
- `ligi index --global` rebuilds global tag indexes from all repos. See [Global Rebuild Tag Indexes Plan](impl_global_rebuild_tag_indexes.md).
- `ligi list` (or `ligi repos`) prints all known repos from the global index without validation.
