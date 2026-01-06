# ligi

> pronounced LEE-ghee, ligi is Esperanto for the verb "to link, connect, or tie"

A CLI tool for managing project artifacts as plain markdown. Replaces Obsidian-style document linking and GitHub project management with a git-native, LLM-friendly system.

## Why

Software projects accumulate context: design decisions, task lists, meeting notes, specs. This context typically lives in scattered locations—Notion, GitHub issues, Obsidian vaults, Slack threads—none of which are version-controlled with the code or easily consumed by LLMs.

ligi stores everything in `art/` as markdown files with wiki-style tags. The format is trivial for both humans and LLMs to read and write. When an LLM agent needs project context, it reads markdown. When it produces artifacts, it writes markdown. No API calls, no context window gymnastics.

The practical result: teams using LLM agents can coordinate through shared artifacts at significantly higher velocity. The agents read the same docs humans do.

## Install

```
zig build -Doptimize=ReleaseSafe
```

Requires Zig 0.15+.

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
ligi serve --open
```

## Directory Structure

```
repo/
├── art/
│   ├── index/
│   │   ├── ligi_tags.md      # master tag index
│   │   └── tags/             # per-tag indexes
│   ├── template/             # prompt/report templates
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

Creates the `art/` directory structure and registers the repo in the global index.

```bash
ligi init              # local repo
ligi init --global     # ~/.ligi
```

### `ligi index` / `ligi i`

Scans markdown files for tags, builds index files.

```bash
ligi index                    # index current repo
ligi index --file path.md     # index single file
ligi index --global           # rebuild global indexes from all repos
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

Validates the global index. Reports broken repo paths, missing `art/` directories.

```bash
ligi check              # list all repos with status
ligi check --prune      # remove broken entries
```

Output:
```
/path/to/repo1 OK
/path/to/repo2 BROKEN
/path/to/repo3 MISSING_ART
```

### `ligi template fill` / `ligi t f`

Fill TOML-frontmatter templates interactively.

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

Local HTTP server for rendered markdown. Supports GFM and Mermaid diagrams.

```bash
ligi serve                     # serve ./art on :8777
ligi serve -p 3000 --open      # custom port, open browser
ligi serve -r ./docs           # serve different directory
```

### `ligi backup`

Backup `~/.ligi` (must be a git repo).

```bash
ligi backup                          # run backup now
ligi backup --install                # install daily cron job
ligi backup -i -s "0 */6 * * *"      # every 6 hours
```

### `ligi v` / `ligi voice`

Record audio from the microphone and transcribe locally using whisper.cpp. Linux only.

```bash
ligi v                           # record and transcribe (default: 10m timeout, base.en model)
ligi v --timeout 5m              # limit recording to 5 minutes
ligi v --model-size small.en     # use smaller/faster model
ligi v --model-size large        # use large multilingual model
ligi v --model ~/my-model.bin    # use custom model file
ligi v --no-download             # fail if model not cached (don't download)
ligi v -c                        # copy transcript to clipboard
```

**Controls during recording:**
- `Ctrl+C` or `Esc` - cancel recording
- `Space` - pause/resume recording

**Model sizes:** `tiny`, `base`, `small`, `medium`, `large` (multilingual) or `tiny.en`, `base.en`, `small.en`, `medium.en` (English-only, faster).

Models are cached in `~/.cache/ligi/whisper/` and downloaded automatically on first use.

**Building with voice support:**

Voice requires ALSA development libraries and is built separately:

```bash
# Install dependencies (Debian/Ubuntu)
sudo apt install libasound2-dev

# Build and install with voice support
make voice
```

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

**Replace GitHub Issues**: Create `art/issues/` with one markdown file per issue. Tag with `[[t/open]]`, `[[t/bug]]`, `[[t/p0]]`. Query with `ligi q t open & bug`.

**Replace Project Boards**: Tag docs with `[[t/todo]]`, `[[t/in-progress]]`, `[[t/done]]`. Move tags as status changes. Everything is in git history.

**Obsidian-style Linking**: Tags function like backlinks. The index maintains bidirectional references. No proprietary sync, no cloud dependency.

**LLM Context**: Point agents at `art/` for project context. The markdown is self-describing. Agents can create and tag new artifacts directly.

## Design Principles

- Plain markdown, always
- Git-native (no external databases)
- Index files are human-readable markdown
- Safe by default (path traversal protection)
- No network dependencies for core functionality

## License

MIT
