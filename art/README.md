# art/ (Ligi artifacts)

This directory is created by `ligi init` for each repo and for the global
`~/.ligi` store. It is the project's human/LLM artifact system.

Contents:
- `index/`    auto-maintained link + tag indexes
- `template/` prompt/report templates
- `config/`   Ligi config (e.g., `ligi.toml`)
- `archive/`  soft-delete area for retired docs

Docs:
- `ligi_art.md` explains the art directory
- `ligi_templates.md` explains templates

Please treat `art/` as durable project context. Avoid deleting or moving files
here unless explicitly requested; prefer `archive/` for cleanup. See
`art/founding_idea.md` for design intent.
