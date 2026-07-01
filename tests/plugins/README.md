# Plugin Tests

This directory contains hardware tests for nvme-cli vendor plugins. Each plugin
has its own subdirectory with tests that exercise plugin commands against real
hardware.

## Architecture

```
tests/plugins/
├── plugin_test.py            # Base class for all plugin tests
├── micron/
│   ├── meson.build           # Meson test definitions for micron
│   ├── micron_test.py        # Micron-specific base class
│   └── *_test.py             # Individual test files
└── ocp/
    ├── meson.build           # Meson test definitions for ocp
    ├── ocp_test.py           # OCP-specific base class
    └── *_test.py             # Individual test files
```

### Class Hierarchy

```
unittest.TestCase
└── TestNVMe (tests/nvme_test.py)
    └── TestPlugin (tests/plugins/plugin_test.py)
        ├── TestMicron (tests/plugins/micron/micron_test.py)
        └── TestOCP (tests/plugins/ocp/ocp_test.py)
```

- **TestNVMe** — provides device config loading, `run_cmd()`, `exec_cmd()`,
  JSON parsing helpers, and log directory management.
- **TestPlugin** — adds `run_plugin_cmd()` and `run_plugin_cmd_check()` which
  invoke `nvme <plugin> <command> <device> <args>`. Automatically skips tests
  if the plugin is not available.
- **TestMicron / TestOCP** — set the `plugin_name` attribute and provide a
  place for plugin-specific helpers.

## Meson Options

Each plugin test suite is gated by its own meson option:

| Option          | Default | Description                              |
|-----------------|---------|------------------------------------------|
| `micron-tests`  | false   | Run tests against real Micron hardware   |
| `ocp-tests`     | false   | Run tests against real OCP-compliant hardware |

A plugin test suite is included in the build only when all three conditions
are met:

1. `nvme-tests=true` (gates the entire `tests/` subtree)
2. The per-plugin option is enabled (e.g., `micron-tests=true`)
3. The plugin is listed in the `plugins` build option

## Configuration

Plugin tests reuse the same `tests/config.json` as the core tests. Ensure it
points to the correct controller and namespace for your hardware:

```json
{
    "controller": "/dev/nvme0",
    "ns1": "/dev/nvme0n1",
    "log_dir": "nvmetests",
    "log_level": "DEBUG"
}
```

## Building and Running

### Configure with plugin tests enabled

```bash
meson setup .build -Dnvme-tests=true -Dmicron-tests=true -Docp-tests=true
```

### Run all enabled test suites

```bash
meson test -C .build
```

### Run a specific plugin suite

```bash
meson test -C .build --suite micron
meson test -C .build --suite ocp
```

### Run a single test by name

```bash
meson test -C .build "micron - micron_vs_drive_info_test"
```

### Verbose output

```bash
meson test -C .build --suite micron -v
```

## Writing a New Test

1. Create a file in the appropriate plugin directory (e.g.,
   `tests/plugins/micron/micron_smart_log_test.py`).

2. Inherit from the plugin base class and write test methods:

```python
from micron_test import TestMicron


class TestMicronSmartLog(TestMicron):
    """Test the micron smart-log command."""

    def test_smart_log(self):
        """Run micron smart-log and verify success."""
        self.run_plugin_cmd_check("smart-log")

    def test_smart_log_json(self):
        """Run micron smart-log with JSON output and parse it."""
        result = self.run_plugin_cmd_check("smart-log", args="-o json")
        data = self.parse_json_output(result.stdout, "micron smart-log")
        self.assertIn("temperature", data)
```

3. Add the test filename to the plugin's `meson.build`:

```meson
micron_tests = [
    'micron_vs_drive_info_test.py',
    'micron_smart_log_test.py',       # <-- add here
]
```

### Key Helper Methods

| Method | Description |
|--------|-------------|
| `self.run_plugin_cmd(cmd, device=None, args="")` | Run a plugin command, return `CompletedProcess` |
| `self.run_plugin_cmd_check(cmd, device=None, args="")` | Same as above but asserts `returncode == 0` |
| `self.run_cmd(cmd)` | Run an arbitrary shell command |
| `self.exec_cmd(cmd)` | Run a shell command, return only the returncode |
| `self.parse_json_output(output, context)` | Parse JSON string, fail with clear message on error |

## Adding a New Plugin Test Suite

To add tests for another plugin (e.g., `wdc`):

1. Add a meson option in `meson_options.txt`:

```meson
option(
  'wdc-tests',
  type : 'boolean',
  value : false,
  description: 'Run tests against real WDC hardware'
)
```

2. Add the conditional `subdir()` in `tests/plugins/meson.build`:

```meson
if get_option('wdc-tests') and 'wdc' in selected_plugins
    subdir('wdc')
endif
```

3. Create the directory structure:

```
tests/plugins/wdc/
├── meson.build
├── wdc_test.py
└── wdc_<command>_test.py
```

4. In `wdc_test.py`, inherit from `TestPlugin` and set `plugin_name = "wdc"`.

5. Copy one of the existing `meson.build` files (e.g., from `micron/`) and
   adapt the variable names and test list.
