# nvme-cli Instructions for AI Agents

## Scope

This repository builds both nvme-cli and libnvme from one source tree.

- `libnvme/` is integrated here; do not assume a separate checkout.
- Meson is the primary build system.
- Windows support exists, but feature coverage is narrower than Linux.

## Where to Change Things

- Built-in command registration is driven by `define_cmd.h` and `nvme-builtin.h`.
- Plugin commands follow the same macro pattern and are invoked as
  `nvme <plugin> <command>`.
- Do not assume command callbacks belong in `nvme.c`; follow nearby ownership.

Primary code areas:

- `nvme.c`, `nvme-cmds.c`, `nvme-print*.c`: CLI command and output paths
- `libnvme/src/`: library core and transport/ioctl logic
- `plugins/`: plugin-specific commands
- `util/`: shared helpers

## Build and Test

Prefer direct Meson commands for fast local validation:

```bash
meson setup .build
meson compile -C .build
meson test -C .build
```

Use `scripts/build.sh` to reproduce CI-style configurations.

Common CI-parity invocations:

```bash
scripts/build.sh
scripts/build.sh -c clang
scripts/build.sh -x
scripts/build.sh fallback
scripts/build.sh nofabrics
scripts/build.sh libnvme
```

Test notes:

- `-Dnvme-tests=true` enables real-hardware tests.
- `-Dplugin-tests=[...]` opts into plugin hardware tests.
- Valgrind setup: `meson test -C .build --setup valgrind`
- Sanitizers: configure with `-Db_sanitize=address,undefined`

## Feature and Platform Gating

Check `meson.build` and `plugins/meson.build` before changing behavior.

- On Windows, Meson disables `fabrics`, `mi`, `top`, and examples.
- Python bindings require fabrics support plus Python+SWIG+headers.
- `micron` builds on Linux and Windows with platform-specific helper sources.
- `ocp` and `solidigm` build only when `json-c` is available.
- `nbft`, `exclusion`, and `registry` are only included with fabrics enabled.

Prefer existing Meson gates over new ad hoc preprocessor conditionals.

## Python Bindings

- Packaged via `meson-python` (`mesonpy`) in `pyproject.toml`.
- Python package name is `libnvme3`.
- PyPI build args are defined in `pyproject.toml`; keep Meson options in sync
  when changing Python build behavior.

## Style and Conventions

Follow local style (Linux kernel style for C unless file-local conventions differ):

- 8-space tabs, K&R braces, lower_snake_case identifiers
- 80 columns for code where practical; optimize for clarity over strict width limits
- pointer style: `char *buf`
- sparse technical comments only
- preserve existing SPDX header style

Implementation guidance:

- Reuse existing helpers and patterns before adding new abstractions.
- Keep error handling consistent with the touched layer.
- Prefer existing cleanup/ownership patterns (for example `_cleanup_` usage where
  already established).

## Agent Rules

- Start at the narrowest owning layer (command, plugin, Meson gate, platform file).
- Keep changes small and verify with the smallest meaningful build/test command.
- Do not assume plugin or platform parity; confirm in Meson files first.
- Treat this as one repo for both nvme-cli and libnvme.

Useful anchors:

- `meson.build`
- `meson_options.txt`
- `plugins/meson.build`
- `README.md`
- `TESTING.md`
- `.github/workflows/build.yml`

## Commit Message Format

Use Linux kernel-style subjects:

```text
<area>: <short description>

<detailed description>

Signed-off-by: Name <email>
```
