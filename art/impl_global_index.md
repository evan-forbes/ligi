# Ligi Global Index Implementation Plan

## Executive Summary

This document defines the global index that lives under `~/.ligi/art/` and serves as a registry of every repo (and its `art/` root) that has been initialized with `ligi`. It enables quick discovery, cross-repo navigation, and future features like global tag/query without scanning every repo.

---

## Part 1: Decisions (Finalized)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Global index file name | `~/.ligi/art/index/ligi_global_index.md` |
| 2 | Format | Human-editable Markdown with stable, parseable sections |
| 3 | Repo identity key | Absolute repo root path (canonicalized) |
| 4 | Repo entry storage | Inline entries in the global index + optional per-repo index files |
| 5 | Update triggers | `ligi init`, `ligi index`, and explicit `ligi global-index` (future) |
| 6 | Idempotency | Merge/update existing entries; never duplicate |

---

## Part 2: Global Index Structure

### 2.1 File Location

```
~/.ligi/
└── art/
    └── index/
        └── ligi_global_index.md
```

### 2.2 Markdown Format (Stable Sections)

The file is divided into:

1. **Header** (static) with doc purpose
2. **Repo Registry** (machine-parseable list)
3. **Notes** (optional freeform section)

```md
# Ligi Global Index

This file is auto-maintained by ligi. It tracks all repositories initialized with ligi.

## Repositories

- repo: /abs/path/to/repo
  name: repo
  art: /abs/path/to/repo/art
  config: /abs/path/to/repo/art/config/ligi.toml
  index: /abs/path/to/repo/art/index/ligi_tags.md
  last_indexed: 2026-01-04T20:15:00Z
  status: ok

- repo: /abs/path/to/other
  name: other
  art: /abs/path/to/other/art
  config: /abs/path/to/other/art/config/ligi.toml
  index: /abs/path/to/other/art/index/ligi_tags.md
  last_indexed: unknown
  status: missing_art

## Notes

(Freeform, not parsed by ligi)
```

### 2.3 Field Definitions

- `repo`: Canonical absolute path to the repo root (primary key).
- `name`: Basename of repo directory (display only; not unique).
- `art`: Absolute path to the repo’s `art/` directory.
- `config`: Absolute path to `ligi.toml` (local config).
- `index`: Absolute path to `art/index/ligi_tags.md`.
- `last_indexed`: RFC3339 UTC timestamp or `unknown`.
- `status`: One of:
  - `ok` (art + config present)
  - `missing_art`
  - `missing_config`
  - `missing_index`
  - `unknown`

---

## Part 3: Update Rules

### 3.1 When `ligi init` runs

- Resolve repo root (default `.` or `--root`).
- Canonicalize path (resolve `.`/`..`, symlinks if possible).
- Ensure `~/.ligi/art/index/ligi_global_index.md` exists (create if missing).
- Upsert an entry:
  - If `repo` path matches an existing entry, update fields.
  - If not found, append a new entry under “## Repositories”.

### 3.2 When `ligi index` runs

- Update `last_indexed` for the repo.
- Optionally update `status` based on filesystem checks.

### 3.3 When repo is removed

- Do **not** delete entries automatically.
- Mark `status` as `missing_art` or `missing_config` on the next update.

---

## Part 4: Parsing Strategy

Parsing should be line-based and tolerant:
- Identify “## Repositories” section.
- Entries begin with `- repo: `.
- All indented `key: value` lines that follow belong to that entry until the next `- repo:` or section header.
- Unknown keys are preserved.

This avoids strict YAML parsing and keeps the file human-editable.

---

## Part 5: Implementation Sketch (Zig)

1. **Ensure file exists**: `~/.ligi/art/index/ligi_global_index.md`.
2. **Read file** into memory.
3. **Parse entries** into a map keyed by `repo` path.
4. **Upsert entry** for the current repo.
5. **Render file** back out with stable ordering:
   - Header
   - “## Repositories”
   - Entries sorted lexicographically by `repo`
   - “## Notes” (preserve existing block if present)

---

## Part 6: Future Extensions (Non-blocking)

- Per-repo detail files in global index:
  - `~/.ligi/art/index/repo_<slug>.md` with backlinks and repo summary.
- Global tag summary aggregation across repos.
- `ligi global-index --prune` to remove stale entries.

