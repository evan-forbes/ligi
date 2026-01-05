# Browser Table Rendering Enhancement Plan

## Executive Summary

This plan enhances the browser-based lazy table rendering to handle large datasets with smooth performance and rich interactivity. It replaces the simple HTML table from the base implementation with a virtualized, feature-rich table component that supports sorting, filtering, sticky headers, cell expansion, copy functionality, and Google Docs export.

## Prerequisites

This plan assumes the base `ligi table` implementation is complete, specifically:
- `lazy-render/` link detection in `app.js`
- CSV/JSONL fetching via `/api/file`
- Basic `parseCsv()` and `parseJsonl()` functions in JS

## Goals

1. **Performance**: Render 10,000+ row tables smoothly via virtualization
2. **Navigation**: Sticky headers, horizontal scroll with frozen first column
3. **Interactivity**: Column sorting, row filtering, cell expansion
4. **Data extraction**: Copy cells/rows, export to Google Docs-compatible format
5. **Progressive enhancement**: Small tables (<100 rows) render simply; features activate for larger tables
6. **Zero dependencies**: Pure JS/CSS, no external libraries

## Non-Goals

- Inline cell editing
- Column reordering via drag-and-drop
- Pivot tables or aggregations
- Chart generation from table data
- Server-side filtering/sorting (all client-side)

## Feature Specifications

### 1. Virtualized Scrolling

**Problem**: Rendering 10k rows as DOM elements freezes the browser.

**Solution**: Only render visible rows + buffer. Maintain a fixed-height container with a tall "spacer" element to preserve scroll position.

```
┌─────────────────────────────┐
│ Header Row (sticky)         │ <- Always visible
├─────────────────────────────┤
│ [spacer: 0-999 rows]        │ <- Empty div with calculated height
│ Row 1000                    │ <- First rendered row
│ Row 1001                    │
│ Row 1002                    │    Viewport
│ ...                         │    (visible area)
│ Row 1024                    │
│ [spacer: 1025-9999 rows]    │ <- Empty div with calculated height
└─────────────────────────────┘
```

**Parameters**:
- `ROW_HEIGHT = 36px` (fixed row height for calculation)
- `BUFFER_ROWS = 10` (render 10 rows above/below viewport)
- `VIRTUALIZATION_THRESHOLD = 100` (only virtualize if >100 rows)

**Scroll handler**:
```javascript
function onScroll(scrollTop) {
    const startIdx = Math.floor(scrollTop / ROW_HEIGHT) - BUFFER_ROWS;
    const visibleCount = Math.ceil(containerHeight / ROW_HEIGHT) + BUFFER_ROWS * 2;
    renderRows(Math.max(0, startIdx), Math.min(totalRows, startIdx + visibleCount));
}
```

### 2. Sticky Headers

**Behavior**: Header row stays fixed at top of table container while scrolling vertically.

**CSS approach**:
```css
.ligi-table-container {
    max-height: 70vh;
    overflow-y: auto;
    position: relative;
}

.ligi-table thead {
    position: sticky;
    top: 0;
    z-index: 10;
    background: var(--header-bg);
}
```

**With virtualization**: Header is rendered outside the virtualized body as a separate element that doesn't scroll.

### 3. Horizontal Scroll with Frozen First Column

**Behavior**: When table is wider than container, horizontal scroll appears. First column stays fixed.

**Structure**:
```html
<div class="ligi-table-wrapper">
    <div class="ligi-frozen-column">
        <!-- First column cells, synced with main scroll -->
    </div>
    <div class="ligi-scrollable-area">
        <!-- Remaining columns, horizontally scrollable -->
    </div>
</div>
```

**Sync scrolling**: When main area scrolls vertically, frozen column scrolls too:
```javascript
scrollableArea.addEventListener('scroll', () => {
    frozenColumn.scrollTop = scrollableArea.scrollTop;
});
```

**CSS**:
```css
.ligi-table-wrapper {
    display: flex;
    max-width: 100%;
}

.ligi-frozen-column {
    flex-shrink: 0;
    position: sticky;
    left: 0;
    z-index: 5;
    background: var(--bg);
    border-right: 2px solid var(--border);
}

.ligi-scrollable-area {
    overflow-x: auto;
    flex: 1;
}
```

**Toggle**: Only freeze first column if table has >3 columns and is wider than container.

### 4. Column Sorting

**Behavior**: Click column header to sort. First click = ascending, second = descending, third = original order.

**UI**:
```
| Name ▲ | Age | City    |   <- ▲ indicates ascending sort on Name
|--------|-----|---------|
| Alice  | 30  | Boston  |
| Bob    | 25  | Chicago |
```

**Sort indicators**: `▲` (asc), `▼` (desc), none (original)

**Sort logic**:
```javascript
function sortBy(columnIndex, direction) {
    const sorted = [...rows].sort((a, b) => {
        const valA = a[columnIndex];
        const valB = b[columnIndex];

        // Numeric comparison if both parse as numbers
        const numA = parseFloat(valA);
        const numB = parseFloat(valB);
        if (!isNaN(numA) && !isNaN(numB)) {
            return direction === 'asc' ? numA - numB : numB - numA;
        }

        // String comparison (case-insensitive)
        return direction === 'asc'
            ? valA.localeCompare(valB)
            : valB.localeCompare(valA);
    });
    return sorted;
}
```

**State**:
```javascript
let sortState = { column: null, direction: null }; // null | 'asc' | 'desc'
```

### 5. Filter/Search

**Behavior**: Text input filters rows to those containing the search term (case-insensitive, searches all columns).

**UI**:
```
┌─────────────────────────────────────┐
│ 🔍 Filter: [search term____] [Clear]│  <- Input above table
│ Showing 47 of 2,847 rows            │  <- Result count
├─────────────────────────────────────┤
│ | Name | Age | City |               │
│ |------|-----|------|               │
```

**Filter logic**:
```javascript
function filterRows(rows, searchTerm) {
    if (!searchTerm.trim()) return rows;
    const term = searchTerm.toLowerCase();
    return rows.filter(row =>
        row.some(cell => cell.toLowerCase().includes(term))
    );
}
```

**Debounce**: Filter after 150ms of no typing to avoid lag on large tables.

**Column-specific filter** (future enhancement): `column:value` syntax, e.g., `name:alice`.

### 6. Expandable Cells

**Problem**: Long cell content (e.g., JSON, URLs, descriptions) breaks table layout.

**Solution**: Truncate cells beyond a threshold, show full content on click.

**Truncation rules**:
- Max width: `200px` per cell
- Max lines: 2
- Overflow: `...` with expansion indicator

**UI states**:

*Collapsed* (default):
```
| description                    |
|--------------------------------|
| This is a very long text th... |  <- Truncated with hover hint
```

*Expanded* (after click):
```
| description                              |
|------------------------------------------|
| This is a very long text that contains   |
| multiple lines and goes on for quite a   |
| while with lots of detail...             |  <- Full content, click to collapse
```

**Implementation**:
```javascript
function renderCell(content, maxLength = 100) {
    const needsTruncation = content.length > maxLength;
    if (!needsTruncation) return escapeHtml(content);

    return `
        <span class="ligi-cell-truncated" data-full="${escapeAttr(content)}">
            ${escapeHtml(content.slice(0, maxLength))}...
            <button class="ligi-expand-btn" title="Expand">⤢</button>
        </span>
    `;
}
```

**Expanded view**: Clicking opens a modal/popover for very long content (>500 chars) or expands inline for moderate content.

### 7. Copy Cell/Row

**Behavior**: Click cell to copy its value. Right-click row for copy options.

**Cell copy**:
- Single click: Copy cell value to clipboard
- Visual feedback: Brief highlight + "Copied!" toast

**Row copy** (context menu or button):
- Copy as TSV (tab-separated, for spreadsheet paste)
- Copy as JSON object
- Copy as CSV row

**Implementation**:
```javascript
async function copyToClipboard(text, format = 'text') {
    try {
        await navigator.clipboard.writeText(text);
        showToast('Copied!');
    } catch (err) {
        // Fallback for older browsers
        fallbackCopy(text);
    }
}

function rowToTsv(row) {
    return row.join('\t');
}

function rowToJson(headers, row) {
    const obj = {};
    headers.forEach((h, i) => obj[h] = row[i]);
    return JSON.stringify(obj);
}
```

**UI**:
```
┌──────────────────────────────────────┐
│ | Name  | Age |  [Copy All] [Export] │  <- Header actions
│ |-------|-----|                      │
│ | Alice | 30  | [📋]                 │  <- Row copy button (appears on hover)
│ | Bob   | 25  | [📋]                 │
```

### 8. Google Docs Export

**Goal**: One-click export that pastes cleanly into Google Docs/Sheets.

**Approach**: Google Sheets accepts TSV (tab-separated values) from clipboard. Google Docs accepts HTML tables.

**Export options**:

1. **Copy for Google Sheets**:
   - Format: TSV with headers
   - User pastes with Ctrl+V into Sheets

2. **Copy for Google Docs**:
   - Format: HTML table
   - User pastes with Ctrl+V into Docs

3. **Download CSV**:
   - Triggers file download
   - Can be imported into Sheets via File > Import

**Implementation**:
```javascript
function exportForSheets(headers, rows) {
    const tsv = [headers.join('\t'), ...rows.map(r => r.join('\t'))].join('\n');
    copyToClipboard(tsv);
    showToast('Copied! Paste into Google Sheets with Ctrl+V');
}

function exportForDocs(headers, rows) {
    const html = `
        <table>
            <tr>${headers.map(h => `<th>${escapeHtml(h)}</th>`).join('')}</tr>
            ${rows.map(row =>
                `<tr>${row.map(cell => `<td>${escapeHtml(cell)}</td>`).join('')}</tr>`
            ).join('')}
        </table>
    `;
    copyHtmlToClipboard(html);
    showToast('Copied! Paste into Google Docs with Ctrl+V');
}

function downloadCsv(headers, rows, filename) {
    const csv = [
        headers.map(h => csvEscape(h)).join(','),
        ...rows.map(row => row.map(cell => csvEscape(cell)).join(','))
    ].join('\r\n');

    const blob = new Blob([csv], { type: 'text/csv' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename || 'export.csv';
    a.click();
    URL.revokeObjectURL(url);
}

// Copy HTML to clipboard (for rich paste)
async function copyHtmlToClipboard(html) {
    const blob = new Blob([html], { type: 'text/html' });
    await navigator.clipboard.write([
        new ClipboardItem({ 'text/html': blob })
    ]);
}
```

**Export UI**:
```
┌────────────────────────────────────────────┐
│ [Export ▼]                                 │
│ ┌────────────────────────────────────────┐ │
│ │ 📋 Copy for Google Sheets              │ │
│ │ 📋 Copy for Google Docs                │ │
│ │ 💾 Download CSV                        │ │
│ │ 💾 Download JSONL                      │ │
│ └────────────────────────────────────────┘ │
```

**Filtered export**: If filter is active, only export visible rows. Show "(filtered)" in filename.

## UI Component Structure

```
ligi-table-container
├── ligi-table-toolbar
│   ├── ligi-filter-input
│   ├── ligi-row-count
│   └── ligi-export-dropdown
├── ligi-table-wrapper
│   ├── ligi-frozen-column (optional)
│   │   ├── ligi-frozen-header
│   │   └── ligi-frozen-body
│   └── ligi-scrollable-area
│       ├── ligi-table-header (sticky)
│       └── ligi-table-body (virtualized)
└── ligi-table-footer
    └── ligi-pagination (if not virtualized)
```

## Progressive Enhancement Tiers

| Table Size | Rendering Strategy |
|------------|-------------------|
| 1-50 rows | Simple HTML table, all features except virtualization |
| 51-100 rows | Simple HTML table + pagination option |
| 101-1000 rows | Virtualized scrolling, all features |
| 1000+ rows | Virtualized + "Load more" chunks of 1000 |

**Detection**:
```javascript
function chooseRenderStrategy(rowCount) {
    if (rowCount <= 50) return 'simple';
    if (rowCount <= 100) return 'simple-paginated';
    if (rowCount <= 1000) return 'virtualized';
    return 'virtualized-chunked';
}
```

## File Structure

```
src/serve/assets/
├── table/
│   ├── table-renderer.js      # Main entry, orchestrates components
│   ├── virtual-scroller.js    # Virtualization logic
│   ├── table-sorter.js        # Sorting logic
│   ├── table-filter.js        # Filter logic
│   ├── table-export.js        # Export/copy functions
│   ├── cell-expander.js       # Expandable cell logic
│   └── table-styles.css       # All table-specific styles
├── app.js                     # Imports and initializes table renderer
└── styles.css                 # General app styles
```

**Bundling**: Since ligi uses `@embedFile`, all JS will be concatenated into a single file at build time. Structure is for maintainability.

**Actual implementation**: Single file `table-renderer.js` with clearly separated sections:
```javascript
// === PARSING ===
function parseCsv(text) { ... }
function parseJsonl(text) { ... }

// === VIRTUALIZATION ===
class VirtualScroller { ... }

// === SORTING ===
function sortRows(rows, column, direction) { ... }

// === FILTERING ===
function filterRows(rows, term) { ... }

// === EXPORT ===
function exportForSheets(headers, rows) { ... }
function exportForDocs(headers, rows) { ... }
function downloadCsv(headers, rows, filename) { ... }

// === CELL EXPANSION ===
function renderCell(content) { ... }
function expandCell(cell) { ... }

// === COPY ===
function copyCell(cell) { ... }
function copyRow(row, format) { ... }

// === MAIN RENDERER ===
class TableRenderer { ... }

// === INITIALIZATION ===
function processLazyRenderLinks() { ... }
window.ligiTableRenderer = { processLazyRenderLinks };
```

## CSS Design

**Theme variables** (integrate with existing ligi theme):
```css
:root {
    --table-bg: #fff;
    --table-header-bg: #f5f5f5;
    --table-border: #ddd;
    --table-row-hover: #f9f9f9;
    --table-row-alt: #fafafa;
    --table-sort-active: #0066cc;
    --table-filter-match: #fff3cd;
}

@media (prefers-color-scheme: dark) {
    :root {
        --table-bg: #1e1e1e;
        --table-header-bg: #2d2d2d;
        --table-border: #444;
        --table-row-hover: #2a2a2a;
        --table-row-alt: #242424;
        --table-sort-active: #4da6ff;
        --table-filter-match: #3d3000;
    }
}
```

**Core styles** (~150 lines):
```css
.ligi-table-container {
    margin: 1em 0;
    border: 1px solid var(--table-border);
    border-radius: 4px;
    overflow: hidden;
}

.ligi-table-toolbar {
    display: flex;
    align-items: center;
    gap: 1em;
    padding: 0.5em 1em;
    background: var(--table-header-bg);
    border-bottom: 1px solid var(--table-border);
}

.ligi-filter-input {
    flex: 1;
    max-width: 300px;
    padding: 0.4em 0.8em;
    border: 1px solid var(--table-border);
    border-radius: 4px;
}

.ligi-table-wrapper {
    max-height: 70vh;
    overflow: auto;
}

.ligi-table {
    width: 100%;
    border-collapse: collapse;
}

.ligi-table th {
    position: sticky;
    top: 0;
    background: var(--table-header-bg);
    padding: 0.6em 1em;
    text-align: left;
    font-weight: 600;
    border-bottom: 2px solid var(--table-border);
    cursor: pointer;
    user-select: none;
}

.ligi-table th:hover {
    background: var(--table-row-hover);
}

.ligi-table th .sort-indicator {
    margin-left: 0.5em;
    opacity: 0.5;
}

.ligi-table th.sorted .sort-indicator {
    opacity: 1;
    color: var(--table-sort-active);
}

.ligi-table td {
    padding: 0.5em 1em;
    border-bottom: 1px solid var(--table-border);
    max-width: 200px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.ligi-table tr:hover td {
    background: var(--table-row-hover);
}

.ligi-table tr:nth-child(even) td {
    background: var(--table-row-alt);
}

.ligi-cell-expandable {
    cursor: pointer;
}

.ligi-cell-expanded {
    white-space: pre-wrap;
    max-width: none;
}

.ligi-export-dropdown {
    position: relative;
}

.ligi-export-menu {
    position: absolute;
    top: 100%;
    right: 0;
    background: var(--table-bg);
    border: 1px solid var(--table-border);
    border-radius: 4px;
    box-shadow: 0 2px 8px rgba(0,0,0,0.15);
    z-index: 100;
}

.ligi-export-menu button {
    display: block;
    width: 100%;
    padding: 0.5em 1em;
    text-align: left;
    border: none;
    background: none;
    cursor: pointer;
}

.ligi-export-menu button:hover {
    background: var(--table-row-hover);
}

.ligi-toast {
    position: fixed;
    bottom: 2em;
    right: 2em;
    padding: 0.8em 1.5em;
    background: #333;
    color: #fff;
    border-radius: 4px;
    animation: fadeInOut 2s ease;
}

@keyframes fadeInOut {
    0%, 100% { opacity: 0; }
    10%, 90% { opacity: 1; }
}
```

## Implementation Phases

### Phase 1: Core Virtualization & Sticky Headers

1. Implement `VirtualScroller` class
2. Replace simple table render with virtualized version
3. Add sticky headers via CSS
4. Add row count display
5. Test with 10k row CSV

**Deliverables**:
- Virtualized rendering for >100 rows
- Sticky headers
- Performance: 60fps scroll on 10k rows

### Phase 2: Sorting & Filtering

1. Add sort click handlers to headers
2. Implement sort state management
3. Add filter input to toolbar
4. Implement debounced filter
5. Update row count to show filtered count

**Deliverables**:
- Click-to-sort columns
- Filter input with live results
- "Showing X of Y rows" display

### Phase 3: Horizontal Scroll & Frozen Column

1. Detect when table exceeds container width
2. Implement frozen first column
3. Sync vertical scroll between frozen and main areas
4. Add horizontal scroll shadows/indicators

**Deliverables**:
- Frozen first column for wide tables
- Smooth synced scrolling
- Visual indicators for scroll position

### Phase 4: Cell Expansion & Copy

1. Implement cell truncation with expand button
2. Add click-to-expand/collapse
3. Add cell click-to-copy
4. Add row copy button (hover)
5. Add toast notifications

**Deliverables**:
- Expandable long cells
- Copy cell on click
- Copy row button

### Phase 5: Export Functionality

1. Implement export dropdown menu
2. Add "Copy for Google Sheets" (TSV)
3. Add "Copy for Google Docs" (HTML)
4. Add "Download CSV"
5. Add "Download JSONL"
6. Handle filtered exports

**Deliverables**:
- Export dropdown with 4 options
- Proper clipboard formats for Google apps
- File downloads

### Phase 6: Polish & Edge Cases

1. Dark mode support
2. Keyboard navigation (arrow keys in cells)
3. Loading states
4. Error handling
5. Empty state ("No data" / "No matches")
6. Mobile responsiveness

**Deliverables**:
- Full dark mode support
- Keyboard accessibility
- Graceful error handling

## Testing Plan

### Unit Tests (JavaScript)

```javascript
describe('VirtualScroller', () => {
    it('calculates visible range correctly', () => { ... });
    it('maintains scroll position on re-render', () => { ... });
    it('handles rapid scrolling', () => { ... });
});

describe('sortRows', () => {
    it('sorts strings alphabetically', () => { ... });
    it('sorts numbers numerically', () => { ... });
    it('handles mixed types', () => { ... });
    it('maintains stable sort', () => { ... });
});

describe('filterRows', () => {
    it('filters case-insensitively', () => { ... });
    it('searches all columns', () => { ... });
    it('handles empty search', () => { ... });
    it('handles special regex characters', () => { ... });
});

describe('export', () => {
    it('generates valid TSV', () => { ... });
    it('generates valid CSV with escaping', () => { ... });
    it('generates valid HTML table', () => { ... });
    it('exports only filtered rows when filter active', () => { ... });
});
```

### Performance Tests

| Scenario | Target |
|----------|--------|
| Initial render 100 rows | <50ms |
| Initial render 10k rows | <200ms |
| Scroll 10k rows | 60fps |
| Sort 10k rows | <500ms |
| Filter 10k rows | <200ms (debounced) |
| Export 10k rows to CSV | <1s |

### Manual Tests

1. Load CSV with 10k rows, verify smooth scroll
2. Sort each column type (string, number, mixed)
3. Filter with various terms, verify count updates
4. Expand/collapse long cells
5. Copy cell, paste in text editor
6. Copy row, paste in spreadsheet
7. Export to Google Sheets, verify formatting
8. Export to Google Docs, verify table structure
9. Test dark mode toggle
10. Test on mobile viewport

## Edge Cases

| Case | Handling |
|------|----------|
| Empty table | Show "No data" message |
| Single column | Disable frozen column |
| Single row | Show without virtualization |
| All cells empty | Render empty cells, don't collapse |
| Very wide table (50+ columns) | Horizontal scroll, frozen first column |
| Very long cell (10k+ chars) | Truncate, modal for full view |
| Unicode/emoji in cells | Render correctly, copy correctly |
| HTML in cells | Escape when rendering, preserve when copying |
| Filter matches nothing | Show "No matching rows" |
| Rapid sort clicks | Debounce, show loading indicator |
| Scroll during sort | Queue scroll, apply after sort |
| Copy fails (permissions) | Show error toast, offer fallback |
| Export large table | Show progress, don't freeze UI |

## Browser Support

| Browser | Minimum Version | Notes |
|---------|-----------------|-------|
| Chrome | 80+ | Full support |
| Firefox | 75+ | Full support |
| Safari | 13+ | ClipboardItem may need fallback |
| Edge | 80+ | Full support |

**Fallbacks**:
- `navigator.clipboard` -> `document.execCommand('copy')` for older browsers
- `ClipboardItem` -> Plain text copy for Safari <13.1
- CSS `position: sticky` -> Fixed header with JS scroll sync

## File Changes Summary

| File | Change |
|------|--------|
| `src/serve/assets/table-renderer.js` | Complete rewrite with all features |
| `src/serve/assets/styles.css` | Add table component styles |
| `src/serve/assets/app.js` | Update table renderer initialization |
| `src/serve/assets.zig` | Update embedded file references |

## Estimated Complexity

| Component | Lines of JS | Lines of CSS |
|-----------|-------------|--------------|
| Parsing (existing) | 50 | - |
| Virtual scroller | 150 | 20 |
| Sorting | 50 | 10 |
| Filtering | 40 | 15 |
| Frozen column | 80 | 30 |
| Cell expansion | 60 | 20 |
| Copy functionality | 70 | 10 |
| Export | 100 | 25 |
| Main renderer | 150 | 50 |
| **Total** | **~750** | **~180** |

## Open Questions (Resolved)

1. **Should exports respect current sort order?**
   Yes - export rows in currently displayed order.

2. **Should filter be column-specific?**
   v1: No, search all columns. v2: Add `column:value` syntax.

3. **Maximum rows before warning?**
   Show warning at 50k rows: "Large dataset may be slow. Continue?"

4. **Keyboard shortcuts?**
   - `Ctrl+F` / `Cmd+F`: Focus filter input
   - `Escape`: Clear filter, collapse expanded cells
   - `Ctrl+C` / `Cmd+C` on selected cell: Copy cell value
