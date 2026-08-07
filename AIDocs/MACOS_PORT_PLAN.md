# macOS (Darwin) Support for nvme-cli

## Context

Users have asked for macOS support in this fork (`Micron-TPG-OSS/nvme-cli`), which today
builds for Linux and Windows. Work happens on branch `bbusacker/macos-support`.

**The governing external constraint:** macOS has no general NVMe passthrough interface.
`IONVMeFamily` is a closed Apple kext. The only sanctioned user-space entry point is the
`AppleNVMeSMARTUserClient`, reached through an **IOCFPlugIn interface** on an
`IONVMeController` service — the same path smartmontools uses. It exposes roughly three
methods (`SMARTReadData`, `GetIdentifyData`, `GetFieldCounters`): Identify data and
SMART/health data, **not** arbitrary admin opcodes, **no generic log-page method**, and no
vendor-specific (0xC0–0xFF) commands. True passthrough would require a PCIDriverKit extension with an
Apple-granted managed entitlement plus detaching Apple's driver from the disk (making it
unusable as normal storage). That is explicitly out of scope.

**Decisions made:**

| Decision | Choice |
|---|---|
| Milestone 1 scope | Read-only diagnostics: build on Darwin, device listing, Identify + SMART/health. Everything else fails with a clear "unsupported on macOS". No DriverKit. |
| Hardware target | Third-party PCIe / Thunderbolt NVMe (`IONVMeController`). Apple Silicon internal (`AppleANS3NVMeController`) not a priority; USB-NVMe bridges out of scope. |
| Code structure | Structured for eventual upstreaming to `linux-nvme/nvme-cli`: follow the existing per-OS source-suffix split exactly, minimal guarded changes, no refactoring of shared logic. |
| Delivery | Source build + a macOS CI job. No Homebrew formula, no signed installer. |

Intended outcome: a macOS engineer can `brew install meson ninja json-c pkg-config`, build
from source, run `nvme list` to see their Thunderbolt/PCIe NVMe drives, and pull
`id-ctrl` / `smart-log` — with every unsupported subcommand failing loudly and legibly
rather than crashing or silently misreporting.

## Why this port is tractable

The repo is already structured for it. Platform differences are **separate source files
selected by meson**, not `#ifdef`s — only 16 OS-guard lines exist tree-wide. The pattern is
`<topic>-linux.c` / `<topic>-win.c` behind a shared `<topic>.h`.

Three pieces of existing groundwork matter:

1. Upstream commit `c35887c07` ("build: do not implicitly assume host_system") converted the
   feature gates to **positive Linux checks** specifically to prepare for non-Linux ports.
   So `meson.build:54-63` already reads `... and host_system == 'linux'` for
   `want_fabrics`/`want_mi`/`want_top`/`want_discoverd`/`want_libkmod`/`want_examples`.
   On Darwin these auto-disable, which forces `want_python = false` and empties the
   openssl/keyutils/liburing deps (all fabrics-gated), swapping in the existing
   `no-fabrics.c` / `no-crypto.c` / `no-mi.c` / `no-uring.c` stubs. **Darwin inherits the
   same reduced "local PCIe only" feature set Windows gets, for free.**
2. `apple-nvme` is **already a first-class transport string** in libnvme
   (`tree.c:1363`, `tree.c:1504-1511`, `tree.h:778,792`, `private.h:146`).
   `libnvme_transport_is_fabric()` already returns false for it, so the local-vs-fabrics
   classification needs no changes.
3. `libnvme` is **vendored in-tree** at `/libnvme` (not a submodule — `.gitmodules` is
   empty), so it is directly editable.

The single most important architectural fact: every command op takes an opaque
`struct libnvme_transport_handle *`, never a raw fd. The command layer builds a
`struct libnvme_passthru_cmd` via `nvme_init_*` helpers (e.g.
`nvme_init_get_log_smart` at `libnvme/src/nvme/nvme-cmds-base.h:522`) and then calls
`libnvme_exec_admin_passthru`. **Implementing that one function on Darwin inherits the
entire command + print + JSON layer for free.**

`ioctl-win.c` is the template to copy: a 2012-line opcode-dispatch `switch` where each arm
translates one NVMe opcode into a native call, with `default: return -ENOTSUP`. A Darwin
backend is the same shape with a much smaller supported opcode set, so it should be far
smaller.

## Confirmed build blockers

Each verified by reading the file. These are the whole of Phase 0.

| # | Location | Problem | Fix |
|---|---|---|---|
| 1 | `libnvme/src/nvme/endian.h:11,35` | Guards on `_WIN32`, so Darwin falls to `#include <endian.h>` — **does not exist on macOS** | Add a Darwin arm using `<libkern/OSByteOrder.h>` |
| 2 | `libnvme/src/meson.build:143-165` | Unconditional `-Wl,--version-script=` (×3, +2 fabrics, +1 mi). Apple `ld64` rejects these → hard link failure | **Guard only the `link_args` list — not the `nvme_ld`/`accessors_ld`/`ctrl_sysfs_ld` variable assignments at lines 136-141**, which must stay defined on every platform because `libnvme/test/meson.build:18` builds `_ld_args = ['--ld', nvme_ld, ...]` for `check-public-symbols.py`. Dropping the version scripts is verified safe: the lib is built `c_args: ['-fvisibility=hidden']` and public symbols are annotated `__shr_public` = `__attribute__((visibility("default")))` (`shared/compiler-attributes.h:17`), which clang honors. No need to translate `.ld` files to `-exported_symbols_list`. |
| 3 | `shared/fs-util-linux.c:36` | `-D_GNU_SOURCE` is project-wide (`meson.build:530`), so the `#ifdef _GNU_SOURCE` branch picks `mkostemp` — **absent on macOS** → link failure | **Replace the `#ifdef _GNU_SOURCE` guard with a capability probe:** `conf.set10('NVME_HAVE_MKOSTEMP', cc.has_function('mkostemp', prefix: '#define _GNU_SOURCE\n#include <stdlib.h>'))`, then `#if NVME_HAVE_MKOSTEMP`. Do **not** narrow the project-wide `-D_GNU_SOURCE` — bigger, riskier, no benefit. The existing `mkstemp` + `fcntl(F_SETFD)` fallback is already correct; it just needs the right predicate. |
| 4 | `meson.build:674` | `else link_args_list = ['-ldl']` — no `libdl.dylib` on macOS (`dlsym` is in libSystem) | Make the `-ldl` Linux-conditional |
| 5 | `meson.build:274-281` | `NVME_HAVE_SYS_RANDOM` probes only `cc.compiles('#include <sys/random.h>')`. macOS **has** the header but has `getentropy()`, **not** `getrandom()` → `crypto.c:18,666` takes the wrong path | Change to `cc.has_function('getrandom')`. Latent (fabrics-gated) but a 1-line correctness fix that also helps FreeBSD |
| 6 | `libnvme/src/nvme/lib.c:203` | Calls plain `basename(hdl->name)`; the POSIX version on macOS may modify its argument | Use the existing `shr_basename()` (`shared/fs-util.h:45`), which exists for exactly this reason |
| 7 | `util/hash-linux.c` | Uses Linux kernel crypto `AF_ALG` / `<linux/if_alg.h>` | New `util/hash-darwin.c` via CommonCrypto. **Note `CC_MD5`/`CC_SHA1` are deprecated on macOS** and CI builds `--werror`, so wrap the calls in a localised `#pragma clang diagnostic ignored "-Wdeprecated-declarations"` — a targeted pragma, not a project-wide flag. |
| 8 | `libnvme/test/meson.build:73,93` | `if host_system != 'windows'` → Darwin wrongly inherits `test-register` (mmap'd BAR registers) and `test-zns` (needs the ioctl mock) | Re-gate to `== 'linux'` |
| 9 | `libnvme/src/nvme/util.c:12` | `#include <malloc.h>` — **does not exist on macOS** (it is `<malloc/malloc.h>`), and `util.c` is in the **shared** source list, so it compiles on every platform | **Delete the line.** Verified vestigial: grep of the whole file for `malloc_usable_size|memalign|valloc|mallinfo|malloc_trim|malloc_stats` returns zero hits. The single cleanest upstreamable patch in the series. |

Non-blockers confirmed by reading: `lib-types.h:106-121` puts Darwin in the `else` branch
(`typedef int libnvme_fd_t`) — correct, no change. `types.h:11` guards on `__linux__`, so
Darwin correctly falls to the hand-rolled `__u8`..`__be64` typedefs — no change.
`util/sighdl-linux.c` is plain POSIX `sigaction` — works as-is. `shared/fs-util-linux.c` and
`net-util-linux.c` are POSIX-clean (misleading names only); `net-util` is used solely by
fabrics code, which is Linux-gated. Commit `beb53a1b5` already added `#ifndef __LITTLE_ENDIAN`
guards for FreeBSD, which macOS `<machine/endian.h>` benefits from too.

## Phase 0 — Compile and link on Darwin, all device ops stubbed

Goal: `meson setup && ninja` succeeds on macOS and `nvme --help` / `nvme version` run.
Pure build plumbing, **no IOKit**. Independently verifiable and reviewable.

Fix blockers 1–8 above, then add the Darwin arm to each platform source list, pointing at
minimal `-ENOTSUP` stubs:

- `libnvme/src/meson.build:17` — add `elif host_system == 'darwin'` (currently
  `if linux / elif windows` with **no else**, so Darwin compiles zero backend files and
  won't link). New files: `ioctl-darwin.c`, `lib-darwin.c`, `tree-darwin.c`,
  `scan-darwin.c`, `mem-darwin.c`, `ctrl-sysfs-custom-darwin.c`.
- `util/meson.build:11-22` — `sighdl-linux.c` reused; add `hash-darwin.c`; `dashboard.c`
  stays excluded for now (already `want_top`-gated).
- `meson.build:617-625` — add `nvme-pci-ids-darwin.c`.
- `plugins/meson.build:29-56` — **no change**; see plugin decision below.
- `shared/meson.build:23` — leave as-is; the `else` branch already yields the POSIX files.
- `shared/test/meson.build` — leave all three `!= 'windows'` guards as-is. If `test-net-util`
  fails on macOS in CI, narrow **that one target** to `== 'linux'` with a comment; do not
  pre-emptively broaden the guards.

Stub contents for this phase: everything returns `-ENOTSUP` / `NULL` / `0`, mirroring the
shapes in `scan-win.c` and `tree-win.c` — **except `mem-darwin.c`, which is mandatory real
work, not a stub and not reusable from Linux.** Verified: `mem-linux.c` has three hard
glibc/Linux dependencies — `#include <malloc.h>` (line 11), `malloc_usable_size()`
(line 37, glibc-only), and `MAP_HUGETLB` (line 82) + `MADV_HUGEPAGE` (line 102). The Darwin
equivalents are `malloc_size()` from `<malloc/malloc.h>`, `posix_memalign`, and **no huge-page
path at all** — return the plain allocation and let the caller proceed
(`VM_FLAGS_SUPERPAGE_SIZE_ANY` is x86-only and unreliable; do not use it).

Also enable the OS-independent unit tests as the first cheap CI signal: `meson.build:699-701`
gates `subdir('unit')` to Linux only, but `unit/test-argconfig-parse.c`,
`test-global-config.c`, `test-suffix-*`, `test-uint128*` are pure-logic. Branch
`TACT-54-enable-unit-tests-on-windows` needed only two portability fixes for Windows
(`/dev/null` → `NULL_DEVICE`, `mkstemp` → `shr_mkstemp` + a `TMPDIR` helper) — both already
satisfied natively on macOS, so this should be a one-line meson change.

**Verify:** clean configure + build on macOS (arm64 and x86_64); `nvme --help`,
`nvme version` run; `meson test` passes the `unit/` and `shared/test` suites;
`nvme list` exits with a clean error, not a crash.

## Phase 1 — IOKit enumeration and `nvme list`

The centerpiece, mirroring the Windows-only `ctrl-map.c` (1032 lines) +
`private-ctrl-map.h`. New file: `libnvme/src/nvme/device-map-darwin.c`.

Frameworks: **IOKit** and **CoreFoundation**. APIs: `IOServiceMatching("IONVMeController")`,
`IOServiceGetMatchingServices`, `IORegistryEntryCreateCFProperties` (for `vendor-id` /
`device-id`), `IORegistryEntryGetPath`, plus the plug-in open path described in Phase 2.

**Main-port symbol.** `kIOMasterPortDefault` was deprecated in favour of
`kIOMainPortDefault` in macOS 12. Probe it (`cc.has_header_symbol` or a
`#if defined(kIOMainPortDefault)` shim) rather than picking one; **declare macOS 12 as the
documented minimum** so the modern spelling is the normal path.

Link them in meson with the `appleframeworks` dependency (not `cc.find_library`, and not raw
`-framework` flags — meson has first-class support), added alongside the existing
Windows-only `cc.find_library` block at `meson.build:172-177`:

```meson
elif host_system == 'darwin'
    iokit_dep = dependency('appleframeworks', modules: ['IOKit', 'CoreFoundation'])
endif
```

then append `iokit_dep` to the libnvme `deps` list (`libnvme/src/meson.build:127-134`, which
already has a `host_system == 'windows'` arm adding kernel32/bcrypt/setupapi/cfgmgr32) and to
`link_deps` in `meson.build:649-675`.

Two seams already exist and should be reused rather than reinvented:

- **The `dirent` scan API** (`libnvme/src/nvme/scan.h`, 6 functions, `struct dirent ***`
  out-params). `scan-win.c` returns `0` for four of six and synthesizes fake dirents for the
  other two by `calloc` + `snprintf` into `d_name`. `libnvme_scan_topology()` in the shared
  `tree.c:121` is **completely unmodified** by the Windows port — copy that approach exactly.
- **The "sysfs_dir" string is already an opaque per-OS device-identity field.** `tree-win.c`
  stores the SetupAPI device interface path there, and `nvme-pci-ids-win.c` parses VID/DID
  out of it via `strstr(sysfs_dir, "ven_")`. For Darwin, store the **IORegistry path** and
  read PCI IDs from CFProperties instead of string-parsing. Seam:
  `__nvme_get_pci_ids(const char *sysfs_dir, ...)` and `__nvme_get_sysfs_dir()` in
  `nvme-pci-ids.h`.

`tree-darwin.c` must implement the same contract `tree-win.c` does (16 functions incl.
`libnvme_scan_ctrl`, `libnvme_get_ctrl_transport`, `libnvme_ns_init`, `libnvme_ns_open`,
`__libnvme_scan_namespace`, `libnvme_init_subsystem`, plus 5 `libnvme_get_*_attr` → `NULL`
stubs). `tree-win.c` is only 395 lines vs `tree-linux.c`'s 796 — use it as the size model.
Report `"apple-nvme"` (or `"pcie"`) as the transport; both are already classified local.

With no `/sys/class/nvme-subsystem`, subsystems are synthesized bottom-up from controllers,
exactly as `libnvme_get_subsystem_windows()` in `tree-win.c` does: derive subnqn/model/serial
from Identify data and key a hash table on subnqn so two controllers sharing one land in the
same subsystem. `ctrl-sysfs-custom-darwin.c` follows `ctrl-sysfs-custom-win.c`: implement
`libnvme_ctrl_load_identity()` by issuing a live Identify, and make
`libnvme_ctrl_load_phy_slot()` a `return 0` no-op.

**Handle representation.** An IOKit `io_connect_t` is a `mach_port_t` (unsigned int), so it
fits the `int libnvme_fd_t` slot — but this needs deciding explicitly. Recommendation:
**store the `io_connect_t` in `hdl->fd`** (it is what every command needs) and keep the
`/dev/rdiskN` path only for naming/identity. Critically, `hdl->stat` must be **forged** the
way `lib-win.c:97` does it:
`hdl->stat.st_mode = (is_controller ? S_IFCHR : S_IFBLK) | 0600; hdl->stat.st_nlink = 1;`
because shared code tests `S_ISCHR`/`S_ISBLK` on `hdl->stat` to distinguish controller from
namespace. (Commit `b604aeeb3` renamed these checks to `is_ctrl`/`is_ns` precisely because
the char/block distinction is not universal.) Preserve the `LIBNVME_TEST_FD` pseudo-device
special case that both `lib-linux.c` and `lib-win.c` honor.

**Verify:** `sudo nvme list` shows real Thunderbolt/PCIe NVMe drives with correct
model/serial/firmware; `nvme list -o json` is well-formed; behaves sanely with zero NVMe
devices attached and with two drives in one enclosure.

## Phase 2 — Identify and SMART via the SMART user client

**The access path is an IOCFPlugIn interface, not a raw `IOConnectCallStructMethod`.** This
is what smartmontools actually does, and it determines the whole shape of the file:

```
IOCreatePlugInInterfaceForService(service, kIONVMeSMARTUserClientTypeID,
                                 kIOCFPlugInInterfaceID, &plugin, &score);
(*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), &smartIf);
(*smartIf)->SMARTReadData(smartIf, &smartData);
(*smartIf)->GetIdentifyData(smartIf, &identData, nsid);
(*smartIf)->GetFieldCounters(smartIf, &counters);
```

That is roughly the entire interface — **there is no generic "give me log page LID=X"
method.** Plan around those three calls, not around an opcode-transparent pipe.

`NVMeSMARTLibExternal.h` is **not in the public SDK**, so a minimal declaration of the
interface struct must be vendored in-tree (as smartmontools does). Keep that vendored block
small, isolated in one header, and clearly commented as private ABI — see the risk section.

### Phase 2a — Identify only

`GetIdentifyData` alone lights up `nvme id-ctrl` / `id-ns`, and Phase 1's subsystem
synthesis and `libnvme_ctrl_load_identity()` **already depend on issuing a live Identify**.
So enumeration and Identify cannot actually be split into separate deliverables — Phase 1's
`nvme list` needs model/serial/firmware, which come from Identify. Land them together.

### Phase 2b — SMART/health

`SMARTReadData` backs `nvme smart-log`. Independent of 2a and separately verifiable against
`smartctl -a`, so it makes a clean second commit.

`ioctl-darwin.c` becomes the opcode-dispatch switch, structured like
`libnvme_exec_admin_passthru` in `ioctl-win.c:1966`:

```
switch (cmd->opcode) {
case nvme_admin_identify:      return submit_admin_identify(hdl, cmd);
case nvme_admin_get_log_page:  return submit_admin_get_log_page(hdl, cmd);   /* SMART/health only */
default:
        libnvme_msg(hdl->ctx, LIBNVME_LOG_DEBUG, "%s: opcode=0x%02x\n", __func__, cmd->opcode);
        return -ENOTSUP;
}
```

`libnvme_exec_io_passthru` returns `-ENOTSUP` wholesale. Async
(`submit`/`reap`/`wait`) is already handled — `no-uring.c` stubs them to `-ENOTSUP` and makes
`exec_*` take the synchronous path; Darwin gets it automatically from the existing meson
logic.

Preserve the three shared hooks in every submit function, exactly as `ioctl-win.c` does, or
the mock harness and `--dry-run` break:
`user_data = hdl->submit_entry(...)` → `if (hdl->ctx->dry_run) goto out;` → work →
`hdl->submit_exit(hdl, cmd, err, user_data)`, with retries driven by `hdl->decide_retry(...)`.
Add a `kern_return_t` → errno translator mirroring `get_errno_from_error(DWORD)`.

**Honest capability expectation:** Identify Controller/Namespace and SMART/health are the
reliably reachable pieces. **Arbitrary `get-log-page` may well not be available** —
smartmontools gets only Identify + SMART/health from this interface. The dispatch structure
means additional opcodes can be added later if they prove reachable, without restructuring.
Do not promise `telemetry-log`, `persistent-event-log`, or vendor log pages until proven on
hardware.

**Error UX.** Verified path: callers use `nvme_show_error("...: %s", libnvme_strerror(-err))`
(`nvme-print.h:18` → `nvme_show_message`). `libnvme_strerror` (`libnvme/src/nvme/util.c:470`)
falls through to `strerror()`, so bare `-ENOTSUP` prints the vague "Operation not supported" —
indistinguishable from a broken drive.

**Fix: append `ENVME_PLATFORM_UNSUPPORTED` to `enum libnvme_connect_err`**
(`libnvme/src/nvme/util.h:44-65`) with a matching entry in the `libnvme_status[]` table
(`util.c:439`). Verified this is the right seam despite the enum's fabrics-flavoured name,
which is historical:

- `libnvme_strerror`'s only test is `if (errnum >= ENVME_CONNECT_RESOLVE)` (`util.c:472`) — any
  value in the ≥1000 range routes to the custom table automatically.
- `libnvme_status[]` is a sparse designated-initializer array read through bounds-checked
  `ARGSTR`/`arg_str` (`util.c:389-397`), which returns `"unrecognized"` rather than reading out
  of bounds — so appending cannot break existing callers.
- Both `libnvme_errno_to_string` and `libnvme_strerror` are already exported
  (`libnvme/src/libnvme.ld:22,141`), so no export-list change is needed. Appending at the end
  of the enum is ABI-compatible.

Message text along the lines of *"not supported on macOS: Apple's NVMe driver exposes no
passthrough interface"* — so users read it as a platform limit, not a bug or a failing drive.

**Verified safe to change return values:** the only `-ENOTSUP` mentions outside `return`
statements are three *assignments* (`plugins/amzn/amzn-nvme.c:629`,
`plugins/micron/micron-nvme.c:1092,3624`). **No caller anywhere in `nvme.c` or the plugins
compares against `-ENOTSUP`**, so nothing pattern-matches on it. Still re-grep before flipping
any given site, and keep plain `-ENOTSUP` on internal paths where only the CLI-facing
top-level error needs the friendly text.

**Privileges:** opening the IOKit user client requires **root** — document `sudo` everywhere
and make the permission-denied error explicitly say so.

**Verify:** against a real Thunderbolt NVMe drive, `sudo nvme id-ctrl` and
`sudo nvme smart-log` return values matching `smartctl -a` and matching the same drive read
from a Linux box; unsupported subcommands (`format`, `sanitize`, `fw-download`,
`admin-passthru`, vendor plugins) each fail with the clear message and a non-zero exit;
`nvme id-ctrl -o json` is well-formed.

## Phase 3 — Tests, CI, and docs

**Mocking.** The existing harness does **not** transfer. `libnvme/test/ioctl/mock.c`
interposes `ioctl()` via `LD_PRELOAD` + `dlsym(RTLD_NEXT)`, but a Darwin backend never calls
`ioctl()` — it calls through an IOCFPlugIn vtable. (`DYLD_INSERT_LIBRARIES` +
`DYLD_FORCE_FLAT_NAMESPACE` is the mechanical analogue and works for our own build-dir
binaries despite SIP, but the interposed symbol is the wrong one.) **Recommendation:** make
the IOKit call layer a thin injectable indirection in `ioctl-darwin.c` so tests substitute a
fake, rather than fighting dyld. Note `libnvme/test/meson.build:299` gates the
`ioctl`/`sysfs`/`nbft` subdirs to Linux; keep Darwin out and narrow any Darwin mock test list
the way `TACT-59` did for Windows (`['identify','features','logs']`, with a comment that
enabling more needs a decoder per family "rather than reporting a pass they didn't earn").

Reuse the `TACT-59` design lesson: declare divergent behavior in the shared test via fields on
`struct mock_cmd` (Windows added `win_err` / `win_no_ioctl`) resolved through platform inline
accessors, so an undeclared divergence fails loudly instead of being approximated.

**CI.** `.github/workflows/build.yml:296` (`windows-msys2-ucrt64`) is the only non-Linux job
and the exact one to clone. macOS analogue: `runs-on: macos-latest`,
`brew install meson ninja json-c pkg-config`, then `scripts/build.sh -b release -c clang`.
Reuse `config_meson_default` in `scripts/build.sh` (~line 117) — it is clean and portable and
is what the Windows job uses. Avoid the other configs: they hardcode
`-idirafter /usr/include/x86_64-linux-gnu`, `-Wl,--gc-sections`, and `-static` (Apple `ld`
rejects `-static`). Add `scripts/macos-setup.sh` modeled on `scripts/win-ucrt64-setup.sh`.
Build both arm64 and x86_64. CI can only verify build + offline tests — no NVMe hardware on
GitHub runners — so hardware verification stays manual; say so rather than implying coverage.

**Docs.** Add a "Building on macOS" section to `Documentation/BUILDING.md` beside the
existing "Building on Windows" (line 21). Note `BUILDING.md:~275` currently states outright
that "libnvme depends on the `/sys/class/nvme-subsystem` interface" — update it. Write
`MACOS_COMMAND_SUPPORT.md` modeled on `WINDOWS_COMMAND_SUPPORT.md` (a 215-line
supported / needs-testing / not-implemented / not-supported-by-OS matrix). **Keep both docs
on the working branch, not a side branch** — the Windows equivalents stranded on `origin/mingw`
and went stale (its `TODO.md` still describes a per-header shim scheme that was abandoned).

## Plugin decision

`plugins/meson.build` uses two distinct tests. `if host_system != 'windows'` adds
huawei/netapp/sandisk/wdc + `micron-utils-linux.c`, so **Darwin would silently inherit all of
them**; `if host_system == 'linux'` adds scaleflux/zns, correctly excluding Darwin.

Nearly every vendor plugin issues vendor-specific opcodes (0xC0–0xFF) that are **not reachable
on macOS**, so those subcommands fail at runtime with the unsupported error.

**Decision: leave the `!= 'windows'` branch alone — keep all five building on Darwin.**
Verified rationale:

- `micron-utils-linux.c` is misnamed, not Linux-specific: its only platform headers are
  `<spawn.h>` and `<sys/wait.h>`, both POSIX and both present on macOS.
- `plugins/huawei/huawei-nvme.c:96` does a raw `fstat(libnvme_transport_handle_get_fd(hdl))`.
  With an `io_connect_t` in `hdl->fd` this **fails with `EBADF` and the function returns the
  error immediately** — which is the *safe* outcome. A real `/dev/rdiskN` fd would instead
  succeed and mis-classify `rdisk` as `S_IFCHR`, silently corrupting `item->block`. This is an
  argument for the `io_connect_t`-in-`hdl->fd` choice, not against building huawei.
- Failure mode across all five is "no devices found" or a clean per-command error — never a
  crash.

Gating them off would be extra Darwin-specific meson divergence (which the upstreaming goal
says to minimise) in exchange for nothing. Revisit only if one of them actually misbehaves on
hardware.

Plugin registration needs no change: `nvme-builtin.h` uses a single
`COMMAND_LIST(ENTRY(...))` macro gated only at feature level (`CONFIG_TOP`, `CONFIG_FABRICS`,
`CONFIG_MI`, `CONFIG_DEPRECATED_CMDS`); no individual command is `#ifdef`'d per-OS, and
unsupported ones simply fail at runtime. That is the right pattern — keep it. `plugins/sed/sed.c`
is already gated on `NVME_HAVE_SED_OPAL` (0 on Darwin), and scaleflux/zns/lm are already
`== 'linux'`.

## Upstreamability

Send these to `linux-nvme/nvme-cli` independently of the macOS work — they are generic
portability fixes that also help the FreeBSD port upstream has signalled interest in:

- `endian.h` Darwin/BSD arm (blocker 1)
- `--version-script` guarded to GNU ld (blocker 2)
- `getrandom` probe corrected to `has_function` (blocker 5)
- `-ldl` made Linux-conditional (blocker 4)
- `basename` → `shr_basename` (blocker 6)
- `libnvme/test/meson.build` re-gated `!= 'windows'` → `== 'linux'` (blocker 8)

- `util.c` stray `<malloc.h>` include deleted (blocker 9) — the cleanest of the set
- `fs-util-linux.c` `#ifdef _GNU_SOURCE` → `NVME_HAVE_MKOSTEMP` probe (blocker 3)

Fork-specific: the `-darwin.c` backends, `device-map-darwin.c`, the macOS CI job, and the
docs. Reserve `#ifdef __APPLE__` for types and macros only; `endian.h` is the one place it is
genuinely needed.

**Commit sequence.** Follow the Windows port's rhythm — refactor the seam in its own commit,
then add the platform file (e.g. `691b1f43a` "mem: move memory allocator helpers" →
`45d09033e` "mem: implement allocation helpers for Windows"; `4324c32be` "tree: split platform
code into separate files" → `7a4eb8f23` "tree: add windows tree support"). Concretely:

| PR | Contents | Reviewable on its own? |
|---|---|---|
| 1 | The six generic portability fixes above. No Darwin files, no meson `darwin` arms. | Yes — improves Linux/FreeBSD too; upstreamable verbatim |
| 2 | Darwin meson arms + stub backends + `mem-darwin.c` + `hash-darwin.c`. Phase 0. | Yes — "it builds and `--help` runs" |
| 3 | IOKit enumeration **plus** Identify (Phase 1 + 2a — cannot be split, see Phase 2a) | Yes — `nvme list` and `id-ctrl` work |
| 4 | SMART/health (Phase 2b), CI job, docs | Yes — `smart-log` works |

## Risks and open unknowns

- **Arbitrary `get-log-page` may not be reachable** via `AppleNVMeSMARTUserClient`.
  smartmontools gets only Identify + SMART/health. Phase 2 must confirm on hardware before
  any log-page command is documented as supported. This is the single largest scope risk.
- **Apple Silicon internal SSDs** use `AppleANS3NVMeController` with a non-standard
  interface; not a target, and likely partial at best. `nvme list` should omit or clearly
  mark them rather than showing garbage.
- **Vendored private ABI.** `NVMeSMARTLibExternal.h` is not in the public SDK, so the
  interface struct must be declared in-tree. If Apple reorders that vtable in a future
  release, calls land on the wrong function pointer — a **crash risk, not a clean error**.
  Mitigations: keep the declaration in one small isolated header copied faithfully from the
  smartmontools layout; check every `IOCreatePlugInInterfaceForService`/`QueryInterface`
  return before use; document the macOS versions actually tested. Pin macOS 12 as the minimum
  and fail cleanly on mismatch rather than misdecoding.
- **Root required** for the IOKit user client; document `sudo` and make the EACCES path say so.
- **No hardware in CI** — GitHub macOS runners have no NVMe. CI proves compile + offline
  tests only; hardware verification is manual.
- **Fork sync friction** — `micron-sync-and-merge.yml` merges upstream master daily. Keeping
  changes minimal and guarded (and upstreaming the generic fixes) is what limits conflicts.

## Verification summary

| Phase | Check |
|---|---|
| 0 | Configure + build clean on macOS arm64 and x86_64; `nvme --help` / `version` run; `meson test` passes `unit/` + `shared/test`; `nvme list` errors cleanly |
| 1 + 2a | `sudo nvme list` shows real Thunderbolt/PCIe drives, correct model/serial/firmware; JSON well-formed; sane with 0 devices and with 2 drives sharing a subsystem; `sudo nvme id-ctrl` / `id-ns` match a Linux read of the same drive |
| 2b | `sudo nvme smart-log` matches `smartctl -a` on the same drive; unsupported subcommands (`format`, `sanitize`, `fw-download`, `admin-passthru`, vendor plugins) each fail with the clear platform message + non-zero exit |
| 3 | macOS CI job green on both arches; `MACOS_COMMAND_SUPPORT.md` matches observed behavior command-by-command |
