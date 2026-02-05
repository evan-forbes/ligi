# Refactor: Single art/ per Organization

## Summary

Pivot ligi from "every repo has its own art/" to "one art/ per organization." Repos become pure code directories. The org-level art/ holds all notes, plans, indexes, and templates. Tags still provide the cross-cutting view, but directory structure (inbox/, notes/, plans/) becomes the primary way to organize and move documents through their lifecycle.

This is a subtle refactor: the indexing engine itself doesn't change. What changes is how commands find art/ and how init scaffolds the workspace.

## Current Model

```
org/
  art/                   <- org art (templates, org-level docs)
  art/config/ligi.toml   <- type = "org", repos = ["repo1", "repo2"]
  repo1/
    art/                 <- repo art (repo-specific docs, index, templates)
    art/config/ligi.toml <- type = "repo"
    src/
  repo2/
    art/                 <- another repo art
    art/config/ligi.toml <- type = "repo"
    src/
```

Every repo has its own art/, index, templates, inbox. The org also has art/. `ligi index` operates on whichever art/ is nearest. `ligi index --org` iterates each repo's art/ separately.

## Target Model

```
org/
  art/                   <- THE art directory (single source of truth)
    config/ligi.toml     <- type = "org", repos = ["repo1", "repo2"]
    index/               <- one unified index
    template/            <- one template set
    inbox/               <- WIP docs land here
    notes/               <- promoted docs live here
    calendar/            <- day/week/month/quarter plans + calendar index
      index.md
  repo1/                 <- code only, no art/
    src/
  repo2/                 <- code only, no art/
    src/
```

Repos have no art/ directory. All markdown lives in the org's art/. The tag system still works identically (collectTags walks art/, skips art/index/, finds all .md files). The difference is that there's only one art/ to walk.

## What Doesn't Change

- **Tag parsing**: `collectTags` walks art/ recursively, extracts `[[t/...]]` tags. Directory depth doesn't matter. Works as-is.
- **Index format**: `art/index/ligi_tags.md` and `art/index/tags/*.md` structure is unchanged.
- **fillTagLinks**: Computes relative paths from source file depth to `index/tags/`. Works for any nesting level already.
- **isIndexStale**: Walks all .md under art/ (excluding art/index/). Works as-is.
- **readTagIndex**: Parses repo-relative paths from index files. Works as-is.
- **Global index** (`~/.ligi/art/index/`): Still useful for cross-org queries. Now registers orgs instead of individual repos.
- **Tag link filling**: No behavioral change.

## What Changes

### 1. Workspace Detection (`src/core/workspace.zig`)

**Current**: `findNearestArtParent` walks up from cwd looking for the nearest directory containing `art/`. If you're in `org/repo1/src/`, it finds `org/repo1/art/`.

**Change**: No code change needed here. Once repo-level art/ directories are removed, `findNearestArtParent` naturally walks up to `org/art/`. This is the key insight - the existing detection algorithm does the right thing once repos stop having art/.

**New behavior needed**: When running from inside a repo subdirectory, we want to know *which repo* we're in (for auto-tagging with `{{repo}}`). Add a helper that, given the resolved workspace root and the cwd, determines the repo name by checking if cwd is under one of the org's registered repos.

```
detectRepoContext(allocator, org_root, cwd) -> ?[]const u8
```

This returns the repo directory name (e.g., "repo1") if cwd is inside a registered repo, null otherwise.

**Files**: `src/core/workspace.zig`
**Touches**: `WorkspaceContext` struct (add `repo_name: ?[]const u8` field)

### 2. `ligi init` (`src/cli/commands/init.zig`)

**Current**: `ligi init` creates art/ in the current directory, registers with global index, tries to register with parent org.

**Change**:
- `ligi init --org` (or just `ligi init` at the org level): Unchanged. Creates art/ with all subdirectories, templates, config.
- `ligi init` from inside a repo under an org: Instead of creating art/ in the repo, detect the parent org and register the repo in the org's config. Print a message like "registered repo1 with org at ../". Do NOT create art/ in the repo.
- `ligi init` standalone (no parent org): Still works - creates art/ for a standalone workspace. This is the "single repo that is its own org" case.
- Remove `--no-register` flag (no longer relevant since repos don't have independent art/).
- Update `INITIAL_INBOX_README`, `INITIAL_ART_README` to reflect the new workflow (inbox -> notes promotion).

**Files**: `src/cli/commands/init.zig`
**Touches**: `run()`, `findParentOrg()`, initial content constants

### 3. `ligi index` (`src/cli/commands/index.zig`)

**Current (default)**: Resolves `art/` from `root_path` (defaults to "."), runs collectTags + writeLocalIndexes + fillAllTagLinks + writeGlobalIndexes.

**Change**:
- Default mode: Use workspace detection instead of raw `paths.getLocalArtPath(arena_alloc, root_path)`. Detect the workspace, find the org's art/ path, index that. This is the main behavioral change.
- `--org` flag: Remove. There's only one art/ now, so `ligi index` and `ligi index --org` do the same thing. Keep the flag as a no-op with a deprecation message for backwards compat for one release.
- `--file` mode: Still works. The file path is relative to the workspace root (the org), not the repo.
- `--global` mode: Unchanged.
- `--root` override: Still works, explicitly sets the workspace root.

**Key code change** (line 116-125):
```zig
// Before:
const root_path = root orelse ".";
const art_path = try paths.getLocalArtPath(arena_alloc, root_path);

// After:
const art_path = try resolveArtPath(arena_alloc, root, stderr) orelse return 1;
```

Where `resolveArtPath` uses workspace detection to find the org's art/.

**Files**: `src/cli/commands/index.zig`
**Touches**: `run()`, `runOrgIndex()` (deprecate or remove)

### 4. `ligi query` (`src/cli/commands/query.zig`)

**Current (single repo)**: Resolves art/ from root_path, runs staleness check, queries index files.

**Change**: Same as index - use workspace detection to find the org's art/. The query logic itself (AND/OR over tag files) is unchanged.

- Single-repo query (default): Resolves to org art/, queries there.
- `--org` flag: Remove (same as default now). Deprecation message.
- `--global` flag: Unchanged.
- Auto-indexing: Works the same, just against the org's art/.

**Key code change** (lines 231-242): Replace `getLocalArtPath` with workspace-aware resolution.

**Files**: `src/cli/commands/query.zig`
**Touches**: `runTagQuery()` path resolution block

### 5. `ligi plan` (`src/cli/commands/plan.zig`)

**Current**: Hardcodes `"art/inbox"` and `"art/plan"` as base directories (line 196). Hardcodes template paths as `"art/template/plan_*.md"` (lines 722-753). Hardcodes `"."` as root for `getLocalArtPath` (line 582).

**Change**:
- Use workspace detection to find the org's art/ path.
- Resolve template paths through the workspace context (use `context.template_paths` or equivalent).
- Write plan output files to the org's art/plans/ (or art/inbox/ for feature/chore/etc).
- `updateCalendar` (line 582): Use workspace-resolved art path instead of hardcoded `"."`.

**Files**: `src/cli/commands/plan.zig`
**Touches**: `resolveTarget()`, `updateCalendar()`, `renderTemplate()`, `templatePathForKind()`

### 6. `ligi check` (`src/cli/commands/check.zig`)

**Current**: Iterates repos from global index, checks each repo's art/, prunes local and global indexes.

**Change**: Minor. When pruning local tag indexes, resolve the org's art/ instead of per-repo art/. The pruning logic itself (remove entries pointing to non-existent files) is unchanged.

**Files**: `src/cli/commands/check.zig`
**Touches**: `run()` path resolution for local pruning

### 7. `ligi workspace` (`src/cli/commands/workspace.zig`)

**Current**: Shows workspace hierarchy info, lists repos, shows template paths.

**Change**: Update `info` subcommand output to reflect the new model. Show the single art/ path, list registered repos under it.

**Files**: `src/cli/commands/workspace.zig`
**Touches**: Display formatting

### 8. Registry (`src/cli/registry.zig`)

**Current**: Registers all subcommands including their help text.

**Change**: Update help text for `index` and `query` to remove `--org` references (or mark deprecated). No structural change.

**Files**: `src/cli/registry.zig`

### 9. Global Index (`src/core/global_index.zig`)

**Current**: Registers individual repos. Each repo path is an entry.

**Change**: Register org paths instead of individual repo paths. When `ligi init` is run at the org level, register the org. When `ligi init` is run in a repo, don't register the repo individually - it's part of the org.

**Files**: `src/core/global_index.zig`
**Touches**: `registerRepo` -> potentially rename to `registerWorkspace`

## Shared Helper: `resolveArtPath`

Multiple commands need the same logic: "find the art/ directory for where I am." Extract this into a shared helper in `src/core/paths.zig` or `src/core/workspace.zig`:

```zig
/// Resolve the art/ path for the current context.
/// Uses explicit root if provided, otherwise detects workspace.
pub fn resolveArtPath(
    allocator: std.mem.Allocator,
    root_override: ?[]const u8,
    stderr: anytype,
) !?[]const u8 {
    if (root_override) |root| {
        return try getLocalArtPath(allocator, root);
    }

    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const ws = detectWorkspace(allocator, cwd);
    if (ws != .ok) {
        try stderr.writeAll("error: no art/ directory found (run 'ligi init' first)\n");
        return null;
    }
    var ctx = ws.ok;
    defer ctx.deinit();

    return try std.fs.path.join(allocator, &.{ ctx.root, "art" });
}
```

This replaces the pattern `const art_path = try paths.getLocalArtPath(arena_alloc, root_path)` that appears in index.zig:119, query.zig:234, and plan.zig:582.

## Implementation Steps

### Step 1: Add `resolveArtPath` helper and `detectRepoContext`

**Files**: `src/core/workspace.zig`, `src/core/paths.zig`

**Tasks**:
- Add `resolveArtPath()` to workspace.zig
- Add `detectRepoContext()` to workspace.zig
- Add `repo_name: ?[]const u8` to `WorkspaceContext`
- Unit test: resolveArtPath with explicit root returns `<root>/art`
- Unit test: detectRepoContext returns repo name when cwd is inside a registered repo
- Unit test: detectRepoContext returns null when cwd is at org level

**Verification**: `zig build test` passes

### Step 2: Content-comparison write guard

`writeLocalIndexes` (tag_index.zig:981) unconditionally rewrites every index file on every run, even when content hasn't changed. The private `writeFile` (tag_index.zig:1719) and `fs.writeFile` (fs.zig:87) both do raw `createFile` + `writeAll` with no comparison. This means every `ligi index` touches every tag file's mtime, which can make `isIndexStale` think things changed when they didn't, and causes the "updated: ..." messages that don't correspond to real changes.

`fillTagLinksInFile` (tag_index.zig:361) is already correct - it checks `if (fill_result.tags_filled > 0)` before writing.

**Fix**: Add a `writeFileIfChanged` function that reads existing content first and skips the write if identical.

**File**: `src/core/fs.zig`

```zig
/// Write content to a file only if it differs from existing content.
/// Returns true if the file was written, false if skipped (content identical).
pub fn writeFileIfChanged(path: []const u8, content: []const u8, allocator: std.mem.Allocator) errors.Result(bool) {
    // Read existing content
    if (readFile(allocator, path)) |existing| {
        defer allocator.free(existing.ok);
        if (std.mem.eql(u8, existing.ok, content)) {
            return .{ .ok = false }; // Content unchanged, skip write
        }
    } else |_| {
        // File doesn't exist or can't be read, proceed with write
    }

    // Content differs or file is new - write it
    switch (writeFile(path, content)) {
        .ok => return .{ .ok = true },
        .err => |e| return .{ .err = e },
    }
}
```

**Then update callers in `tag_index.zig`**:

- `writeLocalIndexes` line 1025: `writeFile(tag_index_path, tag_index_content)` -> `writeFileIfChanged(...)`. Only count as "updated" if it returned true.
- `writeLocalIndexes` line 1060: Same for per-tag index files.
- `writeLocalIndexes` line 1092: Same for pruned (emptied) tag files.
- `writeGlobalIndexes` and `writeGlobalIndexesAuthoritative`: Same pattern.
- Private `writeFile` in tag_index.zig (line 1719): Replace calls to it with `fs.writeFileIfChanged`.

**Result**: The "updated"/"created" counts now reflect actual disk changes. `isIndexStale` won't see phantom mtime bumps. The log (step 9) can distinguish `write_index` (content changed) from `write_index_skip` (content identical).

**Verification**:
- Run `ligi index` twice with no source changes. Second run reports 0 updated, 0 created.
- Index file mtimes don't change on the second run.
- `zig build test` passes.

### Step 3: Update `ligi index` to use workspace detection

(Previously step 2)

**Files**: `src/cli/commands/index.zig`

**Tasks**:
- Replace `paths.getLocalArtPath(arena_alloc, root_path)` with `resolveArtPath`
- Make `--org` print deprecation message and behave like default
- Remove `runOrgIndex` body (make it delegate to default path)
- Keep `--global` unchanged

**Verification**:
- `ligi index` from inside an org repo indexes the org's art/
- `ligi index --org` prints deprecation, still works
- `ligi index --global` unchanged
- `zig build test` passes

### Step 3: Update `ligi query` to use workspace detection

**Files**: `src/cli/commands/query.zig`

**Tasks**:
- Replace `paths.getLocalArtPath` with `resolveArtPath` in single-repo path
- Make `--org` print deprecation, behave like default
- Keep `--global` unchanged

**Verification**:
- `ligi q t sometag` from inside a repo queries the org's art/index/
- Auto-indexing triggers against org art/
- `zig build test` passes

### Step 4: Update `ligi plan` to use workspace detection

**Files**: `src/cli/commands/plan.zig`

**Tasks**:
- Replace hardcoded `"."` in `updateCalendar` with workspace-resolved art path
- Update `resolveTarget` to use workspace-resolved art path instead of hardcoded `"art/inbox"` / `"art/plan"`
- Update `templatePathForKind` to resolve templates through workspace context
- Update `renderTemplate` to check workspace template_paths before falling back to builtins

**Verification**:
- `ligi plan day` from inside a repo creates the plan in org's art/
- Templates resolve from org art/template/
- Calendar updates in org art/calendar/index.md
- `zig build test` passes

### Step 5: Update `ligi init` for new model

**Files**: `src/cli/commands/init.zig`

**Tasks**:
- `ligi init` at org level: Unchanged behavior (create full art/ scaffolding)
- `ligi init` inside a repo under an org: Detect parent org, register repo in org config, do NOT create art/ in repo. Print registration message.
- `ligi init` standalone (no parent org): Create art/ as before (this directory is effectively both the "org" and the "repo")
- Add `art/notes/` to the standard directory set in `SPECIAL_DIRS` (paths.zig) and init scaffolding
- Add `art/plans/` as a standard directory
- Update `INITIAL_INBOX_README` and `INITIAL_ART_README` content

**Verification**:
- `ligi init` in a fresh directory creates art/ with notes/ and plans/
- `ligi init` inside a repo under an existing org does NOT create art/, does register with org
- `zig build test` passes

### Step 6: Update `ligi check` and `ligi workspace`

**Files**: `src/cli/commands/check.zig`, `src/cli/commands/workspace.zig`

**Tasks**:
- check: Use workspace detection for local prune path resolution
- workspace info: Update display to show single art/ location
- workspace list: Unchanged (still lists org repos)

**Verification**:
- `ligi check --prune` prunes the org's art/index/
- `ligi workspace info` shows correct hierarchy
- `zig build test` passes

### Step 7: Update registry help text and global index

**Files**: `src/cli/registry.zig`, `src/core/global_index.zig`

**Tasks**:
- Update help text for index and query (remove --org docs or mark deprecated)
- Global index: Register orgs instead of individual repos
- Update `registerRepo` naming/behavior

**Verification**:
- `ligi --help` reflects new model
- `ligi index --global` rebuilds from registered org paths
- `zig build test` passes

### Step 8: Clean up and integration test

**Tasks**:
- Remove dead code from runOrgIndex if fully deprecated
- End-to-end test: init org, init repo under org, create notes, index, query
- Verify inbox -> notes workflow: create in inbox, move to notes, reindex, query finds new path

### Step 9: Structured logging to `art/.ligi_log.jsonl`

Replace stdout printing with append-only JSONL logging. Commands currently print progress messages like "indexed 12 files, found 4 unique tags" and "filled 3 tag link(s) in source files" to stdout. This is noisy for normal use and not detailed enough for debugging. Move all of this to a structured log file.

**New file**: `src/core/log.zig`

**Design**:
```zig
pub const LogEntry = struct {
    timestamp: i64,       // unix seconds
    command: []const u8,  // "index", "query", "plan", "check", "init"
    action: []const u8,   // "collect_tags", "write_index", "fill_tag_links", "prune", etc.
    detail: ?[]const u8,  // optional: file path, tag name, etc.
    count: ?usize,        // optional: number of items affected
    duration_ms: ?u64,    // optional: how long the action took
};

/// Append a log entry to art/.ligi_log.jsonl
pub fn log(allocator: std.mem.Allocator, art_path: []const u8, entry: LogEntry) void
```

Each line is a self-contained JSON object:
```jsonl
{"ts":1738540800,"cmd":"index","action":"collect_tags","detail":"art/","count":47,"ms":12}
{"ts":1738540800,"cmd":"index","action":"write_local_index","detail":"art/index/tags/planning.md","count":5}
{"ts":1738540800,"cmd":"index","action":"fill_tag_links","detail":"art/inbox/my_note.md","count":2}
{"ts":1738540800,"cmd":"index","action":"fill_tag_links_skip","detail":"art/notes/old.md","count":0}
{"ts":1738540801,"cmd":"index","action":"done","count":47,"ms":85}
{"ts":1738541000,"cmd":"query","action":"auto_reindex","detail":"stale"}
{"ts":1738541000,"cmd":"query","action":"read_tag_index","detail":"art/index/tags/planning.md","count":5}
```

**Key logging points** (these replace existing stdout prints):

| Command | Current stdout | Log action | What it captures |
|---------|---------------|------------|-----------------|
| index | "indexed N files, found M unique tags" | `collect_tags` | file count, tag count |
| index | "filled N tag link(s) in source files" | `fill_tag_links` per file | which file, how many links filled, 0 if unchanged |
| index | writeLocalIndexes prints created/updated | `write_local_index` per tag file | which tag file, created vs updated |
| index | writeGlobalIndexes output | `write_global_index` | tag count |
| query | (silent auto-reindex) | `auto_reindex` | "stale" or "fresh" |
| query | (no logging of what it reads) | `read_tag_index` | which tag file, result count |
| plan | "created: path" | `create_plan` | output path |
| plan | "updated: calendar" | `update_calendar` | tags added |
| check | prune counts | `prune_local`, `prune_global` | entries removed |
| init | "created: dir" | `create_dir`, `create_file` | path |

**Behavior changes**:
- Commands that currently print progress to stdout become silent by default (clean unix-tool behavior: output only the result, not the process)
- `ligi index` prints nothing on success (or just the count line if not `--quiet`)
- `ligi query` prints only the matching file paths
- All detail goes to `art/.ligi_log.jsonl`
- Add `--verbose` / `-v` flag to commands that want the old behavior (prints log entries to stderr as they happen)
- Log file is append-only. `ligi check` can optionally truncate/rotate it.
- Add `.ligi_log.jsonl` to the suggested .gitignore pattern (this is local debug state, not shared)

**Debugging the "weird things" in indexing**:

The specific issue you mentioned - files being reported as updated when you're not sure they should have been - becomes trivially debuggable:

```bash
# What did the last index do?
tail -20 art/.ligi_log.jsonl | jq 'select(.cmd=="index")'

# Which files had tag links filled?
grep fill_tag_links art/.ligi_log.jsonl | jq 'select(.count > 0)'

# Which files were checked but NOT modified?
grep fill_tag_links_skip art/.ligi_log.jsonl | tail -20

# How long does indexing take?
grep '"action":"done"' art/.ligi_log.jsonl | jq '.ms'
```

**Files**: New `src/core/log.zig`, touch `src/core/mod.zig` to export it
**Touches**: Every command file (index.zig, query.zig, plan.zig, check.zig, init.zig) - replace `stdout.print(...)` calls with `log.log(...)` calls. Also touch `tag_index.zig` to log per-file detail from `fillAllTagLinks` and `writeLocalIndexes`.

**Tasks**:
- Create `src/core/log.zig` with `LogEntry` struct and `log()` function
- Add to `src/core/mod.zig` exports
- Replace stdout progress prints in index.zig with log calls
- Replace stdout progress prints in query.zig with log calls
- Replace stdout progress prints in plan.zig with log calls
- Replace stdout progress prints in check.zig with log calls
- Replace stdout progress prints in init.zig with log calls
- Add per-file logging to `fillAllTagLinks` (log each file: path + count of links filled, including 0)
- Add per-tag-file logging to `writeLocalIndexes` (log each tag file: created vs updated)
- Add `--verbose` flag to registry for commands that want stderr output
- Add `.ligi_log.jsonl` to init's suggested .gitignore content

**Verification**:
- `ligi index` produces no stdout output (or minimal summary)
- `art/.ligi_log.jsonl` contains detailed JSONL entries
- `ligi index -v` prints log entries to stderr
- `zig build test` passes
- Log entries are parseable by `jq`

### Step 10: Test audit and hardening

Go through all existing tests and add coverage for the gaps exposed by this refactor and the "weird update" issue. The current test suite has 24 tests in tag_index.zig and ~150 total, but there are specific gaps.

**Current gaps identified**:

1. **No test for fillAllTagLinks only modifying files that actually change.** `fillTagLinks` has an idempotency test (line 2516 of tag_index.zig), but `fillAllTagLinks` (the disk-walking version) has no test that verifies it skips files where no links were added. This is likely the source of the "weird updates" - the function may be rewriting files even when content is identical.

2. **No test for writeLocalIndexes skipping unchanged tag files.** The function returns `{ created, updated }` counts but there's no test that verifies a tag file whose content hasn't changed is NOT rewritten (preserving mtime). If it rewrites unchanged files, `isIndexStale` will see a newer mtime and trigger unnecessary reindexes.

3. **No end-to-end index-then-query test.** There are unit tests for collectTags, writeLocalIndexes, readTagIndex separately, but no test that runs the full pipeline: create files with tags -> index -> query -> verify results.

4. **No test for file movement (inbox -> notes).** No test verifies that after moving a file and reindexing, the old path is gone from the index and the new path appears.

5. **No test for workspace-resolved art path.** After step 1-4, need tests that verify commands find the org's art/ when run from inside a repo.

6. **No test for auto-reindex in query.** `isIndexStale` is tested, but the auto-reindex path in query.zig is not.

**Tasks**:

#### 10a: Verify the step 2 fix (content-comparison write guard)

The unconditional write bug was identified and fixed in step 2. Tests here verify the fix works end-to-end:

#### 10b: Add fillAllTagLinks tests

```
test "fillAllTagLinks skips files with no bare tags"
  - Create art/ with files that already have all tags linked
  - Run fillAllTagLinks
  - Verify return count is 0
  - Verify file mtimes are unchanged (files not rewritten)

test "fillAllTagLinks only modifies files with bare tags"
  - Create art/ with 3 files: one with bare tags, one with linked tags, one with no tags
  - Run fillAllTagLinks
  - Verify only the bare-tag file was modified
  - Verify the other two files have unchanged mtimes

test "fillAllTagLinks is idempotent on disk"
  - Create art/ with files containing bare tags
  - Run fillAllTagLinks twice
  - Verify second run returns 0 (no changes)
  - Verify no file mtimes changed on second run
```

#### 10c: Add writeLocalIndexes tests

```
test "writeLocalIndexes does not rewrite unchanged tag files"
  - Create art/ with tags, write indexes
  - Record mtimes of all index files
  - Run writeLocalIndexes again with same tag map
  - Verify mtimes unchanged (no unnecessary writes)

test "writeLocalIndexes correctly handles tag removal"
  - Index with tags A and B
  - Remove tag A from source file
  - Reindex
  - Verify tag A's index file is updated (empty or removed)
  - Verify tag B's index file unchanged
```

#### 10d: Add end-to-end pipeline tests

```
test "full pipeline: create files, index, query"
  - Create temp org with art/
  - Create art/notes/a.md with [[t/project]] [[t/todo]]
  - Create art/notes/b.md with [[t/project]] [[t/done]]
  - Run collectTags + writeLocalIndexes + fillAllTagLinks
  - Read tag index for "project" -> verify both files listed
  - Read tag index for "todo" -> verify only a.md
  - Simulate AND query (project & todo) -> verify a.md only
  - Simulate OR query (todo | done) -> verify both files

test "file movement: reindex picks up new path"
  - Create art/inbox/draft.md with [[t/planning]]
  - Index
  - Verify index lists art/inbox/draft.md
  - Move file to art/notes/draft.md
  - Reindex
  - Verify index lists art/notes/draft.md (not inbox path)

test "staleness triggers reindex on query"
  - Create art/ with a tagged file, index it
  - Touch a file (update mtime)
  - Verify isIndexStale returns true
  - (After refactor) verify query auto-reindexes
```

#### 10e: Add workspace resolution tests

```
test "resolveArtPath from repo inside org finds org art/"
  - Create temp org with art/ and repo subdirectory (no art/)
  - From repo dir, call resolveArtPath
  - Verify it returns org's art/ path

test "resolveArtPath standalone repo finds local art/"
  - Create temp repo with art/ (no parent org)
  - Call resolveArtPath
  - Verify it returns local art/ path

test "resolveArtPath with explicit root overrides detection"
  - Call resolveArtPath with root_override set
  - Verify it returns <root>/art regardless of workspace
```

#### 10f: Add logging tests

```
test "log.log appends valid JSONL to file"
  - Create temp art/ dir
  - Log 3 entries
  - Read .ligi_log.jsonl
  - Verify 3 lines, each valid JSON

test "log.log handles missing art/ gracefully"
  - Log to nonexistent path
  - Verify no crash (silent failure)
```

**Files**: `src/core/tag_index.zig` (add tests), `src/core/log.zig` (add tests), `src/testing/integration/` (add pipeline tests)

**Verification**:
- All new tests pass: `zig build test`
- The "unnecessary write" behavior is identified and fixed (or confirmed as intentional and documented)
- Full pipeline test demonstrates the inbox -> notes workflow

## Migration

For existing users with per-repo art/ directories:

1. Move contents of each repo's art/ into the org's art/ (manually or with a helper script)
2. Re-run `ligi index` at the org level
3. Delete repo-level art/ directories
4. The global index entries for old repo paths will be cleaned by `ligi check --prune`

No automated migration tool is planned for v1. The manual process is straightforward since it's just moving markdown files.

## Risks

- **Breaking existing workflows**: Users with per-repo art/ will need to migrate. Mitigated by keeping standalone (no-org) init working the same way.
- **Workspace detection ambiguity**: If a repo still has a stale art/ directory, `findNearestArtParent` will find it before the org's art/. Mitigated by step 5 (init doesn't create repo art/) and migration docs.
- **Plan path assumptions**: plan.zig has the most hardcoded paths (30+ instances). This is the riskiest file to change. Mitigated by keeping the same directory structure within art/, just changing where art/ is resolved from.

## Non-Goals

- Changing the tag syntax or parsing
- Changing the index file format
- Supporting multiple art/ directories per org
- Automated migration tooling (can be added later if needed)
- Changing how `--global` mode works
