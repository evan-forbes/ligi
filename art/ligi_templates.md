# Ligi Templates

A template is markdown with a top ` ```toml ` block (before any heading) that
declares fields, then the body.

Example fields:
```toml
name = "Alice"
age = 30
role = { type = "string" }
```

## Syntax

### Variable Substitution
`{{ name }}` substitutes values from the frontmatter or prompts.

### File Includes
`!![label](path)` includes a file (path relative to template file). If the
included file has `# front`...`# Document` or `---` frontmatter, it is stripped.
Max include depth: 10.

### Remove Blocks
Content inside ` ```@remove ` blocks is stripped when filling the template.
Use this for instructions that should appear in the raw template but not in
filled output:

````markdown
```@remove
> **Note**: Do not edit this template directly. Use `ligi f` to fill it.
```
````

This is useful for:
- Template usage instructions
- Agent/LLM instructions (e.g., "do not edit directly")
- Comments that only template authors need to see

See `art/template/impl_plan.md` for an example.

## CLI

`ligi f [path]` (or `ligi fill`). Use `--clipboard` to copy output.
Omit path to launch `fzf` for template selection.
