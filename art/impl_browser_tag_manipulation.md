[[t/TODO]](index/tags/TODO.md) [[t/browser]](index/tags/browser.md) [[t/tagging]](index/tags/tagging.md)

# Implementation Plan: Browser Tag Manipulation

## Executive Summary

This plan adds the ability to add and remove tags from documents directly in the `ligi serve` browser interface. Features include:
1. **Tag dropdown** - Dropdown menu showing all available tags with checkboxes
2. **Add tags** - Select tags from dropdown or create new ones
3. **Remove tags** - Uncheck tags to remove them from the document
4. **Auto-reindex** - Automatically update the tag index after changes

This is the browser equivalent of manually editing `[[t/tagname]]` in markdown files.

---

## Goals

- Display tags on the current document in a visible location
- Provide dropdown to add/remove tags with one click
- Support creating new tags inline
- Write changes back to the markdown file
- Trigger re-indexing after tag changes
- Provide visual feedback for pending/saved changes

## Non-Goals

- Bulk tag operations across multiple files (use CLI)
- Tag renaming (requires find-and-replace across all files)
- Tag deletion from index (orphaned tags remain until re-index)
- Editing tag position within the document (always added at top)

---

## Design Decisions

1. **Tag position**: New tags are added to the first line (or after existing tags if present)
2. **Tag format**: Uses the standard `[[t/tagname]](index/tags/tagname.md)` format
3. **Write-through**: Changes are written immediately to the file
4. **Optimistic UI**: UI updates immediately, then confirms with server
5. **Conflict handling**: If file changed externally, prompt user to reload

---

## Server API

### New Endpoint: `POST /api/file/tags`

Update tags on a file:

**Request:**
```json
{
  "path": "art/impl_example.md",
  "add": ["feature", "v2"],
  "remove": ["WIP"]
}
```

**Response (success):**
```json
{
  "success": true,
  "tags": ["feature", "v2", "DONE"],
  "reindexed": true
}
```

**Response (conflict):**
```json
{
  "success": false,
  "error": "file_modified",
  "message": "File was modified externally. Reload to see changes."
}
```

### Implementation (`src/serve/mod.zig`)

```zig
fn handleTagUpdate(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    config: anytype,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Read request body
    const body = try request.reader().readAllAlloc(arena_alloc, 64 * 1024);
    const parsed = try std.json.parseFromSlice(TagUpdateRequest, arena_alloc, body, .{});

    // Validate path
    const rel_path = parsed.value.path;
    _ = path_mod.validatePath(rel_path) catch {
        try sendJsonError(request, "Invalid path");
        return;
    };

    const full_path = try path_mod.joinSafePath(arena_alloc, config.root, rel_path) orelse {
        try sendJsonError(request, "Invalid path");
        return;
    };

    // Read current file
    const file = std.fs.cwd().openFile(full_path, .{ .mode = .read_write }) catch {
        try sendJsonError(request, "Cannot open file");
        return;
    };
    defer file.close();

    const content = try file.readToEndAlloc(arena_alloc, 10 * 1024 * 1024);

    // Parse existing tags
    var existing_tags = try tag_index.parseTagsFromContent(arena_alloc, content);

    // Apply changes
    var new_tags = std.StringHashMap(void).init(arena_alloc);
    for (existing_tags) |tag| {
        if (!contains(parsed.value.remove, tag)) {
            try new_tags.put(tag, {});
        }
    }
    for (parsed.value.add) |tag| {
        if (tag_index.isValidTagName(tag)) {
            try new_tags.put(tag, {});
        }
    }

    // Generate new content with updated tags
    const new_content = try updateTagsInContent(arena_alloc, content, new_tags);

    // Write back to file
    try file.seekTo(0);
    try file.setEndPos(0);
    try file.writeAll(new_content);

    // Trigger re-index for this file
    const cfg = core.config.getDefaultConfig();
    _ = tag_index.indexSingleFile(arena_alloc, config.root, rel_path, cfg) catch {};

    // Return success with current tags
    const response = try buildTagResponse(arena_alloc, new_tags);
    try sendResponse(request, .ok, "application/json", response);
}

fn updateTagsInContent(
    allocator: std.mem.Allocator,
    content: []const u8,
    tags: std.StringHashMap(void),
) ![]const u8 {
    // Find existing tag line (starts with [[t/)
    const lines = std.mem.splitScalar(u8, content, '\n');
    var result = std.ArrayList(u8).init(allocator);

    var found_tag_line = false;
    var first_line = true;

    // Build new tag line
    var tag_line = std.ArrayList(u8).init(allocator);
    var tag_iter = tags.keyIterator();
    var tag_count: usize = 0;
    while (tag_iter.next()) |key| {
        if (tag_count > 0) try tag_line.appendSlice(" ");
        try tag_line.writer().print("[[t/{s}]](index/tags/{s}.md)", .{key.*, key.*});
        tag_count += 1;
    }

    while (lines.next()) |line| {
        if (!first_line) try result.append('\n');
        first_line = false;

        // Check if this is a tag line
        if (std.mem.indexOf(u8, line, "[[t/") != null) {
            if (!found_tag_line) {
                // Replace first tag line
                try result.appendSlice(tag_line.items);
                found_tag_line = true;
            }
            // Skip existing tag line
            continue;
        }

        try result.appendSlice(line);
    }

    // If no tag line existed, prepend it
    if (!found_tag_line and tag_line.items.len > 0) {
        var final = std.ArrayList(u8).init(allocator);
        try final.appendSlice(tag_line.items);
        try final.append('\n');
        if (result.items.len > 0 and result.items[0] != '\n') {
            try final.append('\n');
        }
        try final.appendSlice(result.items);
        return final.items;
    }

    return result.items;
}
```

### Route Addition

```zig
// In handleRequest
else if (std.mem.eql(u8, request_path, "/api/file/tags") and
         request.head.method == .POST) {
    try handleTagUpdate(allocator, request, config);
}
```

---

## Browser Implementation

### UI Component (`src/serve/assets/index.html`)

Add tag editor to document header:

```html
<div id="content-header">
    <div id="document-tags">
        <div id="current-tags"></div>
        <div id="tag-dropdown" class="dropdown">
            <button id="tag-dropdown-toggle" class="dropdown-toggle">
                + Add Tag
            </button>
            <div id="tag-dropdown-menu" class="dropdown-menu">
                <input type="text" id="tag-search" placeholder="Search or create tag...">
                <div id="tag-options"></div>
                <div id="tag-create" class="tag-create-option" style="display:none">
                    Create "<span id="tag-create-name"></span>"
                </div>
            </div>
        </div>
    </div>
    <div id="tag-save-status"></div>
</div>
```

### JavaScript (`src/serve/assets/tag-editor.js`)

```javascript
(function() {
    'use strict';

    // State
    let documentTags = new Set();
    let allAvailableTags = [];
    let isDropdownOpen = false;
    let pendingSave = null;

    // Initialize when a file is loaded
    function initForFile(path, content) {
        // Parse tags from content
        documentTags = new Set(parseTagsFromContent(content));
        renderCurrentTags();
        updateDropdownOptions();
    }

    // Parse [[t/tagname]] patterns from content
    function parseTagsFromContent(content) {
        const pattern = /\[\[t\/([^\]]+)\]\]/g;
        const tags = [];
        let match;
        while ((match = pattern.exec(content)) !== null) {
            tags.push(match[1]);
        }
        return tags;
    }

    // Render current tags as pills
    function renderCurrentTags() {
        const container = document.getElementById('current-tags');
        container.innerHTML = [...documentTags].map(tag => `
            <span class="tag-pill" data-tag="${escapeHtml(tag)}">
                ${escapeHtml(tag)}
                <button class="tag-remove" title="Remove tag">×</button>
            </span>
        `).join('');

        // Attach remove handlers
        container.querySelectorAll('.tag-remove').forEach(btn => {
            btn.addEventListener('click', (e) => {
                e.stopPropagation();
                const tag = btn.parentElement.dataset.tag;
                removeTag(tag);
            });
        });
    }

    // Update dropdown with available tags
    function updateDropdownOptions() {
        const optionsEl = document.getElementById('tag-options');
        const searchValue = document.getElementById('tag-search')?.value.toLowerCase() || '';

        // Filter tags
        const filtered = allAvailableTags.filter(tag =>
            tag.name.toLowerCase().includes(searchValue)
        );

        optionsEl.innerHTML = filtered.map(tag => {
            const isSelected = documentTags.has(tag.name);
            return `
                <label class="tag-option ${isSelected ? 'selected' : ''}" data-tag="${escapeHtml(tag.name)}">
                    <input type="checkbox" ${isSelected ? 'checked' : ''}>
                    <span class="tag-option-name">${escapeHtml(tag.name)}</span>
                    <span class="tag-option-count">${tag.count}</span>
                </label>
            `;
        }).join('');

        // Show create option if search doesn't match existing tag
        const createEl = document.getElementById('tag-create');
        const createNameEl = document.getElementById('tag-create-name');
        if (searchValue && !allAvailableTags.some(t => t.name.toLowerCase() === searchValue)) {
            createEl.style.display = 'block';
            createNameEl.textContent = searchValue;
        } else {
            createEl.style.display = 'none';
        }

        // Attach handlers
        optionsEl.querySelectorAll('.tag-option').forEach(opt => {
            opt.addEventListener('click', () => {
                const tag = opt.dataset.tag;
                const checkbox = opt.querySelector('input');
                if (checkbox.checked) {
                    removeTag(tag);
                } else {
                    addTag(tag);
                }
            });
        });
    }

    // Add a tag
    async function addTag(tag) {
        if (!isValidTagName(tag)) {
            showStatus('Invalid tag name', 'error');
            return;
        }

        documentTags.add(tag);
        renderCurrentTags();
        updateDropdownOptions();
        await saveTagChanges([tag], []);
    }

    // Remove a tag
    async function removeTag(tag) {
        documentTags.delete(tag);
        renderCurrentTags();
        updateDropdownOptions();
        await saveTagChanges([], [tag]);
    }

    // Validate tag name
    function isValidTagName(name) {
        if (!name || name.length === 0 || name.length > 255) return false;
        if (name.includes('..')) return false;
        return /^[A-Za-z0-9_\-.\/]+$/.test(name);
    }

    // Save tag changes to server
    async function saveTagChanges(add, remove) {
        // Debounce rapid changes
        if (pendingSave) {
            pendingSave.add = [...pendingSave.add, ...add];
            pendingSave.remove = [...pendingSave.remove, ...remove];
            return;
        }

        pendingSave = { add, remove };
        showStatus('Saving...', 'pending');

        // Small delay to batch rapid changes
        await new Promise(r => setTimeout(r, 300));

        const changes = pendingSave;
        pendingSave = null;

        try {
            const response = await fetch('/api/file/tags', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    path: currentFile,
                    add: changes.add,
                    remove: changes.remove
                })
            });

            const result = await response.json();

            if (result.success) {
                showStatus('Saved', 'success');
                // Update local state with server response
                documentTags = new Set(result.tags);
                renderCurrentTags();

                // Refresh tag list if new tag was created
                if (changes.add.some(t => !allAvailableTags.find(at => at.name === t))) {
                    if (window.ligiTags) {
                        window.ligiTags.refresh();
                    }
                }
            } else {
                showStatus(result.message || 'Save failed', 'error');
                // Revert optimistic update
                // TODO: reload file
            }
        } catch (err) {
            showStatus('Network error', 'error');
            console.error('Failed to save tags:', err);
        }
    }

    // Show save status
    function showStatus(message, type) {
        const statusEl = document.getElementById('tag-save-status');
        statusEl.textContent = message;
        statusEl.className = `save-status ${type}`;

        if (type === 'success') {
            setTimeout(() => {
                statusEl.textContent = '';
                statusEl.className = 'save-status';
            }, 2000);
        }
    }

    // Toggle dropdown
    function toggleDropdown() {
        isDropdownOpen = !isDropdownOpen;
        const menu = document.getElementById('tag-dropdown-menu');
        menu.classList.toggle('open', isDropdownOpen);

        if (isDropdownOpen) {
            document.getElementById('tag-search').focus();
        }
    }

    // Close dropdown when clicking outside
    document.addEventListener('click', (e) => {
        const dropdown = document.getElementById('tag-dropdown');
        if (!dropdown.contains(e.target) && isDropdownOpen) {
            toggleDropdown();
        }
    });

    // Event listeners
    document.getElementById('tag-dropdown-toggle')?.addEventListener('click', (e) => {
        e.stopPropagation();
        toggleDropdown();
    });

    document.getElementById('tag-search')?.addEventListener('input', () => {
        updateDropdownOptions();
    });

    document.getElementById('tag-search')?.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') {
            const value = e.target.value.trim();
            if (value && isValidTagName(value)) {
                addTag(value);
                e.target.value = '';
            }
        }
    });

    document.getElementById('tag-create')?.addEventListener('click', () => {
        const name = document.getElementById('tag-create-name').textContent;
        if (name && isValidTagName(name)) {
            addTag(name);
            document.getElementById('tag-search').value = '';
        }
    });

    function escapeHtml(str) {
        return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    }

    // Load available tags
    async function loadAvailableTags() {
        try {
            const response = await fetch('/api/tags');
            const data = await response.json();
            allAvailableTags = data.tags || [];
        } catch (err) {
            console.error('Failed to load tags:', err);
        }
    }

    // Export for app.js
    window.ligiTagEditor = {
        init: initForFile,
        loadAvailableTags
    };

    // Initialize available tags
    loadAvailableTags();
})();
```

### Integration with app.js

```javascript
// After loading a file
async function loadFile(path, anchor) {
    // ... existing code to fetch and render markdown ...

    // Initialize tag editor
    if (window.ligiTagEditor) {
        window.ligiTagEditor.init(path, markdown);
    }
}
```

### Styles (`src/serve/assets/styles.css`)

```css
/* Document header with tags */
#content-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 0.5rem 1rem;
    border-bottom: 1px solid #333;
    background: #1e1e1e;
    position: sticky;
    top: 0;
    z-index: 100;
}

#document-tags {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    flex-wrap: wrap;
}

/* Tag pills */
.tag-pill {
    display: inline-flex;
    align-items: center;
    gap: 0.25rem;
    background: #2d4a6d;
    color: #6ab0f3;
    padding: 0.25rem 0.5rem;
    border-radius: 4px;
    font-size: 0.8rem;
}

.tag-remove {
    background: transparent;
    border: none;
    color: #6ab0f3;
    cursor: pointer;
    padding: 0 0.25rem;
    font-size: 1rem;
    line-height: 1;
    opacity: 0.6;
}

.tag-remove:hover {
    opacity: 1;
}

/* Dropdown */
.dropdown {
    position: relative;
}

.dropdown-toggle {
    background: #333;
    border: 1px dashed #555;
    color: #888;
    padding: 0.25rem 0.5rem;
    border-radius: 4px;
    cursor: pointer;
    font-size: 0.8rem;
}

.dropdown-toggle:hover {
    border-color: #6ab0f3;
    color: #6ab0f3;
}

.dropdown-menu {
    display: none;
    position: absolute;
    top: 100%;
    left: 0;
    min-width: 250px;
    max-height: 300px;
    background: #2d2d2d;
    border: 1px solid #444;
    border-radius: 4px;
    box-shadow: 0 4px 12px rgba(0,0,0,0.3);
    z-index: 1000;
    margin-top: 4px;
}

.dropdown-menu.open {
    display: block;
}

.dropdown-menu input[type="text"] {
    width: 100%;
    padding: 0.5rem;
    background: #1e1e1e;
    border: none;
    border-bottom: 1px solid #444;
    color: #fff;
    font-size: 0.9rem;
}

#tag-options {
    max-height: 200px;
    overflow-y: auto;
}

.tag-option {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.5rem;
    cursor: pointer;
}

.tag-option:hover {
    background: #333;
}

.tag-option.selected {
    background: #2d4a6d;
}

.tag-option input {
    margin: 0;
}

.tag-option-name {
    flex: 1;
    color: #fff;
}

.tag-option-count {
    color: #666;
    font-size: 0.75rem;
}

.tag-create-option {
    padding: 0.5rem;
    border-top: 1px solid #444;
    color: #6ab0f3;
    cursor: pointer;
}

.tag-create-option:hover {
    background: #333;
}

/* Save status */
.save-status {
    font-size: 0.75rem;
    padding: 0.25rem 0.5rem;
}

.save-status.pending {
    color: #ffa500;
}

.save-status.success {
    color: #4caf50;
}

.save-status.error {
    color: #f44336;
}
```

---

## Security Considerations

1. **Path validation**: Reject paths with `..` or absolute paths
2. **Tag validation**: Only allow valid tag characters
3. **File size limit**: Reject files larger than 10MB
4. **Rate limiting**: Consider limiting tag update frequency
5. **CSRF**: Not a concern for localhost-only server

---

## Implementation Steps

1. Add `POST /api/file/tags` endpoint
2. Implement tag parsing and content update in Zig
3. Create tag-editor.js module
4. Add UI elements to index.html
5. Integrate with app.js file loading
6. Add CSS styles
7. Add error handling and edge cases

---

## Testing

- Add single tag to document
- Add multiple tags rapidly
- Remove tag from document
- Create new tag (not in index)
- Invalid tag name rejected
- Tags persist after page refresh
- Concurrent edit warning
- Large document handling
- Special characters in tags

---

## Edge Cases

| Case | Handling |
|------|----------|
| File has no tags | Insert tag line at top |
| File has multiple tag lines | Consolidate to single line |
| Tag line is not at top | Keep in original position |
| File modified externally | Show conflict warning |
| Invalid tag characters | Reject with error message |
| Tag already exists | No-op |
| Network error during save | Show error, keep local state |
| Very long tag name | Truncate at 255 chars |

---

## File Changes

| File | Change |
|------|--------|
| `src/serve/mod.zig` | Add `POST /api/file/tags` endpoint |
| `src/serve/assets/index.html` | Add tag editor UI |
| `src/serve/assets/tag-editor.js` | New file: tag manipulation |
| `src/serve/assets/app.js` | Integrate tag editor |
| `src/serve/assets/styles.css` | Tag editor styles |
| `src/serve/assets.zig` | Embed tag-editor.js |
