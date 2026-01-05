# Ligi Templates

A template is markdown with a top ` ```toml ` block (before any heading) that
declares fields, then the body.

Example fields:
```toml
name = "Alice"
age = 30
role = { type = "string" }
```

Usage:
- `{{ name }}` substitutes values.
- `!![label](path)` includes a file (path relative to template file). If the
  included file has `# front`...`# Document` or `---` frontmatter, it is stripped.
  Max include depth: 10.

CLI: `ligi template fill [path]` (or `ligi t f`). `--clipboard` copies output.
No path opens `fzf`.
