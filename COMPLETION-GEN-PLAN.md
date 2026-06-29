# Shell Completion Generator — Two-Pass Implementation Plan

## Context

`nvme-cli` ships hand-maintained shell completion files (`completions/bash-nvme-completion.sh` ~2k lines, `completions/_nvme` zsh ~3.3k lines) that silently drift as commands change. An earlier `generate-completions.py` tried to recover completions by regex-parsing the C source; it was never tested and re-implements the preprocessor badly, so it is being abandoned.

The reliable source of truth for per-command options lives only in the **compiled binary**: each command's `fn` builds its options array on the stack via `NVME_ARGS(opts, ...)`, which expands to a `struct argconfig_commandline_options[]` carrying the long name, short option, value type, meta placeholder, and help text. All parsing funnels through `argconfig_parse()` (`util/argconfig.c:319`), and `nvme <cmd> --help` already proves this path returns *before* any device is opened.

We will generate completions from that live data, using a **two-pass, decoupled** design (this supersedes the single `argconfig_emit_completion` callback sketched in `COMPLETION-GEN-DESIGN.md`):

- **Pass 1** walks the command tree and captures each command's options into an in-memory model — and does *nothing else*.
- **Pass 2** is new code, fully decoupled from `argconfig`, that iterates the model and emits one shell's script. Each shell generator is an independent function.

This separates *capturing* option data from *formatting* it, so adding PowerShell never touches the parse layer and each generator is testable in isolation.

## Key facts (verified)

- `struct argconfig_commandline_options` (`util/argconfig.h:163`): `option`, `short_option`, `meta`, `config_type` (`enum argconfig_types`), `default_value`, `argument_type` (`no_/required_/optional_argument`), `help`, `seen`, `opt_val`.
- `NVME_ARGS` (`nvme.h:73`) always appends a global block: `verbose`, `output-format` (`-o`), `timeout`, `dry-run`, `no-retries`, `no-ioctl-probing`, `output-format-version`, bracketed by two `OPT_GROUP` separators. Generators must handle these globally, not repeat them per-command.
- All option strings (`option`/`meta`/`help`) and `opt_val` tables are **string literals / `static`** → immortal. Only the array itself is stack-allocated. So the deep copy copies struct elements by value and **aliases the string pointers — no `strdup`**.
- Command tree: `struct program nvme` (`nvme.c:171`, static) → `.extensions` linked list of `struct plugin` (`.next`), builtin has `.name == NULL`; each plugin has NULL-terminated `commands[]` of `struct command*` (`name`, `help`, `fn`, `alias`). Reachable inside a subcommand via `plugin->parent->extensions` — no new extern needed.
- ENTRY macro Stage 1 (`cmd_handler.h:12`) emits `static int f(...)`, so the registered command function **must be `static` and defined in nvme.c's TU**. Hence a thin static wrapper in nvme.c delegating to a non-static `gen_run()` in `completion-gen.c`.
- The tree is fully populated at startup by `__attribute__((constructor))` (`cmd_handler.h:103`), so Pass 1 has every command without invoking anything — `fn` is invoked *only* to capture its stack options array.

## Implementation

### 1. Hook in argconfig (minimal, decoupled)

`util/argconfig.h` — add near the other prototypes:
```c
typedef int (*argconfig_parse_hook_fn)(int argc, char *argv[],
                                       const char *program_desc,
                                       struct argconfig_commandline_options *options);
void argconfig_set_parse_hook(argconfig_parse_hook_fn hook);
```

`util/argconfig.c` — file-scope `static argconfig_parse_hook_fn argconfig_parse_hook;`, the setter, and a guard as the **first statement** of `argconfig_parse` (before `errno = 0`, line 329):
```c
if (argconfig_parse_hook)
    return argconfig_parse_hook(argc, argv, program_desc, options);
```
This short-circuits getopt entirely, so the `-h/--help` branch that prints to stderr (`argconfig.c:371`) and `setlocale` never run. `argconfig_parse_global` is separate and intentionally **not** hooked.

### 2. Model + generator — new files

`completion-gen.h` — model structs and the exported entry:
```c
struct gen_option  { const char *option; char short_option; const char *meta;
                     enum argconfig_types config_type; int argument_type;
                     const char *help; const struct argconfig_opt_val *opt_val; };
struct gen_command { const char *name, *alias, *help;
                     struct gen_option *options; size_t n_options;
                     bool captured, no_args; };
struct gen_plugin  { const char *name, *desc;
                     struct gen_command *commands; size_t n_commands; };
struct gen_program { const char *name, *version, *desc;
                     struct gen_plugin *plugins; size_t n_plugins; };

int gen_run(int argc, char **argv, struct program *prog);  /* non-static */
```

`completion-gen.c`:
- `static struct gen_command *gen_cur_command;` — set by the driver before each `fn` call; read by the hook to associate captured options with the current command.
- `static int completion_capture_hook(...)` — if `gen_cur_command && !captured`, deep-copy `options[]` (pointer-alias strings, stop at `option == NULL`, keep `CFG_GROUP_SEPARATOR` entries since they carry group titles), set `captured = true`, return a private sentinel (`-ECANCELED`) to unwind `fn` before any device open.
- `gen_copy_options()` — the copy loop.
- `gen_build_model(struct gen_program *m, struct program *prog)` — Pass 1 driver. Install hook, walk `prog->extensions` → plugins → `commands[]`, allocate model nodes, set `gen_cur_command`, call `(*cmd)->fn(2, {name, "/dev/nvme0", NULL}, *cmd, plugin)` (device token need not exist — sentinel returns before `get_transport_handle`), then check `captured`; if false mark `no_args`. **Suppress stdout during the `fn` calls** (a few `fn`s like `gen_hostnqn_cmd` printf before any parse). Uninstall hook (`argconfig_set_parse_hook(NULL)`) at the end. Success is detected by the `captured` side effect, **not** the return value.
- `gen_bash(model, out)`, `gen_zsh(model, out)`, `gen_powershell(model, out)` — independent emitters writing to stdout.
- `gen_run(argc, argv, prog)` — validate shell arg, build model, dispatch to the right emitter.

Argument-type mapping for emitters: `required/optional_argument` → `--name=` (+ ` -<short>`); `no_argument` → `--name`. Skip `CFG_GROUP_SEPARATOR` when listing options. Emit the global block once.

### 3. Register the hidden-ish subcommand

`nvme.c` — add a `static` wrapper among the command fns:
```c
static int gen_completions_cmd(int argc, char **argv, struct command *acmd,
                               struct plugin *plugin)
{ return gen_run(argc, argv, plugin->parent); }
```

`nvme-builtin.h` — one ENTRY in `COMMAND_LIST(...)`:
```c
ENTRY("gen-completions", "Generate shell completion script (bash|zsh|powershell)", gen_completions_cmd)
```
(No existing mechanism truly hides a command from `general_help`; true hiding is a separate follow-up and out of scope.)

`meson.build` — add `'completion-gen.c'` to the non-Windows `sources` list (~line 542); it links into the existing `nvme` executable. No new target. Per decision: completion files stay **committed**; regenerate manually (`./.build/nvme gen-completions bash > completions/bash-nvme-completion.sh`).

### 4. Match existing committed format

Treat static boilerplate as **verbatim templates**, generate only the data-driven parts:
- bash: `_nvme_detect_value_completion()` helper, `/dev/nvme*` device globbing — emit verbatim. `nvme_list_opts()` per-command `case` strings — generated (`--opt=`/`-s` convention).
- zsh: `#compdef _nvme nvme` header, `_cmds=( 'name:desc' )` from `command.help`, per-command `_arguments` blocks — generated.
- `output-format` value set (`normal`/`json`/`binary`/`tabular`, `json` gated on `CONFIG_JSONC`) is **not** in an `opt_val` table — hardcode to match `nvme.h:64`.
- Plugin dispatch nesting keyed on `plugin->name` (NULL = top-level builtin).

### 5. Remove the abandoned Python approach

Delete `completions/generate-completions.py` and `completions/GENERATOR-NOTES.md` (untested, superseded). Keep `COMPLETION-GEN-DESIGN.md` as the working spec; delete it once the C generator lands and output matches.

## Risks (flagged, not blocking Phase 1)

- A `fn` that `exit()`s/crashes before reaching `argconfig_parse` would take down the generator. No builtin does this; vendor plugins are the only risk. Mitigation if it appears: fork-per-capture (defer to Phase 2).
- stdout pollution from pre-parse `fn` work → handled by suppressing stdout during Pass 1.
- `gen-completions` will show in `help` output unless `general_help` is taught to hide it (separate follow-up).

## Files

- `util/argconfig.h` / `util/argconfig.c` — hook typedef, setter, one-line guard.
- `completion-gen.h` / `completion-gen.c` — **new**; model, capture hook, driver, three emitters, `gen_run`.
- `nvme.c` — `static gen_completions_cmd` wrapper → `gen_run(plugin->parent)`.
- `nvme-builtin.h` — ENTRY for `gen-completions`.
- `meson.build` — add `completion-gen.c` to sources (~line 542).
- Delete `completions/generate-completions.py`, `completions/GENERATOR-NOTES.md`.

## Verification

1. `meson compile -C .build` — builds clean with `completion-gen.c` linked.
2. `./.build/nvme gen-completions bash`, `... zsh`, `... powershell` — run cleanly, no device touched, no stderr help text, no stray hostnqn lines in output.
3. Diff generated bash/zsh against the committed `completions/bash-nvme-completion.sh` / `_nvme` to converge on format; iterate emitters until structurally equivalent.
4. Spot-check a command with rich options (e.g. `create-ns`) and one with none (e.g. `gen-hostnqn`, expect device/global-only) in the generated output.
5. Source the generated bash file in a shell and confirm `nvme <tab>` / `nvme id-ctrl --<tab>` complete.

## Addendum — JSON + Python pivot (branch `generate-completions-json`)

The original C-emitter design above is preserved on branch `generate-completions`
(pushed to `oss`). This branch keeps **Pass 1 (capture) in C** but moves
**Pass 2 (formatting) to Python**, following the precedent of
`libnvme/tools/generator/generate-accessors.py` (a committed, developer-only
generator run via a `build_by_default:false` meson target, sync-checked in CI).

- The C side now emits a single stable JSON model: `nvme dump-command-metadata`
  (via the project's `util/json.h` / json-c). `completion-gen.c` shrank from
  ~990 to ~480 lines; the three shell emitters and their string-escaping
  helpers are gone.
- `completions/generate-completions.py` consumes the JSON and emits bash, zsh,
  and PowerShell using triple-quoted templates (readable, no per-line escaping).
- `completions/update-completions.sh` + the `update-completions` meson target
  regenerate the committed files from the freshly built binary;
  `-Dcheck-completions=true` runs it read-only for CI drift detection.
- Regenerate with: `meson compile -C .build update-completions`.

The Python output is content-identical to the verified C output, except it
**fixes a latent C bug**: for a plugin whose first command lacks the global
option block (e.g. `sndk vs-internal-log`), the C emitter sourced the shared
global block from that first command and emitted nothing; the Python generator
sources it from the first command that actually has globals.

## Follow-ups to consider (review notes, not yet done)

### Treat the JSON dump as a general-purpose interface

`dump-command-metadata` is useful beyond completions — docs/man-page
generation, test-coverage audits (commands/options exercised by nothing),
release diffing (auto-changelog of added/removed options, CI catch for an
accidentally dropped option), CLI self-linting (duplicate short options,
missing help, inconsistent meta types), and any external tool that needs to
know the CLI surface without parsing `--help`.

If we lean into that, the JSON becomes a **contract** and should be made
intentional rather than "whatever completions happened to need":

- Add a top-level `"schema_version"` so consumers can detect breaking changes.
- Emit the richer per-option type info completions don't use but docs/validation
  would: the raw `config_type` (`CFG_*` enum, as a string), and always emit
  `meta` (currently only emitted when non-NULL). Source is the model fields
  already captured in `struct gen_option` (`config_type`, `meta`) — they are
  just not all written out by `gen_json_option()` today.
- Keep the name as-is: `dump-command-metadata` is already generic (no
  "completion" in it), so it reads fine as an introspection command.

### Command visibility (do NOT use a leading underscore)

Verified in `plugin.c`: `general_help()` (lines 105-116) prints **every**
command unconditionally — there is **no hidden-command mechanism**, and no
existing command starts with `_`. A leading-underscore name
(`_dump-command-metadata`) would NOT hide it: it would still be listed in
`help`, just be uglier to type and sort oddly. Avoid that.

Two real options:
- **Leave it visible** (current state). Given the general-purpose framing above,
  visible is arguably correct — discoverable introspection tooling.
- **Actually hide it**: add a `hidden` bool to `struct command` (precedent
  exists — `struct argconfig_commandline_options` already has a `hidden` field)
  and skip such commands in the two `general_help()` loops at `plugin.c:105`
  and `:112`. Small, clean change, but it is new infrastructure.
