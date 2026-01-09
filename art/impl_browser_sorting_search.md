[[t/TODO]](index/tags/TODO.md) [[t/browser]](index/tags/browser.md) [[t/search]](index/tags/search.md)

# Implementation Plan: Browser Sorting and Search

## Executive Summary

This plan adds two features to `ligi serve`:
1. **File sorting options** - Sort the file list by name (current default), modification time, or creation time
2. **Grep-style search** - Full-text search across all markdown files with result highlighting

Both features are implemented entirely in the browser UI with minimal server-side changes.

---

## Part 1: File Sorting

### Goal

Allow users to sort the file list in the sidebar by:
- **Name** (lexicographic, current behavior)
- **Modified** (most recently modified first)
- **Created** (most recently created first)

### Server API Changes

#### New Endpoint: `/api/list` Enhanced Response

Current response:
```json
["file1.md", "file2.md", "subdir/file3.md"]
```

Enhanced response (when `?metadata=true`):
```json
{
  "files": [
    {"path": "file1.md", "mtime": 1704067200, "ctime": 1704000000},
    {"path": "file2.md", "mtime": 1704153600, "ctime": 1704100000},
    {"path": "subdir/file3.md", "mtime": 1704240000, "ctime": 1704200000}
  ]
}
```

Fields:
- `path`: relative path to file
- `mtime`: modification time as Unix timestamp (seconds)
- `ctime`: creation time as Unix timestamp (seconds), falls back to mtime if unavailable

#### Server Implementation (`src/serve/mod.zig`)

```zig
fn serveFileList(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    config: anytype,
) !void {
    // Parse query for metadata flag
    const include_metadata = parseMetadataFlag(request.head.target);

    // ... existing file collection code ...

    if (include_metadata) {
        // Build JSON with metadata
        for (files.items) |file| {
            const full_path = try std.fs.path.join(arena_alloc, &.{ config.root, file });
            const stat = try std.fs.cwd().statFile(full_path);
            // Add mtime, ctime to response
        }
    } else {
        // Return simple array for backwards compatibility
    }
}
```

### Browser Implementation

#### UI Controls (`src/serve/assets/index.html`)

Add sort controls to the sidebar header:

```html
<div id="sidebar-header">
    <div class="sort-controls">
        <label>Sort:</label>
        <select id="sort-select">
            <option value="name">Name</option>
            <option value="mtime">Modified</option>
            <option value="ctime">Created</option>
        </select>
        <button id="sort-direction" title="Toggle direction">↓</button>
    </div>
</div>
```

#### JavaScript (`src/serve/assets/app.js`)

```javascript
// State
let fileListData = [];  // {path, mtime, ctime}
let sortBy = 'name';
let sortAscending = true;

// Load file list with metadata
async function loadFileList() {
    const response = await fetch('/api/list?metadata=true');
    const data = await response.json();
    fileListData = data.files || data.map(p => ({path: p, mtime: 0, ctime: 0}));
    renderFileList();
}

// Sort and render
function renderFileList() {
    const sorted = [...fileListData].sort((a, b) => {
        let cmp;
        switch (sortBy) {
            case 'mtime': cmp = b.mtime - a.mtime; break;
            case 'ctime': cmp = b.ctime - a.ctime; break;
            default: cmp = a.path.localeCompare(b.path);
        }
        return sortAscending ? cmp : -cmp;
    });

    fileListEl.innerHTML = sorted.map(file => {
        const isActive = file.path === currentFile ? 'active' : '';
        const timeInfo = sortBy !== 'name'
            ? `<span class="file-time">${formatTime(file[sortBy])}</span>`
            : '';
        return `<a class="file-item ${isActive}" data-path="${escapeHtml(file.path)}">
            ${escapeHtml(file.path)}${timeInfo}
        </a>`;
    }).join('');

    // Attach click handlers...
}

// Time formatting
function formatTime(timestamp) {
    if (!timestamp) return '';
    const date = new Date(timestamp * 1000);
    const now = new Date();
    const diffDays = Math.floor((now - date) / (1000 * 60 * 60 * 24));

    if (diffDays === 0) return 'today';
    if (diffDays === 1) return 'yesterday';
    if (diffDays < 7) return `${diffDays}d ago`;
    if (diffDays < 30) return `${Math.floor(diffDays/7)}w ago`;
    return date.toLocaleDateString();
}

// Event handlers
document.getElementById('sort-select').addEventListener('change', e => {
    sortBy = e.target.value;
    renderFileList();
});

document.getElementById('sort-direction').addEventListener('click', () => {
    sortAscending = !sortAscending;
    document.getElementById('sort-direction').textContent = sortAscending ? '↓' : '↑';
    renderFileList();
});
```

#### Styles (`src/serve/assets/styles.css`)

```css
.sort-controls {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.5rem;
    border-bottom: 1px solid #333;
}

.sort-controls label {
    font-size: 0.8rem;
    color: #888;
}

.sort-controls select {
    background: #2d2d2d;
    color: #fff;
    border: 1px solid #444;
    border-radius: 4px;
    padding: 0.25rem 0.5rem;
    font-size: 0.8rem;
}

.sort-controls button {
    background: transparent;
    border: 1px solid #444;
    color: #fff;
    border-radius: 4px;
    padding: 0.25rem 0.5rem;
    cursor: pointer;
}

.file-time {
    display: block;
    font-size: 0.7rem;
    color: #666;
    margin-top: 2px;
}
```

---

## Part 2: Grep-Style Search

### Goal

Provide full-text search across all markdown files with:
- Regex support (basic patterns)
- Case-insensitive by default, with option for case-sensitive
- Result previews with highlighted matches
- Click to navigate to file

### Design Decisions

1. **Client-side search**: Fetch all file contents and search in browser (simpler, works offline after initial load)
2. **Indexed search**: Cache file contents after first access
3. **Progressive loading**: Load and search files incrementally
4. **No server changes**: Reuse existing `/api/file` endpoint

### Browser Implementation

#### UI (`src/serve/assets/index.html`)

```html
<div id="search-panel" class="search-panel">
    <div class="search-header">
        <input type="text" id="search-input" placeholder="Search files..." />
        <label class="search-option">
            <input type="checkbox" id="search-case"> Aa
        </label>
        <label class="search-option">
            <input type="checkbox" id="search-regex"> .*
        </label>
        <button id="search-close" title="Close">×</button>
    </div>
    <div id="search-results" class="search-results"></div>
    <div id="search-status" class="search-status"></div>
</div>
```

#### JavaScript (`src/serve/assets/search.js`)

```javascript
(function() {
    'use strict';

    // Search index: path -> content
    const contentCache = new Map();
    let searchAbortController = null;

    // Open search with Ctrl+/
    document.addEventListener('keydown', e => {
        if ((e.ctrlKey || e.metaKey) && e.key === '/') {
            e.preventDefault();
            openSearch();
        }
        if (e.key === 'Escape') {
            closeSearch();
        }
    });

    function openSearch() {
        document.getElementById('search-panel').classList.add('open');
        document.getElementById('search-input').focus();
    }

    function closeSearch() {
        document.getElementById('search-panel').classList.remove('open');
        if (searchAbortController) {
            searchAbortController.abort();
        }
    }

    // Debounced search
    let searchTimeout;
    document.getElementById('search-input').addEventListener('input', e => {
        clearTimeout(searchTimeout);
        searchTimeout = setTimeout(() => runSearch(e.target.value), 300);
    });

    async function runSearch(query) {
        if (searchAbortController) searchAbortController.abort();
        searchAbortController = new AbortController();

        const resultsEl = document.getElementById('search-results');
        const statusEl = document.getElementById('search-status');

        if (!query.trim()) {
            resultsEl.innerHTML = '';
            statusEl.textContent = '';
            return;
        }

        const caseSensitive = document.getElementById('search-case').checked;
        const useRegex = document.getElementById('search-regex').checked;

        let pattern;
        try {
            pattern = useRegex
                ? new RegExp(query, caseSensitive ? 'g' : 'gi')
                : new RegExp(escapeRegex(query), caseSensitive ? 'g' : 'gi');
        } catch (e) {
            statusEl.textContent = 'Invalid regex';
            return;
        }

        resultsEl.innerHTML = '';
        statusEl.textContent = 'Searching...';

        const results = [];
        let searchedCount = 0;

        for (const file of fileListData) {
            if (searchAbortController.signal.aborted) return;

            try {
                const content = await getFileContent(file.path);
                const matches = findMatches(content, pattern, file.path);
                if (matches.length > 0) {
                    results.push({ path: file.path, matches });
                    renderResults(results);
                }
            } catch (e) {
                console.warn('Failed to search:', file.path, e);
            }

            searchedCount++;
            statusEl.textContent = `Searched ${searchedCount}/${fileListData.length} files, ${results.length} matches`;
        }

        if (results.length === 0) {
            resultsEl.innerHTML = '<div class="no-results">No matches found</div>';
        }
    }

    async function getFileContent(path) {
        if (contentCache.has(path)) {
            return contentCache.get(path);
        }
        const response = await fetch(`/api/file?path=${encodeURIComponent(path)}`);
        const content = await response.text();
        contentCache.set(path, content);
        return content;
    }

    function findMatches(content, pattern, path) {
        const lines = content.split('\n');
        const matches = [];

        for (let i = 0; i < lines.length; i++) {
            const line = lines[i];
            pattern.lastIndex = 0;

            if (pattern.test(line)) {
                matches.push({
                    lineNum: i + 1,
                    line: line.trim(),
                    context: getContext(lines, i)
                });

                if (matches.length >= 10) break; // Limit per file
            }
        }

        return matches;
    }

    function getContext(lines, index) {
        const start = Math.max(0, index - 1);
        const end = Math.min(lines.length, index + 2);
        return lines.slice(start, end).map((l, i) => ({
            num: start + i + 1,
            text: l,
            isCurrent: start + i === index
        }));
    }

    function renderResults(results) {
        const resultsEl = document.getElementById('search-results');
        resultsEl.innerHTML = results.map(r => `
            <div class="search-result">
                <div class="result-file" data-path="${escapeHtml(r.path)}">
                    ${escapeHtml(r.path)}
                </div>
                ${r.matches.slice(0, 3).map(m => `
                    <div class="result-match" data-path="${escapeHtml(r.path)}" data-line="${m.lineNum}">
                        <span class="line-num">${m.lineNum}</span>
                        <span class="line-text">${highlightMatch(m.line)}</span>
                    </div>
                `).join('')}
                ${r.matches.length > 3 ? `<div class="more-matches">+${r.matches.length - 3} more</div>` : ''}
            </div>
        `).join('');

        // Click handlers
        resultsEl.querySelectorAll('[data-path]').forEach(el => {
            el.addEventListener('click', () => {
                const path = el.dataset.path;
                const line = el.dataset.line;
                loadFile(path);
                closeSearch();
                // TODO: scroll to line after load
            });
        });
    }

    function highlightMatch(text) {
        const query = document.getElementById('search-input').value;
        const caseSensitive = document.getElementById('search-case').checked;
        const escaped = escapeHtml(text);
        const pattern = new RegExp(`(${escapeRegex(query)})`, caseSensitive ? 'g' : 'gi');
        return escaped.replace(pattern, '<mark>$1</mark>');
    }

    function escapeRegex(str) {
        return str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    }

    function escapeHtml(str) {
        return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }

    // Export for app.js
    window.ligiSearch = { openSearch, closeSearch };
})();
```

#### Styles (`src/serve/assets/styles.css`)

```css
.search-panel {
    position: fixed;
    top: 0;
    right: 0;
    width: 400px;
    height: 100vh;
    background: #1e1e1e;
    border-left: 1px solid #333;
    transform: translateX(100%);
    transition: transform 0.2s ease;
    display: flex;
    flex-direction: column;
    z-index: 1000;
}

.search-panel.open {
    transform: translateX(0);
}

.search-header {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.75rem;
    border-bottom: 1px solid #333;
}

.search-header input[type="text"] {
    flex: 1;
    background: #2d2d2d;
    border: 1px solid #444;
    color: #fff;
    padding: 0.5rem;
    border-radius: 4px;
}

.search-option {
    display: flex;
    align-items: center;
    gap: 0.25rem;
    font-size: 0.75rem;
    color: #888;
}

.search-results {
    flex: 1;
    overflow-y: auto;
    padding: 0.5rem;
}

.search-result {
    margin-bottom: 1rem;
}

.result-file {
    font-weight: bold;
    color: #6ab0f3;
    padding: 0.25rem;
    cursor: pointer;
}

.result-file:hover {
    background: #333;
}

.result-match {
    display: flex;
    gap: 0.5rem;
    padding: 0.25rem 0.5rem;
    font-family: monospace;
    font-size: 0.8rem;
    cursor: pointer;
}

.result-match:hover {
    background: #333;
}

.line-num {
    color: #666;
    min-width: 3ch;
}

.line-text {
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.line-text mark {
    background: #5a4a00;
    color: #fff;
}

.search-status {
    padding: 0.5rem;
    font-size: 0.75rem;
    color: #888;
    border-top: 1px solid #333;
}

.no-results {
    padding: 1rem;
    text-align: center;
    color: #666;
}
```

---

## Implementation Steps

### Phase 1: Sorting (server + client)
1. Update `/api/list` endpoint to support `?metadata=true`
2. Add sort controls to sidebar HTML
3. Implement sort logic in app.js
4. Add CSS for sort controls

### Phase 2: Search (client only)
1. Add search panel HTML
2. Create search.js module
3. Integrate with app.js (keyboard shortcuts, file loading)
4. Add CSS for search UI

### Phase 3: Polish
1. Persist sort preference in localStorage
2. Add search keyboard navigation (up/down arrows)
3. Highlight matched line after navigation
4. Add loading indicators

---

## Testing

### Sort Feature
- Sort by name ascending/descending
- Sort by mtime (newest/oldest first)
- Sort by ctime (newest/oldest first)
- Persistence across page reloads
- Backwards compatibility (no metadata flag)

### Search Feature
- Basic text search
- Case-insensitive search
- Case-sensitive search
- Regex patterns
- Invalid regex handling
- Large file handling
- Search cancellation
- Navigation to results

---

## File Changes

| File | Change |
|------|--------|
| `src/serve/mod.zig` | Add metadata support to `/api/list` |
| `src/serve/assets/index.html` | Add sort controls and search panel |
| `src/serve/assets/app.js` | Add sort logic, integrate search |
| `src/serve/assets/search.js` | New file: search implementation |
| `src/serve/assets/styles.css` | Add sort and search styles |
| `src/serve/assets.zig` | Embed search.js |
