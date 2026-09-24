# Micron & OCP Plugin Test Coverage — Report and Next Steps

## Context

Branch `bgoing/more-micron-tests` has built out the micron plugin's test
coverage in two layers: hardware-free mock suites under
[tests/cli/micron/](tests/cli/micron/) driven by `libmock_nvme.so` +
`MockIPCServer`, and hardware e2e suites under
[tests/e2e/plugins/micron/](tests/e2e/plugins/micron/). Micron is now close to
complete. OCP is not: the plugin registers **30 commands** and exactly **one**
of them has a test.

This document inventories what is untested in both plugins, then lays out a
build order for closing the gap — OCP telemetry first, then by impact.

---

# Part 1: Coverage Report

## Command inventories

- micron — 26 commands, registered in
  [micron-nvme.c:4898](plugins/micron/micron-nvme.c#L4898)
- ocp — 30 commands, registered in
  [ocp-nvme.c:3385](plugins/ocp/ocp-nvme.c#L3385)

## Micron: 26 commands

| Command | Mock (`tests/cli/micron/`) | e2e (`tests/e2e/plugins/micron/`) |
|---|---|---|
| `id-ctrl` | ✅ | ✅ |
| `smart-log` | ✅ | ✅ |
| `log-page-directory` | ✅ | ✅ |
| `vs-drive-info` | ✅ | ✅ |
| `vs-temperature-stats` | ✅ | ✅ |
| `vs-pcie-stats` | ✅ | ✅ |
| `clear-pcie-correctable-errors` | ✅ | ✅ |
| `vs-internal-log` | ✅ | ✅ |
| `vs-fw-activate-history` | ✅ | ✅ |
| `vs-smart-ext-log` | ✅ | ✅ |
| `vs-smart-add-log` | ✅ | ✅ |
| `vs-nand-stats` | ✅ | ✅ |
| `vs-work-load-log` | ✅ | ✅ |
| `vs-vendor-telemetry-log` | ✅ | ✅ |
| `vs-cloud-log` | ✅ | ✅ |
| `vs-device-waf` | ✅ | ✅ |
| `cloud-boot-SSD-version` | ✅ | ✅ |
| `plugin-version` | ✅ | — (static output; no device needed) |
| `cloud-SSD-plugin-version` | ✅ | — (static output; no device needed) |
| `latency-stats` | ✅ | ✅ |
| `latency-logs` | ✅ | ✅ |
| `latency-tracking` | ✅ | ❌ **gap** |
| `vs-smbus-option` | ✅ | ❌ **gap** |
| `vs-telemetry-controller-option` | ✅ | ❌ **gap** |
| `select-download` | ✅ | ❌ **gap** (destructive — likely should stay mock-only) |
| `clear-fw-activate-history` | ⚠️ **gate only** | ❌ **gap** |

**Micron findings**

1. `clear-fw-activate-history` is the only micron command with no functional
   coverage. It appears solely in the `_GATES` table of
   [micron_drive_model_mock_test.py:75](tests/cli/micron/micron_drive_model_mock_test.py#L75),
   which asserts the *refusal* path on unsupported models. Nothing ever
   exercises a successful clear on a supported model (`M51CX`, `M51BY`,
   `M51CY`, `M6003`, `M6004`), so the set-features path is unverified.
2. Four commands are mock-only. `latency-tracking` is the notable one: the e2e
   suites read `latency-stats` and `latency-logs` but nothing enables or
   reports the 0xD0 monitoring feature on real hardware, so the e2e latency
   tests depend on whatever state the drive happens to be in.
3. `select-download` (firmware download + commit) and `vs-smbus-option` are
   deliberately awkward to run on hardware. Mock-only is defensible; worth
   recording as a decision rather than an oversight.

## OCP: 30 commands — 29 untested

Tested: `smart-add-log` only, via
[ocp_smart_add_log_test.py](tests/e2e/plugins/ocp/ocp_smart_add_log_test.py).

There is **no hardware-free OCP suite at all**. `tests/cli/ocp/` exists but
holds nothing except a stale `__pycache__` (untracked), and
[tests/cli/meson.build](tests/cli/meson.build) has no `subdir('ocp')`.

### Telemetry family — 4 untested

| Command | Target | Notes |
|---|---|---|
| `internal-log` | telemetry host/ctrl + C9 | Fetch + full OCP decode; `-l -s -a -t -f` |
| `telemetry-string-log` | LID C9 | Ignores `-o` (see finding 1) |
| `get-telemetry-profile` | FID C8 | |
| `set-telemetry-profile` | FID C8 | |

### Log pages — 8 untested

| Command | LID |
|---|---|
| `error-recovery-log` | C1 |
| `fw-activate-history` | C2 (FAHL) |
| `latency-monitor-log` | C3 |
| `device-capability-log` | C4 |
| `unsupported-reqs-log` | C5 |
| `hardware-component-log` | C6 |
| `tcg-configuration-log` | C7 |
| `persistent-event-log` | 0x0D + OCP event decode |

### Feature getters — 8 untested (read-only, cheap)

`get-error-injection` (C0), `get-clear-pcie-correctable-errors` (C3),
`get-enable-ieee1667-silo` (C4), `get-latency-monitor` (C5),
`get-plp-health-check-interval` (C6), `get-dssd-power-state-feature` (C7),
`get-dssd-async-event-config` (C9), `get-idle-wakeup-time` (CA).

### Mutating commands — 9 untested (mock-first)

`set-error-injection` (C0), `clear-fw-activate-history` (C1),
`eol-plp-failure-mode` (C2), `clear-pcie-correctable-errors` (C3),
`set-enable-ieee1667-silo` (C4), `set-latency-monitor-feature` (C5),
`set-plp-health-check-interval` (C6), `set-dssd-power-state-feature` (C7),
`set-dssd-async-event-config` (C9).

LID/FID enums: [ocp-nvme.h:207](plugins/ocp/ocp-nvme.h#L207) and
[ocp-nvme.h:221](plugins/ocp/ocp-nvme.h#L221).

## Defects already visible in the untested code

These are the concrete reasons the OCP gap matters — each is the kind of thing
the micron suites' existing assertion patterns catch on the first run.

**Finding 1 — five OCP commands silently ignore `--output-format`.**
`output-format` is a *global* option that `NVME_ARGS` binds to
`nvme_args.output_format` ([src/args.h:63](src/args.h#L63)). Five commands
instead declare a private `struct config { char *output_format; }` initialised
to `"normal"`, never bind it to any option, and pass *that* to
`validate_output_format()`. The flag parses fine and is then discarded, so
output is always normal text:

| Command | cfg init | passed at |
|---|---|---|
| `unsupported-reqs-log` | [1751](plugins/ocp/ocp-nvme.c#L1751) | 1762 |
| `error-recovery-log` | [1851](plugins/ocp/ocp-nvme.c#L1851) | 1862 |
| `device-capability-log` | [1950](plugins/ocp/ocp-nvme.c#L1950) | 1961 |
| `telemetry-string-log` | [2511](plugins/ocp/ocp-nvme.c#L2511) | [2527](plugins/ocp/ocp-nvme.c#L2527) |
| `tcg-configuration-log` | [2621](plugins/ocp/ocp-nvme.c#L2621) | 2632 |

For contrast, the commands that get this right read `nvme_args.output_format`
directly: [ocp-nvme.c:279](plugins/ocp/ocp-nvme.c#L279),
[ocp-smart-extended-log.c:121](plugins/ocp/ocp-smart-extended-log.c#L121),
[ocp-hardware-component-log.c:260](plugins/ocp/ocp-hardware-component-log.c#L260),
[ocp-fw-activation-history.c:74](plugins/ocp/ocp-fw-activation-history.c#L74),
and `internal-log` via `argconfig_parse_seen()` at
[ocp-nvme.c:1622](plugins/ocp/ocp-nvme.c#L1622).

**Finding 2 — `internal-log` exits 0 after refusing to do anything.** Three
paths print a message and `goto out` while `err` is still 0, so the shell sees
success:

- invalid `--data-area` — [ocp-nvme.c:1542](plugins/ocp/ocp-nvme.c#L1542)
- invalid `--telemetry-type` — [ocp-nvme.c:1559](plugins/ocp/ocp-nvme.c#L1559)
- `-t controller` on a drive with `lpa` bit 3 clear — the
  `if (is_support_telemetry_controller == true)` at
  [ocp-nvme.c:1640](plugins/ocp/ocp-nvme.c#L1640) has no `else`, and the
  function still prints `ocp internal-log command completed.`
  ([1659](plugins/ocp/ocp-nvme.c#L1659))

This is exactly what micron's `_gate_reason()` helper asserts against
([micron_drive_model_mock_test.py:95](tests/cli/micron/micron_drive_model_mock_test.py#L95)):
"reported the refusal but exited 0; a caller cannot tell the refusal from
success."

**Finding 3 — the local OCP drive can't reach most of this.** The drive
available for e2e reports C0 log page version 4, so even the existing
`smart_add_log` version-6 tests skip. Telemetry data area 4 additionally
requires `lpa` bit 6 and an ETDAS round-trip
([ocp-nvme.c:1577](plugins/ocp/ocp-nvme.c#L1577)). Hardware alone cannot cover
the OCP matrix; the mock layer is not optional.

---

# Part 2: Plan for Next Steps

Strategy: **mock leads, e2e follows.** Mock suites carry branch coverage and
need a Linux host (`have_mock_nvme` requires `host_system == 'linux'` and a
non-static build, per [tests/cli/meson.build](tests/cli/meson.build)); thin e2e
suites confirm the commands work against a real OCP drive.

Key enabler for OCP telemetry: `internal-log` accepts `-l` (telemetry binary)
and `-s` (C9 string binary) and skips the drive read when both are given
([ocp-nvme.c:1568](plugins/ocp/ocp-nvme.c#L1568) and
[1601](plugins/ocp/ocp-nvme.c#L1601)). `parse_ocp_telemetry_log()` is pure file
parsing. So with crafted fixtures the entire decoder becomes deterministic
input — only the identify at [1526](plugins/ocp/ocp-nvme.c#L1526) needs the
mock at all.

## Phase 0 — Stand up the OCP mock harness

Mirror the micron layout; reuse, don't reinvent.

- **New** `tests/cli/ocp/__init__.py`
- **New** `tests/cli/ocp/ocp_mock_test.py` — the shared harness, modelled
  directly on [micron_mock_test.py](tests/cli/micron/micron_mock_test.py):
  - `OCPMockServer(MockIPCServer)` — reuse `MockIPCServer`, `make_mock_env`,
    `resolve_mock_lib_path` and `run_nvme` from
    [tests/cli/nvme_mock_ipc.py](tests/cli/nvme_mock_ipc.py) unchanged. Handle
    `OPC_IDENTIFY`, `OPC_GET_LOG_PAGE` (LID-keyed `logs` dict, paged via the
    existing `_send_slice`), and `OPC_GET_FEATURES`/`OPC_SET_FEATURES`
    (FID-keyed). Default every unconfigured page/feature to a failure status so
    the unsupported path is the default, as micron's does.
  - `TestOCPMock(TestNVMeBase)` exposing the same
    `run_plugin_cmd` / `run_plugin_cmd_check` / `run_plugin_cmd_json` surface as
    [plugin_test.py](tests/e2e/plugins/plugin_test.py), so a body reads the same
    in both layers.
  - Fixture builders: `pack_id_ctrl(lpa=…)` and a
    `pack_ocp_log(lid, *, guid, version, size)` that stamps the per-page GUID at
    the right trailing offset. The GUIDs live per page:
    [ocp-nvme.c:52](plugins/ocp/ocp-nvme.c#L52) (C3),
    [1673](plugins/ocp/ocp-nvme.c#L1673) (C5),
    [1775](plugins/ocp/ocp-nvme.c#L1775) (C1),
    [1874](plugins/ocp/ocp-nvme.c#L1874) (C4),
    [2543](plugins/ocp/ocp-nvme.c#L2543) (C7),
    [ocp-smart-extended-log.c:25](plugins/ocp/ocp-smart-extended-log.c#L25) (C0).
  - No fake sysfs tree needed — unlike micron, OCP branches on `lpa` and log
    page GUID/version, not PCI device ID. Skip `write_mock_sysfs`.
- **New** `tests/cli/ocp/meson.build` — copy
  [tests/cli/micron/meson.build](tests/cli/micron/meson.build), swap the test
  list, suites `['ocp', 'ocp-cli']`.
- **Edit** [tests/cli/meson.build](tests/cli/meson.build) — add
  `if 'ocp' in selected_plugins / subdir('ocp')` next to the micron block.
- Reuse [tests/micron_checks.py](tests/micron_checks.py)'s
  `check_bad_device_name()` / `check_output_format_rejected()` /
  `hex_fields_from_json()` — these are plugin-agnostic. Rename the module to
  `tests/plugin_checks.py` (or add a neutral alias) rather than copying it.

## Phase 1 — OCP telemetry (top priority)

**Mock:** `tests/cli/ocp/ocp_internal_log_mock_test.py`

- Argument validation, asserting **exit status, not just the message** — this
  catches Finding 2: invalid `--data-area` (0, 5, non-numeric), invalid
  `--telemetry-type`, and `-t controller` with `lpa` bit 3 clear.
- `--telemetry-type` → LID mapping: `host`/`host0`/`host1` read LID 0x07,
  `controller` reads 0x08. Assert against `server.log_reads()`.
- `--data-area` 1..4 sizing, and the data-area-4 path: `lpa` bit 6 clear must
  refuse; set must drive the ETDAS set/clear pair
  ([1577](plugins/ocp/ocp-nvme.c#L1577)–[1594](plugins/ocp/ocp-nvme.c#L1594)),
  including that a failed clear is non-fatal.
- Offline decode: `-l fixture-telemetry.bin -s fixture-string.bin` with no log
  pages configured on the mock, asserting the mock saw **no** Get Log Page —
  this is the deterministic decoder test.
- `-f` output path handling, including a directory that does not yet exist.
- Default-value messages ("Missing data-area…", "Missing telemetry-type…",
  "Missing output format…").

**Mock:** `tests/cli/ocp/ocp_telemetry_string_log_mock_test.py`

- C9 fetch + decode from a crafted fixture; `-f` naming.
- **Add an `-o json` assertion that currently fails** (Finding 1). Fix
  [ocp-nvme.c:2511](plugins/ocp/ocp-nvme.c#L2511)/[2527](plugins/ocp/ocp-nvme.c#L2527)
  to use `nvme_args.output_format` in the same commit.

**Mock:** `tests/cli/ocp/ocp_telemetry_profile_mock_test.py`

- `set-telemetry-profile` / `get-telemetry-profile` on FID C8: value
  round-trip, `--sel` variants, the save/UUID bits, and failure reporting.

**e2e:** `tests/e2e/plugins/ocp/ocp_internal_log_test.py` and
`ocp_telemetry_string_log_test.py`

- Thin. Run against the real drive, assert exit 0 and that the expected
  `*-telemetry.bin` / `*-string.bin` artifacts appear and are non-empty; skip on
  the documented unsupported messages, following `_unsupported_reason()` in
  [ocp_smart_add_log_test.py:86](tests/e2e/plugins/ocp/ocp_smart_add_log_test.py#L86).
- Write outputs under the test's log dir (`setup_log_dir`), not the cwd.

## Phase 2 — Highest-impact remaining OCP work

Ordered by coverage gained per unit of effort.

1. **One parametrised log-page mock suite** —
   `tests/cli/ocp/ocp_log_pages_mock_test.py`, table-driven over C1, C2, C3,
   C4, C5, C6, C7. All seven share the same shape (read page → check GUID →
   dispatch to a printer), so one table covers seven commands: GUID mismatch
   refused with a non-zero exit, read failure reported, valid page renders, and
   text/JSON field sets agree. That last assertion is what pins Finding 1 for
   C1, C4, C5 and C7 — fix all five call sites together.
2. **One parametrised feature mock suite** —
   `tests/cli/ocp/ocp_features_mock_test.py`, table-driven over the get/set FID
   pairs (C0, C2, C3, C4, C5, C6, C7, C9, CA): value round-trip, `--sel`
   handling including `supported`, the save bit, UUID index, and error
   reporting. Covers 17 commands in one file.
3. **`micron clear-fw-activate-history`** — the one genuine micron hole. Add a
   success path to
   [micron_options_mock_test.py](tests/cli/micron/micron_options_mock_test.py)
   (it already owns the option-style commands) asserting the set-features FID
   and value on a supported model, alongside the existing gate assertion.
4. **`micron latency-tracking` e2e** —
   `tests/e2e/plugins/micron/micron_latency_tracking_test.py`, reporting the
   feature state and restoring it in `tearDown`. This also makes the existing
   `latency-stats` / `latency-logs` e2e tests deterministic.
5. **OCP `persistent-event-log` and `hardware-component-log`** — the two
   remaining log pages with real decode logic, each deserving its own file
   ([ocp-hardware-component-log.c](plugins/ocp/ocp-hardware-component-log.c),
   [ocp-nvme.c:3009](plugins/ocp/ocp-nvme.c#L3009)).
6. **Mutating OCP commands, mock-only** — the nine setters/clears. Keep them
   off hardware; assert the issued FID, value, save and UUID bits against
   `server.commands`.

## Build wiring

No new meson options are needed: `ocp` is already in the `plugin-tests`
`choices` ([meson_options.txt:251](meson_options.txt#L251)) and
[tests/e2e/plugins/meson.build](tests/e2e/plugins/meson.build) already
`subdir()`s it. Per phase, append filenames to `ocp_tests` in
[tests/e2e/plugins/ocp/meson.build](tests/e2e/plugins/ocp/meson.build) and to
`ocp_mock_tests` in the new `tests/cli/ocp/meson.build`.

## Verification

Mock suites (Linux host):

```bash
meson setup .build && meson compile -C .build
meson test -C .build --suite ocp-cli --suite micron-cli -v
```

A single suite standalone, which is faster while iterating:

```bash
python3 tests/cli/ocp/ocp_internal_log_mock_test.py \
    .build/nvme .build/libmock_nvme.so
```

e2e, against a real OCP drive:

```bash
meson setup .build -De2e-tests=true -Dplugin-tests=ocp,micron \
    -De2e-controller=/dev/nvme0 -De2e-ns1=/dev/nvme0n1
meson test -C .build --suite ocp -v
```

Or standalone:

```bash
tests/nvme-cli-e2e --controller /dev/nvme0 --ns1 /dev/nvme0n1 \
    tests.e2e.plugins.ocp.ocp_internal_log_test
```

Lint before committing:

```bash
meson compile -C .build lint-python
make checkpatch-diff
```

Expected outcome per phase: Phase 1 lands 4 OCP commands with real branch
coverage and fixes Findings 1 (C9) and 2. Phase 2 items 1–2 take OCP from
1/30 to roughly 26/30 covered across two parametrised files, and close
Finding 1 entirely.

## Open question to settle before Phase 1

The fixes for Findings 1 and 2 are small but they are C behaviour changes, not
test code. The plan above lands each fix in the same commit as the test that
exposes it. Keeping the branch test-only instead means writing those
assertions against the *current* behaviour and marking them
`expectedFailure` — decide which before Phase 1 starts.
