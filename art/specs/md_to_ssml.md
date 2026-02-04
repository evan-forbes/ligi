# Spec: Markdown to SSML Converter

Module: `src/tts/ssml.zig`

Converts markdown text into SSML so that `ligi tts` produces natural spoken output instead of reading raw markdown syntax aloud. Pure transformation with no side effects — takes a UTF-8 string in, returns an SSML string out.

---

## Public API

### `convert(allocator, markdown) !SsmlResult`

Main entry point. Single-pass line scanner that classifies each line, skips non-speakable regions, applies inline transforms, and emits SSML into an output buffer.

- **Input**: raw markdown bytes (UTF-8)
- **Output**: `SsmlResult` containing the SSML string wrapped in `<speak>...</speak>`, plus line counts
- **Memory**: caller owns the returned `ssml` slice. Internally uses an arena for intermediates.

### `transformInline(allocator, content) ![]const u8`

Transforms inline markdown within a single content string (after block-level prefix stripping). Caller owns the returned slice.

Processing order:
1. Escape XML special characters (`& < > " '`)
2. Strip `[[t/...]]` tags
3. Strip `![alt](url)` images
4. Replace `[text](url)` links with `text`
5. Replace `**text**` / `__text__` with `<emphasis level="strong">text</emphasis>`
6. Replace `*text*` / `_text_` with `<emphasis level="moderate">text</emphasis>`
7. Strip backticks from `` `code` `` (keep content)

Unclosed markers (`**`, `*`) are left as literal text.

### `escapeXml(allocator, input) ![]const u8`

Escapes the five XML special characters. Ampersand is escaped first to prevent double-escaping.

### `stripTags(allocator, input) ![]const u8`

Removes all `[[t/...]]` tag references, including nested paths like `[[t/t/d/26-01-14]]`.

---

## Element Mapping

| Markdown | SSML Output |
|---|---|
| `# Heading` | `<break time="600ms"/><prosody rate="95%" pitch="+5%"><emphasis level="strong">...</emphasis></prosody><break time="400ms"/>` |
| `## Heading` | `<break time="500ms"/><prosody rate="97%"><emphasis level="strong">...</emphasis></prosody><break time="300ms"/>` |
| `### Heading` (and H4-H6) | `<break time="400ms"/><emphasis level="moderate">...</emphasis><break time="200ms"/>` |
| `- item` or `* item` | `<s>item</s>` |
| `  - nested` | `<s>nested</s>` (same as top-level) |
| `1. item` | `<s>item</s>` (number stripped) |
| `- [ ] task` | `<s>task. Not yet done.</s>` |
| `- [x] task` | `<s>task. Done.</s>` |
| `> quote` | `<emphasis level="moderate">quote</emphasis>` |
| `---` / `___` / `***` | `<break time="800ms"/>` |
| Plain text | `<p>text</p>` (consecutive lines merged with space) |
| `**bold**` | `<emphasis level="strong">bold</emphasis>` |
| `*italic*` | `<emphasis level="moderate">italic</emphasis>` |
| `` `code` `` | `code` (backticks stripped) |
| `[text](url)` | `text` (URL dropped) |
| `![alt](url)` | *(removed)* |
| `[[t/tag]]` | *(removed)* |

---

## Skipped Regions

These produce no spoken output. The state machine tracks entry/exit:

| Region | Entry | Exit |
|---|---|---|
| Fenced code block | Line starting with `` ``` `` | Next line starting with `` ``` `` |
| TOML frontmatter | `` ```toml `` within first 5 non-empty lines | Next `` ``` `` |
| `@remove` block | `` ```@remove `` | Next `` ``` `` |
| Table | Line starting with `\|` | First line not starting with `\|` |
| HTML comment (single-line) | Line starting with `<!--` that also contains `-->` | Same line |
| HTML comment (multi-line) | Line starting with `<!--` without `-->` | Line containing `-->` |
| Mermaid block | `` ```mermaid `` | Next `` ``` `` (treated as code block) |

---

## Line Classification Priority

Order matters. First match wins:

1. Heading (`#` through `######` followed by space)
2. Checkbox (`- [ ] ` or `- [x] `)
3. Bullet (`- ` or `* ` with optional leading whitespace)
4. Numbered (`digits` + `. ` + content)
5. Blockquote (`> ` + content)
6. Horizontal rule (3+ identical chars from `- _ *`, no spaces between)
7. Paragraph (everything else)

---

## Parser State Machine

```
                    +-----------+
                    |  normal   |<-----------+
                    +-----+-----+            |
                          |                  |
        +---------+-------+-------+------+   |
        |         |       |       |      |   |
        v         v       v       v      v   |
  fenced_code  frontmatter  remove  table  html_comment
        |         |       |       |      |
        |    closing ```  |   non-| line |
        +----closing ```--+   |   +-->---+
                              |
                          contains -->
```

All skip states return to `normal` on their exit condition. The `table` state is unique: on exit, the current line falls through to content classification (no `continue`).

---

## Timing Constants

| Constant | Value | Used For |
|---|---|---|
| `h1_pre_pause` | 600ms | Before H1 heading |
| `h1_post_pause` | 400ms | After H1 heading |
| `h2_pre_pause` | 500ms | Before H2 heading |
| `h2_post_pause` | 300ms | After H2 heading |
| `h3_pre_pause` | 400ms | Before H3-H6 heading |
| `h3_post_pause` | 200ms | After H3-H6 heading |
| `rule_pause` | 800ms | Horizontal rule |

Not user-configurable. Module-level constants.

---

## Memory Model

`convert` creates an internal `ArenaAllocator`. All intermediate strings (from `transformInline`, `escapeXml`, etc.) and the output buffer live in the arena. The final SSML string is `dupe`d into the caller's allocator before the arena is freed.

`transformInline` and its helpers (`escapeXml`, `stripTags`) each return caller-owned memory. In tests, `std.testing.allocator` catches leaks.

---

## Edge Cases

| Input | Behavior |
|---|---|
| Empty string | `<speak></speak>`, 0 processed, 0 skipped |
| Only whitespace | `<speak></speak>` |
| Only code blocks and tables | `<speak></speak>`, all lines skipped |
| Only `[[t/...]]` tags | Tags stripped, empty result after trim, no output |
| Unclosed code block | All subsequent lines skipped, no error |
| Unclosed `**` or `*` | Treated as literal text |
| `\r\n` line endings | `\r` stripped before processing |
| `- --` | Classified as bullet (content `--`), not horizontal rule |
| Line with `<!--` mid-text | Not detected as comment (must start the line) |

---

## Test Coverage

59 tests across two phases:

- **Phase 1** (28 tests): `escapeXml` (6), `stripTags` (5), `transformInline` (17 including 1 integration)
- **Phase 2** (31 tests): `convert` unit (27), `convert` integration (4)

Integration tests read `art/template/plan_feature.md` and `art/template/plan_day.md` from disk.

Tests registered in `src/root.zig` via `_ = @import("tts/ssml.zig")`.

---

## Phase 3 (Not Yet Implemented)

Integration with the `ligi tts` command. Blocked until the TTS command pipeline exists (see `art/inbox/tts_implementation_plan.md`). Will add:

- Auto-detection of `.md` / `.markdown` files for SSML conversion
- `--dry-run` flag (print SSML, no API call, no API key required)
- `--show-ssml` flag (print SSML to stderr, then synthesize)
- SSML auto-detection in `TtsClient.synthesize()` via `<speak>` prefix

---

*Source plan: art/inbox/markdown_to_ssml.md*
