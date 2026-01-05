# Ligi Tags

Tags are wiki-style markers that let you categorize and query documents.

## Syntax

`[[t/tag_name]]` — place anywhere in markdown.

Nested paths work: `[[t/project/release/v1.0]]`

Allowed characters: `A-Za-z0-9_-./`

## What's Ignored

Tags inside these are skipped:
- Fenced code blocks (```)
- Inline code (`backticks`)
- HTML comments (`<!-- -->`)

## Commands

```bash
ligi index                # rebuild tag indexes
ligi query t planning     # files with [[t/planning]]
ligi q t bug & urgent     # AND query
ligi q t bug | urgent     # OR query
```

## Index Structure

After `ligi index`, indexes appear in `art/index/`:
- `ligi_tags.md` — master list of all tags
- `tags/tag_name.md` — files containing each tag
