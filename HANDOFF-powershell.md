# HANDOFF — PowerShell completions (Windows work)

**DELETE THIS FILE before opening the PR. It is a cross-machine context passdown,
not part of the change.** It rides on branch `powershell_completions` only so the
context survives the Linux→Windows→Linux move.

## Where this fits

Completion generator ships as ordered per-shell upstream PRs:
1. bash — MERGED upstream (PR #3764). `upstream/master` has `generate_bash` only.
2. zsh — PR **#3826**, base `linux-nvme:master`, head `Micron-TPG-OSS:zsh_generation_internal`.
   OPEN, NOT merged. HEAD commit `abd286aa4`.
3. **PowerShell — THIS branch (`powershell_completions`). What you do on Windows.**
4. integration — meson/CI wiring + `.gitignore` (later, back on Linux).

## Base — why this branch stacks on zsh, not upstream/master

`powershell_completions` is branched off `zsh_generation_internal` (commit `abd286aa4`),
NOT off `upstream/master`. Reason: each shell's commit ADDS its `generate_<shell>`
section on top of the prior generator. `upstream/master` currently has bash only;
zsh is still in review. Basing on master (bash-only) would produce a generator with
bash+PowerShell but no zsh — wrong ordering. So PS stacks on zsh now.

**REBASE STEP (do this once #3826 merges):**
`git rebase upstream/master` — after zsh lands on master, the zsh commit becomes a
no-op in the rebase and PS ends up as a clean single commit on top of merged
bash+zsh. That restores the normal "based on upstream/master" shape before the PR.
If you PR before #3826 merges, base the PR on `linux-nvme:master` and note it stacks
on #3826 (or just wait for zsh to merge first — simpler).

## The actual work: carve PowerShell out of the integration branch

The PowerShell generator ALREADY EXISTS on `completions-generation-v2` — you are
carving it out and refining/testing it live on Windows, exactly like bash and zsh
were done. Do NOT write it from scratch.

Source of the PS code (v2 line numbers, will drift — grep, don't trust the numbers):
- `# powershell` banner + PS header/helpers: v2 ~L516–577
  (`ps_escape()` at ~L563 — "Escape for a PowerShell single-quoted string").
- `def generate_powershell(model, out):` at v2 ~L578.
- GENERATORS entry: `"powershell": generate_powershell` (v2 ~L610).
- argparse: `--powershell` (v2 ~L626).

Recipe on THIS branch:
```
# bring the PS section over from v2
git show completions-generation-v2:completions/generate-completions.py   # read it
# hand-port the PS section + GENERATORS entry + --powershell arg onto THIS file
```

### CRITICAL: port onto CURRENT helpers, do NOT copy v2's main()/guards

v2 predates the current branch's generator state. Differences that matter:

1. **Arg guard is stronger here.** Current `main()` (HEAD L727–735) has the R2
   multi-shell guard: ">1 shell requires a named FILE per shell (no shared stdout)".
   v2's `main()` (L636) lacks it. KEEP the current guard — just extend the error
   strings to mention `--powershell` (current L729 says "--bash/--zsh"; v2 said
   "--bash/--zsh/--powershell" — adopt the 3-shell wording but keep the current
   FILE-per-shell rule).

2. **`cmd_names()` routing.** The PS generator must use `cmd_names(cmd)` for command
   AND alias names and route the case-label/var through it (bash & zsh already do;
   v2's PS section had this as a TODO). This is what makes aliases complete and
   strips the solidigm trailing-space. Verify the ported PS code uses `cmd_names()`
   everywhere it emits a command name, not raw `cmd['name']`.

3. **Regenerate the artifact.** After the generator is right:
   `nvme utils dump-command-metadata | python3 completions/generate-completions.py --powershell completions/nvme-completion.ps1`
   (On Windows you won't have a live `nvme`; capture the JSON from Linux —
   `nvme utils dump-command-metadata > model.json` on this box, commit it here
   temporarily OR paste it — then feed `--powershell` from the file. Easiest:
   generate the .ps1 on Linux from real metadata, and do only PS-runtime testing
   on Windows.)

## Testability ceiling (same as zsh)

PowerShell completion is framework-driven (Register-ArgumentCompleter), like zsh's
_arguments — you cannot unit-test the live render from a plain script. Model the
zsh approach: stub/drive the completer to capture what it WOULD offer, testing the
generator's routing + value lists, not the live UI. Live behavior is spot-checked
in a real PowerShell session. See `completions/test-zsh-completion.sh` for the
pattern (stub-the-builtins harness) and `completions/TESTING.md` for manual steps.
NOTE: TESTING.md currently has bash+zsh only (PS refs were removed) — add a
PowerShell section when you do this work.

## Files to expect in the PS PR

- `completions/generate-completions.py` (+PS section, +GENERATORS, +--powershell arg,
  +3-shell error wording)
- `completions/nvme-completion.ps1` (NEW generated artifact)
- `completions/test-*.ps1` or `.sh` test harness (NEW — model on test-zsh-completion.sh)
- `completions/TESTING.md` (+PowerShell section)
- SPDX + `Copyright (c) 2026 Micron Technology, Inc.` header on any new file
  (see copyright-notice-followup memory).

## Commit / push conventions (global CLAUDE.md — DO NOT VIOLATE)

- Prefix `completions:` — e.g. `completions: generate PowerShell completion from command metadata`.
- `git commit -s`, WITH a body, NO Co-Authored-By line.
- `meson compile -C .build` + `/code-review` before committing structural changes.
- Push to **oss** remote, never upstream. NEVER push without explicit approval;
  never offer to push — the user pushes himself.
- Single clean commit (amend, like the zsh branch).

## When you come back to Linux

- **DELETE this file**, delete branch `powershell_completions` if the PS work moved
  to its own PR branch (or reuse it — your call).
- Pick up the **integration** work here: meson `update-completions` run_target,
  `-Dcheck-completions`, CI drift-check, register the SHELL tests into meson (needs
  new `completions/meson.build` + `find_program('zsh')` + zsh & PS in ci-containers),
  add `completions/**/__pycache__` to `.gitignore`.

## Claude memory does NOT travel

Claude's memory lives under `~/.claude/.../memory/` on the Linux box. Windows Claude
starts blank on this project. This file is the bridge. For deeper history, the public
PRs #3764 (bash) and #3826 (zsh) show the exact pattern to follow.
