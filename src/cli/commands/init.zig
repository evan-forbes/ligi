//! The `ligi init` command implementation.

const std = @import("std");
const core = @import("../../core/mod.zig");
const paths = core.paths;
const fs = core.fs;
const config = core.config;
const global_index = core.global_index;

/// Initial content for ligi_tags.md
pub const INITIAL_TAGS_INDEX =
    \\# Ligi Tag Index
    \\
    \\This file is auto-maintained by ligi. Each tag links to its index file.
    \\
    \\## Tags
    \\
    \\(No tags indexed yet)
    \\
;

/// Initial content for art/README.md
pub const INITIAL_ART_README =
    \\# art/ (Ligi artifacts)
    \\
    \\This directory is created by `ligi init` for each repo and for the global
    \\`~/.ligi` store. It is the project's human/LLM artifact system.
    \\
    \\Contents:
    \\- `index/`    auto-maintained link + tag indexes
    \\- `template/` prompt/report templates
    \\- `config/`   Ligi config (e.g., `ligi.toml`)
    \\- `archive/`  soft-delete area for retired docs
    \\- `media/`    images and diagrams for markdown docs
    \\- `data/`     CSV/JSONL files for tables and visualizations
    \\- `inbox/`    work-in-progress documents before final placement
    \\
    \\Docs:
    \\- `ligi_art.md` explains the art directory
    \\- `ligi_templates.md` explains templates
    \\- `ligi_tags.md` explains tags
    \\
    \\Please treat `art/` as durable project context. Avoid deleting or moving files
    \\here unless explicitly requested; prefer `archive/` for cleanup. See
    \\`art/founding_idea.md` for design intent.
    \\
;

/// Initial content for art/ligi_art.md
pub const INITIAL_LIGI_ART_DOC =
    \\# Ligi Art Directory
    \\
    \\`art/` is the durable Ligi artifact store (repo) and `~/.ligi/art` (global). It
    \\holds human/LLM context and is meant to live in git.
    \\
    \\Core areas:
    \\- `index/` auto-maintained tag/link indexes
    \\- `template/` reusable templates
    \\- `config/` ligi config
    \\- `archive/` retired docs
    \\- `media/` images and diagrams
    \\- `data/` structured data files
    \\- `inbox/` work-in-progress documents
    \\
;

/// Initial content for art/ligi_templates.md
pub const INITIAL_LIGI_TEMPLATES_DOC =
    \\# Ligi Templates
    \\
    \\A template is markdown with a top ` ```toml ` block (before any heading) that
    \\declares fields, then the body.
    \\
    \\Example fields:
    \\```toml
    \\name = "Alice"
    \\age = 30
    \\role = { type = "string" }
    \\```
    \\
    \\Usage:
    \\- `{{ name }}` substitutes values.
    \\- `!![label](path)` includes a file (path relative to template file). If the
    \\  included file has `# front`...`# Document` or `---` frontmatter, it is stripped.
    \\  Max include depth: 10.
    \\
    \\CLI: `ligi template fill [path]` (or `ligi t f`). `--clipboard` copies output.
    \\No path opens `fzf`.
    \\
;

/// Initial content for art/ligi_tags.md
pub const INITIAL_LIGI_TAGS_DOC =
    \\# Ligi Tags
    \\
    \\Tags are wiki-style markers that let you categorize and query documents.
    \\
    \\## Syntax
    \\
    \\`[[t/tag_name]]` — place anywhere in markdown.
    \\
    \\Nested paths work: `[[t/project/release/v1.0]]`
    \\
    \\Allowed characters: `A-Za-z0-9_-./`
    \\
    \\## What's Ignored
    \\
    \\Tags inside these are skipped:
    \\- Fenced code blocks (```)
    \\- Inline code (`backticks`)
    \\- HTML comments (`<!-- -->`)
    \\
    \\## Commands
    \\
    \\```bash
    \\ligi index                # rebuild tag indexes
    \\ligi query t planning     # files with [[t/planning]]
    \\ligi q t bug & urgent     # AND query
    \\ligi q t bug | urgent     # OR query
    \\```
    \\
    \\## Index Structure
    \\
    \\After `ligi index`, indexes appear in `art/index/`:
    \\- `ligi_tags.md` — master list of all tags
    \\- `tags/tag_name.md` — files containing each tag
    \\
;

/// Initial content for art/calendar.md
pub const INITIAL_CALENDAR_DOC =
    \\# Calendar
    \\
    \\This file is auto-maintained by `ligi plan`. Each section is newest-first.
    \\
    \\## Days
    \\
    \\## Weeks
    \\
    \\## Months
    \\
    \\## Quarters
    \\
;

/// Initial content for AGENTS.md
pub const INITIAL_AGENTS =
    \\# Ligi Agent Notes
    \\
    \\`art/` is the durable Ligi artifact store created by `ligi init`.
    \\
    \\Do not delete or move files under `art/` unless explicitly asked; archive instead
    \\(`art/archive/`). See `art/ligi_art.md` and `art/founding_idea.md`.
    \\
    \\Optional: run `scripts/install_git_hooks.sh` to block `art/` deletions.
    \\
;

/// Initial content for media/README.md
pub const INITIAL_MEDIA_README =
    \\# media/
    \\
    \\This directory holds media files (images, diagrams, etc.) referenced by markdown
    \\documents in this repository.
    \\
    \\Guidelines:
    \\- Use descriptive filenames (e.g., `architecture-overview.png`)
    \\- Prefer vector formats (SVG) when possible for diagrams
    \\- Reference files using relative paths from your markdown: `![alt](../media/image.png)`
    \\
;

/// Initial content for data/README.md
pub const INITIAL_DATA_README =
    \\# data/
    \\
    \\This directory holds structured data files (CSV, JSONL, etc.) that can be rendered
    \\into tables or visualizations in markdown documents.
    \\
    \\Guidelines:
    \\- Use descriptive filenames (e.g., `metrics-2024.csv`)
    \\- Include a header row in CSV files
    \\- Use JSONL for semi-structured or nested data
    \\
;

/// Initial content for inbox/README.md
pub const INITIAL_INBOX_README =
    \\# inbox/
    \\
    \\This directory is for work-in-progress documents. Use it to iterate on drafts
    \\before promoting them to their final location in `art/`.
    \\
    \\Workflow:
    \\1. Create and edit documents here while they're in progress
    \\2. When ready, move them to `art/` with tags:
    \\   ```bash
    \\   ligi index art/inbox/file.md -t todo,feature,tag_name
    \\   ```
    \\   This adds the tags to the file's frontmatter and indexes it.
    \\3. Then move the file to its final location in `art/`
    \\
    \\The inbox is not indexed by default during `ligi index` to keep your
    \\work-in-progress separate from finalized artifacts.
    \\
;

/// Initial content for art/index/extensions.md
pub const INITIAL_EXTENSIONS_INDEX =
    \\# Extensions
    \\
    \\An **extension** is a lightweight document that references another document to build on it or connect it to something else. Extensions are similar to comments but live as standalone files.
    \\
    \\## Usage
    \\
    \\Create an extension using:
    \\```bash
    \\ligi t art/template/extension.md
    \\```
    \\
    \\Files generated from this template should use the `ext_` prefix.
    \\
    \\## Structure
    \\
    \\Extensions contain:
    \\1. The `[[t/extension]]` tag
    \\2. A link to the referenced document
    \\
    \\That's it. Keep extensions minimal.
    \\
;

/// Initial content for art/template/extension.md
pub const INITIAL_EXTENSION_TEMPLATE =
    \\```toml
    \\other_doc_path = { type = "string" }
    \\```
    \\
    \\<!--
    \\AGENT INSTRUCTION:
    \\Do NOT edit this document directly.
    \\Create a new document with the prefix ext_ based on this template by copy-pasting the content and filling in the details.
    \\-->
    \\
    \\# Document
    \\
    \\[[t/extension]]
    \\
    \\[{{ other_doc_path }}]({{ other_doc_path }})
    \\
;

/// Initial content for art/template/impl_plan.md
pub const INITIAL_IMPL_PLAN_TEMPLATE =
    \\```toml
    \\feature_name = { type = "string" }
    \\feature_description = { type = "string" }
    \\cli_surface = { type = "string", default = "" }
    \\```
    \\
    \\<!--
    \\AGENT INSTRUCTION:
    \\Do NOT edit this document directly.
    \\Create a new document in the local `art/` directory based on this template by copy-pasting the content and filling in the details.
    \\-->
    \\
    \\# Document
    \\
    \\# Implementation Plan: {{ feature_name }}
    \\
    \\## Executive Summary
    \\
    \\<!--
    \\Write 2-3 sentences that a busy reader can scan to understand:
    \\1. What this feature does
    \\2. Why it matters
    \\3. The key technical approach
    \\-->
    \\
    \\-
    \\
    \\---
    \\
    \\## Part 1: Motivation
    \\
    \\### Problem Statement
    \\
    \\<!--
    \\What pain point does this solve? Be specific about the current state and why it's inadequate.
    \\Good: "Users cannot find documents by tag without manually searching each file"
    \\Bad: "We need tagging"
    \\-->
    \\
    \\-
    \\
    \\### User Story
    \\
    \\<!--
    \\Format: As a [user type], I want to [action] so that [benefit].
    \\The benefit should connect to a real workflow or outcome.
    \\-->
    \\
    \\{{ feature_description }}
    \\
    \\---
    \\
    \\## Part 2: Design Decisions
    \\
    \\<!--
    \\These are FINAL once documented. Future readers will reference this to understand why
    \\the system works the way it does. Include alternatives you considered and why you rejected them.
    \\Also include entries (even if "N/A") for: constraints, compatibility/backward-compat, dependencies,
    \\risks/mitigations, security/privacy (when applicable). For local-only CLI features, security/privacy
    \\may be "N/A"; for user input or server/networked features, it must be addressed.
    \\-->
    \\
    \\| # | Decision | Choice | Alternatives Considered | Rationale |
    \\|---|----------|--------|------------------------|-----------|
    \\| 1 | | | | |
    \\
    \\---
    \\
    \\## Part 3: Specification
    \\
    \\### Behavior Summary
    \\
    \\{{ cli_surface }}
    \\
    \\- **Command**:
    \\- **Input**:
    \\- **Output**:
    \\- **Side effects**:
    \\
    \\### Data Structures
    \\
    \\<!--
    \\Define types with field-level documentation. These become the source of truth for implementation.
    \\If this is a CLI feature, include the exit codes and their meanings here.
    \\After type definitions, include a Mermaid data flow diagram (where data is created, validated,
    \\transformed, and consumed) so implementers can follow the lifecycle. Use Mermaid, not text tables.
    \\-->
    \\
    \\```zig
    \\pub const Example = struct {
    \\    /// Description of what this field represents and valid values
    \\    field: []const u8,
    \\};
    \\```
    \\
    \\**Exit Codes**:
    \\| Code | Meaning | When Returned |
    \\|------|---------|---------------|
    \\| | | |
    \\
    \\**Data Flow (Mermaid)**:
    \\
    \\```mermaid
    \\flowchart LR
    \\    A[Source] --> B[Validation]
    \\    B --> C[Transformation]
    \\    C --> D[Consumption]
    \\```
    \\
    \\### File Formats
    \\
    \\<!--
    \\If this feature reads/writes files, specify the exact format with examples.
    \\-->
    \\
    \\### Error Messages
    \\
    \\<!--
    \\Define exact error message templates for consistency. Format:
    \\error: <context>: <cause>
    \\warning: <message>
    \\-->
    \\
    \\```
    \\error: <context>: <cause>
    \\```
    \\
    \\---
    \\
    \\## Part 4: Implementation
    \\
    \\### New/Modified Files
    \\
    \\| File | Purpose |
    \\|------|---------|
    \\| | |
    \\
    \\### Existing Touchpoints
    \\
    \\<!--
    \\List current files/modules/commands that this change will touch or depend on,
    \\and why they're relevant (e.g., reuse patterns, extend behavior, hook into flow).
    \\-->
    \\
    \\| Touchpoint | Why It Matters |
    \\|------------|----------------|
    \\| | |
    \\
    \\### Implementation Steps
    \\
    \\<!--
    \\Each step should be:
    \\- Atomic (can be completed in one sitting)
    \\- Verifiable (has clear done criteria)
    \\- Ordered (dependencies are explicit)
    \\Also: break work into easy, one-by-one steps. Each step should include (or point to)
    \\the test(s) you will add/run for that step so tests are written as you go.
    \\
    \\A junior developer unfamiliar with the codebase should be able to follow these.
    \\-->
    \\
    \\#### Step 1: [Description]
    \\
    \\**File(s)**:
    \\
    \\**Tasks**:
    \\-
    \\
    \\**Checklist**:
    \\- [ ]
    \\
    \\**Verification**:
    \\**Tests**:
    \\
    \\#### Step 2: [Description]
    \\
    \\-
    \\
    \\### Integration with Existing Code
    \\
    \\<!--
    \\Map this feature to existing modules. What can be reused? What patterns should be followed?
    \\-->
    \\
    \\| Existing Module | Use For |
    \\|----------------|---------|
    \\| | |
    \\
    \\---
    \\
    \\## Part 5: Known Limitations & Non-Goals
    \\
    \\<!--
    \\Explicitly list any intentional limitations or exclusions.
    \\These are not edge cases; they are deliberate tradeoffs.
    \\-->
    \\
    \\### Known Limitations
    \\
    \\-
    \\
    \\### Non-Goals
    \\
    \\-
    \\
    \\---
    \\
    \\## Part 6: Edge Cases
    \\
    \\<!--
    \\Exhaustive. If an edge case isn't listed, it will be handled inconsistently.
    \\Group by category for scannability.
    \\-->
    \\
    \\### Input Edge Cases
    \\
    \\| Case | Input | Expected Behavior |
    \\|------|-------|-------------------|
    \\| | | |
    \\
    \\### System Edge Cases
    \\
    \\| Case | Condition | Expected Behavior |
    \\|------|-----------|-------------------|
    \\| | | |
    \\
    \\---
    \\
    \\## Part 7: Testing
    \\
    \\<!--
    \\Tests prove correctness. Each test should verify one specific property.
    \\Name tests as statements: "tag_parsing_ignores_fenced_code_blocks"
    \\Start with a brief testing strategy note: scope, boundaries, and what's not tested.
    \\Ensure tests cover exit codes, error messages (100% coverage expected), and any constraints,
    \\compatibility or dependency behaviors called out in Part 2.
    \\-->
    \\
    \\### Testing Strategy
    \\
    \\-
    \\
    \\### Unit Tests
    \\
    \\| Test | Property Verified |
    \\|------|-------------------|
    \\| | |
    \\
    \\### Integration Tests
    \\
    \\| Test | Scenario |
    \\|------|----------|
    \\| | |
    \\
    \\### Smoke Tests
    \\
    \\```bash
    \\test_{{ feature_name }}() {
    \\    # Setup
    \\    # Execute
    \\    # Assert
    \\    echo "PASS: test_{{ feature_name }}"
    \\}
    \\```
    \\
    \\---
    \\
    \\## Part 8: Acceptance Criteria
    \\
    \\<!--
    \\All boxes must be checked before the feature is complete.
    \\Add feature-specific criteria beyond the standard ones.
    \\-->
    \\
    \\- [ ] Core functionality works as specified in Part 3
    \\- [ ] All edge cases from Part 6 are handled
    \\- [ ] All unit tests pass
    \\- [ ] All integration tests pass
    \\- [ ] Smoke tests pass
    \\- [ ] Help text documents the feature
    \\- [ ] No regressions in existing tests
    \\
    \\---
    \\
    \\## Part 9: Examples
    \\
    \\<!--
    \\Concrete examples make abstract specs tangible. Show real inputs and outputs.
    \\-->
    \\
    \\```
    \\$ ligi [command]
    \\[expected output]
    \\```
    \\
    \\---
    \\
    \\## Appendix A: Open Questions
    \\
    \\<!--
    \\Questions that need answers. Remove this section once all are resolved.
    \\Unresolved questions block implementation.
    \\-->
    \\
    \\- [ ] Question?
    \\
    \\## Appendix B: Future Considerations
    \\
    \\<!--
    \\Out of scope but documented for context. These should NOT be implemented as part of this plan.
    \\Helps future readers understand what was intentionally deferred.
    \\-->
    \\
    \\-
    \\
    \\## Appendix C: Implementation Order (Recommended)
    \\
    \\<!--
    \\Suggested sequence for tackling the implementation steps. Consider dependencies and testing feedback loops.
    \\-->
    \\
    \\1.
    \\
    \\---
    \\
    \\*Generated from art/template/impl_plan.md*
    \\
;

/// Initial content for art/template/impl_short_plan.md
pub const INITIAL_IMPL_SHORT_PLAN_TEMPLATE =
    \\```toml
    \\feature_name = { type = "string" }
    \\feature_description = { type = "string" }
    \\cli_surface = { type = "string", default = "" }
    \\```
    \\
    \\<!--
    \\AGENT INSTRUCTION:
    \\Do NOT edit this document directly.
    \\Create a new document in the local `art/` directory based on this template by copy-pasting the content and filling in the details.
    \\-->
    \\
    \\# Document
    \\
    \\# Short Implementation Plan: {{ feature_name }}
    \\
    \\## Summary
    \\
    \\<!--
    \\2-3 sentences: what it does, why it matters, and the approach.
    \\-->
    \\
    \\-
    \\
    \\---
    \\
    \\## Scope & Design Notes
    \\
    \\<!--
    \\Keep this compact. Include:
    \\- Constraints (perf/memory/platform)
    \\- Compatibility/backward-compat
    \\- Dependencies/prereqs
    \\- Risks/mitigations (if any)
    \\- Security/privacy (if applicable)
    \\-->
    \\
    \\-
    \\
    \\### Non-Goals
    \\
    \\-
    \\
    \\---
    \\
    \\## Specification (Compact)
    \\
    \\{{ cli_surface }}
    \\
    \\- **Command**:
    \\- **Input**:
    \\- **Output**:
    \\- **Side effects**:
    \\
    \\### Types / Messages
    \\
    \\<!--
    \\Define only the key structs or message shapes. Include exit codes.
    \\Append a Mermaid data flow diagram (create/validate/transform/consume). Use Mermaid, not text tables.
    \\-->
    \\
    \\```zig
    \\pub const Example = struct {
    \\    /// Description of what this field represents and valid values
    \\    field: []const u8,
    \\};
    \\```
    \\
    \\**Exit Codes**:
    \\| Code | Meaning | When Returned |
    \\|------|---------|---------------|
    \\| | | |
    \\
    \\**Data Flow (Mermaid)**:
    \\
    \\```mermaid
    \\flowchart LR
    \\    A[Source] --> B[Validation]
    \\    B --> C[Transformation]
    \\    C --> D[Consumption]
    \\```
    \\
    \\---
    \\
    \\## Implementation Notes
    \\
    \\### Touchpoints
    \\
    \\<!--
    \\Existing files/modules/commands affected and why.
    \\-->
    \\
    \\| Touchpoint | Why It Matters |
    \\|------------|----------------|
    \\| | |
    \\
    \\### Steps (High Level)
    \\
    \\1.
    \\2.
    \\3.
    \\
    \\---
    \\
    \\## Testing (Strategy + Essentials)
    \\
    \\<!--
    \\1-2 sentences on scope and boundaries. Ensure exit codes + error messages (100% coverage)
    \\and any constraints/compat/deps from Scope & Design Notes are exercised.
    \\-->
    \\
    \\- Strategy:
    \\- Unit:
    \\- Integration:
    \\- Smoke:
    \\
    \\---
    \\
    \\## Examples
    \\
    \\```
    \\$ ligi [command]
    \\[expected output]
    \\```
    \\
    \\---
    \\
    \\*Generated from art/template/impl_short_plan.md*
    \\
;

/// Initial content for art/template/plan_day.md
pub const INITIAL_PLAN_DAY_TEMPLATE =
    \\```toml
    \\date = { type = "string" }
    \\date_long = { type = "string" }
    \\day_tag = { type = "string" }
    \\week_tag = { type = "string" }
    \\month_tag = { type = "string" }
    \\quarter_tag = { type = "string" }
    \\prev_day_tag = { type = "string" }
    \\prev_week_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p day`.
    \\```
    \\
    \\# Daily Plan - {{ date_long }}
    \\
    \\[[t/planning]] [[t/{{ day_tag }}]] [[t/{{ week_tag }}]] [[t/{{ month_tag }}]] [[t/{{ quarter_tag }}]]
    \\
    \\## Review (required)
    \\- Review yesterday: [[t/{{ prev_day_tag }}]]
    \\- Review current week: [[t/{{ week_tag }}]]
    \\- Review open work: `ligi q t TODO | planning`
    \\
    \\## Today
    \\-
    \\
    \\## Commitments
    \\-
    \\
    \\## Notes
    \\-
    \\
;

/// Initial content for art/template/plan_week.md
pub const INITIAL_PLAN_WEEK_TEMPLATE =
    \\```toml
    \\week = { type = "string" }
    \\week_tag = { type = "string" }
    \\month_tag = { type = "string" }
    \\quarter_tag = { type = "string" }
    \\prev_week_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p week`.
    \\```
    \\
    \\# Weekly Plan - {{ week }}
    \\
    \\[[t/planning]] [[t/{{ week_tag }}]] [[t/{{ month_tag }}]] [[t/{{ quarter_tag }}]]
    \\
    \\## Review (required)
    \\- Review last week: [[t/{{ prev_week_tag }}]]
    \\- Review open work: `ligi q t TODO | planning`
    \\
    \\## Goals
    \\-
    \\
    \\## Scope
    \\- In:
    \\- Out:
    \\
    \\## Risks / Dependencies
    \\-
    \\
;

/// Initial content for art/template/plan_month.md
pub const INITIAL_PLAN_MONTH_TEMPLATE =
    \\```toml
    \\month = { type = "string" }
    \\month_tag = { type = "string" }
    \\quarter_tag = { type = "string" }
    \\prev_month_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p month`.
    \\```
    \\
    \\# Monthly Plan - {{ month }}
    \\
    \\[[t/planning]] [[t/{{ month_tag }}]] [[t/{{ quarter_tag }}]]
    \\
    \\## Review (required)
    \\- Review last month: [[t/{{ prev_month_tag }}]]
    \\- Review open work: `ligi q t TODO | planning`
    \\
    \\## Goals
    \\-
    \\
    \\## Milestones
    \\-
    \\
    \\## Risks / Dependencies
    \\-
    \\
;

/// Initial content for art/template/plan_quarter.md
pub const INITIAL_PLAN_QUARTER_TEMPLATE =
    \\```toml
    \\quarter = { type = "string" }
    \\quarter_tag = { type = "string" }
    \\prev_quarter_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p quarter`.
    \\```
    \\
    \\# Quarterly Plan - {{ quarter }}
    \\
    \\[[t/planning]] [[t/{{ quarter_tag }}]]
    \\
    \\## Review (required)
    \\- Review last quarter: [[t/{{ prev_quarter_tag }}]]
    \\- Review open work: `ligi q t TODO | planning`
    \\
    \\## Themes
    \\-
    \\
    \\## Outcomes
    \\-
    \\
    \\## Risks / Dependencies
    \\-
    \\
;

/// Initial content for art/template/plan_day_short.md
pub const INITIAL_PLAN_DAY_SHORT_TEMPLATE =
    \\```toml
    \\date_long = { type = "string" }
    \\day_tag = { type = "string" }
    \\week_tag = { type = "string" }
    \\month_tag = { type = "string" }
    \\quarter_tag = { type = "string" }
    \\prev_day_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p day -l short`.
    \\```
    \\
    \\# Daily Plan - {{ date_long }}
    \\
    \\[[t/planning]] [[t/{{ day_tag }}]] [[t/{{ week_tag }}]] [[t/{{ month_tag }}]] [[t/{{ quarter_tag }}]]
    \\
    \\## Review
    \\- Yesterday: [[t/{{ prev_day_tag }}]]
    \\- Week: [[t/{{ week_tag }}]]
    \\
    \\## Focus
    \\-
    \\
    \\## Notes
    \\-
    \\
;

/// Initial content for art/template/plan_week_short.md
pub const INITIAL_PLAN_WEEK_SHORT_TEMPLATE =
    \\```toml
    \\week = { type = "string" }
    \\week_tag = { type = "string" }
    \\month_tag = { type = "string" }
    \\quarter_tag = { type = "string" }
    \\prev_week_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p week -l short`.
    \\```
    \\
    \\# Weekly Plan - {{ week }}
    \\
    \\[[t/planning]] [[t/{{ week_tag }}]] [[t/{{ month_tag }}]] [[t/{{ quarter_tag }}]]
    \\
    \\## Review
    \\- Last week: [[t/{{ prev_week_tag }}]]
    \\
    \\## Goals
    \\-
    \\
    \\## Notes
    \\-
    \\
;

/// Initial content for art/template/plan_month_short.md
pub const INITIAL_PLAN_MONTH_SHORT_TEMPLATE =
    \\```toml
    \\month = { type = "string" }
    \\month_tag = { type = "string" }
    \\quarter_tag = { type = "string" }
    \\prev_month_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p month -l short`.
    \\```
    \\
    \\# Monthly Plan - {{ month }}
    \\
    \\[[t/planning]] [[t/{{ month_tag }}]] [[t/{{ quarter_tag }}]]
    \\
    \\## Review
    \\- Last month: [[t/{{ prev_month_tag }}]]
    \\
    \\## Goals
    \\-
    \\
    \\## Notes
    \\-
    \\
;

/// Initial content for art/template/plan_quarter_short.md
pub const INITIAL_PLAN_QUARTER_SHORT_TEMPLATE =
    \\```toml
    \\quarter = { type = "string" }
    \\quarter_tag = { type = "string" }
    \\prev_quarter_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p quarter -l short`.
    \\```
    \\
    \\# Quarterly Plan - {{ quarter }}
    \\
    \\[[t/planning]] [[t/{{ quarter_tag }}]]
    \\
    \\## Review
    \\- Last quarter: [[t/{{ prev_quarter_tag }}]]
    \\
    \\## Themes
    \\-
    \\
    \\## Notes
    \\-
    \\
;

/// Initial content for art/template/plan_feature.md
pub const INITIAL_PLAN_FEATURE_TEMPLATE =
    \\```toml
    \\item = { type = "string" }
    \\date_long = { type = "string" }
    \\day_tag = { type = "string" }
    \\week_tag = { type = "string" }
    \\month_tag = { type = "string" }
    \\quarter_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p feature <name>`.
    \\```
    \\
    \\# Feature Plan - {{ item }}
    \\
    \\Date: {{ date_long }}
    \\
    \\[[t/planning]] [[t/feature]] [[t/{{ day_tag }}]] [[t/{{ week_tag }}]] [[t/{{ month_tag }}]] [[t/{{ quarter_tag }}]]
    \\
    \\## Summary
    \\-
    \\
    \\## Problem / Opportunity
    \\-
    \\
    \\## Desired Outcome
    \\-
    \\
    \\## Scope
    \\- In:
    \\- Out:
    \\
    \\## Plan
    \\-
    \\
    \\## Risks / Dependencies
    \\-
    \\
    \\## Definition of Done
    \\-
    \\
    \\## Notes
    \\-
    \\
;

/// Initial content for art/template/plan_feature_short.md
pub const INITIAL_PLAN_FEATURE_SHORT_TEMPLATE =
    \\```toml
    \\item = { type = "string" }
    \\date_long = { type = "string" }
    \\day_tag = { type = "string" }
    \\week_tag = { type = "string" }
    \\month_tag = { type = "string" }
    \\quarter_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p feature <name> -l short`.
    \\```
    \\
    \\# Feature Plan - {{ item }}
    \\
    \\Date: {{ date_long }}
    \\
    \\[[t/planning]] [[t/feature]] [[t/{{ day_tag }}]] [[t/{{ week_tag }}]] [[t/{{ month_tag }}]] [[t/{{ quarter_tag }}]]
    \\
    \\## Goal
    \\-
    \\
    \\## Approach
    \\-
    \\
    \\## Done When
    \\-
    \\
;

/// Initial content for art/template/plan_chore.md
pub const INITIAL_PLAN_CHORE_TEMPLATE =
    \\```toml
    \\item = { type = "string" }
    \\date_long = { type = "string" }
    \\day_tag = { type = "string" }
    \\week_tag = { type = "string" }
    \\month_tag = { type = "string" }
    \\quarter_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p chore <name>`.
    \\```
    \\
    \\# Chore Plan - {{ item }}
    \\
    \\Date: {{ date_long }}
    \\
    \\[[t/planning]] [[t/chore]] [[t/{{ day_tag }}]] [[t/{{ week_tag }}]] [[t/{{ month_tag }}]] [[t/{{ quarter_tag }}]]
    \\
    \\## Purpose
    \\-
    \\
    \\## Steps
    \\-
    \\
    \\## Checks
    \\-
    \\
    \\## Risks / Dependencies
    \\-
    \\
    \\## Notes
    \\-
    \\
;

/// Initial content for art/template/plan_chore_short.md
pub const INITIAL_PLAN_CHORE_SHORT_TEMPLATE =
    \\```toml
    \\item = { type = "string" }
    \\date_long = { type = "string" }
    \\day_tag = { type = "string" }
    \\week_tag = { type = "string" }
    \\month_tag = { type = "string" }
    \\quarter_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p chore <name> -l short`.
    \\```
    \\
    \\# Chore Plan - {{ item }}
    \\
    \\Date: {{ date_long }}
    \\
    \\[[t/planning]] [[t/chore]] [[t/{{ day_tag }}]] [[t/{{ week_tag }}]] [[t/{{ month_tag }}]] [[t/{{ quarter_tag }}]]
    \\
    \\## Steps
    \\-
    \\
    \\## Done When
    \\-
    \\
;

/// Initial content for art/template/plan_refactor.md
pub const INITIAL_PLAN_REFACTOR_TEMPLATE =
    \\```toml
    \\item = { type = "string" }
    \\date_long = { type = "string" }
    \\day_tag = { type = "string" }
    \\week_tag = { type = "string" }
    \\month_tag = { type = "string" }
    \\quarter_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p refactor <name>`.
    \\```
    \\
    \\# Refactor Plan - {{ item }}
    \\
    \\Date: {{ date_long }}
    \\
    \\[[t/planning]] [[t/refactor]] [[t/{{ day_tag }}]] [[t/{{ week_tag }}]] [[t/{{ month_tag }}]] [[t/{{ quarter_tag }}]]
    \\
    \\## Motivation
    \\-
    \\
    \\## Target Areas
    \\-
    \\
    \\## Strategy
    \\-
    \\
    \\## Safety / Rollout
    \\-
    \\
    \\## Risks / Dependencies
    \\-
    \\
    \\## Success Criteria
    \\-
    \\
;

/// Initial content for art/template/plan_refactor_short.md
pub const INITIAL_PLAN_REFACTOR_SHORT_TEMPLATE =
    \\```toml
    \\item = { type = "string" }
    \\date_long = { type = "string" }
    \\day_tag = { type = "string" }
    \\week_tag = { type = "string" }
    \\month_tag = { type = "string" }
    \\quarter_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p refactor <name> -l short`.
    \\```
    \\
    \\# Refactor Plan - {{ item }}
    \\
    \\Date: {{ date_long }}
    \\
    \\[[t/planning]] [[t/refactor]] [[t/{{ day_tag }}]] [[t/{{ week_tag }}]] [[t/{{ month_tag }}]] [[t/{{ quarter_tag }}]]
    \\
    \\## Strategy
    \\-
    \\
    \\## Done When
    \\-
    \\
;

/// Initial content for art/template/plan_perf.md
pub const INITIAL_PLAN_PERF_TEMPLATE =
    \\```toml
    \\item = { type = "string" }
    \\date_long = { type = "string" }
    \\day_tag = { type = "string" }
    \\week_tag = { type = "string" }
    \\month_tag = { type = "string" }
    \\quarter_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p perf <name>`.
    \\```
    \\
    \\# Performance Plan - {{ item }}
    \\
    \\Date: {{ date_long }}
    \\
    \\[[t/planning]] [[t/perf]] [[t/{{ day_tag }}]] [[t/{{ week_tag }}]] [[t/{{ month_tag }}]] [[t/{{ quarter_tag }}]]
    \\
    \\## Baseline
    \\-
    \\
    \\## Target
    \\-
    \\
    \\## Hypothesis
    \\-
    \\
    \\## Plan
    \\-
    \\
    \\## Validation
    \\-
    \\
    \\## Risks / Dependencies
    \\-
    \\
;

/// Initial content for art/template/plan_perf_short.md
pub const INITIAL_PLAN_PERF_SHORT_TEMPLATE =
    \\```toml
    \\item = { type = "string" }
    \\date_long = { type = "string" }
    \\day_tag = { type = "string" }
    \\week_tag = { type = "string" }
    \\month_tag = { type = "string" }
    \\quarter_tag = { type = "string" }
    \\```
    \\
    \\```@remove
    \\> **Template Instructions**
    \\>
    \\> Do NOT edit this template directly. Create a new doc with `ligi p perf <name> -l short`.
    \\```
    \\
    \\# Performance Plan - {{ item }}
    \\
    \\Date: {{ date_long }}
    \\
    \\[[t/planning]] [[t/perf]] [[t/{{ day_tag }}]] [[t/{{ week_tag }}]] [[t/{{ month_tag }}]] [[t/{{ quarter_tag }}]]
    \\
    \\## Target
    \\-
    \\
    \\## Approach
    \\-
    \\
    \\## Validation
    \\-
    \\
;

/// Result of init operation for reporting
pub const InitResult = struct {
    created_dirs: std.ArrayList([]const u8) = .empty,
    skipped_dirs: std.ArrayList([]const u8) = .empty,
    created_files: std.ArrayList([]const u8) = .empty,
    skipped_files: std.ArrayList([]const u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) InitResult {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *InitResult) void {
        for (self.created_dirs.items) |path| {
            self.allocator.free(path);
        }
        for (self.skipped_dirs.items) |path| {
            self.allocator.free(path);
        }
        for (self.created_files.items) |path| {
            self.allocator.free(path);
        }
        for (self.skipped_files.items) |path| {
            self.allocator.free(path);
        }
        self.created_dirs.deinit(self.allocator);
        self.skipped_dirs.deinit(self.allocator);
        self.created_files.deinit(self.allocator);
        self.skipped_files.deinit(self.allocator);
    }
};

/// Run the init command
pub fn run(
    allocator: std.mem.Allocator,
    global: bool,
    root_override: ?[]const u8,
    quiet: bool,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var result = InitResult.init(allocator);
    defer result.deinit();

    // Determine base path
    var base_path: []const u8 = undefined;
    var base_path_allocated = false;
    defer if (base_path_allocated) allocator.free(base_path);

    if (root_override) |r| {
        base_path = r;
    } else if (global) {
        switch (paths.getGlobalRoot(allocator)) {
            .ok => |p| {
                base_path = p;
                base_path_allocated = true;
            },
            .err => |e| {
                try e.write(stderr);
                return e.exitCode();
            },
        }
    } else {
        base_path = ".";
    }

    // Create main art directory
    const art_path = try paths.joinPath(allocator, &.{ base_path, "art" });
    defer allocator.free(art_path);

    try createDirTracked(allocator, art_path, &result);

    // Create special subdirectories
    for (paths.SPECIAL_DIRS) |special| {
        const dir_path = try paths.joinPath(allocator, &.{ art_path, special });
        defer allocator.free(dir_path);
        try createDirTracked(allocator, dir_path, &result);
    }

    // Create initial files
    // 1. Tag index in art/index/ligi_tags.md
    const tags_path = try paths.joinPath(allocator, &.{ art_path, "index", "ligi_tags.md" });
    defer allocator.free(tags_path);
    try createFileTracked(allocator, tags_path, INITIAL_TAGS_INDEX, &result);

    // 2. Art README in art/README.md
    const art_readme_path = try paths.joinPath(allocator, &.{ art_path, "README.md" });
    defer allocator.free(art_readme_path);
    try createFileTracked(allocator, art_readme_path, INITIAL_ART_README, &result);

    // 3. Art docs in art/
    const art_doc_path = try paths.joinPath(allocator, &.{ art_path, "ligi_art.md" });
    defer allocator.free(art_doc_path);
    try createFileTracked(allocator, art_doc_path, INITIAL_LIGI_ART_DOC, &result);

    const templates_doc_path = try paths.joinPath(allocator, &.{ art_path, "ligi_templates.md" });
    defer allocator.free(templates_doc_path);
    try createFileTracked(allocator, templates_doc_path, INITIAL_LIGI_TEMPLATES_DOC, &result);

    const tags_doc_path = try paths.joinPath(allocator, &.{ art_path, "ligi_tags.md" });
    defer allocator.free(tags_doc_path);
    try createFileTracked(allocator, tags_doc_path, INITIAL_LIGI_TAGS_DOC, &result);

    const calendar_path = try paths.joinPath(allocator, &.{ art_path, "calendar.md" });
    defer allocator.free(calendar_path);
    try createFileTracked(allocator, calendar_path, INITIAL_CALENDAR_DOC, &result);

    // 4. AGENTS.md in base path
    const agents_path = try paths.joinPath(allocator, &.{ base_path, "AGENTS.md" });
    defer allocator.free(agents_path);
    try createFileTracked(allocator, agents_path, INITIAL_AGENTS, &result);

    // 5. media/ directory and README (inside art/)
    const media_path = try paths.joinPath(allocator, &.{ art_path, "media" });
    defer allocator.free(media_path);
    try createDirTracked(allocator, media_path, &result);

    const media_readme_path = try paths.joinPath(allocator, &.{ media_path, "README.md" });
    defer allocator.free(media_readme_path);
    try createFileTracked(allocator, media_readme_path, INITIAL_MEDIA_README, &result);

    // 6. data/ directory and README (inside art/)
    const data_path = try paths.joinPath(allocator, &.{ art_path, "data" });
    defer allocator.free(data_path);
    try createDirTracked(allocator, data_path, &result);

    const data_readme_path = try paths.joinPath(allocator, &.{ data_path, "README.md" });
    defer allocator.free(data_readme_path);
    try createFileTracked(allocator, data_readme_path, INITIAL_DATA_README, &result);

    // 7. inbox/ directory and README (inside art/)
    const inbox_path = try paths.joinPath(allocator, &.{ art_path, "inbox" });
    defer allocator.free(inbox_path);
    try createDirTracked(allocator, inbox_path, &result);

    const inbox_readme_path = try paths.joinPath(allocator, &.{ inbox_path, "README.md" });
    defer allocator.free(inbox_readme_path);
    try createFileTracked(allocator, inbox_readme_path, INITIAL_INBOX_README, &result);

    // 8. Extensions index in art/index/extensions.md
    const extensions_index_path = try paths.joinPath(allocator, &.{ art_path, "index", "extensions.md" });
    defer allocator.free(extensions_index_path);
    try createFileTracked(allocator, extensions_index_path, INITIAL_EXTENSIONS_INDEX, &result);

    // 9. Template files in art/template/
    const template_path = try paths.joinPath(allocator, &.{ art_path, "template" });
    defer allocator.free(template_path);

    const extension_template_path = try paths.joinPath(allocator, &.{ template_path, "extension.md" });
    defer allocator.free(extension_template_path);
    try createFileTracked(allocator, extension_template_path, INITIAL_EXTENSION_TEMPLATE, &result);

    const impl_plan_path = try paths.joinPath(allocator, &.{ template_path, "impl_plan.md" });
    defer allocator.free(impl_plan_path);
    try createFileTracked(allocator, impl_plan_path, INITIAL_IMPL_PLAN_TEMPLATE, &result);

    const impl_short_plan_path = try paths.joinPath(allocator, &.{ template_path, "impl_short_plan.md" });
    defer allocator.free(impl_short_plan_path);
    try createFileTracked(allocator, impl_short_plan_path, INITIAL_IMPL_SHORT_PLAN_TEMPLATE, &result);

    const plan_day_path = try paths.joinPath(allocator, &.{ template_path, "plan_day.md" });
    defer allocator.free(plan_day_path);
    try createFileTracked(allocator, plan_day_path, INITIAL_PLAN_DAY_TEMPLATE, &result);

    const plan_week_path = try paths.joinPath(allocator, &.{ template_path, "plan_week.md" });
    defer allocator.free(plan_week_path);
    try createFileTracked(allocator, plan_week_path, INITIAL_PLAN_WEEK_TEMPLATE, &result);

    const plan_month_path = try paths.joinPath(allocator, &.{ template_path, "plan_month.md" });
    defer allocator.free(plan_month_path);
    try createFileTracked(allocator, plan_month_path, INITIAL_PLAN_MONTH_TEMPLATE, &result);

    const plan_quarter_path = try paths.joinPath(allocator, &.{ template_path, "plan_quarter.md" });
    defer allocator.free(plan_quarter_path);
    try createFileTracked(allocator, plan_quarter_path, INITIAL_PLAN_QUARTER_TEMPLATE, &result);

    const plan_day_short_path = try paths.joinPath(allocator, &.{ template_path, "plan_day_short.md" });
    defer allocator.free(plan_day_short_path);
    try createFileTracked(allocator, plan_day_short_path, INITIAL_PLAN_DAY_SHORT_TEMPLATE, &result);

    const plan_week_short_path = try paths.joinPath(allocator, &.{ template_path, "plan_week_short.md" });
    defer allocator.free(plan_week_short_path);
    try createFileTracked(allocator, plan_week_short_path, INITIAL_PLAN_WEEK_SHORT_TEMPLATE, &result);

    const plan_month_short_path = try paths.joinPath(allocator, &.{ template_path, "plan_month_short.md" });
    defer allocator.free(plan_month_short_path);
    try createFileTracked(allocator, plan_month_short_path, INITIAL_PLAN_MONTH_SHORT_TEMPLATE, &result);

    const plan_quarter_short_path = try paths.joinPath(allocator, &.{ template_path, "plan_quarter_short.md" });
    defer allocator.free(plan_quarter_short_path);
    try createFileTracked(allocator, plan_quarter_short_path, INITIAL_PLAN_QUARTER_SHORT_TEMPLATE, &result);

    const plan_feature_path = try paths.joinPath(allocator, &.{ template_path, "plan_feature.md" });
    defer allocator.free(plan_feature_path);
    try createFileTracked(allocator, plan_feature_path, INITIAL_PLAN_FEATURE_TEMPLATE, &result);

    const plan_feature_short_path = try paths.joinPath(allocator, &.{ template_path, "plan_feature_short.md" });
    defer allocator.free(plan_feature_short_path);
    try createFileTracked(allocator, plan_feature_short_path, INITIAL_PLAN_FEATURE_SHORT_TEMPLATE, &result);

    const plan_chore_path = try paths.joinPath(allocator, &.{ template_path, "plan_chore.md" });
    defer allocator.free(plan_chore_path);
    try createFileTracked(allocator, plan_chore_path, INITIAL_PLAN_CHORE_TEMPLATE, &result);

    const plan_chore_short_path = try paths.joinPath(allocator, &.{ template_path, "plan_chore_short.md" });
    defer allocator.free(plan_chore_short_path);
    try createFileTracked(allocator, plan_chore_short_path, INITIAL_PLAN_CHORE_SHORT_TEMPLATE, &result);

    const plan_refactor_path = try paths.joinPath(allocator, &.{ template_path, "plan_refactor.md" });
    defer allocator.free(plan_refactor_path);
    try createFileTracked(allocator, plan_refactor_path, INITIAL_PLAN_REFACTOR_TEMPLATE, &result);

    const plan_refactor_short_path = try paths.joinPath(allocator, &.{ template_path, "plan_refactor_short.md" });
    defer allocator.free(plan_refactor_short_path);
    try createFileTracked(allocator, plan_refactor_short_path, INITIAL_PLAN_REFACTOR_SHORT_TEMPLATE, &result);

    const plan_perf_path = try paths.joinPath(allocator, &.{ template_path, "plan_perf.md" });
    defer allocator.free(plan_perf_path);
    try createFileTracked(allocator, plan_perf_path, INITIAL_PLAN_PERF_TEMPLATE, &result);

    const plan_perf_short_path = try paths.joinPath(allocator, &.{ template_path, "plan_perf_short.md" });
    defer allocator.free(plan_perf_short_path);
    try createFileTracked(allocator, plan_perf_short_path, INITIAL_PLAN_PERF_SHORT_TEMPLATE, &result);

    // 10. Config file
    var config_dir: []const u8 = undefined;
    var config_dir_allocated = false;
    defer if (config_dir_allocated) allocator.free(config_dir);

    if (global) {
        switch (paths.getGlobalConfigPath(allocator)) {
            .ok => |p| {
                config_dir = p;
                config_dir_allocated = true;
            },
            .err => |e| {
                try e.write(stderr);
                return e.exitCode();
            },
        }
    } else {
        config_dir = try paths.joinPath(allocator, &.{ art_path, "config" });
        config_dir_allocated = true;
    }

    // Ensure config dir exists
    try createDirTracked(allocator, config_dir, &result);

    const config_path = try paths.joinPath(allocator, &.{ config_dir, "ligi.toml" });
    defer allocator.free(config_path);
    try createFileTracked(allocator, config_path, config.DEFAULT_CONFIG_TOML, &result);

    // Register repo in global index (only for local init, not --global)
    if (!global) {
        switch (global_index.registerRepo(allocator, base_path)) {
            .ok => {},
            .err => |e| {
                // Non-fatal: warn but continue
                try stderr.writeAll("warning: failed to register repo in global index: ");
                try e.context.format("", .{}, stderr);
                try stderr.writeAll("\n");
            },
        }
    }

    // Print summary if not quiet
    if (!quiet) {
        if (result.created_dirs.items.len > 0 or result.created_files.items.len > 0) {
            try stdout.print("Initialized ligi in {s}\n", .{base_path});
            for (result.created_dirs.items) |dir| {
                try stdout.print("  created: {s}/\n", .{dir});
            }
            for (result.created_files.items) |file| {
                try stdout.print("  created: {s}\n", .{file});
            }
        } else {
            try stdout.print("ligi already initialized in {s}\n", .{base_path});
        }
    }

    return 0;
}

fn createDirTracked(allocator: std.mem.Allocator, path: []const u8, result: *InitResult) !void {
    const existed = fs.dirExists(path);
    switch (fs.ensureDirRecursive(path)) {
        .ok => {
            const path_copy = try allocator.dupe(u8, path);
            if (!existed) {
                try result.created_dirs.append(allocator, path_copy);
            } else {
                try result.skipped_dirs.append(allocator, path_copy);
            }
        },
        .err => |e| {
            std.debug.print("Warning: {s}\n", .{e.context.message});
        },
    }
}

fn createFileTracked(allocator: std.mem.Allocator, path: []const u8, content: []const u8, result: *InitResult) !void {
    switch (fs.writeFileIfNotExists(path, content)) {
        .ok => |created| {
            const path_copy = try allocator.dupe(u8, path);
            if (created) {
                try result.created_files.append(allocator, path_copy);
            } else {
                try result.skipped_files.append(allocator, path_copy);
            }
        },
        .err => |e| {
            std.debug.print("Warning: {s}\n", .{e.context.message});
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

test "INITIAL_TAGS_INDEX contains expected header" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_TAGS_INDEX, "# Ligi Tag Index") != null);
}

test "INITIAL_TAGS_INDEX contains Tags section" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_TAGS_INDEX, "## Tags") != null);
}

test "INITIAL_ART_README contains header" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_ART_README, "# art/ (Ligi artifacts)") != null);
}

test "INITIAL_LIGI_ART_DOC contains header" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_LIGI_ART_DOC, "# Ligi Art Directory") != null);
}

test "INITIAL_LIGI_TEMPLATES_DOC contains header" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_LIGI_TEMPLATES_DOC, "# Ligi Templates") != null);
}

test "INITIAL_LIGI_TAGS_DOC contains header" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_LIGI_TAGS_DOC, "# Ligi Tags") != null);
}

test "INITIAL_AGENTS contains header" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_AGENTS, "# Ligi Agent Notes") != null);
}

test "INITIAL_MEDIA_README contains header" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_MEDIA_README, "# media/") != null);
}

test "INITIAL_DATA_README contains header" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_DATA_README, "# data/") != null);
}

test "INITIAL_INBOX_README contains header" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_INBOX_README, "# inbox/") != null);
}

test "INITIAL_INBOX_README contains workflow instructions" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_INBOX_README, "ligi index") != null);
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_INBOX_README, "-t") != null);
}

test "INITIAL_ART_README lists media, data, and inbox" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_ART_README, "`media/`") != null);
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_ART_README, "`data/`") != null);
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_ART_README, "`inbox/`") != null);
}

test "INITIAL_LIGI_ART_DOC lists inbox" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_LIGI_ART_DOC, "`inbox/`") != null);
}

test "INITIAL_EXTENSIONS_INDEX contains header" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_EXTENSIONS_INDEX, "# Extensions") != null);
}

test "INITIAL_EXTENSION_TEMPLATE contains extension tag" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_EXTENSION_TEMPLATE, "[[t/extension]]") != null);
}

test "INITIAL_IMPL_PLAN_TEMPLATE contains header" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_IMPL_PLAN_TEMPLATE, "# Implementation Plan:") != null);
}

test "INITIAL_IMPL_SHORT_PLAN_TEMPLATE contains header" {
    try std.testing.expect(std.mem.indexOf(u8, INITIAL_IMPL_SHORT_PLAN_TEMPLATE, "# Short Implementation Plan:") != null);
}

test "InitResult init and deinit work correctly" {
    const allocator = std.testing.allocator;
    var result = InitResult.init(allocator);
    defer result.deinit();

    const path1 = try allocator.dupe(u8, "test/path1");
    const path2 = try allocator.dupe(u8, "test/path2");
    try result.created_dirs.append(allocator, path1);
    try result.created_files.append(allocator, path2);

    try std.testing.expectEqual(@as(usize, 1), result.created_dirs.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.created_files.items.len);
}
