# art/ (Ligi artifacts)

This directory is created by `ligi init` for each repo and for the global
`~/.ligi` store. It is the project's human/LLM artifact system.

Contents:
- `index/`    auto-maintained link + tag indexes
- `template/` prompt/report templates
- `config/`   Ligi config (e.g., `ligi.toml`)
- `archive/`  soft-delete area for retired docs
- `media/`    images and diagrams for markdown docs
- `data/`     CSV/JSONL files for tables and visualizations

Docs:
- `ligi_art.md` explains the art directory
- `ligi_templates.md` explains templates
- `ligi_tags.md` explains tags

Please treat `art/` as durable project context. Avoid deleting or moving files
here unless explicitly requested; prefer `archive/` for cleanup. See
`art/founding_idea.md` for design intent.
