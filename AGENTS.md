# Ligi Agent Notes

The `art/` directory is the repository's Ligi artifact store, initialized by
`ligi init`. It contains human/LLM notes, indexes, templates, config, and
archive data that are part of the project's durable context.

Do not delete or move files under `art/` unless explicitly requested. If
something should be retired, use `art/archive/` or the future `ligi archive`
command instead. See `art/founding_idea.md` for the intended purpose.

To enable the local safety check that blocks `art/` deletions at commit time,
run `scripts/install_git_hooks.sh`.
