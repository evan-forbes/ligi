# ligi

> pronounced LEE-ghee, ligi is Esperanto for the verb "to link, connect, or tie"

Ligi is an opinionated, minimal Obsidian-like system written in Zig. It is CLI-first, expects you to keep using your existing text editor, and is built for humans to effectively generate code via LLMs, instead of "vibe coding". This is done via first generating and reviewing planning documents such as specs, ADRs, and implementation plans before proceeding with the actual generation of the code.

Notes are itemized markdown artifacts that can span many repos and projects. There is a global view in `~/.ligi` that aggregates registered repos, and you can also keep smaller scoped views for a company or team by initializing Ligi in a separate workspace. Voice input is built in via whisper.cpp, with Vulkan acceleration when available.

## Why

Software projects collect decisions, tasks, specs, and meeting notes. Those notes usually end up scattered across tools that do not live with the code and are awkward for LLMs to read. Ligi keeps the context next to the repo in plain markdown under `art/`. The same files are easy for humans to read and for LLMs to write.

## Install

```
zig build -Doptimize=ReleaseSafe
```

Requires Zig 0.15+.

Optional voice support on Linux:

```
sudo apt install libasound2-dev
make voice
```

## Quick Start

```bash
# Initialize in a repo
ligi init

# Create a doc with tags
echo "# Sprint Goals\n\n[[t/sprint-12]] [[t/planning]]\n\n- Ship auth\n- Fix perf regression" > art/sprint-goals.md

# Index tags
ligi index

# Query by tag
ligi query t planning

# Serve locally with rendered markdown
ligi serve
```

## Directory Structure

```
repo/
├── art/
│   ├── index/
│   │   ├── ligi_tags.md      # master tag index
│   │   └── tags/             # per-tag indexes
│   ├── template/             # prompt and report templates
│   ├── config/
│   │   └── ligi.toml
│   └── archive/              # soft-deleted docs
└── AGENTS.md                 # AI agent notes
```

Global artifacts live in `~/.ligi/` with the same structure. The global index tracks all registered repos.

## Tags

Wiki-style syntax: `[[t/tag_name]]`

Tags can appear anywhere in markdown except code blocks and HTML comments. Allowed characters: `A-Za-z0-9_-./`

See [art/ligi_tags.md](art/ligi_tags.md) for full details.

## Commands

### `ligi init`

Creates the `art/` directory structure and registers the repo in the global index. It also generates or updates `AGENTS.md` with instructions for LLMs to use Ligi in that repo. Use the global mode to create `~/.ligi`.

### `ligi index` / `ligi i`

Scans markdown files for tags, builds index files. You can index a single file or rebuild global indexes across all repos.

```bash
ligi index
```

### `ligi query t` / `ligi q t`

Query documents by tag. Supports boolean operations.

```bash
ligi q t planning              # files tagged [[t/planning]]
ligi q t sprint-12 & backend   # AND
ligi q t bug | urgent          # OR
ligi q t planning -o json      # JSON output
ligi q t planning -c           # copy to clipboard
```

### `ligi check`

Validates the global index. It can also prune broken entries.

Output:
```
/path/to/repo1 OK
/path/to/repo2 BROKEN
/path/to/repo3 MISSING_ART
```

### `ligi template fill` / `ligi t f`

Fill TOML frontmatter templates interactively.

```bash
ligi t f art/template/standup.md    # fill specific template
ligi t f                            # fzf picker
ligi t f template.md -c             # copy result to clipboard
```

Template format:
```markdown
# front

```toml
author = { type = "string", default = "anon" }
count = { type = "int", default = 0 }
```

# Report

Author: {{ author }}
Items completed: {{ count }}
```

### `ligi serve` / `ligi s`

Local HTTP server for rendered markdown. Supports GFM and Mermaid diagrams. Use the open option to launch a browser, or set a custom port and root directory.

```bash
ligi serve                     # serve ./art on :8777
ligi serve -p 3000             # custom port
ligi serve -r ./docs           # serve different directory
```

### `ligi backup`

Backup `~/.ligi` (must be a git repo). You can install a cron job and set a schedule.

```bash
ligi backup                          # run backup now
ligi backup -i -s "0 */6 * * *"      # every 6 hours
```

### `ligi v` / `ligi voice`

Record audio from the microphone and transcribe locally using whisper.cpp. Linux only. Supports time limits, model size selection, custom model files, offline mode, and clipboard copy. Vulkan acceleration is used when available.

```bash
ligi v                           # record and transcribe
ligi v -c                        # copy transcript to clipboard
```

Controls during recording:
- `Ctrl+C` or `Esc` - cancel recording
- `Space` - pause or resume recording

Model sizes: `tiny`, `base`, `small`, `medium`, `large` or the English-only variants `tiny.en`, `base.en`, `small.en`, `medium.en`.

Models are cached in `~/.cache/ligi/whisper/` and downloaded automatically on first use unless offline mode is selected.

## Configuration

`art/config/ligi.toml`:

```toml
version = "0.1.0"

[index]
ignore_patterns = ["*.tmp", "*.bak"]
follow_symlinks = false

[query]
default_format = "text"
```

## Use Cases

Replace GitHub Issues: keep one markdown file per item in `art/`, tag with `[[t/open]]`, `[[t/bug]]`, `[[t/p0]]`. Query with `ligi q t open & bug`. The bug tag and status tags act as the issue tracker.

Replace project boards: tag docs with `[[t/todo]]`, `[[t/in-progress]]`, `[[t/done]]`. Move tags as status changes. Everything is in git history.

Obsidian-like linking: tags function like backlinks. The index maintains bidirectional references. No proprietary sync, no cloud dependency.

LLM context: point agents at `art/` for project context. The markdown is self-describing. Agents can create and tag new artifacts directly.

## Design Principles

- Plain markdown, always
- Git-native, no external databases
- Index files are human-readable markdown
- Safe by default with path traversal protection
- No network dependencies for core functionality

## License

MIT
