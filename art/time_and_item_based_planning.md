[[t/planning]] [[t/cli]] [[t/plan]] [[t/init]] [[t/tagging]]

# Time and Item Based Planning

This document describes the planning workflow introduced by `ligi plan` and the time-tagged planning artifacts it generates.

## Summary

- `ligi plan` (`ligi p`) creates planning docs from templates under `art/template/`.
- Day and week time tags are always included for all plan types.
- `art/calendar/index.md` is auto-maintained as the chronological index of day/week tags (newest-first per section).

## Time Tags

Time tags live under the time namespace and follow these formats:

- Day: `[[t/t/d/yy-mm-dd]]` (example: `[[t/t/d/26-01-14]]`)
- Week: `[[t/t/w/yy-mm-w]]` (week-of-month, example: `[[t/t/w/26-01-2]]`)

These tags are inserted automatically by `ligi plan` templates and mirrored into `art/calendar/index.md`.

## Calendar Behavior

`art/calendar/index.md` is rewritten by `ligi plan` and contains two sections (Days, Weeks). Each section is sorted newest-first using the tag's embedded date/period. Manual edits to `art/calendar/index.md` will be overwritten the next time `ligi plan` runs. The calendar is built from the existing calendar content plus the current local tag index (`art/index/ligi_tags.md`) if present; run `ligi index` to ensure the tag index is complete.

## File Locations

By default, time-based plans are created under `art/calendar/`:

- `art/calendar/day/<yy-mm-dd>.md`
- `art/calendar/week/<yy-mm-w>.md`
- `art/calendar/month/<yy-mm>.md`
- `art/calendar/quarter/<yy-q>.md`

Item-based plans are created under `art/inbox/`:

- `art/inbox/feature/<name>.md`
- `art/inbox/chore/<name>.md`
- `art/inbox/refactor/<name>.md`
- `art/inbox/perf/<name>.md`

Templates live at:

- `art/template/plan_day.md`
- `art/template/plan_week.md`
- `art/template/plan_month.md`
- `art/template/plan_quarter.md`
- `art/template/plan_day_short.md`
- `art/template/plan_week_short.md`
- `art/template/plan_month_short.md`
- `art/template/plan_quarter_short.md`
- `art/template/plan_feature.md`
- `art/template/plan_feature_short.md`
- `art/template/plan_chore.md`
- `art/template/plan_chore_short.md`
- `art/template/plan_refactor.md`
- `art/template/plan_refactor_short.md`
- `art/template/plan_perf.md`
- `art/template/plan_perf_short.md`

`ligi init` now creates `art/calendar/index.md` and these templates automatically.

Use `--no-inbox` to write item-based plans into `art/plan/<kind>/` instead. Use `-D, --dir` to create a directory and write `plan.md` inside (for example, `art/inbox/feature/<name>/plan.md`).
Inbox flags do not affect time-based plans; they always live under `art/calendar/`.

## CLI Usage

```bash
ligi p day                 # uses today (UTC), defaults to art/calendar
ligi p day -d 26-01-14      # explicit date (YY-MM-DD)
ligi p week -d 2026-01-14   # explicit date (YYYY-MM-DD)
ligi p feature login-flow   # item plan (defaults to inbox)
ligi p feature login-flow -l short
ligi p feature login-flow -D
```

## Item-Based Planning

The CLI supports item-based planning for feature/chore/refactor/perf. Each plan requires a name, uses the same time tags as day/week/month/quarter plans, and is created from its matching template (long or short).

Options:

- `-l, --length` defaults to `long`; use `short` for the compact templates.
- `-d, --date` controls which time tags are applied (defaults to today, UTC).
- `-i, --inbox` writes item plans into `art/inbox/` (default for item plans; time-based plans always go to `art/calendar/`).
- `--no-inbox` writes into `art/plan/`.
- `-D, --dir` creates a directory and writes `plan.md`, which is intended to collect simple markdown links to related items.

**Current `ligi p` Behavior (Implementation Summary)**
- Requires a subcommand: `day|week|month|quarter|feature|chore|refactor|perf`.
- Picks the date from `-d/--date` (YYYY-MM-DD or YY-MM-DD); otherwise uses today (UTC).
- Resolves a template by kind + `-l/--length`, loading from `art/template/*.md` with a builtin fallback if the file is missing.
- Prompts for any missing template fields, then renders the template.
- Chooses the output base directory as `art/calendar/` for time-based kinds and `art/inbox/` for item kinds by default, with `-i/--inbox` and `--no-inbox` overriding only item output.
- When `-D, --dir` is set, creates a directory and writes `plan.md` inside it; otherwise writes a single `.md` file.
- Names files by date for time-based kinds and by the provided item name for item kinds; ensures a `.md` extension (directories use the name without `.md`).
- Creates parent directories and writes the file only if it does not already exist (prints `exists:` otherwise, unless `--quiet`).
- Injects auto-tags for org/repo when workspace auto-tags are enabled, then fills tag links.
- Updates `art/calendar/index.md` by collecting existing calendar tags, the local tag index, and the current plan’s time tags, then rewriting Days/Weeks sections newest-first.

**Changes Required for Calendar Directory + Day/Week Tags + Directory Mode**
- Calendar directory for time-based plans: Route day/week/month/quarter plan output into `art/calendar/` (regardless of inbox flags), and write the calendar index to `art/calendar/index.md`. Update `src/cli/commands/plan.zig`, `src/cli/commands/init.zig`, `src/core/paths.zig`, and the serve UI default (`src/serve/assets/app.js`).
- Remove monthly/quarterly tags (keep day/week only): Update all plan templates in `art/template/` and builtin templates in `src/core/templates.zig` to remove `{{ month_tag }}`, `{{ quarter_tag }}`, and `prev_month_tag`/`prev_quarter_tag` references; update `calendarTagsForKind` in `src/cli/commands/plan.zig` to add day/week tags; and simplify calendar generation to remove Month/Quarter buckets and sections if those tags are no longer produced.
- Directory creation flag: Add a new CLI flag in `src/cli/registry.zig` (`-D, --dir`) and carry it through `PlanOptions`, use `plan.md` inside the directory, append a Links section to collect simple markdown links to related items, ensure `file_in_art` points at the markdown file inside the directory for tag-link filling and calendar updates, and update docs/usage plus tests for the new flag and output paths.
