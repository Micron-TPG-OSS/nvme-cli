# HANDOFF — PowerShell completions (Windows → Linux)

**DELETE THIS FILE before opening the upstream PR. It is a cross-machine
context passdown, not part of the change.**

## Status (2026-08-18)

The PowerShell completion work is DONE on the Windows side. Branch
`powershell_completions` on the `oss` remote has the implementation.
Internal review PR: https://github.com/Micron-TPG-OSS/nvme-cli/pull/131

The branch is rebased on `upstream/master` (zsh PR #3826 merged).

## What was done on Windows

All work lives on branch `powershell_completions` (5 commits, will be
squashed for the upstream PR):

1. `completions/generate-completions.py` — added `generate_powershell()`,
   `ps_escape()`, `ps_command_options()`, `PS_HEADER`, `PS_COMPLETER`
   template, `--powershell` CLI arg, updated GENERATORS dict and error
   messages. Uses data-driven flat hashtable approach (not case-statement
   dispatch like bash/zsh). All hashtable keys sorted alphabetically.
   File paths with spaces are properly quoted.

2. `completions/nvme-completion.ps1` — generated artifact (~1774 lines).
   Structure: NvmeCommands array, NvmePluginCommands/NvmeOptions/
   NvmeFileOptions/NvmeOptionValues hashtables, Register-ArgumentCompleter
   scriptblock. NOTE: generated from Windows build which excludes
   Linux-only plugins (zns, wdc, nbft, keys, exclusion, etc.) — must be
   regenerated from a Linux build before upstream PR.

3. `completions/test-powershell-completion.ps1` — 31 tests using
   TabExpansion2 to exercise the real completion path end-to-end (top-level
   dispatch, plugin subcommands, option completion, value completion, file
   options, device hints, sorting).

4. `completions/TESTING.md` — restructured into sections: All shells,
   Bash & zsh, Zsh-specific, PowerShell-specific, Automated suites.
   Documents PowerShell loading, Ctrl+Space trigger, `--`/`-` framework
   limitation, static device hint, file fallback behavior.

5. `tests/unit/py/test_generate_completions_args.py` — 11 tests covering
   CLI contract (all two/three-shell stdout combos rejected, single-shell
   stdout succeeds, all-to-files succeeds, wrong schema_version rejected).

6. `scripts/release.sh` — added `--powershell completions/nvme-completion.ps1`
   to the generate-completions.py invocation, updated git add/commit.

## Known issues / design decisions

- **Duplicate short options** (e.g. rpmb `-o` maps to both `--open` and
  `--output-format`) — this is a metadata/C-code issue present in all
  shells, not a generator bug.

- **`--` or `-` alone may not trigger completion** — PowerShell framework
  limitation. Documented in TESTING.md. TabExpansion2 returns correct
  results programmatically; only the interactive trigger is affected.

- **Static device hint** — PowerShell offers `/dev/nvme` as a static hint
  rather than a filesystem glob (no `/dev/` on Windows). User types the
  rest (e.g. `0`, `0n1`).

- **File fallback on empty return** — when completer returns nothing (e.g.
  `nvme version <tab>`), PowerShell falls back to file completion. Cannot
  be suppressed from a native-command completer.

## Before the upstream PR

1. Regenerate `nvme-completion.ps1` from a Linux build (to include all
   plugins: zns, wdc, nbft, etc.).
2. Squash the 5 commits into one clean commit.
3. Delete this file from the branch.

## Next phase: integration (separate PR, back on Linux)

- meson `update-completions` run_target
- `-Dcheck-completions` option
- CI drift-check
- Register shell tests into meson (new `completions/meson.build` +
  `find_program('zsh')` + zsh & PS in ci-containers)
- `completions/**/__pycache__` in `.gitignore`

## Commit conventions (global CLAUDE.md — DO NOT VIOLATE)

- Prefix: `completions:`
- `git commit -s`, WITH a body, NO Co-Authored-By line.
- Push to **oss** remote, never upstream.
- NEVER push without explicit approval; never offer to push.
