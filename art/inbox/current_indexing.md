# How Indexing Actually Works (Code Audit)

## What the index is

The index is a set of markdown files that map tags to the files that contain them. There are two tiers:

- **Local** (`art/index/`): per-repo tag index with relative paths
- **Global** (`~/.ligi/art/index/`): cross-repo tag index with absolute paths

Both tiers have the same structure:
```
index/
  ligi_tags.md          # list of all tags, each linking to its tag file
  tags/
    tag_name.md         # list of files containing that tag
    nested/tag.md       # hierarchical tags get nested dirs
```

There is also a separate global repo registry at `~/.ligi/art/index/ligi_global_index.md` which just lists repo paths.

## What `ligi index` does (the explicit command)

### Default (no flags): full local + global reindex

1. **collectTags**: Walks every `.md` file under `art/` (skipping `art/index/`). For each file, a state-machine parser extracts `[[t/tag_name]]` patterns. The parser is markdown-aware: it skips fenced code blocks, inline code, and HTML comments. Builds a `TagMap` (HashMap of tag name -> list of file paths).

2. **writeLocalIndexes**: Writes `art/index/ligi_tags.md` and one file per tag under `art/index/tags/`. Each tag file lists its source files as relative markdown links. Tags that existed in a previous index but no longer have files get written as empty placeholder files (not deleted).

3. **fillAllTagLinks**: Walks all `.md` files again. Converts bare `[[t/tag_name]]` references into `[[t/tag_name]](relative/path/to/index/tags/tag_name.md)` markdown links. Only touches tags that don't already have a link after the `]]`.

4. **writeGlobalIndexes**: Merges the current repo's tags into `~/.ligi/art/index/`. Loads existing global tag files, removes stale entries from this repo, adds new entries with absolute paths, preserves entries from other repos.

### `--file <path>` mode

Skips the full walk. Loads the existing tag map from the index files (`loadTagMapFromIndexes`), then updates just the one file (`updateTagMapForFile`). Then writes local + global indexes and fills tag links for that single file only.

If `--tags tag1,tag2` is also provided, those tags are injected into the file content before indexing.

### `--org` mode

Iterates all repos in the workspace org (from workspace config). For each repo:
- collectTags
- writeLocalIndexes
- fillAllTagLinks
- Accumulates stats (repos indexed, total files, total tags)

Then creates a unified org-level index.

### `--global` mode

Calls `rebuildGlobalTagIndexesFromRepos` which loads all repos from the global registry and rebuilds `~/.ligi/art/index/` from scratch (authoritative write, not merge).

## Automatic indexing from other commands

### `ligi query` (the main consumer)

Before running a query, checks `isIndexStale()`. This compares the mtime of `art/index/ligi_tags.md` against all `.md` files under `art/` (excluding `art/index/`). If any source file is newer than the index:
- Runs collectTags + writeLocalIndexes + writeGlobalIndexes
- Then proceeds with the query

This only happens for single-repo queries (not `--org` or `--global`), and can be disabled with `--index false`.

The query itself reads per-tag files from `art/index/tags/<tag>.md`, extracts file paths from the markdown list items, and supports AND (`&`) and OR (`|`) operations across multiple tags.

### `ligi plan`

Two uses of tag_index:

1. **When creating a plan file**: After rendering the template and injecting auto-tags (org/repo tags), calls `fillTagLinks` on the content before writing it to disk. This converts bare `[[t/...]]` tags into linked form. No full reindex happens.

2. **When updating the calendar** (`art/calendar/index.md`): Parses tags from existing calendar content via `parseTagsFromContent`, loads the tag list from the index via `loadTagListFromIndex`, sorts time-based tags into day/week buckets, renders the calendar, then calls `fillTagLinks` on the result. This reads the index but does not rebuild it.

### `ligi check`

Runs pruning, not indexing:
- `pruneLocalTagIndexes`: For each repo, removes entries from per-tag files that point to files that no longer exist on disk. Deletes tag files that become empty.
- `pruneGlobalTagIndexes`: Same for the global index. Also removes entries pointing to repos that no longer exist.

### `ligi init`

Registers the new repo path in the global index (`~/.ligi/art/index/ligi_global_index.md`). Does not perform any tag indexing.

## What the staleness check actually does

`isIndexStale` (tag_index.zig):
- If `art/index/ligi_tags.md` doesn't exist -> stale
- Gets mtime of the index file
- Walks all `.md` files under `art/` (excluding `art/index/`)
- If any file's mtime is newer than the index -> stale
- Otherwise -> fresh

This means any edit to any markdown file in `art/` will trigger a full reindex on the next `ligi query`.

## What fillTagLinks does to your files

This is a side-effect worth noting: `fillAllTagLinks` (called during `ligi index`) modifies your source markdown files in-place. It appends link targets to bare tag references. So after indexing, `[[t/foo]]` in your notes becomes `[[t/foo]](../../index/tags/foo.md)`.

The plan command also calls `fillTagLinks` on content it's about to write, but that's on generated content, not existing files.

## Summary of what touches disk

| Command | Reads source files | Writes index | Modifies source files | Writes global index |
|---------|-------------------|-------------|----------------------|-------------------|
| `index` (default) | all md in art/ | yes | yes (fills tag links) | yes |
| `index --file` | one file | yes | yes (that file only) | yes |
| `index --org` | all md in all org repos | yes (each repo) | yes (all repos) | no (unified org index instead) |
| `index --global` | none (reads existing indexes) | no | no | yes (full rebuild) |
| `query` (if stale) | all md in art/ | yes | no | yes |
| `plan` | reads index only | no | no (writes new files) | no |
| `check` | reads index + checks file existence | yes (prunes) | no | yes (prunes) |
| `init` | no | no | no | yes (registers repo) |

Note: `query` auto-reindex does NOT call fillAllTagLinks, so it won't modify your source files. It only rebuilds the index files themselves.
