# PDF Rendering Options for `ligi pdf`
[[t/pdf]](../index/tags/pdf.md)

## Goal

Add:

```bash
ligi pdf /path/to/doc.md
ligi pdf /path/to/doc.md -o /path/to/output.pdf
ligi pdf /path/to/doc.md -r
```

With support for:
- Images
- Links (external + internal)
- Mermaid diagrams
- Code snippets/highlighting
- Recursive mode (`-r`) that follows linked markdown files and emits one cohesive, clickable PDF

## What "Cohesive With Ligi" Means

The existing codebase already has:
- Embedded web assets (`marked`, `mermaid`, `highlight.js`) in `src/serve/assets/vendor/`
- A markdown browser renderer in `src/serve/assets/app.js`
- A clap-based command registry in `src/cli/registry.zig`

So the strongest option is the one that reuses this rendering stack and avoids introducing a second markdown dialect/renderer for normal output.

## Best Options (Max 3)

### 1. Recommended: Reuse `ligi serve` Rendering + Headless Chromium PDF Print

**How it works**
1. Add `pdf` command in Zig (`src/cli/commands/pdf.zig`).
2. Render target document using the existing embedded browser renderer (`marked + mermaid + highlight.js`).
3. For PDF generation, invoke Chrome/Chromium headless:
   - `--headless`
   - `--print-to-pdf`
   - `--no-pdf-header-footer`
   - `--timeout` and/or `--virtual-time-budget` for Mermaid/render settle time.
4. Write output to `-o` path or default to `<input>.pdf`.

**Why it fits ligi**
- Reuses current rendering behavior users already see in `ligi serve`.
- Keeps Mermaid/code rendering consistent between browser and PDF.
- No CDN requirement; assets are already embedded.

**Recursive mode (`-r`)**
- Build a local markdown graph from the root file:
  - Follow local `.md`/`.markdown` links.
  - Ignore external URLs.
  - Track visited files to prevent cycles.
- Produce one combined document in traversal order.
- Rewrite intra-doc links from `file.md#anchor` to internal anchors in the merged output.
- Keep external links as-is.

**Tradeoffs**
- Requires a local Chrome/Chromium binary at runtime (external dependency).
- Need a deterministic "render complete" signal before printing.

### 2. Pandoc Pipeline + Mermaid CLI Prepass

**How it works**
1. Preprocess Mermaid blocks with `mmdc` in markdown mode (diagram blocks become image references).
2. Run `pandoc` to produce PDF.
3. Use `--resource-path` for image resolution and `--toc`/`--toc-depth` as needed.

**Why it is good**
- Very mature document conversion toolchain.
- Strong PDF controls and code highlighting support.
- Easy to concatenate many input files for recursive mode.

**Recursive mode (`-r`)**
- Expand linked markdown set in Zig.
- Pass ordered files to pandoc (pandoc concatenates multiple input files).
- Rewrite local file links to section anchors in the merged content.

**Tradeoffs**
- Introduces more external tools (`pandoc`, TeX/WeasyPrint engine, plus `mmdc` for Mermaid).
- Output style can diverge from `ligi serve` unless heavily tuned.

### 3. mdBook Pipeline (`mdbook` + `mdbook-mermaid` + `mdbook-pdf`)

**How it works**
1. Generate a temporary mdBook (`book.toml` + `SUMMARY.md`) from linked docs.
2. Use `mdbook-mermaid` preprocessor for Mermaid.
3. Build HTML and export PDF via `mdbook-pdf`.

**Why it is good**
- Naturally designed for multi-page linked docs.
- Print mode exists in mdBook HTML renderer.

**Tradeoffs**
- Highest integration complexity for ligi.
- Additional toolchain/install burden.
- `mdbook-pdf` is a separate plugin stack; this is less cohesive than reusing existing `ligi serve` renderer.

## Recommendation

Choose **Option 1** for v1:
- It best matches existing ligi rendering behavior.
- It minimizes duplicate rendering logic.
- It gives full support for Mermaid/images/links/code with the current embedded assets.

Keep **Option 2** as fallback for environments where Chromium headless is unavailable.

## Decision

We are choosing **Option 1**.

Scope clarification:
- `ligi` will **not** embed Chromium in the binary.
- `ligi pdf` will invoke a system-installed `chrome`/`chromium` executable only when PDF generation is requested.
- If no compatible browser binary is found, `ligi pdf` should fail with a clear install hint.

## Proposed `ligi pdf` Spec

```text
Usage: ligi pdf <input.md> [-o <output.pdf>] [-r]
```

- `<input.md>`: required path to root markdown file.
- `-o, --output <path>`: optional output PDF path.
  - Default: same dir/name as input with `.pdf`.
- `-r, --recursive`: include linked markdown files recursively, merged into one PDF.

Behavior:
- Preserve external links.
- Resolve local image paths relative to the source file.
- Render Mermaid/code blocks before print.
- Fail clearly if the browser engine is not found.

## Implementation Shape in This Repo

- `src/cli/registry.zig`
  - Add `pdf` command metadata and clap params (`-o`, `-r`).
- `src/cli/commands/pdf.zig`
  - CLI entry + argument validation.
- `src/pdf/mod.zig` (new)
  - Recursive link graph + merge/rewrite logic.
  - HTML/PDF orchestration.
- `src/serve/mod.zig` and/or `src/serve/assets/app.js`
  - Add a PDF-oriented render mode or endpoint for deterministic print rendering.

## Sources

- Chrome headless PDF flags (`--print-to-pdf`, `--no-pdf-header-footer`, `--timeout`, `--virtual-time-budget`): https://developer.chrome.com/docs/chromium/headless
- Playwright `page.pdf()` behavior/options (if used instead of direct Chrome flags): https://playwright.dev/docs/next/api/class-page
- Pandoc PDF/engine/resource behavior: https://pandoc.org/MANUAL.html
- Mermaid CLI markdown transform + SVG generation: https://github.com/mermaid-js/mermaid-cli
- mdBook renderer/print config: https://rust-lang.github.io/mdBook/format/configuration/renderers.html
- mdBook preprocessors: https://rust-lang.github.io/mdBook/format/configuration/preprocessors.html
- mdbook-mermaid usage: https://docs.rs/crate/mdbook-mermaid/latest/source/README.md
- mdbook-pdf plugin: https://github.com/HuguesGuilleus/mdbook-pdf
