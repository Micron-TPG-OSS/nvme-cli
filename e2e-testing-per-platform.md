# Python E2E Test Coverage: Windows vs Linux

**Scope:** `tests/e2e/` (excludes `tests/e2e/plugins/micron/` and `tests/e2e/plugins/ocp/`). These are the 21 modules wired into [tests/e2e/meson.build](tests/e2e/meson.build)'s `tests = [...]` list, run via `tests/nvme-cli-e2e` / [tests/e2e/runner.py](tests/e2e/runner.py) against a real device. `nvme_simple_template_test.py` is an unregistered docs-only template and `nvme_test_io.py` is a shared base class (`TestNVMeIO`), not a test; both are excluded.

Enumerated against nvme-cli 3.1.

## How platform gating works

- [nvme_test.py:224-226](tests/nvme_test.py#L224-L226) — `is_windows()` checks `platform.system() == 'Windows'`.
- [nvme_test.py:464-465](tests/nvme_test.py#L464-L465) — `get_ns_mgmt_support()` **always returns `False` on Windows**, regardless of controller capability. Every test that needs `ns create`/`ns attach`/`ns detach`/`ns delete` is therefore unconditionally skipped on Windows, as is `create_and_attach_default_ns()` in the shared `setUp`/`tearDown`.
- Several tests additionally have an explicit `if self.is_windows(): self.skipTest(...)` guard for commands the Windows backend doesn't implement, and one test (`dsm`) branches on the platform to assert Windows-specific behavior rather than skipping.
- The Windows backend implements only a subset of NVMe commands, using a different IOCTL per command instead of a single passthru:
  - IO ([ioctl-win.c:2453-2475](libnvme/src/nvme/ioctl-win.c#L2453-L2475)): `flush`, `write`, `read`, `compare` (**WinPE only**), `dsm`, and vendor-specific opcodes `0x80-0xFF`. Everything else — including `copy`, `verify`, `write-zeroes` and `write-uncor` — returns `-ENOTSUP`.
  - Admin ([ioctl-win.c:2502-2539](libnvme/src/nvme/ioctl-win.c#L2502-L2539)): Get Log Page, Identify, Set/Get Features, Firmware Commit/Download, Device Self-test, Format NVM, Security Send/Receive, Sanitize, vendor-specific `0xC0-0xFF`, plus Namespace Management, Namespace Attachment and NVMe-MI Send/Receive **WinPE only**.
- Log-page retrieval prefers `IOCTL_STORAGE_QUERY_PROPERTY` and falls back to `IOCTL_STORAGE_PROTOCOL_COMMAND` when the driver reports `ERROR_INVALID_FUNCTION` for a page it does not carry in its supported-logs list (commit `e9242eb7d`), and goes straight to the generic passthrough when the requested CSI is not NVM (commit `d42a89e64`), since `IOCTL_STORAGE_QUERY_PROPERTY` has no CSI-equivalent field. Log-page tests therefore behave like Linux passthrough rather than being restricted to a fixed page list.

## Directly tested commands, by e2e test file

| Test file / class | Command(s) under test | Linux | Windows | Notes |
|---|---|---|---|---|
| [nvme_id_ctrl_test.py](tests/e2e/nvme_id_ctrl_test.py) `TestNVMeIdctrlCmd` | `id ctrl`, `id ctrl --vendor-specific` | ✅ | ✅ | No platform guard. |
| [nvme_id_ns_test.py](tests/e2e/nvme_id_ns_test.py) `TestNVMeIdentifyNamespace` | `id ns` (single + all namespaces) | ✅ | ✅ | No platform guard. |
| [nvme_smart_log_test.py](tests/e2e/nvme_smart_log_test.py) `TestNVMeSmartLogCmd` | `log smart` (ctrl + per-namespace if LPA bit 0 set) | ✅ | ✅ | No platform guard; relies on generic log passthrough. |
| [nvme_error_log_test.py](tests/e2e/nvme_error_log_test.py) `TestNVMeErrorLogCmd` | `log error` | ✅ | ✅ | No platform guard; `get_error_log()` also parses the human-readable output and asserts the reported entry count matches the number of `Entry[n]` lines. |
| [nvme_fw_log_test.py](tests/e2e/nvme_fw_log_test.py) `TestNVMeFwLogCmd` | `log fw` | ✅ | ✅ | No platform guard. |
| [nvme_lba_status_log_test.py](tests/e2e/nvme_lba_status_log_test.py) `TestNVMeLbaStatLogCmd` | `log lba-status` | ✅ (skipped if OACS→GLSS unsupported) | ✅ (same, no OS guard) | Skip is capability-based, not OS-based. |
| [nvme_get_lba_status_test.py](tests/e2e/nvme_get_lba_status_test.py) `TestNVMeGetLbaStatusCmd` | `get-lba-status` | ✅ (skipped if OACS→GLSS unsupported) | ✅ (same, no OS guard) | Skip is capability-based, not OS-based. |
| [nvme_flush_test.py](tests/e2e/nvme_flush_test.py) `TestNVMeFlushCmd` | `flush` | ✅ | ✅ | No platform guard. |
| [nvme_ctrl_reset_test.py](tests/e2e/nvme_ctrl_reset_test.py) `TestNVMeCtrlReset` | `reset` | ✅ | ✅ | On Windows this maps to a PnP disable/enable cycle (`reset_ctrl_device`, [ioctl-win.c:142](libnvme/src/nvme/ioctl-win.c#L142)) rather than a true controller reset; the `/sys/bus/pci/rescan` step in `nvme_reset_ctrl()` is skipped. |
| [nvme_read_write_test.py](tests/e2e/nvme_read_write_test.py) `TestNVMeReadWriteTest` | `write`, `read` | ✅ | ✅ | No platform guard. |
| [nvme_dsm_test.py](tests/e2e/nvme_dsm_test.py) `TestNVMeDsm` | `dsm` | ✅ | ✅ (platform-specific assertions) | Runs on both. On Windows the test asserts that only the Deallocate attribute works: bare `dsm` must fail, `--ad` must succeed, and `--ad --idr` / `--ad --idw` must fail. Matches [ioctl-win.c:1139-1184](libnvme/src/nvme/ioctl-win.c#L1139-L1184), where DSM is translated to SCSI UNMAP — the integral-dataset attributes and per-range context attributes have no UNMAP equivalent and are rejected rather than silently dropped. |
| [nvme_get_features_test.py](tests/e2e/nvme_get_features_test.py) `TestNVMeGetMandatoryFeatures` | `get-feature` | ✅ (FIDs 01,02,04,05,07,08,09,0A,0B) | ⚠️ Partial | Windows drops FID 05 (Error Recovery) and FID 07 (Number of Queues), and interrupt-vector discovery for FID 09 is fixed at 1 vector instead of parsing `/proc/interrupts` ([nvme_get_features_test.py:55-69](tests/e2e/nvme_get_features_test.py#L55-L69)). |
| [nvme_compare_test.py](tests/e2e/nvme_compare_test.py) `TestNVMeCompareCmd` | `compare` | ✅ (skipped if ONCS bit 0 unsupported) | ❌ Skipped | Explicit `is_windows()` skip — "Compare command not supported by Windows". The backend supports it only under WinPE. |
| [nvme_verify_test.py](tests/e2e/nvme_verify_test.py) `TestNVMeVerify` | `verify` | ✅ (skipped if ONCS bit 7 unsupported) | ❌ Skipped | Explicit `is_windows()` skip — "Verify command not supported by Windows". |
| [nvme_writeuncor_test.py](tests/e2e/nvme_writeuncor_test.py) `TestNVMeUncor` | `write-uncor` | ✅ (skipped if ONCS bit 1 unsupported) | ❌ Skipped | Explicit `is_windows()` skip — "Write Uncorrectable command not supported by Windows". |
| [nvme_writezeros_test.py](tests/e2e/nvme_writezeros_test.py) `TestNVMeWriteZeros` | `write-zeroes` | ✅ | ❌ Skipped | Explicit `is_windows()` skip — "Write Zeroes command not supported by Windows". |
| [nvme_attach_detach_ns_test.py](tests/e2e/nvme_attach_detach_ns_test.py) `TestNVMeAttachDetachNSCmd` | `ns create`, `ns attach`, `ns detach`, `ns delete` | ✅ (skipped if ctrl lacks NS mgmt) | ❌ Skipped | `ns_mgmt_supported` is hard-coded `False` on Windows. |
| [nvme_create_max_ns_test.py](tests/e2e/nvme_create_max_ns_test.py) `TestNVMeCreateMaxNS` | `ns create`, `ns attach`, `ns detach`, `ns delete` (looped to max NS count) | ✅ (skipped if ctrl lacks NS mgmt) | ❌ Skipped | Same NS-mgmt gate. |
| [nvme_format_test.py](tests/e2e/nvme_format_test.py) `TestNVMeFormatCmd` | `ns create`/`ns attach`/`ns detach`/`ns delete` across every reported LBA format, plus read/write IO per format | ✅ (skipped if ctrl lacks NS mgmt) | ❌ Skipped | Same NS-mgmt gate. Despite the name, this test **never invokes the `format` subcommand** — it exercises LBA-format selection by recreating the namespace with each `flbas` value. |
| [nvme_qpif_test.py](tests/e2e/nvme_qpif_test.py) `TestNVMeQPIFTest` | `ns create`/`ns attach`/`ns delete` (QPIF LBA format) + `write`/`read` with `--storage-tag` | ✅ (skipped if ctrl lacks NS mgmt or no QPIF LBA format) | ❌ Skipped | Same NS-mgmt gate. |
| [nvme_copy_test.py](tests/e2e/nvme_copy_test.py) `TestNVMeCopyFormat0/1/23` | `copy` (descriptor formats 0/1/2/3) | ✅ (each format skipped independently if OCFS/limits/PI-format unsupported) | ❌ Skipped | Copy is not supported on Windows (`nvme_cmd_copy` has no Windows IOCTL mapping). Formats 1/3 explicitly require NS mgmt to reformat the namespace; formats 0/2 additionally require a 16-bit-guard PI format. |

## Indirectly tested commands (used by shared setup/teardown helpers in `nvme_test.py`)

These aren't a test's primary subject but run in nearly every test's `setUp`/`tearDown` (or a helper used by several tests above), so their basic functionality is continuously exercised:

| Command | Used by (helper) | Linux | Windows |
|---|---|---|---|
| `id ctrl` | `get_id_ctrl_field_value`, `get_ncap`, `get_max_ns`, device-metadata capture — used by nearly every test | ✅ | ✅ |
| `id ns` | `get_lba_format_size`, `_get_active_lbaf_index`, `_get_ns_dps`, `_is_metadata_ext`, `_get_pif`, `get_id_ns_field_value` — used by nearly every test | ✅ | ✅ |
| `id ctrl-list` | `get_ctrl_id()` — used by every NS-mgmt-based test | ✅ | ❌ (only reached when NS mgmt is exercised) |
| `id ns-list` | `get_nsid_list()`, `delete_all_ns()` | ✅ | ❌ (only reached when NS mgmt is exercised) |
| `id nvm-ns` | copy-format PI lookup, QPIF LBA-format discovery | ✅ | ❌ (only reached when NS mgmt is exercised) |
| `ns get-id` | `TestNVMeCopy.setUp` | ✅ | ❌ (only reached since copy is skipped on Windows) |
| `feat host-behavior-support` | `TestNVMeCopy` / `TestNVMeQPIFTest` (get/set CDFE, LBAFEE) | ✅ | ❌ (only reached since copy/QPIF are skipped on Windows) |
| `ns create` / `ns attach` / `ns detach` / `ns delete` | `create_and_attach_default_ns()` in every `setUp`/`tearDown` ([nvme_test.py:246-248](tests/nvme_test.py#L246-L248)) | ✅ | ❌ (`ns_mgmt_supported` forced `False`) |

## Core commands with no e2e testing path

**How this list was built:** the command tree was enumerated from `nvme utils dump-command-metadata` (schema version 1, nvme-cli 3.1 — 103 built-ins, 34 plugins) and diffed against every command string reachable from `tests/e2e/`, including the commands invoked only by `nvme_test.py` helpers, i.e. the "indirectly tested" table above. A command counts as having a testing path if *any* e2e test can reach it on *either* platform; commands skipped only on Windows are therefore **not** listed here.

Excluded from the count:

- All 21 vendor plugins (`amzn`, `dapustor`, `dell`, `dera`, `ibm`, `innogrit`, `inspur`, `intel`, `mangoboost`, `memblaze`, `micron`, `nvidia`, `ocp`, `seagate`, `shannon`, `solidigm`, `ssstc`, `toshiba`, `transcend`, `virtium`, `ymtc`).
- The 75 deprecated flat aliases in [src/nvme-cmds-deprecated.c](src/nvme-cmds-deprecated.c), which would double-count their grouped equivalents. Note that 9 of them *do* have a conditional path: `_LEGACY_COMMANDS` / `_probe_command()` in [nvme_test.py:45-76](tests/nvme_test.py#L45-L76) falls back to `id-ctrl`, `id-ns`, `list-ctrl`, `list-ns`, `nvm-id-ns`, `smart-log`, `error-log`, `fw-log`, `lba-status-log` when the binary under test doesn't accept the grouped form.

### Built-in commands — 21 of 33 untested

| Command | Note |
|---|---|
| `admin-passthru`, `io-passthru` | Generic passthrough; no e2e test constructs a raw command. |
| `format` | Never invoked. [nvme_format_test.py](tests/e2e/nvme_format_test.py) exercises LBA-format *selection* by creating/deleting namespaces, not the `format` subcommand. |
| `sanitize`, `sanitize-ns` | Destructive; no test attempts them. |
| `device-self-test` | Untested; the companion `log self-test` is also untested. |
| `set-feature` | The get side (`get-feature`) is covered; the set side is not. |
| `get-log` | The generic LID-by-number form is untested; only named `log` subcommands are exercised. |
| `capacity-mgmt`, `virt-mgmt`, `lockdown` | Untested. |
| `get-property`, `set-property`, `get-reg`, `set-reg`, `show-regs` | Register/property access; untested. |
| `subsystem-reset`, `ns-rescan` | Untested (`reset` itself is covered). |
| `list`, `list-subsys`, `show-topology` | Enumeration commands; untested by e2e (a `--help` invocation appears in `tests/unit/py/test_command_metadata_schema.py`, which is not device coverage). |

### Core plugin subcommands

| Plugin | Untested / total | Commands with no e2e testing path |
|---|---|---|
| `ns` | **0 / 5** | — fully covered (`create`, `attach`, `detach`, `delete`, `get-id`) |
| `log` | 29 / 33 | `ana`, `ave-discovery`, `boot-part`, `changed-alloc-ns-list`, `changed-ns-list`, `dispersed-ns-participating-nss`, `effects`, `endurance`, `endurance-event-agg`, `fid-support-effects`, `host-discovery`, `media-unit-stat`, `mgmt-addr-list`, `mi-cmd-support-effects`, `persistent-event`, `phy-rx-eom`, `power-measurement`, `pred-lat-event-agg`, `predictable-lat`, `pull-model-ddc-req`, `reachability-associations`, `reachability-groups`, `resv-notif`, `rotational-media-info`, `sanitize`, `self-test`, `supported-cap-config`, `supported-pages`, `telemetry` |
| `feat` | 18 / 19 | `arbitration`, `async-event-conf`, `err-recovery`, `hctm`, `int-coalesce`, `int-vector-config`, `keep-alive-timer`, `lba-range-type`, `num-queues`, `perf-characteristics`, `power-limit`, `power-meas`, `power-mgmt`, `power-thresh`, `temp-thresh`, `timestamp`, `volatile-wc`, `write-atom-normal` (only `host-behavior-support` is reached, indirectly) |
| `id` | 13 / 18 | `domain`, `endgrp-list`, `iocs`, `ns-descs`, `ns-granularity`, `ns-ind`, `ns-lba-format`, `nvm-ctrl`, `nvm-ns-lba-format`, `nvmset`, `primary-ctrl-caps`, `secondary-ctrl-list`, `uuid` |
| `fdp` | 8 / 8 | `configs`, `events`, `feature`, `set-events`, `stats`, `status`, `update`, `usage` |
| `rpmb` | 7 / 7 | `info`, `program-key`, `read-config`, `read-counter`, `read-data`, `write-config`, `write-data` |
| `resv` | 4 / 4 | `acquire`, `register`, `release`, `report` |
| `dir` | 2 / 2 | `receive`, `send` |
| `fw` | 2 / 2 | `commit`, `download` |
| `io-mgmt` | 2 / 2 | `recv`, `send` |
| `nvme-mi` | 2 / 2 | `recv`, `send` |
| `security` | 2 / 2 | `recv`, `send` |
| `utils` | 1 / 1 | `dump-command-metadata` (covered by `tests/unit/py/test_command_metadata_schema.py`, a unit test — no e2e path) |

Two log pages stand out as gaps worth noting given the Windows log-page fallback described above: `log supported-pages` (LID 0x00) would directly validate the `IOCTL_STORAGE_QUERY_PROPERTY` → `IOCTL_STORAGE_PROTOCOL_COMMAND` path, and `log effects` is the only core command that takes a `--csi` argument — no e2e test passes a CSI other than NVM anywhere, so the non-NVM CSI passthrough path has no coverage either.

### Core plugins not enumerable from this build

The enumeration above came from a **Windows** build, where these core plugins are gated out (fabrics-dependent or platform-gated). None of them has any `tests/e2e/` coverage; several are exercised only by the non-device tests in `tests/cli/`:

| Plugin | Subcommands | Non-e2e coverage |
|---|---|---|
| `zns` | 15 | none |
| `keys` | 8 | `tests/cli/nvme_keys_test.py` |
| `lm` | 7 | none |
| `exclusion` | 6 | none |
| `sed` | 6 | none |
| `config` | 5 | `tests/cli/nvme_config_convert_test.py`, `tests/cli/nvme_config_create_test.py` |
| `registry` | 4 | `tests/cli/nvme_registry_test.py` |
| `nbft` | 1 | `tests/cli/nvme_nbft_test.py`, `tests/cli/nbft/` |

That is a further **52 commands** with no e2e testing path on either platform.

### Totals

| | Count |
|---|---|
| Core commands enumerable from this build | 138 |
| — with an e2e testing path (direct or indirect) | 27 |
| — with **no** e2e testing path | **111** |
| Additional core commands in build-gated plugins (`zns`, `keys`, `lm`, `exclusion`, `sed`, `config`, `registry`, `nbft`) | 52, all untested |

Breakdown: 33 non-deprecated built-ins (12 tested / 21 untested) plus 105 core-plugin subcommands (15 tested / 90 untested).

Two caveats on these figures. The 138 / 111 counts are scoped to the command tree a **Windows** build registers; the 52 gated-plugin commands were counted from the `.name = "..."` entries in their plugin sources rather than from a live dump, so they should be confirmed against a Linux build before the combined figure is quoted elsewhere. And "tested" here means an e2e test invokes the command — not that its output is validated; several tests only assert the exit status.

## Summary

- **Fully covered on both platforms:** `id ctrl`, `id ns`, `log smart`, `log error`, `log fw`, `log lba-status`, `get-lba-status`, `flush`, `reset`, `read`, `write`, `dsm` (Windows asserts Deallocate-only behavior).
- **Partial on Windows:** `get-feature` — FIDs 05 and 07 are dropped and interrupt-vector discovery is reduced to a single vector.
- **Skipped on Windows via explicit OS check:** `compare`, `verify`, `write-uncor`, `write-zeroes`.
- **Skipped on Windows because namespace management is hard-disabled:** `ns create`/`attach`/`detach`/`delete`, and everything that depends on them — max-NS creation, per-format namespace testing, QPIF, and all `copy` descriptor formats — plus the indirectly-exercised `id ctrl-list`, `id ns-list`, `id nvm-ns`, `ns get-id`, and `feat host-behavior-support`.
- **Untested on both platforms:** 111 of the 138 core commands in this build have no e2e testing path at all, plus 52 more in the build-gated core plugins. The largest gaps by count are `log` (29 pages untested), `feat` (18), `id` (13), and the 21 untested built-ins — most notably `format`, `set-feature`, `get-log`, `admin-passthru`/`io-passthru`, and `sanitize`. `ns` is the only core plugin with complete coverage.
