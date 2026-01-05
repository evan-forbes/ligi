# Ligi Batch Operations: Performance Exploration

## Overview

This document explores opportunities to batch file operations in ligi for improved performance, particularly when managing large numbers of tags, files, or repositories.

---

## Current Approach

### Per-File Write Pattern

Currently, ligi writes index files one at a time:

```
for each tag:
    open file
    write content
    close file
```

This works well for small to medium repos but has overhead:
- File system calls for each open/close
- Potential disk sync overhead
- Lock contention on some filesystems

### Operations That Write Multiple Files

1. **`ligi index`** - Writes `ligi_tags.md` + N per-tag files
2. **`ligi index --global`** - Same as above, for each repo + global indexes
3. **`ligi check --prune`** - Rewrites broken tag indexes
4. **Tag removal** - Updates multiple per-tag files when a tag is removed from a file

---

## Batching Opportunities

### 1. Collect-Then-Write Pattern

Instead of writing each file immediately, collect all changes in memory then write in one pass:

```
changes = {}
for each tag:
    changes[tag_path] = render_content(tag)
for path, content in changes:
    write(path, content)
```

**Benefits:**
- Single iteration over file system
- Easier error handling (can abort before any writes)
- Natural transaction boundary

**Trade-offs:**
- Higher memory usage (all content in RAM)
- Slightly more complex code

**Estimate:** Modest improvement (10-30%) for repos with many tags.

### 2. Parallel Writes

Tags are independent; per-tag files can be written concurrently:

```zig
var threads = ThreadPool.init(allocator);
for (tags) |tag| {
    threads.spawn(writeTagFile, .{ tag, content });
}
threads.wait();
```

**Benefits:**
- Better I/O utilization on SSDs
- Significant speedup for global rebuilds

**Trade-offs:**
- Zig's async is limited; would need manual thread pool
- Complexity increase
- Diminishing returns on HDDs

**Estimate:** 2-4x speedup for large global rebuilds on SSD.

### 3. Delta Updates (Incremental)

Currently `ligi index --file` supports incremental updates. Extend this pattern:

- Track file modification times
- Only reprocess changed files
- Only rewrite affected tag indexes

**Benefits:**
- Minimal work for common case (editing one file)
- Scales to very large repos

**Trade-offs:**
- Need to track state (mtimes, hashes)
- Edge cases with moved/renamed files

**Already partially implemented:** `isIndexStale()` exists but not fully utilized.

---

## Tools for Cross-File Updates

### Existing Tools

| Tool | Use Case | When to Use |
|------|----------|-------------|
| `ripgrep` | Find files containing pattern | Tag search across repos |
| `fd` | Find files by name pattern | Locate tag index files |
| `sed -i` | In-place text replacement | Simple pattern replacement |
| `jq` | JSON manipulation | If we had JSON indexes |
| `parallel` | Parallel execution | Batch any operation |

### Example: Rename Tag Across All Indexes

Using existing tools:
```bash
# Find all tag index files
fd -t f '\.md$' ~/.ligi/art/index/tags/ |
  # Replace old tag name with new
  xargs -P4 sed -i 's/old_tag/new_tag/g'
```

### Example: Remove Tag References

```bash
# Find files referencing a tag
rg -l '\[\[t/deprecated_tag\]\]' art/ |
  xargs -P4 sed -i 's/\[\[t\/deprecated_tag\]\]//g'
```

---

## Do We Need Custom Tooling?

### Cases Where Shell Tools Suffice

1. **Bulk tag rename** - `sed` + `fd` works
2. **Find orphaned tag files** - `fd` + `comm` to diff
3. **Mass re-index** - `find | xargs ligi index --file`

### Cases Requiring Custom Tooling

1. **Semantic operations** - "Move all files with tag X to tag Y" requires understanding tag structure
2. **Cross-repo operations** - Need awareness of global index
3. **Validation** - "Ensure no tag file references missing paths"

### Recommendation

**Phase 1:** Leverage shell tools via documentation. Add a `ligi batch` command that generates appropriate shell commands:

```
$ ligi batch rename-tag old new
# Would output:
# fd -t f '\.md$' art/ | xargs sed -i 's/\[\[t\/old\]\]/[[t\/new]]/g'
# ligi index
```

**Phase 2:** If shell tools become limiting, implement:
- `ligi tag rename <old> <new>` - Semantic rename
- `ligi prune --dry-run` - Preview changes before applying

---

## Implementation Considerations

### Memory vs I/O Trade-off

For most repos, memory is cheap. A reasonable approach:

```zig
pub fn batchWriteTagIndexes(
    allocator: Allocator,
    tag_map: *const TagMap,
    art_path: []const u8,
) !void {
    // 1. Collect all file contents in memory
    var pending = StringHashMap([]const u8).init(allocator);
    defer {
        var it = pending.iterator();
        while (it.next()) |entry| allocator.free(entry.value_ptr.*);
        pending.deinit();
    }

    const tags = try tag_map.getSortedTags(allocator);
    defer allocator.free(tags);

    for (tags) |tag| {
        const path = try buildTagPath(allocator, art_path, tag);
        const content = try renderPerTagIndex(allocator, tag, ...);
        try pending.put(path, content);
    }

    // 2. Write all files
    var it = pending.iterator();
    while (it.next()) |entry| {
        try writeFile(entry.key_ptr.*, entry.value_ptr.*);
    }
}
```

### Error Handling

With batching, consider:
- Should we write partial results on error?
- Can we roll back?

For ligi, indexes are regeneratable. A simple approach: on error, log and continue. User can re-run `ligi index` to fix.

---

## Performance Estimates

| Scenario | Current | Batched | Parallel |
|----------|---------|---------|----------|
| 10 tags | 5ms | 5ms | 5ms |
| 100 tags | 50ms | 40ms | 15ms |
| 1000 tags | 500ms | 350ms | 100ms |
| Global (10 repos × 100 tags) | 5s | 3.5s | 1s |

*Estimates based on typical SSD latency (~0.1ms per small file operation)*

---

## Conclusion

For v1, the current per-file approach is acceptable. Recommended improvements:

1. **Short term:** Document shell-based batch operations in README
2. **Medium term:** Implement collect-then-write pattern for `--global`
3. **Long term:** Add `ligi batch` command to generate/execute shell pipelines

The main bottleneck for most users will be file parsing (tag extraction), not file writing. Focus optimization efforts there first.

---

## Related Documents

- [Tagging System Implementation Plan](impl_tagging_system.md)
- [Global Rebuild Tag Indexes Plan](impl_global_rebuild_tag_indexes.md)
- [Pruning Broken Links Plan](impl_pruning_broken_links.md)
