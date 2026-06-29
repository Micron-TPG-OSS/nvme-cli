# WIP notes — completions JSON work (read before Monday's PR)

Temporary scratch file. **Delete before opening the PRs.**

## PR plan

1. **PR #1 — C only.** Just `command-metadata.c` and `command-metadata.h`
   (the JSON model + schema). Internal review first, then upstream. Splitting
   the C out makes review easier.
2. **PR #2 — follow-up.** `completions/generate-completions.py` plus the
   regenerated completion files (`bash-nvme-completion.sh`, `_nvme`,
   `nvme-completion.ps1`).

This end-of-day commit bundles everything together for safety. Re-split it
into the two PRs above on Monday (cherry-pick / interactive rebase).

## Open issue: committed completion files depend on build configuration

The committed completion files are generated from whatever plugins are
**compiled into the binary** that `update-completions` runs against. Several
plugins are gated by meson options — e.g. the `registry` plugin is behind
`want_fabrics` (`plugins/meson.build:57`).

Consequences:

- The completion files committed in `e440bd345` were generated from a build
  **without** fabrics, so they were missing `plugin_registry_opts` (and
  anything else fabrics-gated) from the moment they were committed. Running
  `update-completions` against a fabrics-enabled build adds those blocks back.
  That is the source of the unexpected `plugin_registry_opts` diff — it is
  correct output, not a bug in the schema changes.
- The CI drift check (`-Dcheck-completions=true`) compares against one
  specific config. It will report STALE for anyone whose build config differs
  from whoever last regenerated the files, even when nothing is actually wrong.

### To decide for PR #2

- Pick a single canonical build configuration for generating the committed
  completion files (most likely a full / all-features build).
- Make the CI drift check use that same configuration, so the check is
  deterministic regardless of a contributor's local options.
- Regenerate and commit the completion files from that canonical config.

The C-only PR (#1) is unaffected: the dumper correctly emits whatever plugins
are compiled in.
