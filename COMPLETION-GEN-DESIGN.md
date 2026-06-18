# Shell Completion Generator — Design Notes

**Status:** Draft / proof-of-concept planning. Temporary document — delete once the
generator lands.
**Last updated:** 2026-06-18

## Goal

Generate the shell completion scripts for `nvme-cli` from a single source of truth:

- `completions/bash-nvme-completion.sh` (bash)
- `completions/_nvme` (zsh)
- PowerShell completion (no file yet — to be created)

Replace the earlier approach of parsing the C source with a Python script, which is
brittle: it has to re-implement the C preprocessor, macro expansion, `#ifdef CONFIG_*`
handling, and local description-variable resolution, and it silently drifts as commands
change.

## What we learned

### Two halves of a completion file

1. **Command / subcommand names** (~10% of the file). These come from the X-macro
   `COMMAND_LIST` / `ENTRY` tables in `nvme-builtin.h` and each `plugins/*/*-nvme.h`.
   Cleanly reachable via the preprocessor.

2. **Per-command options** (~90% of the file) — the `--flag` / `-f` entries *and their
   descriptions*. These are declared **inside each command's `fn` body** via
   `NVME_ARGS(...)` / `OPT_*(...)`, and frequently reference **local description
   variables**. They only exist, fully resolved, in the compiled binary at runtime.

   The zsh file already carries per-option descriptions, e.g.:
   ```
   --mode=':0-3: default/rom/wtm/normal'
   --telemetry-type=':Telemetry Type; host, host0, host1 or controller generated'
   ```
   These strings are the 4th argument (`help`/`d`) to `OPT_*`. Unreachable from the
   preprocessor or a source-text parser.

### Why a pure preprocessor / X-macro approach fails

The `COMMAND_LIST` X-macro trick works only because the command table is at **file
scope** in a header **designed to be re-`#include`d** in different macro modes (see
`cmd_handler.h` 4-stage expansion). Options have none of those properties: they live
inside function bodies, reference locals (`&cfg.namespace_id`), and are interleaved with
logic and `#ifdef`s. You cannot re-`#include` a `.c` file to re-expand just the `OPT_*`
calls. Conclusion: the X-macro approach can generate the command-name skeleton but is
structurally incapable of the option detail.

### The options data model (this is the key asset)

`NVME_ARGS(opts, ...)` (`nvme.h:73`) expands to a flat, `OPT_END()`-terminated array of
`struct argconfig_commandline_options` (`util/argconfig.h:163`). It appends global
options (verbose, output-format, timeout, dry-run, …) automatically. Each element
carries exactly what a completion needs:

- `.option`        → long name (`"namespace-id"`)
- `.short_option`  → char (`'n'`)
- `.argument_type` → `required_argument` / `optional_argument` / `no_argument`
                     → tells us `--foo=` vs `--foo`
- `.config_type`   → richer type info (enum `CFG_*`)
- `.meta`          → value placeholder (`"NUM"`, `"FMT"`, …)
- `.help`          → the description string (the `':...'` text in zsh)
- `.opt_val`       → optional enumerated value table (`argconfig_opt_val`), richer data
                     than the help text exposes

So the struct is already the exact record set we want to emit, including descriptions.

### The choke point and early-exit safety

All option parsing funnels through `argconfig_parse()` (`util/argconfig.c:319`), reached
via `parse_args()` (nvme.c-local wrapper) and `parse_and_open()` (`nvme.c:385`). ~162
command functions in `nvme.c` reach one of these parse entry points, plus 7 call
`argconfig_parse` directly.

Critically, the call ordering is parse-first:

```
fn() → builds opts[] → parse_and_open() → parse_args() → argconfig_parse()   ← intercept here
                          ↓ (only AFTER parse returns 0)
                       opens device / executes command
```

So intercepting at the parse call returns before any `open()`/ioctl — no device, no
hardware side effects.

We also confirmed that `nvme <cmd> --help` already exercises this exact path: when
getopt sees `-h`/`--help`, `argconfig_parse` calls `argconfig_print_help()` and returns
`-EINVAL` **before** the device is opened. In other words, `--help` is the *already
built-in* version of the hook.

## Approaches considered

### A. Drive each command with `--help`, scrape the text output — REJECTED

- Pro: zero new C code; descriptions already printed.
- Con (killers):
  - Back to **text parsing** — just parsing C's *output* instead of its *source*. Must
    reverse the `show_option` format and reassemble **word-wrapped** multi-line
    descriptions (help wraps at column ~44).
  - Output goes to **stderr with ANSI escapes** (`\033[1m`).
  - **N process spawns** (one per command across 32 plugins).
  - **Lossy**: `show_option` collapses `config_type` into a `<NUM>`/`<FMT>` meta string;
    the `opt_val` enum table is not in the text.

### B. Hook argconfig and emit from the struct directly — CHOSEN

Walk the live `argconfig_commandline_options[]` array in-process and emit per-shell text
from the structured fields, never round-tripping through human-readable text. Same
early-exit safety as `--help` (reuse the same interception point), but read
`.option` / `.short_option` / `.argument_type` / `.help` / `.opt_val` as data.

`--help` is worse than B for a subtle reason: same safety, same source of truth, but it
forces parsing text output to recover structure we already have as C structs one layer
down — reintroducing the fragility we set out to remove. B's only cost is a small,
contained change to the parse layer (one emit function beside `argconfig_print_help`).

## Chosen approach (B) — plan

### Packaging (incremental)

- **Phase 1 (POC):** a hidden `nvme gen-completions <bash|zsh|powershell>` subcommand.
  Reuses the already-built plugin tree and argconfig. Run as:
  ```
  ./.build/nvme gen-completions bash > completions/bash-nvme-completion.sh
  ```
- **Phase 2 (optional, later):** a standalone meson target linking the same objects and
  calling the same entry function. No rewrite — just a different front door.

Put the generation logic in its own translation unit (e.g. `completion-gen.c`) from day
one so both phases share it.

### Mechanism

1. Add a generator mode: a global flag + context (current command name / target shell).
2. At the parse choke point (likely `parse_args`, which is nvme.c-local and wraps
   `argconfig_parse`), when gen-mode is set: instead of parsing, call a new
   `argconfig_emit_completion(opts, shell)` to walk `opts[]` and emit the records, then
   return a **sentinel error**.
3. The sentinel propagates back through `parse_and_open` → `fn` returns early, before any
   device open. No side effects.
4. Generator driver loop: walk `nvme.extensions` → each plugin's `commands[]` →
   `(*cmd)->fn(argc, argv, *cmd, plugin)` with a crafted argv that triggers gen-mode,
   capturing the per-command dump. Emit the command-name skeleton + per-command options
   for the requested shell.

`#ifdef`-gated commands (`CONFIG_FABRICS`, `CONFIG_MI`, `CONFIG_JSONC`) are handled for
free because we generate from the actually-built binary.

### PowerShell

Target **full parity** with zsh (per-command options + descriptions) since the same
generator walk produces all three shells from one data source. (Not yet locked — revisit.)

## Open risks / TODO for Monday

1. **Pre-parse side effects.** A minority of command `fn`s do work *before* calling
   `parse_args`. In gen-mode that prologue runs before we intercept. The dominant pattern
   (build `cfg` → `NVME_ARGS` → `parse_and_open` immediately) is side-effect-free.
   **TODO:** audit how many commands do meaningful work before their parse call (grep for
   `fn`s with logic between entry and the first `parse_*`/`argconfig_parse`). This
   quantifies the main risk.
2. **Commands with no options** (never call parse) → emit device + global completion only.
   Fine, but enumerate them.
3. Decide exact interception point: `parse_args` vs. `argconfig_parse` (former is
   nvme.c-local and already wraps the latter).
4. Decide whether to surface `opt_val` enum value lists in completions (richer than zsh
   currently has) or match existing fidelity first.
5. Confirm whether the `gen-completions` subcommand should be hidden from `help` output.
6. Build verification: `meson compile -C .build` before committing.

## Key file references

- `cmd_handler.h` — 4-stage X-macro expansion of the command table (background for how
  the command list is built; example of the macro technique).
- `nvme-builtin.h` — the builtin `COMMAND_LIST` / `ENTRY` table.
- `nvme.h:73` — `NVME_ARGS` macro (builds the options array, appends globals).
- `util/argconfig.h:163` — `struct argconfig_commandline_options` (the data model).
- `util/argconfig.c:319` — `argconfig_parse` (the choke point).
- `util/argconfig.c` — `argconfig_print_help` / `show_option` (existing text emitter; the
  shape to emit *from struct* instead).
- `nvme.c:385` — `parse_and_open` (parse-then-open ordering).
- `nvme.c:162` / `nvme.c:11685` — builtin plugin registration and `handle_plugin`
  dispatch entry (how the command tree is walked at runtime).
