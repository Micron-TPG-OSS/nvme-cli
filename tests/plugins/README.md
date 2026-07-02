# Plugin Tests

This directory contains hardware tests for nvme-cli vendor plugins. Each plugin
has its own subdirectory with tests that exercise plugin commands against real
hardware.

## Architecture

```
tests/plugins/
├── plugin_test.py            # Base class for all plugin tests
└── <plugin>/
    ├── meson.build           # Meson test definitions for a specific plugin
    ├── <plugin>_test.py      # plugin-specific base class
    └── *_test.py             # Individual test files
```

### Class Hierarchy

```
unittest.TestCase
└── TestNVMe (tests/nvme_test.py)
    └── TestPlugin (tests/plugins/plugin_test.py)
        └── Test<Plugin> (tests/plugins/<plugin>/<plugin>_test.py)
```

- **TestNVMe** — provides device config loading, `run_cmd()`, `exec_cmd()`,
  JSON parsing helpers, and log directory management.
- **TestPlugin** — adds `run_plugin_cmd()` and `run_plugin_cmd_check()` which
  invoke `nvme <plugin> <command> <device> <args>`. Automatically skips tests
  if the plugin is not available.
- **Test&lt;Plugin&gt;** — set the `<plugin>_name` attribute and provide a
  place for plugin-specific helpers.

## Meson Options

Each plugin test suite is gated by its own meson option named
&lt;plugin&gt;-tests (e.g., ocp-tests):

| Option           | Default | Description                              |
|------------------|---------|------------------------------------------|
| `<plugin>-tests` | false   | Run tests against real hardware compliant with the plugin |

A plugin test suite is included in the build when these three conditions
are met:

1. `nvme-tests=true` (gates the entire `tests/` subtree)
2. The per-plugin option is enabled (e.g., `ocp-tests=true`)
3. The plugin is listed in the `plugins` build option

## Configuration

Plugin tests reuse the same `tests/config.json` as the core tests. Ensure it
points to the correct controller and namespace for your hardware:

## Building and Running

### Configure with plugin tests enabled

```bash
meson setup .build -Dnvme-tests=true -Docp-tests=true
```

### Run all enabled test suites

```bash
meson test -C .build
```

### Run a specific plugin suite

```bash
meson test -C .build --suite ocp
```

### Run a single test by name

```bash
meson test -C .build "ocp - ocp_smart_add_log_test"
```

## Writing a New Test

1. Create a file in the appropriate plugin directory (e.g.,
   `tests/plugins/ocp/ocp_smart_add_log_test.py`).

2. Inherit from the plugin base class and write test methods.

3. Add the test filename to the plugin's `meson.build`.


### Key Helper Methods

| Method | Description |
|--------|-------------|
| `self.run_plugin_cmd(cmd, device=None, args="")` | Run a plugin command, return `CompletedProcess` |
| `self.run_plugin_cmd_check(cmd, device=None, args="")` | Same as above but asserts `returncode == 0` |
| `self.run_cmd(cmd)` | Run an arbitrary shell command |
| `self.exec_cmd(cmd)` | Run a shell command, return only the returncode |

## Adding a New Plugin Test Suite

To add tests for another plugin (e.g., `zns`):

1. Add a meson option in `meson_options.txt`:

```meson
option(
  'zns-tests',
  type : 'boolean',
  value : false,
  description: 'Run tests against real hardware that supports ZNS'
)
```

2. Add the conditional `subdir()` in `tests/plugins/meson.build`:

```meson
if get_option('zns-tests') and 'zns' in selected_plugins
    subdir('zns')
endif
```

3. Create the directory structure:

```
tests/plugins/zns/
├── meson.build
├── zns_test.py
└── zns_<command>_test.py
```

4. In `zns_test.py`, inherit from `TestPlugin` and set `plugin_name = "zns"`.

5. Copy one of the existing `meson.build` files (e.g., from `ocp/`) and
   adapt the variable names and test list.
