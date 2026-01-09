[[t/TODO]](index/tags/TODO.md) [[t/query]](index/tags/query.md) [[t/cli]](index/tags/cli.md)

# Implementation Plan: `ligi q g` (Graph Query)

## Goal

Add a new `ligi q g` (graph) subcommand that prints a document graph derived from Markdown links. The graph is output as a tree/forest by default, showing document titles (and optional tags when `-t/--tags` is provided). Links to `art/index/**` are excluded from traversal but used for tag extraction.

## Behavior Summary

- **Command**: `ligi q g` (alias `ligi query graph` via `g` / `graph`)
- **Input**: Markdown files under `art/` (excluding `art/index/**`)
- **Edges**: From a document to the documents it links to via Markdown inline links `[text](path)`
- **Output**: Tree/forest of titles (not paths)
- **Index exclusion**: Links pointing to `art/index/**` are not followed (these are tag links or backlink indexes)
- **Tags**: When `-t/--tags` is passed, extract tag names from links to `index/tags/*.md` and render below each title

## Design Decisions

1. **Title source**: Use first H1 (`# `) outside code/comments; fallback to filename stem. Frontmatter in fenced code blocks is naturally skipped.
2. **Link syntax**: Support only inline links `[text](path)` (ignore reference-style and wiki links).
3. **Path normalization**: Strip `#fragment` / `?query`, resolve `./` and `../` relative to source file, treat paths as repo-root relative.
4. **Graph roots**: Docs with no incoming links are roots. If all nodes have incoming links (pure cycle), all nodes are roots.
5. **Cycle handling**: When a node is visited twice in traversal, print `(cycle)` marker and stop recursion.
6. **Duplicate titles**: When multiple docs share a title, append path suffix: `My Title (sub/file.md)`.
7. **Broken links**: Links to non-existent files are silently ignored (no edge created, no warning).
8. **Self-links**: Links with only a fragment (`#section`) or pointing to the same file are ignored.
9. **Tag extraction**: Links matching `index/tags/*.md` are parsed for tag name but not followed as edges.
10. **Transient graph**: This command builds the graph at query time; it does NOT use or depend on `art/index/links_*.md` files.

## Data Structures

### Link

```zig
pub const Link = struct {
    target_path: []const u8,  // normalized art-relative path (e.g., "art/foo.md")
    line: usize,              // source line number (for debugging)
};
```

### Document

```zig
pub const Document = struct {
    path: []const u8,           // art-relative path (e.g., "art/sub/doc.md")
    title: []const u8,          // extracted H1 or filename stem
    display_title: []const u8,  // title with path suffix if duplicate
    outgoing: [][]const u8,     // paths of linked documents (edges)
    tags: [][]const u8,         // tag names extracted from index/tags links
};
```

### Graph

```zig
pub const Graph = struct {
    docs: std.StringHashMap(Document),  // path -> Document
    incoming_count: std.StringHashMap(usize),  // path -> count of incoming edges
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Graph { ... }
    pub fn deinit(self: *Graph) void { ... }
    pub fn addDocument(self: *Graph, doc: Document) !void { ... }
    pub fn getRoots(self: *const Graph, allocator: std.mem.Allocator) ![][]const u8 { ... }
};
```

## Implementation Steps

### 1) Core Graph Collection (new module)

Create `src/core/link_graph.zig` with:

#### Parsing Helpers

**`parseLinksFromContent(allocator, content, source_path) -> ParseResult`**

```zig
pub const ParseResult = struct {
    links: []Link,      // non-index links (edges)
    tags: [][]const u8, // tag names from index/tags links
};
```

State machine (reuse pattern from `tag_index.parseTagsFromContent`):

```
States: normal, in_fenced_code, in_inline_code, in_html_comment

In normal state, scan for pattern: \[([^\]]+)\]\(([^)]+)\)
  - Extract group 2 as raw_target
  - Skip if raw_target starts with http://, https://, mailto:, tel:, file://
  - Skip if raw_target is only a fragment (#section)
  - Strip #fragment and ?query from raw_target
  - Normalize path relative to source_path directory:
    - Use std.fs.path.resolve or manual ../  ./ handling
    - Result must start with "art/" to be valid
  - If normalized path matches "art/index/tags/*.md":
    - Extract tag name (filename stem after "tags/")
    - Add to tags list
    - Do NOT add to links
  - Else if normalized path matches "art/index/**":
    - Skip (don't follow index files)
  - Else:
    - Add to links list
```

Edge cases to handle:
- Escaped brackets `\[...\]` - not a link
- Image links `[![alt](img)](url)` - outer link is valid, parse it
- Spaces in paths: `my%20doc.md` or `my doc.md` - normalize %20 to space
- Multi-line links - ignore (require link on single line)

**`parseTitleFromContent(content, fallback_stem) -> []const u8`**

```
Algorithm:
1. Skip UTF-8 BOM if present (\xef\xbb\xbf)
2. Enter state machine (normal, in_fenced_code, in_inline_code, in_html_comment)
3. At each newline in normal state:
   - Check if next line starts with "# " (after optional leading whitespace)
   - If yes: extract text after "# " until newline, trim, return
4. If no H1 found, return fallback_stem (filename without .md extension)

Note: Frontmatter in fenced code blocks (``` before the first H1) is naturally
skipped since the state machine ignores content inside code blocks.
```

#### Graph Collection

**`collectGraph(allocator, art_path, follow_symlinks, ignore_patterns, stderr) -> Graph`**

```
Algorithm:
1. Initialize empty Graph
2. Walk art/ directory (reuse pattern from tag_index.walkArtDirectory)
3. For each .md file:
   - Skip if path starts with "art/index/"
   - Skip if matches ignore_patterns
   - Read file content
   - Parse title with fallback to filename stem
   - Parse links and tags
   - Create Document, add to Graph
4. After all docs collected, resolve duplicate titles:
   - Group docs by title
   - For groups with >1 doc, set display_title = "Title (relative/path.md)"
5. Compute incoming_count for each document
6. Return Graph
```

### 2) Tree Rendering

**`renderTree(allocator, graph, show_tags, writer) -> !void`**

```
Algorithm:
1. roots = docs where incoming_count == 0
2. If roots is empty (pure cycle), roots = all docs
3. Sort roots lexicographically by display_title
4. visited = StringHashMap(void)
5. For each root (index i, total n):
   printNode(root, prefix="", is_last=(i == n-1), visited, show_tags, writer)

printNode(doc, prefix, is_last, visited, show_tags, writer):
  connector = if is_last then "└─ " else "├─ "

  if doc.path in visited:
    writer.print("{s}{s}{s} (cycle)\n", .{prefix, connector, doc.display_title})
    return

  visited.put(doc.path, {})
  writer.print("{s}{s}{s}\n", .{prefix, connector, doc.display_title})

  // Render tags if requested
  if show_tags and doc.tags.len > 0:
    tag_prefix = prefix ++ (if is_last then "   " else "│  ")
    for doc.tags |tag|:
      writer.print("{s}  - {s}\n", .{tag_prefix, tag})

  // Render children
  children = sorted(doc.outgoing, by=graph.docs[path].display_title)
  child_prefix = prefix ++ (if is_last then "   " else "│  ")
  for children (index j, total m):
    child_doc = graph.docs.get(child_path) orelse continue  // skip broken links
    printNode(child_doc, child_prefix, j == m-1, visited, show_tags, writer)
```

### 3) CLI Integration

Update `src/cli/commands/query.zig`:

**Add subcommand dispatch** (after line 43):

```zig
if (std.mem.eql(u8, subcmd, "g") or std.mem.eql(u8, subcmd, "graph")) {
    return runGraphQuery(allocator, args[1..], stdout, stderr, quiet);
}
```

**Update query-level help** (lines 47-58) to include:

```
  ligi q g                   Print document graph
  ligi q g -t                Print graph with tags
```

**Implement `runGraphQuery`**:

```zig
fn runGraphQuery(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
    quiet: bool,
) !u8 {
    _ = quiet; // unused for now

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Parse options
    var root: ?[]const u8 = null;
    var show_tags = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--root")) {
            i += 1;
            if (i >= args.len) {
                try stderr.writeAll("error: --root requires a value\n");
                return 1;
            }
            root = args[i];
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--tags")) {
            show_tags = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stdout.writeAll("Usage: ligi q g [options]\n\n");
            try stdout.writeAll("Print document link graph as a tree.\n\n");
            try stdout.writeAll("Options:\n");
            try stdout.writeAll("  -r, --root <path>  Repository root directory\n");
            try stdout.writeAll("  -t, --tags         Show tags under each document\n");
            try stdout.writeAll("  -h, --help         Show this help\n");
            return 0;
        } else {
            try stderr.print("error: unknown option '{s}'\n", .{arg});
            return 1;
        }
    }

    // Resolve paths
    const root_path = root orelse ".";
    const art_path = try paths.getLocalArtPath(arena_alloc, root_path);

    if (!fs.dirExists(art_path)) {
        try stderr.print("error: art directory not found: {s}\n", .{art_path});
        return 1;
    }

    // Collect and render graph
    const cfg = config.getDefaultConfig();
    var graph = try link_graph.collectGraph(
        arena_alloc,
        art_path,
        cfg.index.follow_symlinks,
        cfg.index.ignore_patterns,
        stderr,
    );
    defer graph.deinit();

    try link_graph.renderTree(arena_alloc, &graph, show_tags, stdout);
    return 0;
}
```

**Note**: No changes to `registry.zig` are needed - the query command already handles its own subcommand dispatch.

### 4) Core Module Export

Update `src/core/mod.zig`:

```zig
pub const link_graph = @import("link_graph.zig");
```

## Example Output

```
$ ligi q g
Project Overview
├─ Getting Started
│  ├─ Installation Guide
│  └─ Quick Start
├─ API Reference
│  ├─ Authentication
│  │  └─ OAuth Setup (cycle)
│  └─ REST Endpoints
└─ Troubleshooting
   └─ Common Errors

$ ligi q g -t
Project Overview
├─ Getting Started
│    - tutorial
│    - beginner
│  ├─ Installation Guide
│  │    - setup
│  └─ Quick Start
├─ API Reference
│    - api
│    - reference
│  ├─ Authentication
│  │    - security
│  │  └─ OAuth Setup (cycle)
│  │       - oauth
│  └─ REST Endpoints
│       - api
└─ Troubleshooting
     - support
   └─ Common Errors
        - faq
```

## Testing Plan

### Unit Tests (src/core/link_graph.zig)

#### Link Parsing Tests

| Test | Input | Expected |
|------|-------|----------|
| Basic inline link | `[text](other.md)` | Link to `other.md` |
| Link with fragment | `[text](other.md#section)` | Link to `other.md` (fragment stripped) |
| Link with query | `[text](other.md?v=1)` | Link to `other.md` (query stripped) |
| Fragment-only link | `[text](#section)` | No link (self-reference) |
| External http | `[text](https://example.com)` | No link |
| External mailto | `[text](mailto:a@b.com)` | No link |
| Link in fenced code | ` ```\n[text](link.md)\n``` ` | No link |
| Link in inline code | `` `[text](link.md)` `` | No link |
| Link in HTML comment | `<!-- [text](link.md) -->` | No link |
| Link in frontmatter | ` ```\nlink = "[x](y.md)"\n``` ` (before H1) | No link |
| Relative path `./` | `[text](./sub/doc.md)` | Link to `art/sub/doc.md` |
| Relative path `../` | (from `art/sub/a.md`) `[text](../b.md)` | Link to `art/b.md` |
| Tag link | `[[t/foo](./index/tags/foo.md)]` | Tag `foo`, no edge |
| Index link | `[back](./index/links_doc.md)` | No edge (index excluded) |
| Multiple links same target | `[a](x.md) [b](x.md)` | One edge to `x.md` |
| Space in path | `[text](my%20doc.md)` | Link to `my doc.md` |
| Image inside link | `[![img](i.png)](doc.md)` | Link to `doc.md` |
| Broken link target | `[text](nonexistent.md)` | Link recorded, skipped at render |

#### Title Parsing Tests

| Test | Input | Expected |
|------|-------|----------|
| H1 at start | `# My Title\ntext` | `My Title` |
| H1 after content | `text\n# My Title` | `My Title` |
| H1 with leading space | `  # My Title` | `My Title` |
| H1 in code block | ` ```\n# Not Title\n```\n# Real` | `Real` |
| No H1 | `## Subtitle only` | filename stem |
| Multiple H1s | `# First\n# Second` | `First` |
| H1 with trailing space | `# Title  ` | `Title` |
| H1 after frontmatter | ` ```toml\ntitle = "ignore"\n```\n# Real Title` | `Real Title` |
| Frontmatter only | ` ```toml\ntitle = "x"\n```\nno heading` | filename stem |

#### Graph Structure Tests

| Test | Setup | Expected |
|------|-------|----------|
| Simple chain | a→b→c | Root: a, depth 2 |
| Diamond | a→b, a→c, b→d, c→d | Root: a, d appears once |
| Cycle | a→b→c→a | All roots, cycle marker on revisit |
| Orphan doc | a→b, c (no links) | Roots: a, c |
| Self-loop | a→a | Root: a with (cycle) |
| Pure cycle | a→b→a (no other docs) | Both roots, cycle on second visit |
| Empty graph | no .md files | Empty output |
| Duplicate titles | a.md "Title", b.md "Title" | `Title (a.md)`, `Title (b.md)` |

#### Determinism Tests

| Test | Verify |
|------|--------|
| Stable root order | Same input → same root order (lexicographic) |
| Stable child order | Same input → same child order under each node |
| Stable tag order | Same input → same tag order |

### Integration Tests (src/cli/commands/)

```zig
test "graph query: basic tree structure" {
    // Setup: temp dir with art/a.md → art/b.md → art/c.md
    // Run: runGraphQuery
    // Verify: output contains all three titles in tree format
}

test "graph query: index exclusion" {
    // Setup: art/a.md links to art/index/tags/foo.md and art/b.md
    // Run: runGraphQuery
    // Verify: b.md appears as child, index link does not
}

test "graph query: tags flag" {
    // Setup: art/a.md with [[t/foo](./index/tags/foo.md)]
    // Run: runGraphQuery with show_tags=true
    // Verify: "- foo" appears under a's title
}

test "graph query: cycle detection" {
    // Setup: art/a.md → art/b.md → art/a.md
    // Run: runGraphQuery
    // Verify: "(cycle)" appears in output
}

test "graph query: missing art directory" {
    // Run: runGraphQuery on dir without art/
    // Verify: error message, exit code 1
}
```

### Smoke Tests (scripts/smoke_test.sh)

```bash
test_query_graph() {
    local test_dir="$TEST_TMPDIR/test_query_graph"
    mkdir -p "$test_dir"

    # Initialize
    "$LIGI_BIN" init --root "$test_dir" >/dev/null 2>&1

    # Create test documents
    cat > "$test_dir/art/project.md" << 'EOF'
# My Project

See [getting started](./start.md) for setup.

Tagged: [[t/docs](./index/tags/docs.md)]
EOF

    cat > "$test_dir/art/start.md" << 'EOF'
# Getting Started

Read the [API docs](./api.md).
EOF

    cat > "$test_dir/art/api.md" << 'EOF'
# API Reference

Back to [project](./project.md).
EOF

    # Also create an index file that should be excluded
    mkdir -p "$test_dir/art/index/tags"
    echo "# docs tag" > "$test_dir/art/index/tags/docs.md"

    # Test basic graph
    local output
    output=$("$LIGI_BIN" q g --root "$test_dir" 2>&1)

    assert_contains "$output" "My Project" && \
    assert_contains "$output" "Getting Started" && \
    assert_contains "$output" "API Reference" && \
    assert_contains "$output" "(cycle)" && \
    assert_not_contains "$output" "docs tag" || return 1

    # Test with tags
    output=$("$LIGI_BIN" q g -t --root "$test_dir" 2>&1)

    assert_contains "$output" "- docs" || return 1

    echo "PASS: test_query_graph"
}
```

## Acceptance Criteria

- [ ] `ligi q g` prints a tree/forest of document titles derived from Markdown links
- [ ] Links to files under `art/index/**` are not followed as edges
- [ ] Tags are extracted from links matching `index/tags/*.md` pattern
- [ ] `-t/--tags` prints tags under each document title
- [ ] `-r/--root` allows specifying repository root
- [ ] `-h/--help` prints usage information
- [ ] Output is deterministic (same input → same output)
- [ ] Cycles are detected and marked with `(cycle)`
- [ ] Duplicate titles are disambiguated with path suffix
- [ ] Broken links (to non-existent files) are silently ignored
- [ ] Frontmatter in fenced code blocks is skipped when parsing titles
- [ ] Unit tests cover parsing, graph structure, and determinism
- [ ] Integration tests cover CLI behavior
- [ ] Smoke test verifies end-to-end functionality
