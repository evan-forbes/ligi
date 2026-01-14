[[t/planning]] [[t/cli]] [[t/plan]] [[t/init]] [[t/tagging]]

# Time and Item Based Planning

This document describes the planning workflow introduced by `ligi plan` and the time-tagged planning artifacts it generates.

## Summary

- `ligi plan` (`ligi p`) creates planning docs from templates under `art/template/`.
- Time tags are always included for day/week/month/quarter planning and item plans.
- `art/calendar.md` is auto-maintained as the chronological index of time tags (newest-first per section).

## Time Tags

Time tags live under the time namespace and follow these formats:

- Day: `[[t/t/d/yy-mm-dd]]` (example: `[[t/t/d/26-01-14]]`)
- Week: `[[t/t/w/yy-mm-w]]` (week-of-month, example: `[[t/t/w/26-01-2]]`)
- Month: `[[t/t/m/yy-mm]]` (example: `[[t/t/m/26-01]]`)
- Quarter: `[[t/t/q/yy-q]]` (example: `[[t/t/q/26-2]]`)

These tags are inserted automatically by `ligi plan` templates and mirrored into `art/calendar.md`.

## Calendar Behavior

`art/calendar.md` is rewritten by `ligi plan` and contains four sections (Days, Weeks, Months, Quarters). Each section is sorted newest-first using the tag's embedded date/period. Manual edits to `art/calendar.md` will be overwritten the next time `ligi plan` runs. The calendar is built from the existing calendar content plus the current local tag index (`art/index/ligi_tags.md`) if present; run `ligi index` to ensure the tag index is complete.

## File Locations

By default, time-based plan documents are created under:

- `art/plan/day/<yy-mm-dd>.md`
- `art/plan/week/<yy-mm-w>.md`
- `art/plan/month/<yy-mm>.md`
- `art/plan/quarter/<yy-q>.md`

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

`ligi init` now creates `art/calendar.md` and these templates automatically.

Item-based plan documents are created under:

- `art/inbox/feature/<name>.md` (default)
- `art/inbox/chore/<name>.md`
- `art/inbox/refactor/<name>.md`
- `art/inbox/perf/<name>.md`

Use `--no-inbox` to write into `art/plan/<kind>/` instead.

## CLI Usage

```bash
ligi p day                 # uses today (UTC)
ligi p day -d 26-01-14      # explicit date (YY-MM-DD)
ligi p week -d 2026-01-14   # explicit date (YYYY-MM-DD)
ligi p feature login-flow   # item plan (defaults to inbox)
ligi p feature login-flow -l short
```

## Item-Based Planning

The CLI supports item-based planning for feature/chore/refactor/perf. Each plan requires a name, uses the same time tags as day/week/month/quarter plans, and is created from its matching template (long or short).

Options:

- `-l, --length` defaults to `long`; use `short` for the compact templates.
- `-d, --date` controls which time tags are applied (defaults to today, UTC).
- `-i, --inbox` writes into `art/inbox/` (default for item plans).
- `--no-inbox` writes into `art/plan/`.
