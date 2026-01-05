[[t/TODO]](index/tags/TODO.md)

# Ligi Table Rendering Implementation Plan

## Executive Summary

This plan adds a new `ligi table` command (alias `ligi tbl`) that converts CSV/JSONL data into Markdown tables, supports clipboard output, and introduces eager/lazy table rendering for data links in markdown. It also adds a reverse conversion (`ligi tbl --backward`) that turns a Markdown table into CSV/JSONL stored under `data/`, inserting a link to the data while preserving the table. The server UI will lazy-render tables for `lazy-render/` links in the browser, and the CLI will eagerly render `eager-render/` links into static Markdown tables.

## Goals

1. **CLI table generation**: `ligi tbl [path]` renders a Markdown table from CSV/JSONL; `-c/--clipboard` copies it, otherwise print to stdout.
2. **FZF selection**: If no path is provided, launch `fzf` to select a data file (CSV/JSONL) from `art/data/`.
3. **Lazy render in browser**: Links prefixed with `lazy-render/` are rendered into tables at view time in the local server UI.
4. **Eager render via CLI**: `ligi tbl --eager` expands links prefixed with `eager-render/` into static Markdown tables below the link.
5. **Backwards conversion**: `ligi tbl --backward` converts a Markdown table to CSV/JSONL, writes it under `art/data/`, inserts a link to that data, and leaves the original table intact.
6. **Data location**: All generated and referenced data lives in `art/data/`.
7. **KISS/DRY**: Share table parsing/rendering logic in a single module; keep CLI and server glue minimal.

## Non-Goals

- Full CSV dialect coverage beyond common RFC4180 cases.
- Spreadsheet-level formatting or styling controls.
- Client-side editing of tables in the browser.
- Auto-detection of the "right" table when multiple tables exist (explicit selection or error instead).
- Row limits or pagination (add later if performance becomes an issue).

## Data Flow

```
               ┌─────────────┐
               │   Table     │
               │   struct    │
               └──────┬──────┘
                      │
        ┌─────────────┼─────────────┐
        │             │             │
        ▼             ▼             ▼
   ┌─────────┐   ┌─────────┐   ┌─────────┐
   │   CSV   │   │  JSONL  │   │Markdown │
   │  bytes  │   │  bytes  │   │  table  │
   └─────────┘   └─────────┘   └─────────┘

parseCsv() ───────► Table ◄─────── parseJsonl()
                      │
                      ▼
              renderMarkdown()
              renderCsv()
              renderJsonl()
```

## User-Facing Behavior

### CLI Command

**Command**: `ligi table` (alias: `ligi tbl`)

> **Note**: The `template` command retains its `t` alias. Table uses `tbl` to avoid conflict.

**Flags**:
```
-h, --help              Show help message
-c, --clipboard         Copy output to clipboard (also prints to stdout)
-e, --eager             Eager render mode: expand eager-render/ links in markdown
-b, --backward          Backward conversion: markdown table to CSV/JSONL
-o, --output <name>     Output filename for -b (basename only)
-f, --format <fmt>      Output format for -b: csv (default) or jsonl
-t, --table <index>     Select table by index for -b (0-indexed)
<path>                  Input file or directory
```

**Examples**:
```bash
ligi tbl art/data/sales.csv           # Render CSV as markdown table
ligi tbl -c art/data/metrics.jsonl    # Render and copy to clipboard
ligi tbl -e art/                      # Expand all eager-render/ links in art/
ligi tbl -b art/report.md             # Convert first table to CSV in art/data/
ligi tbl -b art/report.md -t 2 -f jsonl -o metrics   # Convert 3rd table to JSONL
```

**Modes**:

1. **Default mode** (`ligi tbl [path]`):
   - Input: `.csv` or `.jsonl` file
   - Output: Markdown table on stdout
   - If path omitted, open `fzf` over `art/data/**/*.(csv|jsonl)`

2. **Eager render** (`ligi tbl --eager [path]`):
   - Input: markdown file or directory (recurses into subdirs)
   - Action: For each `eager-render/` link, insert table below and normalize link
   - If path omitted, open `fzf` over `art/**/*.md`
   - **Regeneration**: Running again replaces existing tables below links with freshly rendered versions

3. **Backward conversion** (`ligi tbl --backward [path]`):
   - Input: markdown file containing a table
   - Action: Convert table to CSV/JSONL, write to `art/data/`, insert link above table
   - If path omitted, open `fzf` over `art/**/*.md`
   - If multiple tables exist, error with list of table positions; user must specify `--table <index>`
   - **Regeneration**: Running again overwrites the existing data file; if link already exists above table, it is preserved

### Link Syntax

**Lazy render** (browser only):
```markdown
[Metrics](lazy-render/art/data/metrics.csv)
```
The UI strips the `lazy-render/` prefix, fetches `/api/file?path=art/data/metrics.csv`, and renders a table below the link.

**Eager render** (CLI):
```markdown
[Metrics](eager-render/art/data/metrics.csv)
```
After `ligi tbl --eager`, becomes:
```markdown
[Metrics](art/data/metrics.csv)

| col1 | col2 |
| ---- | ---- |
| a    | b    |
```

### Path Resolution

- Paths after `lazy-render/` or `eager-render/` are **relative to the serve root** (project root by default).
- Example: `lazy-render/art/data/foo.csv` resolves to `<project>/art/data/foo.csv`.
- The CLI validates paths stay within the project root (rejects `..` traversal).
- For backward conversion, output files are created under `art/data/` with sanitized names.

## Implementation Plan

### Phase 0: Spike (1-2 hours)

Before building CLI integration, validate the approach with isolated tests:

1. Write a minimal CSV parser that handles quoted fields
2. Write a minimal markdown table renderer
3. Test round-trip: `csv -> Table -> markdown -> Table -> csv`
4. Verify escaping works correctly for pipes and quotes

This catches design issues early before they're baked into the CLI.

### Phase 1: Data Directory Setup

Update `src/cli/commands/init.zig` to create `art/data/` alongside other special directories:

1. Add `"data"` to the list of subdirectories created under `art/`
2. Update `INITIAL_DATA_README` path references if needed
3. The existing `data/` at project root can remain for other purposes; `art/data/` is specifically for table data

### Phase 2: Table Module

Create `src/table/mod.zig` with submodules for parsing and rendering.

#### Table Struct

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Table = struct {
    headers: [][]const u8,
    rows: [][][]const u8,
    allocator: Allocator,

    pub fn deinit(self: *Table) void {
        for (self.headers) |h| self.allocator.free(h);
        self.allocator.free(self.headers);
        for (self.rows) |row| {
            for (row) |cell| self.allocator.free(cell);
            self.allocator.free(row);
        }
        self.allocator.free(self.rows);
    }

    pub fn columnCount(self: Table) usize {
        return self.headers.len;
    }

    pub fn rowCount(self: Table) usize {
        return self.rows.len;
    }
};
```

#### CSV Parser (`src/table/csv.zig`)

```zig
const core = @import("../core/mod.zig");

pub const ParseError = error{
    UnterminatedQuote,
    InvalidUtf8,
    OutOfMemory,
};

/// Parse CSV bytes into a Table.
/// Caller owns the returned Table and must call table.deinit().
/// Returns error context via core.Result on failure.
pub fn parse(allocator: Allocator, bytes: []const u8) core.Result(Table) {
    // Implementation details:
    // - First row is headers
    // - Handle quoted fields: "field with ""escaped"" quotes"
    // - Handle embedded commas and newlines in quoted fields
    // - Normalize CRLF to LF
    // - Trailing empty cells preserved
    // - Empty file -> Table with 0 headers, 0 rows
}
```

**CSV Parsing Rules**:
- Fields containing `,`, `"`, or newlines must be quoted
- Quotes inside quoted fields are escaped as `""`
- CRLF and LF both accepted as line terminators
- Trailing comma = empty final field
- Header row required (first line)

#### JSONL Parser (`src/table/jsonl.zig`)

```zig
pub const ParseError = error{
    InvalidJson,
    NonObjectLine,
    OutOfMemory,
};

/// Parse JSONL bytes into a Table.
/// Columns are the union of all keys, in first-seen order.
/// Nested objects/arrays are serialized as compact JSON strings.
/// Missing values in a row become null (empty string in Table).
pub fn parse(allocator: Allocator, bytes: []const u8) core.Result(Table) {
    // Implementation details:
    // - Skip blank lines
    // - Each non-blank line must be a JSON object
    // - Track column order as keys are encountered
    // - Nested values: {"foo": [1,2]} -> cell contains "[1,2]"
}
```

#### Markdown Table Parser (`src/table/markdown.zig`)

```zig
pub const ParseError = error{
    NoTableFound,
    InvalidTableFormat,
    OutOfMemory,
};

pub const TableLocation = struct {
    start_line: usize,
    end_line: usize,
    column_count: usize,
};

/// Find all tables in markdown content.
/// Returns locations for user selection when multiple tables exist.
pub fn findTables(allocator: Allocator, content: []const u8) ![]TableLocation {
    // A GFM table is identified by:
    // 1. A row with | separators (header)
    // 2. Immediately followed by a separator row matching: |?(\s*:?-+:?\s*\|)+\s*:?-+:?\s*|?
    // 3. Zero or more data rows with | separators
    // Table ends at blank line or non-table line
}

/// Parse a specific table from markdown content.
/// table_index is 0-indexed; use findTables() to discover available tables.
pub fn parse(allocator: Allocator, content: []const u8, table_index: usize) core.Result(Table) {
    // Implementation details:
    // - Trim leading/trailing | from each row (optional in GFM)
    // - Split cells on unescaped |
    // - Handle escaped pipes: \| -> |
    // - Trim whitespace from cells
    // - Pad short rows with empty cells to match header count
    // - Ignore alignment colons in separator row (:--, :-:, --:)
}
```

**GFM Table Detection Regex** (for documentation):
```
Header:    ^\|?(.+\|)+.+\|?$
Separator: ^\|?(\s*:?-+:?\s*\|)+\s*:?-+:?\s*\|?$
Data row:  ^\|?(.+\|)+.+\|?$
```

#### Renderers (`src/table/render.zig`)

```zig
/// Render Table as GFM markdown.
/// Caller owns returned slice and must free with allocator.
pub fn toMarkdown(allocator: Allocator, table: Table) ![]u8 {
    // - Escape | as \|
    // - Escape \ as \\
    // - Replace newlines in cells with <br>
    // - Generate separator row with ---
    // - Always include leading/trailing pipes for clarity
}

/// Render Table as CSV (RFC4180).
/// Uses CRLF line endings per spec.
pub fn toCsv(allocator: Allocator, table: Table) ![]u8 {
    // - Quote fields containing: comma, quote, newline
    // - Escape quotes as ""
    // - CRLF line endings
}

/// Render Table as JSONL.
/// Each row becomes a JSON object with header keys.
/// Empty cells become null in JSON output.
pub fn toJsonl(allocator: Allocator, table: Table) ![]u8 {
    // - One JSON object per line
    // - Keys from headers
    // - Empty cell -> null (not "" or omitted)
    // - LF line endings (JSONL convention)
}
```

#### Module Root (`src/table/mod.zig`)

```zig
pub const csv = @import("csv.zig");
pub const jsonl = @import("jsonl.zig");
pub const markdown = @import("markdown.zig");
pub const render = @import("render.zig");

pub const Table = @import("table.zig").Table;
```

### Phase 2: CLI Command

#### Registry Update (`src/cli/registry.zig`)

Add to `COMMANDS` array:
```zig
.{
    .canonical = "table",
    .names = &.{ "table", "tbl" },
    .description = "Convert between CSV/JSONL and Markdown tables",
    .long_description =
        \\Render data files as Markdown tables, or convert tables back to data.
        \\
        \\Usage:
        \\  ligi tbl [path]           Render CSV/JSONL as Markdown table
        \\  ligi tbl -e [path]        Expand eager-render/ links in markdown
        \\  ligi tbl -b [path]        Convert markdown table to CSV/JSONL
        \\
        \\If path is omitted, opens fzf for file selection.
    ,
},
```

Add dispatch in `run()`:
```zig
"table", "tbl" => return runTableCommand(allocator, iter, stdout, stderr),
```

#### Command Implementation (`src/cli/commands/table.zig`)

```zig
const std = @import("std");
const clap = @import("clap");
const table = @import("../../table/mod.zig");
const core = @import("../../core/mod.zig");
const clipboard = @import("../../template/clipboard.zig");

const TableParams = clap.parseParamsComptime(
    \\-h, --help              Show this help message
    \\-c, --clipboard         Copy output to clipboard
    \\-e, --eager             Eager render: expand eager-render/ links
    \\-b, --backward          Backward: convert markdown table to data
    \\-o, --output <str>      Output filename for -b
    \\-f, --format <str>      Output format: csv (default) or jsonl
    \\-t, --table <usize>     Table index for -b (0-indexed)
    \\<path>                  Input file or directory
    \\
);

pub fn run(
    allocator: std.mem.Allocator,
    args: anytype,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var parser = clap.parse(TableParams, args, .{}) catch |err| {
        try stderr.print("error: {}\n", .{err});
        return 1;
    };
    defer parser.deinit();

    if (parser.args.help) {
        try printHelp(stdout);
        return 0;
    }

    const path = parser.positionals[0] orelse try resolveFzf(allocator, parser.args);

    if (parser.args.eager) {
        return runEagerRender(allocator, path, stdout, stderr);
    } else if (parser.args.backward) {
        return runBackward(allocator, path, parser.args, stdout, stderr);
    } else {
        return runRender(allocator, path, parser.args, stdout, stderr);
    }
}

fn runRender(allocator: Allocator, path: []const u8, args: anytype, stdout: anytype, stderr: anytype) !u8 {
    // 1. Validate extension is .csv or .jsonl
    // 2. Read file
    // 3. Parse based on extension
    // 4. Render to markdown
    // 5. Write to stdout
    // 6. If --clipboard, copy to clipboard
}

fn runEagerRender(allocator: Allocator, path: []const u8, stdout: anytype, stderr: anytype) !u8 {
    // 1. If directory, recurse; if file, process single
    // 2. Find eager-render/ links
    // 3. For each link:
    //    a. Resolve data path
    //    b. Parse data file
    //    c. Render markdown table
    //    d. Insert table below link
    //    e. Normalize link (remove eager-render/ prefix)
    // 4. Write modified file
}

fn runBackward(allocator: Allocator, path: []const u8, args: anytype, stdout: anytype, stderr: anytype) !u8 {
    // 1. Read markdown file
    // 2. Find tables
    // 3. If multiple tables and no --table flag, error with list
    // 4. Parse selected table
    // 5. Determine output format (--format or infer from --output)
    // 6. Render to data format
    // 7. Write to art/data/<output>.csv or .jsonl
    // 8. Insert link above table in markdown
    // 9. If --clipboard, copy data to clipboard
}

fn resolveFzf(allocator: Allocator, args: anytype) ![]const u8 {
    // Determine search path based on mode:
    // - Default: art/data/**/*.{csv,jsonl}
    // - Eager/backward: art/**/*.md
    // Shell out to: find <path> -type f \( -name '*.csv' -o -name '*.jsonl' \) | fzf
    // Return selected path or error.FzfCancelled
}
```

#### FZF Helper

Extract shared FZF logic to `src/core/fzf.zig` (used by both template and table commands):

```zig
pub const FzfError = error{
    FzfNotFound,
    FzfCancelled,
    SpawnFailed,
};

/// Run fzf with the given find command and return selected path.
pub fn selectFile(allocator: Allocator, find_args: []const []const u8) FzfError![]const u8 {
    // 1. Spawn: find <args> | fzf
    // 2. Read stdout for selection
    // 3. Return trimmed path or error
}
```

### Phase 3: Eager Rendering

#### Link Detection

Regex pattern for eager-render links:
```
\[([^\]]+)\]\(eager-render/([^)]+)\)
```

Capture groups:
1. Link label
2. Data path (relative to project root)

#### Table Insertion

Insert the rendered table on the line immediately following the link:

**Before**:
```markdown
Some text.

[Sales Data](eager-render/art/data/sales.csv)

More text.
```

**After**:
```markdown
Some text.

[Sales Data](art/data/sales.csv)

| Product | Revenue |
| ------- | ------- |
| A       | 100     |
| B       | 200     |

More text.
```

**Idempotency & Regeneration**: Running `ligi tbl -e` multiple times is safe and will refresh tables from their data sources:
1. If link still has `eager-render/` prefix: render table, normalize link
2. If link is already normalized (no prefix) and a table exists directly below (within 2 lines): **replace the table** with freshly rendered content from the linked data file
3. Detection: next non-blank line starts with `|`

This allows updating tables when source data changes without manual intervention. No HTML comment markers are used, avoiding compatibility issues with markdown renderers.

#### Directory Recursion

When `--eager` receives a directory:
1. Walk directory recursively
2. Process all `.md` files
3. Skip hidden directories (`.git`, `.cache`, etc.)
4. Report: "Processed N files, expanded M tables"

### Phase 4: Backward Conversion

#### Multiple Table Handling

When a file contains multiple tables:

```
error: found 3 tables in document.md
  table 0: line 15, 4 columns (Product, Price, Qty, Total)
  table 1: line 45, 2 columns (Date, Event)
  table 2: line 78, 3 columns (Name, Role, Email)

Use --table <index> to select one.
```

#### Link Insertion

Insert the data link on a new line directly above the table:

**Before**:
```markdown
Here are the results:

| A | B |
|---|---|
| 1 | 2 |
```

**After** (`ligi tbl -b doc.md -o results`):
```markdown
Here are the results:

[results](art/data/results.csv)

| A | B |
|---|---|
| 1 | 2 |
```

#### Output Filename Resolution

1. If `--output results.csv` specified: use `art/data/results.csv`
2. If `--output results` specified: use `art/data/results.<format>` (csv default)
3. If `--output` omitted: derive from input filename (`doc.md` -> `art/data/doc.csv`)
4. Reject `--output` containing path separators (`/`, `\`)
5. Sanitize filename: replace spaces with `_`, remove special chars

#### Regeneration Behavior

Running `ligi tbl -b` on a file that already has a data link above the table:
1. **Data file**: Overwritten with current table contents
2. **Link in markdown**: Preserved as-is (not duplicated)
3. **Table in markdown**: Preserved as-is (never modified by backward conversion)

This allows re-exporting a table after manual edits without creating duplicate links.

### Phase 5: Lazy Rendering (Browser)

#### Server Changes

**`src/serve/path.zig`**: Add to `AllowedExtension`:
```zig
pub const AllowedExtension = enum {
    md,
    markdown,
    png,
    jpg,
    // ... existing ...
    csv,
    jsonl,
};
```

**`src/serve/assets.zig`**: Add MIME types:
```zig
".csv" => "text/csv; charset=utf-8",
".jsonl" => "application/x-ndjson; charset=utf-8",
```

#### JavaScript Implementation

Create `src/serve/assets/table-renderer.js`:

```javascript
// Minimal CSV parser (handles quotes, commas, newlines)
function parseCsv(text) {
    const rows = [];
    let current = [];
    let cell = '';
    let inQuotes = false;

    for (let i = 0; i < text.length; i++) {
        const ch = text[i];
        if (inQuotes) {
            if (ch === '"' && text[i + 1] === '"') {
                cell += '"';
                i++;
            } else if (ch === '"') {
                inQuotes = false;
            } else {
                cell += ch;
            }
        } else {
            if (ch === '"') {
                inQuotes = true;
            } else if (ch === ',') {
                current.push(cell);
                cell = '';
            } else if (ch === '\n' || (ch === '\r' && text[i + 1] === '\n')) {
                if (ch === '\r') i++;
                current.push(cell);
                if (current.length > 0 || current.some(c => c)) rows.push(current);
                current = [];
                cell = '';
            } else {
                cell += ch;
            }
        }
    }
    if (cell || current.length) {
        current.push(cell);
        rows.push(current);
    }
    return rows;
}

// Minimal JSONL parser
function parseJsonl(text) {
    const lines = text.split('\n').filter(l => l.trim());
    const objects = lines.map(l => JSON.parse(l));
    const headers = [...new Set(objects.flatMap(o => Object.keys(o)))];
    const rows = objects.map(o => headers.map(h => {
        const v = o[h];
        if (v === undefined || v === null) return '';
        if (typeof v === 'object') return JSON.stringify(v);
        return String(v);
    }));
    return [headers, ...rows];
}

// Render HTML table
function renderTable(rows) {
    if (!rows.length) return '<p><em>Empty data file</em></p>';
    const [headers, ...data] = rows;
    return `<table class="ligi-table">
        <thead><tr>${headers.map(h => `<th>${escapeHtml(h)}</th>`).join('')}</tr></thead>
        <tbody>${data.map(row =>
            `<tr>${row.map(cell => `<td>${escapeHtml(cell)}</td>`).join('')}</tr>`
        ).join('')}</tbody>
    </table>`;
}

function escapeHtml(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// Process lazy-render links after markdown render
function processLazyRenderLinks() {
    document.querySelectorAll('a[href^="lazy-render/"]').forEach(async link => {
        const dataPath = link.getAttribute('href').replace('lazy-render/', '');
        link.setAttribute('href', dataPath);

        const container = document.createElement('div');
        container.className = 'ligi-table-container';
        container.innerHTML = '<p><em>Loading table...</em></p>';
        link.parentNode.insertBefore(container, link.nextSibling);

        try {
            const resp = await fetch(`/api/file?path=${encodeURIComponent(dataPath)}`);
            if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
            const text = await resp.text();
            const rows = dataPath.endsWith('.jsonl') ? parseJsonl(text) : parseCsv(text);
            container.innerHTML = renderTable(rows);
        } catch (err) {
            container.innerHTML = `<p class="error">Failed to load table: ${escapeHtml(err.message)}</p>`;
        }
    });
}

// Export for app.js
window.ligiTableRenderer = { processLazyRenderLinks };
```

**`src/serve/assets/app.js`**: Add after markdown render:
```javascript
// After marked renders the markdown...
if (window.ligiTableRenderer) {
    window.ligiTableRenderer.processLazyRenderLinks();
}
```

**`src/serve/assets/styles.css`**: Add table styles:
```css
.ligi-table {
    border-collapse: collapse;
    margin: 1em 0;
    width: 100%;
}
.ligi-table th, .ligi-table td {
    border: 1px solid #ddd;
    padding: 8px;
    text-align: left;
}
.ligi-table th {
    background: #f5f5f5;
}
.ligi-table-container .error {
    color: #c00;
}
```

## Error Messages

All error conditions should produce actionable messages:

```
error: unsupported file extension '.xlsx'
  expected: .csv or .jsonl
  hint: convert your file to CSV first

error: path '../../../etc/passwd' contains directory traversal
  paths must stay within the project root

error: file 'art/data/missing.csv' not found
  working directory: /home/user/project

error: found 3 tables in document.md
  table 0: line 15, 4 columns (Product, Price, Qty, Total)
  table 1: line 45, 2 columns (Date, Event)
  table 2: line 78, 3 columns (Name, Role, Email)
  use --table <index> to select one

error: invalid CSV at line 5
  unterminated quoted field

error: invalid JSONL at line 3
  expected object, got array

error: fzf not found
  install fzf: https://github.com/junegunn/fzf#installation

error: clipboard copy failed
  install one of: wl-copy, xclip, xsel

error: output filename 'foo/bar' contains path separator
  use --output with basename only (e.g., --output bar)
```

## Edge Cases

| Case | Handling |
|------|----------|
| Empty CSV/JSONL file | Return Table with 0 headers, 0 rows; render as empty table |
| CSV with only headers | Table with headers, 0 rows |
| JSONL with invalid line | Error with line number |
| JSONL with non-object | Error: "expected object, got <type>" |
| Markdown table with inconsistent columns | Pad short rows with empty cells |
| Multiple tables in file | Error with list; require `--table` flag |
| Escaped pipe in cell | Unescape when parsing, re-escape when rendering |
| Newline in CSV cell | Preserve in Table; render as `<br>` in markdown |
| Unicode in data | Pass through unchanged (UTF-8) |
| Very wide table (50+ columns) | Render anyway; let markdown viewer handle scroll |
| Nested JSON in JSONL | Serialize to compact JSON string in cell |
| Missing JSONL keys | Cell value is empty string |
| Path outside project | Error with traversal message |
| `art/data/` doesn't exist | Create it automatically or prompt user to run `ligi init` |
| fzf not installed | Clear error with install link |
| Clipboard tools missing | Clear error listing tools to install |
| Eager render on already-processed link | Detect table below, replace with fresh render |
| Backward on table with existing link above | Overwrite data file, preserve link |
| Data file already exists (backward) | Overwrite without prompting |

## Test Plan

### Test Fixtures

Create `src/table/test_data/`:

```
test_data/
├── simple.csv              # Basic 3x3 table
├── quoted.csv              # Fields with quotes, commas, newlines
├── unicode.csv             # Non-ASCII characters, emoji
├── empty.csv               # Empty file
├── headers_only.csv        # Just header row
├── trailing_comma.csv      # Rows ending with comma
├── crlf.csv                # Windows line endings
├── simple.jsonl            # Basic objects
├── nested.jsonl            # Objects with nested arrays/objects
├── sparse.jsonl            # Objects with different keys
├── invalid_json.jsonl      # Line with syntax error
├── non_object.jsonl        # Line with array instead of object
├── simple_table.md         # Single GFM table
├── multiple_tables.md      # Three tables
├── no_outer_pipes.md       # Table without leading/trailing |
├── escaped_pipes.md        # Table with \| in cells
└── eager_links.md          # Document with eager-render/ links
```

### Unit Tests (Zig)

**CSV Parser** (`src/table/csv.zig`):
```zig
test "parse simple csv" { ... }
test "parse quoted fields with escaped quotes" { ... }
test "parse fields with commas" { ... }
test "parse fields with newlines" { ... }
test "parse crlf line endings" { ... }
test "parse trailing comma as empty cell" { ... }
test "parse empty file returns empty table" { ... }
test "parse headers only" { ... }
test "parse unicode content" { ... }
test "error on unterminated quote" { ... }
```

**JSONL Parser** (`src/table/jsonl.zig`):
```zig
test "parse simple jsonl" { ... }
test "parse with nested objects" { ... }
test "parse sparse objects (different keys)" { ... }
test "column order is first-seen" { ... }
test "skip blank lines" { ... }
test "error on invalid json" { ... }
test "error on non-object line" { ... }
```

**Markdown Parser** (`src/table/markdown.zig`):
```zig
test "find single table" { ... }
test "find multiple tables" { ... }
test "parse table with outer pipes" { ... }
test "parse table without outer pipes" { ... }
test "parse escaped pipes" { ... }
test "pad short rows" { ... }
test "ignore alignment markers" { ... }
test "error when no table found" { ... }
```

**Renderers** (`src/table/render.zig`):
```zig
test "render markdown escapes pipes" { ... }
test "render markdown escapes backslashes" { ... }
test "render markdown converts newlines to br" { ... }
test "render csv quotes special fields" { ... }
test "render csv uses crlf" { ... }
test "render jsonl with null for empty" { ... }
```

**Round-trip Tests**:
```zig
test "csv round-trip preserves values" {
    const original = @embedFile("test_data/simple.csv");
    const t = try csv.parse(allocator, original);
    defer t.deinit();
    const rendered = try render.toCsv(allocator, t);
    defer allocator.free(rendered);
    const t2 = try csv.parse(allocator, rendered);
    defer t2.deinit();
    // Compare table contents (not byte-exact, but value-equal)
}

test "jsonl round-trip preserves values" { ... }
test "markdown round-trip preserves values" { ... }
```

### Integration Tests

**CLI Tests** (in `src/testing/`):
```zig
test "ligi tbl renders csv to stdout" {
    const result = try runCommand(&.{ "tbl", "art/data/simple.csv" });
    try expectContains(result.stdout, "| col1 | col2 |");
    try expectEqual(result.exit_code, 0);
}

test "ligi tbl --eager expands links" { ... }
test "ligi tbl --eager regenerates existing tables" { ... }
test "ligi tbl --backward creates data file in art/data/" { ... }
test "ligi tbl --backward overwrites existing data file" { ... }
test "ligi tbl --backward preserves existing link" { ... }
test "ligi tbl errors on invalid extension" { ... }
test "ligi tbl errors on path traversal" { ... }
```

**Server Tests**:
```zig
test "serve csv file returns correct mime type" {
    const resp = try httpGet("/api/file?path=art/data/test.csv");
    try expectEqual(resp.status, 200);
    try expectContains(resp.headers.get("Content-Type"), "text/csv");
}
```

### JavaScript Tests

Create `src/serve/assets/table-renderer.test.js` (run with Node or browser test runner):

```javascript
describe('parseCsv', () => {
    it('parses simple csv', () => { ... });
    it('handles quoted fields', () => { ... });
    it('handles embedded newlines', () => { ... });
});

describe('parseJsonl', () => {
    it('parses simple jsonl', () => { ... });
    it('handles nested objects', () => { ... });
    it('collects all keys as headers', () => { ... });
});
```

### Manual Smoke Tests

1. `ligi tbl` with fzf selection
2. `ligi tbl art/data/sample.csv -c` (clipboard)
3. `ligi tbl -e art/` (recursive eager render)
4. `ligi tbl -b doc.md -t 1` (backward conversion of second table)
5. `ligi serve` with lazy-render links
6. Error handling: missing file, bad extension, no fzf

## File Changes Summary

| File | Change |
|------|--------|
| `src/cli/registry.zig` | Add `table`/`tbl` command, add dispatch |
| `src/cli/commands/table.zig` | New file: command implementation |
| `src/cli/commands/init.zig` | Create `art/data/` directory on init |
| `src/table/mod.zig` | New file: module root |
| `src/table/table.zig` | New file: Table struct |
| `src/table/csv.zig` | New file: CSV parser |
| `src/table/jsonl.zig` | New file: JSONL parser |
| `src/table/markdown.zig` | New file: Markdown table parser |
| `src/table/render.zig` | New file: renderers |
| `src/core/fzf.zig` | New file: shared fzf helper |
| `src/core/mod.zig` | Export fzf module |
| `src/serve/path.zig` | Add `.csv`, `.jsonl` to allowed extensions |
| `src/serve/assets.zig` | Add MIME types, embed table-renderer.js |
| `src/serve/assets/table-renderer.js` | New file: JS table rendering |
| `src/serve/assets/app.js` | Call table renderer after markdown render |
| `src/serve/assets/styles.css` | Add table styles |
| `src/table/test_data/*` | New files: test fixtures |

## Decisions Made

These questions from the original plan are now resolved:

1. **Should `--eager` accept directories?**
   Yes, recurse into subdirectories, processing all `.md` files.

2. **Multiple tables in backward conversion?**
   Error with a list of table positions; require `--table <index>` to select.

3. **JSONL missing values?**
   Emit as `null` in JSON output. This is semantically correct and round-trips cleanly.

4. **Max rows limit?**
   Not implemented in v1. Add later if performance becomes an issue.
