# Ligi `serve` Command Implementation Plan

## Executive Summary

This plan defines how `ligi serve` will run a local HTTP server that lets a browser render Markdown files with GitHub Flavored Markdown (GFM) semantics and Mermaid diagrams. The server will be self-contained (no CDN), safe by default (path traversal protection), and simple to operate from a repo root.

---

## Goals

- Serve Markdown files from a repo (default `./art`, fallback `.`) to a browser.
- Render Markdown with GFM features (tables, task lists, strikethrough, autolinks).
- Render Mermaid code fences as diagrams client-side.
- Avoid external network dependencies by embedding front-end assets.
- Keep the server minimal: one process, no database, no watchers required.
- **Operational Model:** The server runs as a blocking foreground process. It stops when the user sends an interrupt signal (e.g., `Ctrl+C`).

Non-goals (for now): live reload, auth, multi-user, remote hosting.

---

## Command Surface

`ligi serve [options]`

Proposed flags:
- `--root <path>`: Base directory to serve. Default: `./art` if it exists, else `.`.
- `--host <host>`: Host to bind. Default: `127.0.0.1`.
- `--port <port>`: Port to bind. Default: `8777`.
- `--open`: Optional. Attempt to open a browser after bind (best-effort, non-fatal).
- `--no-index`: Optional. Disable directory listing endpoint if desired.

Note: If `--open` is included, handle OS-specific open commands (macOS `open`, Linux `xdg-open`, Windows `start`) behind a best-effort helper.

---

## Architecture Overview

### 1) CLI Integration

- Add new command definition in `src/cli/registry.zig`:
  - canonical: `serve`
  - names: `serve`, `s`
  - description: `Serve markdown files with GFM + Mermaid rendering`
- Update dispatch in `src/cli/registry.zig` to route `serve` to `src/cli/commands/serve.zig`.

### 2) Module Layout

```
src/
├── cli/commands/serve.zig    # CLI handler, parses flags, starts server
├── serve/
│   ├── mod.zig               # Server core + routing
│   ├── routes.zig            # HTTP routing helpers
│   ├── assets.zig            # @embedFile mapping and content-types
│   └── path.zig              # Path validation + normalization
└── serve/assets/
    ├── index.html
    ├── app.js
    ├── styles.css
    └── vendor/
        ├── marked.min.js
        ├── mermaid.min.js
        └── NOTICE.md
```

### 3) HTTP Endpoints

- `GET /` -> HTML shell (app entry). Embedded file `index.html`.
- `GET /assets/...` -> JS/CSS assets (embedded via `@embedFile`).
- `GET /api/list` -> JSON list of markdown files relative to base root.
- `GET /api/file?path=<relpath>` -> raw Markdown content.

Optional: `GET /api/health` -> `200 ok` for testability.

### 4) Rendering Pipeline (Browser)

- `index.html` loads `app.js` + `styles.css`.
- `app.js`:
  - Fetches `GET /api/list` to populate a sidebar file list.
  - Fetches `GET /api/file?path=...` when a file is selected.
  - Renders Markdown via `marked.js` configured for GFM.
  - Intercepts mermaid code blocks during rendering to output `<div class="mermaid">...</div>`.
  - Calls `mermaid.run()` to render the diagrams.

Suggested JS flow (high-level):
1. `init()` -> load list.
2. `loadFile(path)` -> fetch raw markdown.
3. `renderMarkdown(text)` -> `marked.parse(text)`.
4. `renderMermaid()` -> `mermaid.run({ nodes: ... })`.
5. Update `document.title` to file name.

---

## Server Details

### Path Safety

- Only allow relative paths under the base root.
- Reject any path containing `..`, drive letters, or absolute path prefixes.
- Normalize path segments and ensure final resolved path starts with the base root directory.
- Only serve files with allowed extensions to prevent leaking non-content files.
  - Allow: `.md`, `.markdown`
  - Allow Images: `.png`, `.jpg`, `.jpeg`, `.gif`, `.svg`, `.webp`

### Directory Listing

- Use `std.fs.Dir.walk` or `iterate` to build a list of Markdown files.
- Return sorted list in `/api/list` as JSON array of strings.
- Skip hidden directories like `.git` and `zig-cache` by default.

### MIME Types

- `/assets/*.js` -> `application/javascript`
- `/assets/*.css` -> `text/css`
- `/` and html -> `text/html; charset=utf-8`
- `/api/list` -> `application/json`
- `/api/file` -> `text/plain; charset=utf-8`
- Images:
  - `.png` -> `image/png`
  - `.jpg`, `.jpeg` -> `image/jpeg`
  - `.gif` -> `image/gif`
  - `.svg` -> `image/svg+xml`
  - `.webp` -> `image/webp`

### Error Handling

- Unknown route: 404 plain text.
- Bad query param: 400 with reason.
- File not found: 404 with reason.
- Internal errors: 500 with minimal detail.

---

## Front-End Assets (Self-Contained)

- Bundle minified vendor assets under `src/serve/assets/vendor/`.
  - **Action:** Download specific versions manually (e.g., from cdnjs or npm) and commit them to the repo.
  - Recommended: `marked` (v4+), and `mermaid` (v10+).
- Use `@embedFile` in `src/serve/assets.zig` to embed assets into the binary.
- Ensure licenses are preserved in a `src/serve/assets/vendor/NOTICE.md` if required.
- Avoid CDN dependencies to keep offline behavior consistent.

---

## Tests

### Unit Tests (Zig)

1. `serve/path.zig`
   - `normalizePath` rejects `..` traversal.
   - `normalizePath` rejects absolute and drive paths.
   - `normalizePath` accepts simple nested paths.

2. `serve/routes.zig`
   - Route matching for `/`, `/assets/*`, `/api/list`, `/api/file`.
   - Query parsing for `path` param.

3. `serve/assets.zig`
   - Content-type mapping for `.js`, `.css`, `.html`.

4. `serve/mod.zig`
   - List builder skips hidden dirs.
   - List builder returns sorted output.

### CLI Tests

- `parseArgs` includes `serve` and new flags (host/port/root/open).
- `registry.printHelp` lists `serve` and its alias.

### Integration Tests (Optional but recommended)

- Start server on ephemeral port in a thread, use `std.http.Client` to:
  - Fetch `/` and assert `200` and HTML marker.
  - Fetch `/api/list` and validate JSON.
  - Fetch `/api/file?path=...` and verify content.

## Technical Considerations

### Zig Standard Library
- Use `std.http.Server` (or `std.net.TcpListener` with manual HTTP parsing if `std.http.Server` is too unstable/complex for this use case, but `std.http` is preferred) for the web server implementation.
- If `--open` is used, spawn the browser process using `std.ChildProcess` in a non-blocking/detached manner so the server continues running.

### JSON Serialization
- Use `std.json.stringify` to generate the JSON response for `/api/list`.
- Use an `ArenaAllocator` to manage memory for the file list construction and serialization, freeing it all at the end of the request handling.

---

## Implementation Steps

1. Add `serve` command entry in `src/cli/registry.zig` and command dispatch.
2. Create `src/cli/commands/serve.zig` to parse flags and call server.
3. Implement `src/serve/path.zig` for safe path normalization.
4. Implement `src/serve/assets.zig` with embedded assets and MIME helper.
5. Implement `src/serve/routes.zig` for request parsing and routing.
6. Implement `src/serve/mod.zig` with the HTTP server loop.
7. Add front-end assets in `src/serve/assets/` (HTML, JS, CSS, vendor libs).
8. Add tests described above.
9. Update docs if needed (README or `art/` docs) to mention `ligi serve`.

---

## Open Questions

- Should default root be `./art` only, or `.` with a preference for `art`?
- Do we want to support rendering non-markdown assets (images) referenced by Markdown?
- Should `--open` be enabled by default or opt-in only?

