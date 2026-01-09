[[t/TODO]](index/tags/TODO.md) [[t/browser]](index/tags/browser.md) [[t/tagging]](index/tags/tagging.md) [[t/query]](index/tags/query.md)

# Implementation Plan: Browser Tag Viewer

## Executive Summary

This plan adds a tag browsing interface to `ligi serve` that allows users to:
1. **View all tags** - Browse the tag index in a sidebar panel
2. **Filter by tags** - Click tags to filter the file list
3. **See tag counts** - Show how many files have each tag
4. **Combine tags** - Support AND/OR filtering like the CLI

This is the browser equivalent of `ligi q l` (list tags) and `ligi q t` (tag query).

---

## Goals

- Display all tags from the local index (`art/index/ligi_tags.md`)
- Show tag hierarchy for nested tags (e.g., `release/notes`)
- Filter file list by selected tags
- Support multi-tag selection with AND/OR logic
- Highlight tags on the currently viewed document

## Non-Goals

- Global tag index (browser only sees local repo)
- Tag creation/deletion (see [Browser Tag Manipulation](impl_browser_tag_manipulation.md))
- Real-time tag updates (requires page refresh or manual reload)

---

## Server API

### New Endpoint: `/api/tags`

Returns the tag index with file counts:

```json
{
  "tags": [
    {"name": "DONE", "count": 5, "files": ["art/impl_init.md", "..."]},
    {"name": "TODO", "count": 12, "files": ["art/impl_graph_query.md", "..."]},
    {"name": "project", "count": 3, "files": ["..."]},
    {"name": "release/notes", "count": 2, "files": ["..."]}
  ]
}
```

### Implementation (`src/serve/mod.zig`)

```zig
fn serveTagList(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    config: anytype,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Read art/index/ligi_tags.md
    const index_path = try std.fs.path.join(arena_alloc, &.{ config.root, "index", "ligi_tags.md" });

    if (!fs.fileExists(index_path)) {
        // No index yet
        try sendResponse(request, .ok, "application/json", "{\"tags\":[]}");
        return;
    }

    // Parse tag list from ligi_tags.md
    const content = try std.fs.cwd().readFileAlloc(arena_alloc, index_path, 1024 * 1024);
    var tags = std.ArrayList(TagInfo).init(arena_alloc);

    // Extract tag names from markdown links: - [tagname](tags/tagname.md)
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trim(u8, line, " "), "- [")) {
            // Parse: - [tag_name](tags/tag_name.md)
            const tag_name = parseTagFromLine(line);
            if (tag_name) |name| {
                // Read per-tag index to get file count
                const tag_file = try std.fs.path.join(arena_alloc, &.{
                    config.root, "index", "tags", name, ".md"
                });
                const files = readTagFiles(arena_alloc, tag_file);
                try tags.append(.{
                    .name = name,
                    .count = files.len,
                    .files = files,
                });
            }
        }
    }

    // Build JSON response
    const json = try buildTagsJson(arena_alloc, tags.items);
    try sendResponse(request, .ok, "application/json", json);
}
```

### Route Addition

```zig
// In handleRequest
else if (std.mem.eql(u8, request_path, "/api/tags")) {
    try serveTagList(allocator, request, config);
}
```

---

## Browser Implementation

### UI Structure (`src/serve/assets/index.html`)

```html
<div id="sidebar">
    <div id="sidebar-tabs">
        <button class="tab active" data-panel="files">Files</button>
        <button class="tab" data-panel="tags">Tags</button>
    </div>

    <div id="files-panel" class="panel active">
        <!-- Existing file list -->
        <div id="file-list"></div>
    </div>

    <div id="tags-panel" class="panel">
        <div class="tag-filter-bar">
            <span id="tag-filter-mode">AND</span>
            <button id="clear-tag-filter">Clear</button>
        </div>
        <div id="tag-list"></div>
    </div>
</div>
```

### JavaScript (`src/serve/assets/tags.js`)

```javascript
(function() {
    'use strict';

    // State
    let allTags = [];
    let selectedTags = new Set();
    let filterMode = 'AND'; // 'AND' or 'OR'

    // Load tags from API
    async function loadTags() {
        try {
            const response = await fetch('/api/tags');
            const data = await response.json();
            allTags = data.tags || [];
            renderTagList();
        } catch (err) {
            console.error('Failed to load tags:', err);
        }
    }

    // Render tag list
    function renderTagList() {
        const tagListEl = document.getElementById('tag-list');

        if (allTags.length === 0) {
            tagListEl.innerHTML = '<div class="no-tags">No tags indexed yet.<br>Run <code>ligi index</code> to build the index.</div>';
            return;
        }

        // Group tags by prefix for hierarchy
        const grouped = groupTagsByPrefix(allTags);

        tagListEl.innerHTML = renderTagGroups(grouped);

        // Attach click handlers
        tagListEl.querySelectorAll('.tag-item').forEach(el => {
            el.addEventListener('click', () => toggleTag(el.dataset.tag));
        });
    }

    // Group tags like "release/notes" under "release"
    function groupTagsByPrefix(tags) {
        const groups = new Map();
        const toplevel = [];

        for (const tag of tags) {
            const slashIndex = tag.name.indexOf('/');
            if (slashIndex === -1) {
                toplevel.push(tag);
            } else {
                const prefix = tag.name.slice(0, slashIndex);
                if (!groups.has(prefix)) {
                    groups.set(prefix, []);
                }
                groups.get(prefix).push({
                    ...tag,
                    shortName: tag.name.slice(slashIndex + 1)
                });
            }
        }

        return { toplevel, groups };
    }

    // Render grouped tags
    function renderTagGroups(grouped) {
        let html = '';

        // Top-level tags first
        for (const tag of grouped.toplevel) {
            html += renderTagItem(tag.name, tag.name, tag.count);
        }

        // Grouped tags
        for (const [prefix, tags] of grouped.groups) {
            html += `<div class="tag-group">
                <div class="tag-group-header">${escapeHtml(prefix)}/</div>
                ${tags.map(t => renderTagItem(t.name, t.shortName, t.count)).join('')}
            </div>`;
        }

        return html;
    }

    function renderTagItem(fullName, displayName, count) {
        const isSelected = selectedTags.has(fullName);
        return `<div class="tag-item ${isSelected ? 'selected' : ''}" data-tag="${escapeHtml(fullName)}">
            <span class="tag-name">${escapeHtml(displayName)}</span>
            <span class="tag-count">${count}</span>
        </div>`;
    }

    // Toggle tag selection
    function toggleTag(tagName) {
        if (selectedTags.has(tagName)) {
            selectedTags.delete(tagName);
        } else {
            selectedTags.add(tagName);
        }
        renderTagList();
        applyTagFilter();
    }

    // Apply tag filter to file list
    function applyTagFilter() {
        if (selectedTags.size === 0) {
            // Show all files
            window.ligiFileFilter = null;
            renderFileList();
            return;
        }

        // Get files matching selected tags
        const tagData = new Map(allTags.map(t => [t.name, new Set(t.files)]));

        let matchingFiles;
        if (filterMode === 'AND') {
            // Intersection of all selected tag files
            matchingFiles = null;
            for (const tag of selectedTags) {
                const files = tagData.get(tag) || new Set();
                if (matchingFiles === null) {
                    matchingFiles = new Set(files);
                } else {
                    matchingFiles = new Set([...matchingFiles].filter(f => files.has(f)));
                }
            }
        } else {
            // Union of all selected tag files
            matchingFiles = new Set();
            for (const tag of selectedTags) {
                const files = tagData.get(tag) || new Set();
                files.forEach(f => matchingFiles.add(f));
            }
        }

        window.ligiFileFilter = matchingFiles;
        renderFileList();
        updateFilterStatus();
    }

    // Toggle AND/OR mode
    function toggleFilterMode() {
        filterMode = filterMode === 'AND' ? 'OR' : 'AND';
        document.getElementById('tag-filter-mode').textContent = filterMode;
        applyTagFilter();
    }

    // Clear all tag selections
    function clearTagFilter() {
        selectedTags.clear();
        renderTagList();
        applyTagFilter();
    }

    // Update filter status display
    function updateFilterStatus() {
        const statusEl = document.getElementById('tag-filter-status');
        if (!statusEl) return;

        if (selectedTags.size === 0) {
            statusEl.textContent = '';
        } else {
            const count = window.ligiFileFilter ? window.ligiFileFilter.size : 0;
            statusEl.textContent = `${count} files match ${[...selectedTags].join(` ${filterMode} `)}`;
        }
    }

    // Get tags for current file
    function getTagsForFile(path) {
        return allTags.filter(t => t.files.includes(path)).map(t => t.name);
    }

    // Highlight tags for current document
    function highlightCurrentFileTags(path) {
        const fileTags = getTagsForFile(path);
        document.querySelectorAll('.tag-item').forEach(el => {
            el.classList.toggle('current-file', fileTags.includes(el.dataset.tag));
        });
    }

    function escapeHtml(str) {
        return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    }

    // Tab switching
    document.querySelectorAll('#sidebar-tabs .tab').forEach(tab => {
        tab.addEventListener('click', () => {
            document.querySelectorAll('#sidebar-tabs .tab').forEach(t => t.classList.remove('active'));
            document.querySelectorAll('.panel').forEach(p => p.classList.remove('active'));
            tab.classList.add('active');
            document.getElementById(tab.dataset.panel + '-panel').classList.add('active');
        });
    });

    // Event listeners
    document.getElementById('tag-filter-mode')?.addEventListener('click', toggleFilterMode);
    document.getElementById('clear-tag-filter')?.addEventListener('click', clearTagFilter);

    // Export for app.js
    window.ligiTags = {
        loadTags,
        getTagsForFile,
        highlightCurrentFileTags,
        refresh: loadTags
    };

    // Initialize
    loadTags();
})();
```

### Integration with app.js

```javascript
// In renderFileList, apply filter
function renderFileList() {
    let files = [...fileListData];

    // Apply tag filter if active
    if (window.ligiFileFilter) {
        files = files.filter(f => window.ligiFileFilter.has(f.path));
    }

    // ... rest of rendering
}

// After loading a file, highlight its tags
async function loadFile(path, anchor) {
    // ... existing code ...

    // Highlight tags for this file
    if (window.ligiTags) {
        window.ligiTags.highlightCurrentFileTags(path);
    }
}
```

### Styles (`src/serve/assets/styles.css`)

```css
/* Sidebar tabs */
#sidebar-tabs {
    display: flex;
    border-bottom: 1px solid #333;
}

#sidebar-tabs .tab {
    flex: 1;
    padding: 0.5rem;
    background: transparent;
    border: none;
    color: #888;
    cursor: pointer;
    font-size: 0.8rem;
}

#sidebar-tabs .tab.active {
    color: #fff;
    background: #2d2d2d;
    border-bottom: 2px solid #6ab0f3;
}

.panel {
    display: none;
    height: calc(100vh - 40px);
    overflow-y: auto;
}

.panel.active {
    display: block;
}

/* Tag list */
.tag-filter-bar {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 0.5rem;
    border-bottom: 1px solid #333;
    font-size: 0.8rem;
}

#tag-filter-mode {
    background: #333;
    padding: 0.25rem 0.5rem;
    border-radius: 4px;
    cursor: pointer;
}

#clear-tag-filter {
    background: transparent;
    border: 1px solid #444;
    color: #888;
    padding: 0.25rem 0.5rem;
    border-radius: 4px;
    cursor: pointer;
    font-size: 0.75rem;
}

.tag-item {
    display: flex;
    justify-content: space-between;
    padding: 0.5rem 0.75rem;
    cursor: pointer;
    border-left: 3px solid transparent;
}

.tag-item:hover {
    background: #2d2d2d;
}

.tag-item.selected {
    background: #2d2d2d;
    border-left-color: #6ab0f3;
}

.tag-item.current-file {
    background: #1a2a1a;
}

.tag-name {
    color: #6ab0f3;
}

.tag-count {
    color: #666;
    font-size: 0.8rem;
}

.tag-group {
    margin-top: 0.5rem;
}

.tag-group-header {
    padding: 0.25rem 0.75rem;
    color: #888;
    font-size: 0.75rem;
    font-weight: bold;
}

.tag-group .tag-item {
    padding-left: 1.5rem;
}

.no-tags {
    padding: 1rem;
    text-align: center;
    color: #666;
}

.no-tags code {
    background: #333;
    padding: 0.25rem 0.5rem;
    border-radius: 4px;
}
```

---

## URL Integration

Support URL hash for tag filters:

```
http://localhost:8777/#tags=TODO,project&mode=AND
```

```javascript
// Parse tag filter from URL
function parseUrlTags() {
    const hash = window.location.hash.slice(1);
    const params = new URLSearchParams(hash);
    const tags = params.get('tags');
    const mode = params.get('mode');

    if (tags) {
        selectedTags = new Set(tags.split(','));
    }
    if (mode === 'OR') {
        filterMode = 'OR';
    }
}

// Update URL when filter changes
function updateUrlTags() {
    if (selectedTags.size === 0) {
        window.location.hash = '';
        return;
    }
    window.location.hash = `tags=${[...selectedTags].join(',')}&mode=${filterMode}`;
}
```

---

## Implementation Steps

1. Add `/api/tags` endpoint to server
2. Create tags.js module
3. Update index.html with tabs and tag panel
4. Integrate with existing file list filtering
5. Add CSS styles
6. Implement URL integration

---

## Testing

- Tag list loads correctly
- Tags show accurate file counts
- AND filter shows intersection
- OR filter shows union
- Clicking tag toggles selection
- Current file tags are highlighted
- Empty index shows helpful message
- Nested tags display in hierarchy
- URL hash persists filter state

---

## File Changes

| File | Change |
|------|--------|
| `src/serve/mod.zig` | Add `/api/tags` endpoint |
| `src/serve/assets/index.html` | Add tabs and tag panel |
| `src/serve/assets/tags.js` | New file: tag viewer |
| `src/serve/assets/app.js` | Integrate tag filter |
| `src/serve/assets/styles.css` | Tag UI styles |
| `src/serve/assets.zig` | Embed tags.js |
