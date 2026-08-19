# SPDM transport feasibility: MCTP and PCIe DOE as alternatives to SPDM-over-Storage

## Context

`nvme micron vs-spdm-cert` is implemented and working on this branch. It carries the SPDM
requester handshake over the **DSP0286 SPDM-over-Storage** binding — NVMe Security
Send/Receive with security protocol `0xE8` — which is the only transport that needs no
new plumbing and behaves identically on Linux and Windows.

Hardware testing then showed the target drive has **no SPDM responder on that binding**.
The drive's own SECP `0x00` supported-security-protocols list is:

```
00000000: 0000 0000 0000 0004 0001 02ee
                            ^^^^ list length = 4
                                 ^^ ^^ ^^ ^^ protocols 0x00, 0x01, 0x02, 0xEE
```

i.e. protocol information (0x00), TCG (0x01/0x02) and IEEE 1667 (0xEE). **No 0xE8.**
SECP `0xE8` returns `Invalid Field in Command (0x4002)` for every SPSP0 tried.

So the question this document answers: **can the certificate chain be reached over MCTP or
PCIe DOE instead, on Linux and on Windows?** Platform-specific answers are acceptable —
the goal is to state the limitations precisely, not to rule options out for being
one-sided.

**Answer, up front: yes — via two Linux transports, and both are worth building.**

- **PCIe DOE.** The drive *does* have an SPDM responder behind a DOE mailbox (`doe_features/`
  contains `0001:01`, verified on hardware, Part 1b). This is one of the transports OCP actually
  mandates, and DSP0286 is not. It works on any Linux host with root — including the hardware we
  have today — but is blocked by kernel lockdown in integrity mode (Part 6, C3), which makes it a
  lab, qualification and failure-analysis tool rather than a fleet agent.
- **SPDM over MCTP (DSP0275, message type `0x05`).** Also OCP-mandated, and the right transport
  for fleet attestation: immune to lockdown, functional in D3hot, stable uAPI since Linux 5.15.
  It requires an **MCTP-capable server platform** — which is the primary deployment target for
  this work. nvme-cli already ships a working MCTP transport for NVMe-MI, and SPDM rides the same
  socket with one different constant (Part 7). Nothing outside nvme-cli needs to change: bridged
  routing is mainline since Linux 6.17 and `mctpd` needs no modification for message type `0x05`
  (7.4, 7.5b). The drive's sideband terminates on the **BMC** on every platform publicly
  documented, so near term the requester most plausibly runs *on the BMC* — where OpenBMC already
  builds nvme-cli and runs `mctpd` — with host-side requesters becoming practical on servers with a
  target-capable I²C adapter (7.4a). **The code is identical either way**, which is the point.

Windows can host neither, for reasons that are structural rather than incidental (Part 3); the
existing DSP0286 storage binding remains the only cross-platform transport, and the only reason
to keep pursuing it with firmware.

**Scope note on the test hardware.** The Linux box available for this investigation
(`fsm-tact-br04-04`) is a workstation with no BMC and no MCTP link, so it can validate the DOE
path but **not** the MCTP path. That is a limitation of the loaner, not of the approach, and the
plan below is deliberately not scoped down to it — Part 7.5 lists what a validation platform must
provide instead.

---

## Part 1 — What this specific drive tells us (measured, not assumed)

Read from the attached device on this host. Every value below is from a read-only command.

| Field | Value | Meaning |
| --- | --- | --- |
| PCI ID | `VEN_1344 DEV_51BC SUBSYS_2D001344 REV_01` | Micron, Gen4 x4 |
| Model / FW | `EEFDLCE1T9THA` / `E5MS003` | 1.9 TB, OEM part number |
| `ver` | `0x20000` | NVMe 2.0 |
| `oacs` | `0x45f` | bit 0 Security Send/Receive **set**; bit 6 **NVMe-MI Send/Receive set** |
| `nvmsr` | `0x1` | NVM subsystem is part of a Storage Device |
| **`mec`** | **`0x3`** | Management Endpoint on **both** an SMBus/I2C port **and a PCIe port** |
| SECP list | `00 01 02 EE` | no `0xE8` — no SPDM-over-Storage responder |
| Supported log pages | includes **LID `0x13`** | NVMe-MI Commands Supported and Effects |
| LID `0x13` contents | MI cmds `00 01 02 04 05` | Read MI Data Structure, NVM/Controller Health Status Poll, Config Get, VPD Read |

Two of these change the picture materially:

- **`MEC = 3`.** The drive advertises a Management Endpoint on its **PCIe port** as well as
  on SMBus/I2C. The PCIe-port Management Endpoint is reached by **MCTP over PCIe VDM**.
  So the drive has management-endpoint hardware that an MCTP requester could in principle
  address — this is not a drive with no management plane.
- **`OACS` bit 6 = NVMe-MI Send/Receive supported**, and LID `0x13` enumerates a working MI
  command set. There is therefore a *host-side, in-band* door into the MI world on this
  drive, independent of Security Send/Receive.

That in-band door is a **third candidate transport the original plan never considered**, and
it is evaluated in Part 4 alongside MCTP and DOE.

What the drive does **not** tell us *from Windows*: whether it implements a **DOE Extended
Capability** (PCIe ECAP ID `0x002E`). That lives in PCIe extended config space, and — see
Part 3 — Windows exposes no way to read it. Windows' curated PCI property set
(`DEVPKEY_PciDevice_*`) reports AER, ACS, ARI, ATS, link state and more, but has **no DOE
property at all**; the full dump was inspected and contains nothing DOE-related. Confirming or
refuting DOE support therefore required a Linux host — **which has since been done, and the
answer is yes.** See Part 1b.

Also worth recording: `MEC = 3` and `OACS` bit 6 initially suggested an in-band NVMe-MI tunnel
as a third candidate transport. Part 4 rules that out on spec grounds. The management endpoints
are real, but they only answer NVMe-MI.

---

## Part 1b — Linux probe results: the responder exists, behind DOE

The Step 0 probe (see Recommendation) was run on a Linux host with the same drive model. It
answered the one question Windows could not, and it answered it in the affirmative.

```
$ ls /sys/bus/pci/devices/$BDF/doe_features/
0001:01  0001:03  doe_discovery

$ sudo lspci -vv -s $BDF
        Capabilities: [d00 v2] Data Object Exchange
                DOECap: IntSup+
                        Interrupt Message Number 000
                DOECtl: IntEn-
                DOESta: Busy- IntSta- Error- ObjectReady-
        Kernel driver in use: nvme

$ sudo setpci -s $BDF ECAP2e.L
0002002e

$ grep -E '^CONFIG_PCI_DOE=' /boot/config-$(uname -r)
CONFIG_PCI_DOE=y

$ cat /sys/kernel/security/lockdown
none [integrity] confidentiality

$ sudo nvme security recv /dev/nvme0 --secp=0 --spsp=0 --nssf=0 --al=512 --size=512 -b | xxd
00000000: 0000 0000 0000 0004 0001 02ee 0000 0000  ................

$ mctp link show
dev lo index 1 address 00:00:00:00:00:00 net 1 mtu 65536 up
```

| Finding | Value | Consequence |
| --- | --- | --- |
| **`0001:01` present** | PCI-SIG VID `0001`, object type `0x01` = **CMA-SPDM** | **The drive has an SPDM responder.** The feature is achievable on existing hardware and firmware. |
| `0001:03` also present | type `0x03` = IDE_KM (PCIe link encryption key management) | Not needed here; noted only as evidence the DSM is a real, multi-feature implementation. *(Type-code mapping is from PCIe r6.0 Table 6-32, read via QEMU/Linux, not the PCI-SIG text — not load-bearing.)* |
| **`0001:02` absent** | no Secured CMA-SPDM | Irrelevant to us: `vs-spdm-cert` deliberately establishes **no session**, so only `0001:01` is required. Lucky alignment. |
| DOE cap at config offset **`0xd00`**, v2 | `setpci ECAP2e.L` = `0002002e` → ID `0x002e`, version `2`, next `0x000` (end of chain) | The ecap walk works; still discover the offset at runtime rather than hardcoding `0xd00`. |
| `DOESta: Busy- Error- ObjectReady-` | mailbox idle, no error latched | Nothing else is mid-transaction. The `nvme` driver stays bound throughout. |
| **`lockdown = [integrity]`** | `LOCKDOWN_PCI_ACCESS` falls under integrity mode | **Config-space writes are refused on this host as booted.** This is now the single gating issue for the userspace DOE path — see below. |
| SECP list identical to Windows | `00 01 02 EE`, still no `0xE8` | Confirms the missing storage responder is a **firmware** fact, not an artifact of the Windows storage stack. |
| `mctp link show` → **`lo` only** | no MCTP hardware links | **This host** has no MCTP path, so it cannot validate the MCTP transport. Says nothing about MCTP-capable servers — see Part 7.3. |

The BMC leg of the probe did not run — `busctl introspect ... <eid>` failed with
`bash: syntax error near unexpected token 'newline'` because the literal `<eid>` placeholder was
parsed as a shell redirection. It needs a real EID and must be run **on the BMC**, not the host.
It is now moot for the decision: the host-reachable responder has been found, so the
out-of-band path is no longer needed.

### Second pass on the same host, measured directly

A follow-up read-only session on `fsm-tact-br04-04` pinned down the remaining unknowns. Every
value below is observed, not inferred.

| Probe | Result | Consequence |
| --- | --- | --- |
| `nvme0` identity | `EEFDLCE1T9THA` fw **`E5MS002`** at `0000:01:00.0` | Same model as the Windows host, one firmware revision **older** (`E5MS003` there). The DOE responder is present on both revisions' worth of evidence, and the empty `0xE8` reproduces on both. |
| `doe_features/` file *contents* | `0001:01`, `0001:03`, `0001:00` | Each file holds its own `VID:type`; `0001:00` is `doe_discovery`. Confirms the ABI shape the backend's `probe()` will parse. |
| `ls .../0000:01:00.0/tsm` | **absent** | The kernel has **not** claimed the device for a platform TSM. C4's guard precondition holds today. |
| `ECAP2e+0c.L` (DOE_STATUS) | **`0x00000010`** | Busy/Error/ObjectReady all clear — but **bit 4 is set and `pci_regs.h` does not define it** (see C4; this changes the implementation). |
| `ECAP2e+04.L` (DOE_CAP) | `0x00001001` | `INT_SUP` set, `INT_MSG_NUM` 0 — matches `lspci`. Bit 12 is likewise set and undefined in the kernel header. |
| `ECAP2e+08.L` (DOE_CTRL) | `0x00000000` | Mailbox idle and un-armed; nothing mid-transaction. |
| `sudo nvme id-ctrl mctp:1,8` | **`Failure sending MCTP message: No route to host`** | The shipping MI-over-MCTP transport is **equally broken on this host** — see Part 7. |
| same, unprivileged | `Failure sending MCTP message: Permission denied` | Privilege is the *first* obstacle, the missing link the *real* one. |
| `CONFIG_I2C_DESIGNWARE_SLAVE` | **not set**; zero `i2c_dw_*_slave` or `piix4*slave` symbols in `/proc/kallsyms` | **No adapter on this host can act as an I²C target**, so `mctp-i2c` has nothing to bind to. *Kernel-vintage-specific: that option was removed upstream in Dec 2025 and DesignWare now supports target mode — see 7.4a.* |
| `lsmod \| grep mctp` | nothing loaded; `mctp route show` / `addr show` empty | No MCTP state of any kind. |
| `/dev/ipmi*`, ipmi/aspeed modules | **absent** | This is a workstation-class AMD box with an AMDGPU, **not a server with a BMC**. |
| SecureBoot efivar | `06 00 00 00 01` → **enabled** | Together with the two `CONFIG_LOCK_DOWN_*` values below, this fully explains `[integrity]` — see C3. |
| `CONFIG_LOCK_DOWN_IN_SECURE_BOOT` / `..._KERNEL_FORCE_NONE` | `y` / `y` | Lockdown is caused **solely** by Secure Boot. Disabling it in firmware clears integrity mode. |

Build note: the checked-out `nvme` at `~/bgoing/nvme-cli/.build` is `v3.0-rc1-154-g67055fb` with
`mi = enabled`, so the `mctp:` code path is genuinely compiled in and was genuinely executed —
the failures above are runtime, not `-ENOTSUP` stubs.

### The one remaining blocker: kernel lockdown

`pci_write_config()` in `drivers/pci/pci-sysfs.c` begins with
`security_locked_down(LOCKDOWN_PCI_ACCESS)`, and `LOCKDOWN_PCI_ACCESS` sits below
`LOCKDOWN_INTEGRITY_MAX` — so **integrity mode refuses every config-space write**, which is
exactly what driving the DOE mailbox requires. Lockdown is also **one-way at runtime**: it
cannot be lowered without a reboot.

Consequences to design around, not around which to redesign:

- **For development and validation:** boot the test host with Secure Boot disabled, or with
  `lockdown=none` on the kernel command line. Then `lockdown` reads `[none] integrity
  confidentiality` and the writes go through. Re-run the probe to confirm before debugging
  anything else.
- **For deployment:** on a distro that auto-enables lockdown under Secure Boot (Ubuntu, RHEL and
  derivatives do), the userspace DOE transport **will not work**. That is a genuine limitation of
  the approach and must be documented plainly, with a precise error message rather than an
  opaque `EPERM`. It is also the strongest argument for the in-kernel requester
  (Wunner / `rspdm`) eventually being the right long-term home — but neither is merged, so it
  cannot be the plan today.
- This does **not** affect discovery: `doe_features/` and `lspci` reads work fine under
  lockdown, so the tool can always tell an operator *"a CMA-SPDM responder is present but this
  kernel's lockdown setting forbids driving the mailbox"* — a far better failure than silence.

---

## Part 2 — What already exists in the tree (the reuse inventory)

### The SPDM requester is already transport-agnostic

`plugins/micron/micron-spdm.c` (~1170 lines) implements the full five-message handshake,
`ResponseNotReady`/`RESPOND_IF_READY` retry, CT-exponent backoff, chain splitting,
classification and both digest comparisons. Its entire coupling to the storage binding is
**two functions and four struct fields**:

- [micron-spdm.c:359-386](plugins/micron/micron-spdm.c#L359-L386) `spdm_send()` — prefixes the
  4-byte little-endian length, calls `nvme_init_security_send()` + `libnvme_exec_admin_passthru()`
- [micron-spdm.c:393-439](plugins/micron/micron-spdm.c#L393-L439) `spdm_recv()` — the mirror image
- [micron-spdm.c:317-320](plugins/micron/micron-spdm.c#L317-L320) `spdm_spsp()` — SPSP0/SPSP1 encoding
- [micron-spdm.c:328-357](plugins/micron/micron-spdm.c#L328-L357) `spdm_report_xport_err()` — SECP-aware diagnostics
- `struct spdm_ctx` [micron-spdm.c:175-184](plugins/micron/micron-spdm.c#L175-L184) — `hdl`, `secp`,
  `conn_id`, `xfer_size` are binding-specific; `version`, `ct_exponent`, `base_hash_algo`,
  `hash_size` are not

Everything from `spdm_xfer()` [micron-spdm.c:448](plugins/micron/micron-spdm.c#L448) upward is
binding-neutral. **Adding a transport is a vtable behind `spdm_send`/`spdm_recv`, not a
rewrite.** That is the single most important fact for costing any option below.

### MCTP plumbing that exists

- [libnvme/src/nvme/mi-mctp.c](libnvme/src/nvme/mi-mctp.c) — a complete `AF_MCTP` datagram
  implementation: socket open at `:98-135`, addressed send/poll/recv at `:438-530`.
  The MCTP message type is set via `smctp_type` on the socket address, **not** in the
  payload — `MCTP_TYPE_NVME 0x04` / `MCTP_TYPE_MIC 0x80` at `:79-80`.
- [libnvme/src/nvme/mi-mctp-compat.h](libnvme/src/nvme/mi-mctp-compat.h) — hand-rolled
  `struct sockaddr_mctp` etc. for kernels/toolchains without `linux/mctp.h`, selected by the
  `NVME_HAVE_LINUX_MCTP_H` probe at [meson.build:444-451](meson.build#L444-L451). So the code
  compiles even against older headers.
- `libnvme_mi_scan_mctp()` at `mi-mctp.c:749-1048` — D-Bus enumeration of `mctpd` endpoints,
  filtering on `SupportedMessageTypes` at `:858`. Reusable nearly verbatim for discovering
  endpoints that advertise type `0x05`.
- Device-name plumbing: `mctp:<net>,<eid>[:ctrl-id]` is already a first-class device
  argument — parsed at [libnvme/src/nvme/mi.c:48-64](libnvme/src/nvme/mi.c#L48-L64), dispatched at
  [lib-linux.c:105-107](libnvme/src/nvme/lib-linux.c#L105-L107), documented at
  [src/nvme.c:70-71](src/nvme.c#L70-L71).

The catch: none of it is factored out. `struct libnvme_mi_transport`
(`private-mi.h:81-94`) has an MI-shaped `(ep, req, resp)` signature with the MIC and
"More Processing Required" logic baked in, and lives behind `CONFIG_MI` and the
`libnvme-mi.ld` export list. Reusing the vtable is *not* a shortcut; transcribing the
~150-200 lines of socket mechanics into a standalone module is smaller.

**Gating:** [meson.build:55](meson.build#L55) — `want_mi = ... and host_system == 'linux'`.
On Windows no MI code is compiled at all (`no-mi.c` stubs), and
[lib-win.c:152-156](libnvme/src/nvme/lib-win.c#L152-L156) explicitly rejects `mctp:` names with
`-ENOTSUP`.

### In-band NVMe-MI plumbing that exists

- [plugins/nvme-mi/nvme-mi-plugin.c:122-131](plugins/nvme-mi/nvme-mi-plugin.c#L122-L131) — the
  whole in-band MI transport, as a raw passthru:
  ```c
  .opcode = admin_opcode,            /* 0x1d MI Send, 0x1e MI Receive */
  .cdw10  = cfg.nmimt << 11 | 4,     /* NMIMT in bits 14:11; MCTP MT=0x4 in bits 6:0 */
  .cdw11  = cfg.opcode,
  .cdw12  = cfg.nmd0,
  .cdw13  = cfg.nmd1,
  ```
  Note what CDW10 is: **the NVMe-MI Message Header**, whose low 7 bits are the *MCTP message
  type*. The `| 4` hardcodes NVMe-MI. Whether `MT = 0x5` (SPDM) is legal here is the pivotal
  spec question — see Part 4.
- **Windows blocks it.** [ioctl-win.c:2224-2232](libnvme/src/nvme/ioctl-win.c#L2224-L2232) routes MI
  Send/Receive to `submit_storage_protocol_command()` *only* under WinPE
  (`get_is_win_pe()` at `:93-109` probes `HKLM\SYSTEM\CurrentControlSet\Control\MiniNT`),
  otherwise `-ENOTSUP`. Confirmed live on this host:
  ```
  $ nvme nvme-mi recv /dev/nvme0 --opcode=0 --nmimt=1 --data-len=32
  nmi_recv: not supported
  ```

### PCIe / config-space plumbing that exists

- **No DOE, vfio, or config-space code anywhere in the tree.** The only occurrence of "DOE"
  is prose in [Documentation/nvme-micron-spdm-cert.txt:32](Documentation/nvme-micron-spdm-cert.txt#L32).
- BDF resolution exists: `get_pcie_bdf()` at
  [plugins/micron/micron-utils-linux.c:72-141](plugins/micron/micron-utils-linux.c#L72-L141) reads
  `/sys/class/nvme/<ctrl>/address` with a `readlink` fallback. It is `static` and would need
  exporting.
- **Extended config space is already read *and written* on Linux**, by shelling out to
  `setpci` through `spawn_and_capture()`
  ([micron-utils-linux.c:225-342](plugins/micron/micron-utils-linux.c#L225-L342)) — e.g.
  `setpci -s <bdf> ECAP_AER+0x10.L=0xffffffff`. Precedent exists; per-DWORD `fork`/`exec`
  is far too slow and racy for a mailbox protocol, but it proves the access model.
- `src/nvme-pci-ids-linux.c:18-88` reads vendor/device IDs from sysfs. (Note: CLAUDE.md
  still places these under `plugins/micron/` — they now live in `src/`.)

---

## Part 3 — Windows

### MCTP on Windows: infeasible, not merely hard

There is **no MCTP anything** on Windows. Verified absences:

- No WDK header, no DDI page, no `mctp.sys`, no `IOCTL_MCTP_*`. Microsoft Learn returns zero
  results for "Management Component Transport Protocol". The only MCTP code in the
  `microsoft` GitHub org is the vendored Linux stack in `WSL2-Linux-Kernel`, and the shipped
  WSL2 config has `# CONFIG_MCTP is not set` (and WSL2 has no SMBus controller regardless).
  Windows' sanctioned in-band BMC path is **IPMI over KCS**, a different protocol family.
- `openbmc/libmctp` builds only serial / ASTLPC / I2C bindings, gates file I/O on POSIX
  `<poll.h>`, has zero `_WIN32` references, and **has no PCIe VDM binding at all**.
  `CodeConstruct/mctp` + `mctpd` are Linux/systemd/D-Bus only.
- **No SMBus/I2C host-controller path exists.** `IOCTL_SMB_*` on Windows is SMB/NetBT, not
  System Management Bus — there is no `smbus.h`, no host-controller DDI. SpbCx/SerCx is
  ACPI-gated and SoC-oriented ("the ACPI firmware enumerates the SPB-connected peripheral
  devices"); an x86 server's PCH SMBus function has no SpbCx driver and no ACPI-declared
  children. The only user-mode I2C path, **rhproxy**, "must be declared in your ACPI tables"
  and is IoT Core / Enterprise-only.
- **Nothing in the WDK emits Message TLPs**, so MCTP-over-PCIe-VDM has no Windows
  implementation path at any privilege level.

**Cost if pursued anyway:** a KMDF driver that takes the PCH SMBus PCI function away from the
inbox INF, implements DSP0237 framing plus DSP0236 transport/control, invents its own IOCTL
surface, contends with SMM and the BMC for the bus, and is EV-signed. Months of work,
per-platform fragility, and it still cannot reach a drive whose SMBus is wired to the BMC
(see Part 4). MCTP-over-VDM is not implementable at all.

### PCIe DOE on Windows: possible, but not shippable

DOE needs many **32-bit reads *and writes*** inside an Extended Capability at offset
`>= 0x100`, which mandates ECAM/MMCONFIG — legacy `0xCF8/0xCFC` cannot reach it.

| Mechanism | Mode | R/W | Reaches >= 0x100? |
| --- | --- | --- | --- |
| `BUS_INTERFACE_STANDARD` `GetBusData`/`SetBusData` | **kernel only** | R+W | Yes (`Offset` is `ULONG`, no documented cap) |
| `IRP_MN_READ_CONFIG` / `IRP_MN_WRITE_CONFIG` | **kernel only** | R+W | Yes |
| `DEVPKEY_PciDevice_*` (`pciprop.h`) | user | **read-only, derived** | N/A — link/payload/AER props only, **no DOE property** |
| SetupAPI / CfgMgr32 / WMI | user | read-only metadata | No raw config access |
| `IOCTL_STORAGE_QUERY_PROPERTY` | user | read-only | Storage properties only |
| any `IOCTL_PCI_*` to `pci.sys` | — | — | **Does not exist publicly** |

Microsoft's own page on accessing device configuration space enumerates exactly two ways and
both are driver-only. UMDF 2 is out — it lacks "Access to WDM objects and IRPs" and "Bus
enumeration". What real tools do:

- `pciutils` **`win32-cfgmgr32`** (the enumeration default) provides "only basic information
  and *emulated* config space"; its `write()` is literally `return 0;`.
- **`win32-sysdbg`** (`NtSystemDebugControl`) hard-caps at offset 255
  (`if (pos > 255 || pos+len > 256) return 0;`) — **cannot reach DOE.**
- **`win32-kldbg`** is the only working path: extract `kldbgdrv.sys` from an installed WinDbg,
  register it as a service, `DeviceIoControl(IOCTL_KLDBG)` → `SysDbgRead/WriteBusData` with
  `BusDataType = PCIConfiguration`, `Address` a `ULONG` with **no bounds check**, writes
  supported, MCFG parsed via `GetSystemFirmwareTable`. Its own README states the requirement:
  *"Process needs to have Debug privilege and Windows system has to be booted with Debugging
  option."* Microsoft warns that `bcdedit` changes "may need to temporarily suspend ...
  **BitLocker and Secure Boot**". `kldbgdrv.sys` is also a WinDbg component — redistributing
  it in an open-source CLI is a licensing problem, which is why pciutils extracts it at runtime.
- **RWEverything / WinRing0 / phymem are blocked.** Verified against the in-OS
  `driversipolicy.xml` for build **10.0.26100.1** (Server 2025 / Win11 24H2):
  `RwDrv.sys` and `HwRwDrv.sys` are denied at `MaximumFileVersion 65535.65535.65535.65535`,
  `WinRing0.sys` up to `2.0.0.0`, and `phymem.sys` / `phymemx64.sys` are explicit `Deny`
  rules. The vulnerable-driver blocklist is on by default since Windows 11 22H2.

**Two real options, both bad:** (a) own KMDF **filter driver** on the NVMe controller's device
stack that queries `BUS_INTERFACE_STANDARD` from `pci.sys` and does `Get/SetBusData` at
`>= 0x100` — EV-signed, attestation-signed, HVCI-clean, and a generic "read/write any PCI
config" IOCTL is precisely the "circumvents the Windows Security Model" pattern the blocklist
targets, i.e. you would be shipping the next `RwDrv.sys`; or (b) `kldbgdrv` on a debug-booted
lab machine with Secure Boot off — a developer-only mode, never a supported path.

*Unconfirmed:* whether the HAL's `PCIConfiguration` bus-data interface actually honors offsets
`>= 0x100` in practice (historically it is shaped around the 256-byte `PCI_COMMON_CONFIG`;
the pciutils code imposes no cap, but this was not verified on hardware). If it is capped,
even the `kldbg` route is dead. Also unconfirmed whether `pci.sys` silently drops
`SetBusData` writes to registers it manages.

### The in-band NVMe-MI tunnel on Windows: blocked outside WinPE

Proven both ways — by reading
[ioctl-win.c:2224-2232](libnvme/src/nvme/ioctl-win.c#L2224-L2232) and empirically on this host:
`nvme nvme-mi recv /dev/nvme0 --opcode=0 --nmimt=1 --data-len=32` → `nmi_recv: not supported`.

### What *does* work on Windows — and why the current failure is firmware, not the OS

`stornvme`'s documented command-set-support table lists Security Send (`81h`) and Security
Receive (`82h`) as **Supported**, via *"IOCTL_SCSI_PASS_THROUGH for
SCSIOP_SECURITY_PROTOCOL_OUT / _IN"*, and `stornvme` is "compliant to SCSI Translation
Reference Rev 1.5". **Nothing in any Microsoft document says the SECURITY PROTOCOL byte
(CDB[1]) is validated or whitelisted**, so SECP `0xE8` reaches the drive — which is exactly
consistent with the observed `Invalid Field in Command` coming from firmware.

By contrast `IOCTL_STORAGE_PROTOCOL_COMMAND` cannot carry Security Send/Receive: it is for
vendor-specific opcodes, and *"StorNVMe.sys and Storport.sys will block any command to a
device if it is not described in the Command Effects Log"*. There is no
`ProtocolTypeSecurity` — `STORAGE_PROTOCOL_TYPE` is only
`{Unknown, Scsi, Ata, Nvme, Sd, Ufs, Proprietary, MaxReserved}` — and
`STORAGE_PROTOCOL_NVME_DATA_TYPE` is only `{Identify, LogPage, Feature, LogPageEx, FeatureEx}`.
**Windows implements no SPDM anywhere** (zero hits across `windows-driver-docs`, `-pr`, and
`sdk-api`; Server 2025 "What's new" mentions none). Kernel DMA Protection is IOMMU-based with
no device identity; TPM/Pluton/DHA attest the *host*, not a peripheral.

The controller-handle-fails / namespace-handle-works asymmetry seen during hardware testing is
documented Storport behavior, verbatim: *"If a pass-through request is sent to an **adapter
device object** and if it originates from **user mode** and targets an LU that is **claimed by
a class driver**, Storport fails the request with **STATUS_INVALID_DEVICE_REQUEST**."*
The existing `get_ns_handle_from_ctrl()` fallback in
[ioctl-win.c](libnvme/src/nvme/ioctl-win.c) is exactly the right shape. (The
`STATUS_INVALID_DEVICE_REQUEST` → `ERROR_INVALID_FUNCTION` mapping is true in practice but is
not a documented contract.)

---

## Part 4 — Linux

### MCTP: the API is ready today; what varies is the platform

*(Summary here; **Part 7** is the in-depth treatment — MCTP routing and bridging, the platform
prerequisites P1-P11, the build cost, and why this is the fleet-grade transport.)*

| Component | Kernel | Note |
| --- | --- | --- |
| `CONFIG_MCTP` core + `AF_MCTP` | **v5.15** | corroborated in-tree by [mi-mctp-compat.h](libnvme/src/nvme/mi-mctp-compat.h) |
| `CONFIG_MCTP_SERIAL` (DSP0253) | v5.17 | |
| `CONFIG_MCTP_TRANSPORT_I2C` (SMBus/I2C, DSP0237) | v5.18 | |
| `CONFIG_MCTP_TRANSPORT_I3C` (DSP0233) | v6.7 | |
| `CONFIG_MCTP_TRANSPORT_USB` (DSP0283) | v6.15 | |
| **Gateway (bridged) routing** | **v6.17** | `ad39c12fcee3`, Jeremy Kerr — `RTM_GATEWAY` routes to a `(net, eid)`, recursive lookup. This is what lets a host address a drive behind the BMC (7.4) |
| **MCTP over PCIe VDM (DSP0238)** | **never merged** | `drivers/net/mctp/` = `{i2c, i3c, serial, usb}` only, at master and every tag |
| PCC (DSP0292), KCS, MMBI (DSP0284), UCIe | **never merged** | enum values in `include/net/mctp.h` with **zero drivers**; PCC is at v45 after 26 months |

**Message type `0x05` needs no kernel change.** `mctp_bind()` in `net/mctp/af_mctp.c` validates
only `sa_family`, the two padding fields, and `CAP_NET_BIND_SERVICE` (sending additionally requires
`CAP_NET_RAW`, unconditionally — `af_mctp.c:223`). There is no allowlist of
message types anywhere in the kernel; `smctp_type` on the socket address selects which single
type the socket receives. Our own [mi-mctp.c](libnvme/src/nvme/mi-mctp.c) already does
`socket(AF_MCTP, SOCK_DGRAM, 0)` with `MCTP_TYPE_NVME (0x04) | MCTP_TYPE_MIC (0x80)` — swapping
`0x04` → `0x05` and dropping the MIC is on the order of 20 lines. Endpoint discovery is also
already written: `mctpd`'s D-Bus `SupportedMessageTypes` byte array is what
`libnvme_mi_scan_mctp()` already parses looking for `0x04`.

**What it needs is a platform with an MCTP link — which is a deployment prerequisite, not a
blocker:**

- `CONFIG_MCTP_TRANSPORT_I2C` `depends on I2C && I2C_SLAVE` — the *host* adapter must implement
  I²C **target** mode, because MCTP/SMBus responses come back as block writes addressed to the
  requester. Commodity desktop chipsets do not do this (our probe host cannot), but it is a
  kernel-config-plus-board-design property, not a law of nature.
- MCTP is **routed**: a host does not need to sit on the drive's physical bus. It needs *a* link
  and a route to the drive's EID, with the BMC bridging. See 7.4.
- PCIe VDM has no mainline binding driver, and would additionally need a root complex that can
  source/sink MCTP VDMs with route-to-RC.

So an MCTP SPDM requester is a **feature for MCTP-capable server platforms** — the same platforms
on which nvme-cli's existing `mctp:` NVMe-MI transport already works in production. Our probe host
is not one of them. The drive's `MEC = 3` says both management endpoints exist, so the responder
side is in place. Part 7 works through the prerequisites and the build.

### PCIe DOE: one free probe, and one workable userspace path

**Free, zero-privilege discovery (kernel >= 6.15, `CONFIG_PCI_DOE=y`):**
`/sys/bus/pci/devices/<bdf>/doe_features/`. Per
`Documentation/ABI/testing/sysfs-bus-pci` (`Date: March 2025`), the directory contains
`doe_discovery` plus one file per `<VID>:<type>`, and the ABI doc spells out this exact case:
*"if CMA/SPDM and secure CMA/SPDM are supported the doe_features directory will look like
this: `0001:01  0001:02  doe_discovery`"* — PCI-SIG VID `0001`, type `01` = CMA-SPDM,
`02` = Secured CMA-SPDM. `pci_doe_init()` runs for every device at enumeration and performs a
DOE Discovery exchange, so this is a one-`ls` answer to "does this drive have an SPDM
responder behind DOE".

**There is no DOE transaction uAPI.** `drivers/pci/doe.c` exports only `pci_doe()` and
`pci_find_doe_mailbox()` as `EXPORT_SYMBOL_GPL`; no ioctl, char device, debugfs, or netlink.
And the native requester is **not merged**: no `drivers/pci/cma.c`, no `PCI_CMA` in
`drivers/pci/Kconfig`, no `lib/spdm*`, no `include/linux/spdm.h`, no SPDM `MAINTAINERS` entry.
In flight, all at state *New*: Lukas Wunner's "PCI device authentication" (v2, 18 patches,
Jun 2024), Alistair Francis' Rust **`rspdm`** series (v2, 21 patches, 2026-06-23, includes
`get_certificate` and a PCI TSM CMA driver), and Dan Williams' "device evidence over netlink"
(2026-07-05) — which is the eventual sanctioned way for userspace to pull a cert chain.
**Do not design against it yet.** `/sys/.../authenticated` and `tsm/connect` *are* merged but
only appear when a **platform TSM** (AMD SEV-TIO / Intel TDX Connect) accepts the device;
useless for a plain SSD on a normal host.

**Driving the mailbox from userspace works.** Register map from `include/uapi/linux/pci_regs.h`
(`PCI_EXT_CAP_ID_DOE 0x2E`):

```
+0x04 PCI_DOE_CAP      INT_SUP 0x1, INT_MSG_NUM 0xffe
+0x08 PCI_DOE_CTRL     ABORT 0x1, INT_EN 0x2, GO 0x80000000
+0x0c PCI_DOE_STATUS   BUSY 0x1, INT_STATUS 0x2, ERROR 0x4, DATA_OBJECT_READY 0x80000000
+0x10 PCI_DOE_WRITE    Write Data Mailbox
+0x14 PCI_DOE_READ     Read Data Mailbox        PCI_DOE_CAP_SIZEOF 0x18
```

Sequence: poll `!BUSY` → write the object as LE dwords to `+0x10` → set `GO` → poll
`DATA_OBJECT_READY` → read dwords from `+0x14`, writing anything back to `+0x14` after each
read to pop the FIFO. Through `/sys/bus/pci/devices/<bdf>/config`
(`BIN_ATTR(config, 0644, pci_read_config, pci_write_config, 0)`):

1. **Window is 4096 bytes** when the device has extended config space, with no special
   restriction on offsets `>= 0x100`.
2. **Reads past offset 64 need `CAP_SYS_ADMIN`** (`file_ns_capable(...)` in `pci_read_config()`).
3. **Writes are refused under kernel lockdown** — `pci_write_config()` begins with
   `security_locked_down(LOCKDOWN_PCI_ACCESS)`, which is the default on several distros under
   Secure Boot. Check `cat /sys/kernel/security/lockdown` first.
4. Width is right: the loop does `while (size > 3) { ... pci_user_write_config_dword(...) }`,
   so one aligned 4-byte `pwrite()` at an aligned offset is exactly one dword config write.

**Concurrency hazard, real and unguarded.** Nothing reserves the DOE block —
`pci_request_config_region_exclusive()`'s only in-tree caller is `arch/x86/kernel/amd_node.c` —
so our writes are permitted silently even though `drivers/pci/doe.c` keeps its own mutex and
ordered workqueue and knows nothing about us. For a plain NVMe SSD with no CXL and no platform
TSM the kernel touches the mailbox exactly once (Discovery at probe) and we win. That changes
the day CMA-SPDM/TSM lands and claims the device.

**vfio-pci is strictly worse.** Unbinding `nvme` makes the namespaces disappear (fatal for an
nvme-cli feature), it needs IOMMU + a whole claimable IOMMU group, and — decisively —
**vfio hides DOE**: `pci_ext_cap_length[]` in `drivers/vfio/pci/vfio_pci_config.c` has no entry
for `0x2E`, so `vfio_ecap_init()` takes the `if (!len)` branch, logs *"hiding ecap"*, and
rewrites the previous ecap's Next pointer to skip it. (A raw-window loophole probably survives
because the hidden path `continue`s before the `memset`, leaving those offsets mapped to
`unassigned_perms` raw pass-through — *reasoned from source, untested, and could be closed at
any time*.) **Use `/sys/.../config`.**

**Precedent:** WD's `spdm-utils` `--doe-pci-cfg` uses **pciutils' libpci**
(`pci_read_long`/`pci_write_long` at `doe_offset + {0x08,0x0c,0x10,0x14}`, popping the read FIFO
by writing `0xDEADBEEF`), and libpci's `PCI_ACCESS_AUTO` probes the sysfs backend first, whose
`sysfs_read`/`sysfs_write` are plain `pread`/`pwrite` on that same `config` file. **Not vfio,
not `/dev/mem`, and the `nvme` driver stays bound** — the drive remains a block device
throughout. Its constants match the kernel's exactly. (Wart to avoid copying: it re-runs
`pci_alloc`/`pci_scan_bus`/`pci_cleanup` on *every* send and receive.)

### The in-band NVMe-MI tunnel: ruled out on spec grounds, both platforms

This was my own hypothesis, prompted by `OACS` bit 6 and `MEC = 3`. **It is dead.** Checked
against the ratified NVMe-MI **2.1** and NVMe Base **2.3** PDFs (`pdftotext -layout`, searched):

- **Zero occurrences of the string "SPDM" in NVMe-MI 2.1. Zero in NVMe Base 2.3.**
- The NVMe-MI message header **pins MT (MCTP message type) to `4h`** (NVMe Management Messages
  over MCTP, DSP0235). There is no field able to carry message type `0x05`. The `| 4` in
  [nvme-mi-plugin.c:124](plugins/nvme-mi/nvme-mi-plugin.c#L124) is not a default that can be
  overridden — it is the only legal value.
- **NMIMT** enumerates only `0h`-`5h` (Control Primitive, NVMe-MI Command, NVMe Admin Command,
  reserved, PCIe Command, reserved/AE). There is **no "opaque payload" or "tunnel an arbitrary
  MCTP type" value.**
- There is **no NVMe-MI SPDM command set and no NVMe-MI Security command set.** The in-band
  tunnel (MI Send `1Dh` / MI Receive `1Eh`, NVMe Base Figure 28) tunnels *NVMe-MI* messages to
  the Management Endpoint — NMIMT-encoded payloads only. It is a transport for NVMe-MI, not a
  generic MCTP pipe.

So the in-band door reaches the drive's management endpoint but can only ask it NVMe-MI
questions. **Do not build this.** (It was also blocked on Windows outside WinPE, but that no
longer matters.)

Useful provenance that fell out of the same reading: **NVMe delegates SECP entirely to T10
SPC-5**, and NVMe's Security Personality bitmap enumerates only TCG, IEEE 1667 and
vendor-specific — never `E8h`. **DSP0286 §5.1 states that SPC-6 — not NVMe, not SPC-5 —
reserves `0xE8` for DMTF.** That is the complete provenance chain for the code point, and it
explains mechanically why firmware predating SPC-6/DSP0286 has no reason to list it.

---

## Part 5 — Spec and ecosystem

### The complete set of bindings, and which are host-reachable

DMTF PMCI/SPDM documents: **DSP0274** SPDM base; **DSP0275** SPDM over MCTP (message type
`0x05`); **DSP0276** Secured SPDM over MCTP (type `0x06`); **DSP0277** Secured Messages using
SPDM; **DSP0286** SPDM to Storage binding, v1.0.0, **published 2025-05-15**; **DSP0287** SPDM
over TCP; **DSP0289** SPDM Authorization; **DSP0293** vendor header registry. MCTP physical
bindings under DSP0236: DSP0237 SMBus/I²C, DSP0238 PCIe VDM, DSP0233 I3C, DSP0253 serial,
DSP0283 USB, DSP0284 MMBI, DSP0290 UCIe, DSP0292 PCC, DSP0256 MCTP host interface.

**Three are relevant for an SSD:** PCIe DOE carrying CMA/SPDM, DSP0286 over Security
Send/Receive, and **DSP0275 SPDM over MCTP**. The MCTP physical bindings differ in who owns the
bus segment the *drive* sits on — but because MCTP routes by EID, bus ownership determines what
the platform must provide, not whether a host can be the requester:

| Binding | Spec | Who owns the drive-side segment | Host requester story |
| --- | --- | --- | --- |
| MCTP over SMBus/I²C | DSP0237 | usually the **BMC** (SSD sideband pins on U.2/U.3/E1.S) | direct if the host adapter has I²C target mode and the segment is host-wired; otherwise **routed via the BMC** |
| MCTP over PCIe VDM | DSP0238 | BMC or a root-complex agent | no mainline Linux driver; would need RC support for host-sourced VDMs |
| MCTP over I3C | DSP0233 | BMC, or the host I3C controller on EDSFF designs | `mctp-i3c` since v6.7 — potentially direct |
| MCTP over serial / USB | DSP0253 / DSP0283 | n/a for the drive | practical **host ↔ BMC** links; the BMC then bridges |
| MCTP host interface | DSP0256 | n/a | host ↔ BMC link by design; the BMC bridges to the drive's EID |

The point Part 7.4 develops: a host ↔ BMC MCTP link plus an MCTP route is **not** "the BMC
proxies with a bespoke command" — it is ordinary DSP0236 bridging, which is what EIDs and routing
tables are for. The host addresses the drive's EID; the BMC forwards. That is a standard topology,
not a workaround.

For DOE, CMA = *Component Measurement and Authentication*, PCI-SIG's profile of SPDM. Object
types, quoted from QEMU `include/hw/pci/pcie_doe.h` (`/* PCI-SIG defined Data Object Types -
r6.0 Table 6-32 */`): `PCI_SIG_DOE_DISCOVERY 0x00`, `PCI_SIG_DOE_CMA 0x01`,
`PCI_SIG_DOE_SECURED_CMA 0x02`.

### Framing overhead differs by an order of magnitude

Relevant to buffer sizing in the new backend:

- **DOE: 8 bytes / 2 DWORDs** — `vendor_id` (u16), `data_obj_type` (u8), `reserved` (u8),
  `length` (u32, **counted in DWORDs**). Max object `1 << 18` DWORDs. Payload is DWORD-granular,
  which lines up with the existing dword rounding in
  [spdm_recv()](plugins/micron/micron-spdm.c#L403).
- **MCTP: 1 byte** of message header (the type byte) atop a 4-byte MCTP transport header the
  stack owns, plus per-binding fragmentation — the SMBus/I²C baseline MTU is small, so one SPDM
  message becomes many fragments.
- **Storage (DSP0286): a 4-byte SPDM Storage Response Header** — `DataLength[15:0]` +
  `StorageBindingVersion` (`0x1000`) — on Discovery and Pending Info responses. See the
  conformance section below: this is *not* the same thing as the unconditional length prefix the
  current code sends on all traffic.

### OCP mandates the transports we do *not* have — this reframes the whole problem

Quoted requirement IDs from OCP Datacenter NVMe SSD Specification v2.7 §12.3:

- **SPDM-1**: *"shall comply with the Security Protocol and Data Model (SPDM) Specification,
  Version 1.4 or later"*, backwards compatible with *"Version 1.1 and later"*
- **SPDM-3**: shall support SPDM-1/SPDM-2 **via MCTP over SMBus/I2C**
- **SPDM-4**: shall support SPDM-1/SPDM-2 **via MCTP over PCIe VDM**
- **SPDM-5**: shall support SPDM-1/SPDM-2 **via PCI-SIG Data Object Exchange (DOE) Revision 1.1**
- **SPDM-21**: shall support SPDM-1/SPDM-2 **via MCTP over I3C**
- **SPDM-14**: `DataTransferSize` >= 4 KiB. **SPDM-15**: DIGESTS / CERTIFICATE /
  CHALLENGE_AUTH / MEASUREMENTS / KEY_EXCHANGE_RSP required; CSR and SET_CERTIFICATE_RSP
  recommended. **SPDM-20**: >= 2 SPDM banks including a CNSA 2.0 / ML-DSA-87 chain.
- **DSP0286, NVMe Security Send/Receive, and protocol `0xE8` appear nowhere** in SPDM-1..21 or
  CERT-1..6.

*Sourcing caveat: `opencompute.org` returns 402/403 to automated fetch, so these were read from
a verbatim gap-analysis quote of §12.3 (chipsalliance/caliptra-mcu-sw issue 1629), not from the
PDF. The version that first introduced SPDM is not pinned; v2.5 is circumstantially the
"security" release. **Verify §12.3 against the PDF before quoting it externally.***

The implication is the single most useful conclusion in this document: **a compliant
datacenter SSD is required to have an SPDM responder on MCTP and on DOE, and is *not* required
to have one on Security Send/Receive.** So the drive's empty `0xE8` is not evidence that the
drive lacks SPDM — Micron in fact markets "SPDM 1.2 attestation" on the 7500 — it is evidence
that we were knocking on the one door the spec never asked the vendor to open. Part 1b confirms
this empirically: the responder is there, behind DOE.

**The timeline explains the gap cleanly, and removes any suggestion of a firmware defect:**
**DSP0286 was published 2025-05-15**; OCP v2.7 is October 2025. The storage binding is *younger
than the shipping firmware on this drive* and younger than the requirement documents that drove
that firmware. The observed `{0x00, 0x01, 0x02, 0xEE}` list — TCG Storage plus IEEE 1667, no
DMTF code point — is exactly what firmware built against OCP requirements should look like.

### The responders live in different silicon, so absence on one says nothing about the others

| Transport | Responder lives in | Addressed by |
| --- | --- | --- |
| DSP0286 storage | the **NVM Express controller's main firmware** | Security Send/Receive, `SECP = E8h` |
| PCIe CMA-SPDM | the **DSM** in the PCIe function (PCIe logic / microcode) | DOE object VID `0x0001`, type `0x01` / `0x02`; the kernel ABI notes "A DSM is always physical function 0" |
| SPDM over MCTP (type `0x05`) | the **out-of-band management endpoint** — the same one answering NVMe-MI on type `0x04`, usually a separate management microcontroller and firmware image | MCTP EID on SMBus/I²C and/or PCIe VDM |

The specs make this concrete through **incompatible reset and power lifecycles**, which is the
strongest available evidence that these are genuinely distinct endpoints:

- **DSP0286** maps the SPDM responder to the **Controller**, and specifies that a Controller
  Reset or Subsystem Reset **is** an SPDM device reset (sessions torn down). Its lifetime is the
  controller's lifetime — consistent with an implementation in the main NVMe firmware, reachable
  only while the controller is enabled and admin commands flow.
- **OCP requires the opposite of the sideband endpoint**: **PCI-29 / PCI-30 / PCI-41** require
  the MCTP/SPDM endpoint to stay functional in **D3hot** and to survive **non-fundamental
  resets**, on **Function 0** only. A responder that must answer in D3hot cannot be the
  controller's admin-command path.

*(That partitioning is inferred from spec-mandated reset/power behavior, not from any vendor
disclosure.)* Corroboration that vendors ship one and not all: `spdm-utils` — written by the same
people driving the kernel SPDM work — makes storage / DOE / MCTP / TCP mutually independent Cargo
features, and `libspdm` ships four independent transport libraries, precisely because real
devices implement only some. Part 1b is a live instance: this drive has the DOE responder and
not the storage one.

### Tooling landscape

- **`spdm-utils`** (Western Digital) — *"an open source **Linux application**"*, first line of
  its README. Transports: `nvme.rs` (libnvme `nvme_security_send`/`_receive`), `scsi.rs`,
  `doe_pci_cfg.rs` (libpci), `usb_i2c.rs` (MCTP over a UART→USB-I2C bridge — note it does
  **not** use `AF_MCTP`), `tcp_*`, `qemu_server.rs`. `SpcSecurityProtocols::DmtfSpdm => 0xE8`
  and DSP0286 ops `Discovery 0x01 / PendingInfo 0x02 / Message 0x05 / SecMessage 0x06` match
  our constants. **No Windows support**; hard deps on `nix`, libpci, libnvme, libsystemd.
- **`DMTF/libspdm`** ships `spdm_transport_{mctp,pcidoe,storage,tcp}_lib`. Transports are pure
  encode/decode — the integrator registers `spdm_device_send_message` /
  `spdm_device_receive_message`. It ships no driver, no ioctl, no config-space code. **It does
  build with MSVC** (VS2015/2019/2022 in CI) — but that only gets you correctly framed bytes
  with nowhere to send them. `spdm-emu`'s `--trans PCI_DOE` means "DOE-framed bytes over
  127.0.0.1:2323", not a mailbox, and it has no storage/DSP0286 `--trans` at all.
- **QEMU** mainline `hw/nvme/ctrl.c` implements the *responder* side of exactly our binding
  (`nvme_sec_prot_spdm_send/receive`, `NVME_SEC_PROT_DMTF_SPDM`, `StorageSpdmTransportHeader`,
  forwarded to an external responder over a socket) with `spdm_trans=nvme|doe`. Combined with
  WD's `qemu-spdm-emulation-guide`, this is a viable **software test bed for either transport**
  without hardware.
- **Upstream `nvme-cli` / `libnvme` have zero SPDM references**, and `patchwork` shows zero
  SPDM patches for `linux-nvme`. This branch would be the first SPDM support in nvme-cli, and
  the first on Windows anywhere found.
- **Commercial:** SANBlaze advertises "SPDM 1.4 ... across NVMe and PCIe environments" and OCP
  2.5/2.6 suites, built on `DMTF/SPDM-Responder-Validator`; it is a Linux test appliance.
  Teledyne LeCroy/OakGate's OCP 2.5 material does not mention SPDM. No public vendor host tool
  (Micron, Solidigm, Samsung Magician, Kioxia) exposes SPDM cert retrieval.
- **Nobody performs a PCIe DOE transaction from Windows userspace, for any purpose** — not
  SPDM, not CXL CDAT, not IDE_KM. That is an absence of evidence rather than proof, but the
  search was thorough.

---

## Part 6 — Constraints on the DOE transport (consolidated — read before committing)

The responder exists and the mailbox is reachable, but the userspace-DOE approach carries real
limitations. They are gathered here rather than scattered through Parts 3-5 so the cost is
visible in one place.

### C1. Linux only, structurally

Windows has **no user-mode path to PCI config space at all**, let alone a writable one at offset
`>= 0x100` (Part 3). The two kernel-mode mechanisms that can do it are driver-only; the only
already-signed shortcut (`kldbgdrv.sys`) needs a debug-booted machine with Secure Boot suspended
and is not redistributable. This is not a gap that closes with effort — it closes only by
shipping and maintaining an EV-signed kernel driver whose IOCTL is, by construction, the pattern
Microsoft's vulnerable-driver blocklist targets.

### C2. Requires root (`CAP_SYS_ADMIN`)

`pci_read_config()` truncates to 64 bytes without `CAP_SYS_ADMIN`, so even *finding* the
capability by walking the ecap chain needs privilege — as does every mailbox access. Contrast the
storage binding, which needs nothing beyond permission to open `/dev/nvme0`.

### C3. Kernel lockdown in integrity mode blocks it outright — the fleet-use blocker

`pci_write_config()` begins with `security_locked_down(LOCKDOWN_PCI_ACCESS)`, and
`LOCKDOWN_PCI_ACCESS` sits below `LOCKDOWN_INTEGRITY_MAX`, so **integrity mode is sufficient to
refuse every mailbox write**. Specifics that matter operationally:

- **Lockdown is one-way at runtime.** The LSM permits raising the level only; there is no
  runtime escape and therefore no way to avoid a reboot.
- **`lockdown=none` on the kernel command line is not reliably enough.** It sets the *initial*
  level, but distro kernels (Ubuntu, RHEL and derivatives) raise it to integrity when Secure Boot
  is enabled and the cmdline does not override that. **Disabling Secure Boot in firmware is the
  dependable lever.** Also check `grep LOCK_DOWN /boot/config-$(uname -r)`: if
  `CONFIG_LOCK_DOWN_KERNEL_FORCE_INTEGRITY=y`, it is unconditional and no boot option helps.
- **The probe host is in `[integrity]` today** (Part 1b), so this is the first thing anyone
  hits, not a theoretical edge case. **Measured, the cause is unambiguous and the fix is cheap:**
  that kernel has `CONFIG_LOCK_DOWN_IN_SECURE_BOOT=y` *and*
  `CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE=y` — i.e. the compiled-in default is `none` and integrity is
  being imposed **solely** because Secure Boot is on, which the `SecureBoot` efivar confirms
  (`06 00 00 00 01`). Because it is `FORCE_NONE` rather than `FORCE_INTEGRITY`, **turning Secure
  Boot off in firmware will drop lockdown to `[none]` — no custom kernel, no cmdline argument, no
  rebuild.** That is the one environmental action Step 0 leaves outstanding, and it is a BIOS
  setting.
- **No other userspace route sidesteps it.** `setpci` and libpci use the same sysfs syscall path;
  `/dev/mem` is blocked by `LOCKDOWN_DEV_MEM`; port I/O by `LOCKDOWN_IOPORT` and cannot reach
  offset `>= 0x100` regardless. vfio-pci's config path may not hit the same check — unverified —
  but it is moot, because vfio hides the DOE ecap and unbinding `nvme` destroys the namespaces the
  plugin operates on.
- **Reads survive lockdown.** `doe_features/` and `lspci` still work, so the tool can always
  report *"a CMA-SPDM responder is present but this kernel's lockdown setting forbids driving the
  mailbox"* instead of failing opaquely. That distinction is the difference between a usable
  diagnostic and a support ticket.

**Consequence for the stated goal of fleet use:** on hardened production hosts running Secure
Boot, this transport will not function. It is fully usable for lab, qualification and
failure-analysis work. Anyone planning fleet attestation should read C3 as disqualifying and see
Part 7.

### C4. We would be driving hardware the kernel also owns, with no arbitration

Nothing reserves the DOE register block: the only in-tree caller of
`pci_request_config_region_exclusive()` is `arch/x86/kernel/amd_node.c`. So our writes are
permitted silently even though `drivers/pci/doe.c` maintains its own mutex and ordered workqueue
and knows nothing about us. Today this is safe for a plain NVMe SSD — the kernel performs DOE
Discovery once at enumeration and then never touches the mailbox — and the observed
`DOESta: Busy- Error- ObjectReady-` confirms it is idle. It stops being safe when a platform TSM
or the in-kernel CMA-SPDM requester claims the device, or on a CXL device whose CDAT path uses
`pci_doe()`. **Guard for it:** refuse to run if `tsm/` exists on the device — measured absent on
the probe host, so the precondition is satisfiable — and check `DOESta` at entry.

**But check `DOESta` by masking, not by comparing against zero.** This is a correction to the
obvious implementation, forced by measurement: the raw register on this drive reads
**`0x00000010`**, i.e. **bit 4 is set** even though the mailbox is completely idle. `pci_regs.h`
defines only `BUSY 0x1`, `INT_STATUS 0x2`, `ERROR 0x4` and `DATA_OBJECT_READY 0x80000000`; bit 4
is not among them, and `lspci` decodes every bit it knows about as clear
(`Busy- IntSta- Error- ObjectReady-`). It is presumably a DOE r1.1 addition postdating the
kernel's header. `DOE_CAP` shows the same pattern — `0x00001001`, with an undefined bit 12 set
alongside `INT_SUP`. Consequence: a naive `if (status)` or `if (status != 0) → busy` entry check
**would reject this exact drive on every invocation**, and the failure would look like "another
process owns the mailbox" when nothing does. Test `status & (PCI_DOE_STATUS_BUSY |
PCI_DOE_STATUS_ERROR | PCI_DOE_STATUS_DATA_OBJECT_READY)` and ignore everything else. The same
discipline applies to `DOE_CAP`: read `INT_SUP` and `INT_MSG_NUM` by mask and do not assume the
rest of the register is reserved-zero.

### C5. Concurrency between our own invocations is unguarded too

Two simultaneous `vs-spdm-cert --transport=doe` runs against the same drive would interleave
mailbox transactions and corrupt each other, and neither the kernel nor the hardware will stop
them. The mailbox is a single shared resource with no ownership semantics. Take an `flock` on the
`config` file (or a lock file keyed by BDF) for the duration of the handshake, and document that
the command is not concurrency-safe with other tools that drive the same mailbox — `spdm-utils
--doe-pci-cfg` being the obvious one.

### C6. Crash recovery is our problem

If the process dies between setting `GO` and draining the read mailbox, the mailbox is left
mid-transaction and the next run finds `Busy` or a stale `ObjectReady`. The recovery path is the
DOE `ABORT` bit, and it must be implemented deliberately: assert `ABORT`, wait for `Busy` to
clear, then proceed. Without it, one interrupted run makes the feature look permanently broken.

### C7. No stable interface — this is explicitly a stopgap

There is no DOE transaction uAPI; `pci_doe()` and `pci_find_doe_mailbox()` are
`EXPORT_SYMBOL_GPL` in-kernel only. The sanctioned userspace interface is expected to be Dan
Williams' netlink "device evidence" work, and the requester is expected to be Lukas Wunner's
CMA/SPDM series or Alistair Francis' Rust `rspdm` — **none merged**. When one lands, the kernel
will claim the mailbox and this backend becomes actively wrong, not merely redundant. That is an
argument for the vtable in Step 1, not against the plan: the SPDM logic, parsing, digest checks
and output formatting are all reusable, and only the ~200-line transport backend gets replaced.

### C8. Version and feature preconditions

- The free `doe_features/` probe needs kernel **>= 6.15** with `CONFIG_PCI_DOE=y`. The ecap walk
  works on any kernel, so the backend must not depend on the sysfs directory existing.
- `0001:02` (Secured CMA-SPDM) is **absent** on this drive, so no session-based SPDM operation
  will ever be possible over this path — only the sessionless GET_DIGESTS / GET_CERTIFICATE flow
  `vs-spdm-cert` already performs. Fine today; a hard ceiling on future measurement or
  KEY_EXCHANGE work.

---

## Part 7 — MCTP in depth: yes, and it is the fleet-grade answer

**Short answer: yes.** SPDM over MCTP is implementable in nvme-cli, it is small, it needs no
kernel change, and on an MCTP-capable server it is a *better* transport than DOE for the stated
fleet goal. nvme-cli already ships a working MCTP transport for NVMe-MI; SPDM is the same socket
with one different constant and less framing.

The catch is a **platform prerequisite, not a design problem**: the host needs an MCTP link and a
route to the drive's endpoint. Servers built for out-of-band management provide that; the
workstation on loan for this investigation does not, so it can validate DOE but not MCTP. Sections
7.3-7.5 separate those two things carefully — what the loaner proves, what it doesn't, and what a
validation platform must supply.

### 7.1 What a BMC is, and why it owns this bus

A **BMC** (Baseboard Management Controller) is a small always-on ARM SoC soldered to the
server's motherboard — typically an ASPEED AST2500/2600 running OpenBMC or a vendor stack — with
its own CPU, RAM, flash, firmware and NIC. It is a *separate computer* inside the chassis. It
powers on before the host CPU, stays up when the host is off, and exists to manage the machine
out-of-band: power control, fan/thermal, sensors, firmware update, serial-over-LAN, KVM, and
Redfish/IPMI over its own management NIC. That is what "out-of-band" means — a path to the
hardware that does not traverse the host OS and does not care whether the host is even booted.

The BMC is the bus master for the platform's management interconnects: the SMBus/I²C sideband
segments, and (where implemented) MCTP over PCIe VDM. On a U.2/U.3/EDSFF drive bay, the
**SFF-8639 SMClk/SMDat sideband pins route to the BMC**, not to the host CPU's SMBus controller.
That single wiring fact is the whole of the MCTP problem: the drive's management endpoint is
listening on a bus the host is not connected to.

This matters for us in two opposite directions. It is why the drive's sideband SPDM responder is
*there and always powered* — the property that makes MCTP the fleet-grade transport (7.7). And it
is why the requester needs either a host-wired management bus or a route through the BMC (7.4).

### 7.2 What actually differs between MI-over-MCTP and SPDM-over-MCTP

You asked what lets one work and keeps the other from working. The honest answer is: **nothing
protocol-level does.** They are siblings, and the differences are trivial:

| | NVMe-MI over MCTP | SPDM over MCTP |
| --- | --- | --- |
| Spec | DSP0235 | **DSP0275** (and DSP0276 for the secured variant) |
| MCTP message type | `0x04` | **`0x05`** (`0x06` secured) |
| Where the type byte lives in Linux | `smctp_type` on `struct sockaddr_mctp` — **socket address, not payload** ([mi-mctp.c:115](libnvme/src/nvme/mi-mctp.c#L115), [:124](libnvme/src/nvme/mi-mctp.c#L124), [:442](libnvme/src/nvme/mi-mctp.c#L442)) | identical mechanism, one different constant |
| Framing above MCTP | NVMe-MI Message Header + 4-byte MIC (`MCTP_TYPE_MIC 0x80` OR'd in) | bare SPDM message, **no MIC** |
| Kernel support needed | `CONFIG_MCTP` + a binding driver | **exactly the same** |
| Endpoint addressed | the drive's out-of-band Management Endpoint | **the same endpoint**, different message type |
| Responder silicon | management microcontroller | **the same** management microcontroller |

The kernel imposes no allowlist on message types: `mctp_bind()` in `net/mctp/af_mctp.c`
validates `sa_family`, the two padding fields and `CAP_NET_BIND_SERVICE`, and nothing else — and
`mctp_sendmsg()` checks only `CAP_NET_RAW`, never the message type. So
`0x05` needs **no kernel change whatsoever**. Swapping `MCTP_TYPE_NVME (0x04)` for `0x05` and
dropping the `| MCTP_TYPE_MIC` and the MIC computation is on the order of 20 lines against
[mi-mctp.c](libnvme/src/nvme/mi-mctp.c).

**So my earlier framing was wrong, and this is the correction:** it is not that MI-over-MCTP
works and SPDM-over-MCTP wouldn't. Both address the same endpoint over the same link, and
**both need an MCTP link to exist.** SPDM-over-MCTP in nvme-cli is precisely as feasible as the
MI-over-MCTP that already ships — which is to say, feasible wherever there is a link, and
useless where there is not.

### 7.3 What the loaner host proves, and what it does not

Run against the `mi = enabled` build at `~/bgoing/nvme-cli/.build` (`v3.0-rc1-154-g67055fb`):

```
$ nvme id-ctrl mctp:1,8
Failure sending MCTP message: Permission denied
identify controller: Operation not permitted

$ sudo nvme id-ctrl mctp:1,8
Failure sending MCTP message: No route to host
identify controller: Operation not permitted
```

This is **good news read correctly**, and it is worth being precise about what each layer says:

- The `mctp:` device name **parsed**, the transport **dispatched**, `socket(AF_MCTP, ...)`
  **succeeded**, and `bind()` **succeeded** — the code would have reported a different error
  otherwise. The kernel's MCTP core is present and functional (`CONFIG_MCTP=y`). **The entire
  software stack above the link works.**
- Unprivileged, the failure is `EACCES`; with root it becomes **`EHOSTUNREACH` — "No route to
  host."** `EHOSTUNREACH` is a *routing* verdict, the last thing that fails. There is no route
  because there is no MCTP interface: `mctp link show` returns only `lo`, `mctp route show` and
  `mctp addr show` are empty, `lsmod | grep mctp` shows nothing loaded, `mctpd` is not installed,
  and there is no `/sys/class/mctp`.
- **What this does *not* show is that the transport is unusable.** It shows that this particular
  machine is an unsupported platform for it. nvme-cli's `mctp:` transport works in production on
  MCTP-capable servers; the loaner is a workstation with no BMC (no `/dev/ipmi*`, no
  `ipmi_si`/`ipmi_devintf`/`aspeed` modules, an AMDGPU on the bus). The correct conclusion is
  "get the right validation platform", not "don't build it".
- The negative it establishes is narrower than I first wrote, and the correction matters.
  Measured: `CONFIG_I2C_DESIGNWARE_SLAVE` is unset and `/proc/kallsyms` contains zero
  `i2c_dw_*_slave` or `piix4*slave` symbols — only the core
  `i2c_slave_register`/`i2c_slave_unregister` exports, with no adapter driver implementing
  `reg_slave`. So **on this host** no adapter can act as an I²C target, and `mctp-i2c` has nothing
  to bind to. But `CONFIG_I2C_DESIGNWARE_SLAVE` **no longer exists upstream** — it was removed in
  `9f65f8fa18bb` (2025-12-18, Heikki Krogerus, *"i2c: designware: Remove useless driver specific
  option for I2C target"*), folded into plain `CONFIG_I2C_SLAVE`. So that measurement describes
  this box's kernel vintage, **not** the state of DesignWare support. See 7.4a: DesignWare now
  implements both directions, explicitly for MCTP. What survives as a general truth is only that
  **PCH SMBus cannot** — `i2c-i801`'s algorithm is `{ .smbus_xfer, .functionality }` with no
  `.master_xfer` and no `.reg_slave` at all, and `i2c-piix4` / `i2c-ismt` are likewise
  target-incapable (`i2c-ismt`'s own feature table says *"Slave mode  no"*).

### 7.4 How a host reaches the drive's endpoint: MCTP is routed

The mistake in my earlier analysis was treating MCTP as if the requester had to sit on the
responder's physical bus. It does not. **MCTP is a routed protocol.** DSP0236 defines Endpoint IDs,
routing tables and **bridges**, precisely so that endpoints on different physical media can talk.
Linux implements this in `net/mctp/route.c` with a netlink route table, exposed by the
`mctp route add <eid> via <dev>` CLI — the same shape as IP routing.

**And bridged routing is not merely spec-defined, it is mainline as of Linux 6.17.** Commit
`ad39c12fcee3` (Jeremy Kerr, Code Construct, 2025-07-02, *"net: mctp: add gateway routing
support"*, merged via net-next `8be4d31cb8aa`) added `RTM_GATEWAY` route entries that reference a
routable `(network, EID)` instead of a netdevice, making route lookup **recursive** with a
depth limit of 32 (`route.c:976-1020`). The split is correct MCTP bridge behaviour: the on-wire
`hdr->dest` stays the **final** EID while the neighbour lookup uses the resolved gateway
(`route.c:648`, `:906`, `:1178`). **From the socket API a bridged endpoint is indistinguishable
from a link-local one** — you `sendto()` the drive's EID and the kernel resolves the next hop; no
neighbour entry for the drive's EID is needed, and the requester never learns the topology.

The CLI (`CodeConstruct/mctp` `src/mctp.c:1129-1137`) exposes both forms, and note `rtm_dst_len`
carries an **EID range extent** rather than a prefix length, so routes natively cover bridge pools:

```sh
mctp route add <eid>[-<eid>] via <ifname> [mtu <mtu>]
mctp route add <eid>[-<eid>] gw <eid> [net <net>] [mtu <mtu>]
```

A worked example — BMC on `mctpi2c1`, net 1, host EID 8; bridge at i2c `0x1d` with EID 9 and pool
10-13; SPDM target EID 11:

```sh
mctp link set mctpi2c1 up network 1
mctp address add 8 dev mctpi2c1     # mandatory: gateway routes fail without a local source EID
mctp neigh add 9 dev mctpi2c1 lladdr 0x1d
mctp route add 9 via mctpi2c1
mctp route add 10-13 gw 9 net 1
```

That `mctp address add` is not optional — `route.c:1003-1005` breaks out of the recursive lookup if
the outbound device has no local EID, so a gateway route silently fails to resolve without it.
**Nothing in the kernel or in `mctpd` gates routing by message type**: `struct mctp_route`,
`mctp_dst` and `mctp_neigh` have no type field, and `mctp_local_output`/`mctp_dst_output` never
inspect the payload. Type only matters for per-socket receive demux (`mctp_lookup_bind`,
`route.c:81-124`). **Type `0x05` routes exactly as `0x04` does.**

So there are two topologies that work, and only the first requires the drive's sideband to be
host-wired:

1. **Direct.** The host owns the management bus segment the drive is on and speaks the binding
   itself — `mctp-i2c` with a target-capable adapter, or `mctp-i3c` on an EDSFF design where the
   host has the I3C controller. One hop, no BMC involvement.
2. **Bridged via the BMC.** The host has *any* MCTP link to the BMC (serial, USB, I3C, or a
   platform host interface), and a route to the drive's EID pointing at that link. The BMC
   forwards. This is **ordinary DSP0236 bridging, not a bespoke proxy** — the host addresses the
   drive's EID and the fabric does the rest. My earlier claim that it "requires a BMC-side proxy
   that neither the spec nor OpenBMC defines" was wrong: bridging is exactly what the spec
   defines, and it is what `mctp route` exists to configure.

Either way, `nvme micron vs-spdm-cert mctp:<net>,<eid> --transport=mctp` is the same command, and
nothing above the socket changes. This is also why the existing `mctp:<net>,<eid>[:ctrl-id]` device
syntax ([mi.c:48-64](libnvme/src/nvme/mi.c#L48-L64)) already has the right shape — it names a
network and an EID, not a bus and an address.

### 7.4a Which link the host actually gets — now answered, and it is the real constraint

This was the open question. It has been researched against kernel source, patchwork and shipped
distro configs, and the answer is more encouraging than expected in one place and worse in another.

| Binding | Kernel | Host-usable? | What the platform must provide | Reaches a drive? |
| --- | --- | --- | --- | --- |
| `mctp-i2c` (DSP0237) | v5.18 | **Yes** | an adapter with **both** `.xfer` and `.reg_slave` — DesignWare or AMD ASF — plus `CONFIG_I2C_SLAVE=y` | **Yes** — the binding NVMe-MI mandates |
| `mctp-i3c` (DSP0233) | v6.7 | role is right (Linux is **controller**), but **devicetree-only** | `mctp-controller` DT property; ACPI platforms cannot bind | no (not in NVMe-MI 1.2c) |
| `mctp-usb` (DSP0283) | v6.15 | yes (USB **host** side) | a device with USB interface class `0x14` | no — peer is a BMC |
| `mctp-serial` (DSP0253) | v5.17 | yes (`N_MCTP` line discipline, any tty) | a UART to the peer | no — peer is a BMC |
| PCC (DSP0292) | **unmerged** | would be genuinely host-side | ACPI PCCT channels | via the BMC |
| KCS, MMBI (DSP0284), UCIe | **unmerged** | — | — | — |
| PCIe VDM (DSP0238) | **unmerged** | — | — | — |

**The good news: DesignWare I²C gained target mode, explicitly for MCTP.** Commit `cfbcc20d5c02`
(2026-01-20, Heikki Krogerus, Intel, *"i2c: designware: Enable mode swapping"*) says it outright:
*"The DesignWare I2C can now be used with protocols such as MCTP (drivers/net/mctp/mctp-i2c.c) and
IPMI (drivers/char/ipmi/) that require support for both I2C master and I2C slave."* The unified
`i2c_dw_algo` now carries `.reg_slave`/`.unreg_slave` under `CONFIG_I2C_SLAVE`. DesignWare ACPI HIDs
cover Intel (`INT33C2/C3`, `INT3432/3433`, `INTC10EF`), AMD (`AMD0010`, `AMDI0010/0019/0510`),
Ampere lineage (`APMC0D0F`) and HiSilicon/Kunpeng arm64 servers (`HISI02A1`-`A3`). Separately,
`I2C_AMD_ASF` is the only driver in Kconfig's *"PC SMBus host controller drivers"* section that
`select I2C_SLAVE`, with help text naming *"MCTP over ASF"*. One caveat:
`i2c_dw_configure_slave()` bails on `ACCESS_POLLING` instances, which then get no
`I2C_FUNC_SLAVE`.

**The bad news, and it is the actual limiting factor: the drive's sideband terminates on the BMC.**
Every platform document reachable puts U.2 `E23`/`E24` and EDSFF `A7`/`A8` on the BMC domain —
directly or through a mux/CPLD/bridge IC the BMC owns. OpenBMC devicetree confirms the pattern from
the other side: Meta Yosemite 4 (`aspeed-bmc-facebook-yosemite4.dts`) puts `mctp-controller` and
`mctp@10` on the **BMC's** AST2600 i2c3/i2c4 — `0x10` being the standard MCTP-over-SMBus BMC
address — with no analogous binding on the x86 side. **No host-CPU-to-drive-sideband platform was
confirmed from public sources.** So even with a target-capable host adapter, the realistic topology
on a standard server is host ↔ BMC ↔ drive, bridged — which is exactly what 7.4's gateway routing
is for.

**Calibration on the unmerged bindings, worth internalising before betting on any of them:**
MCTP-over-PCC (Adam Young, Ampere — the one genuinely *host-side* binding in flight) is at
**v45, posted 2026-07-21, state `changes-requested`, first posted 2024-05-13** — 26 months and 45
revisions, still unmerged, and now a 7-patch series where 4 patches are prerequisite fixes to
`drivers/mailbox/pcc.c`. MCTP-over-KCS died at v5 in October 2023 and was a **BMC-side** driver
anyway (it registers as a client of the kernel's KCS *BMC* layer, `kcs_bmc_mctp_add_device`), so it
would not have helped a host even if merged. `MCTP_PHYS_BINDING_MMBI`/`_PCC`/`_KCS`/`_UCIe` exist in
`include/net/mctp.h` as **enum values with zero drivers behind them**. `openbmc/libmctp`'s
`astlpc.c` is an IBM/ASPEED vendor binding, userspace-only, with no AF_MCTP integration. **Assume
multi-year for anything that needs a new upstream binding — do not put one on this plan's critical
path.**

### 7.5 Platform prerequisites, and how the tool should report them

MCTP support is a property of the platform, so the tool's job is to check each prerequisite and
say precisely which one is missing. Every one of these is cheaply detectable, which turns "it
doesn't work" into "this host lacks X":

| | Prerequisite | How to detect | Message when absent |
| --- | --- | --- | --- |
| **P1** | Kernel MCTP core | `socket(AF_MCTP, SOCK_DGRAM, 0)` → `EAFNOSUPPORT` | "kernel lacks CONFIG_MCTP (absent entirely on RHEL 10, Debian trixie/sid, Amazon Linux 2023)" |
| **P2** | A binding driver loaded, link up | RTM_GETLINK for `ARPHRD_MCTP`; only `lo` | "no MCTP link. For SMBus need `CONFIG_MCTP_TRANSPORT_I2C` + `CONFIG_I2C_SLAVE`" |
| **P3** | Adapter with I²C target mode *(direct topology only)* | `I2C_FUNC_SLAVE` in the adapter's functionality mask; `i2c_slave_register` → `-EOPNOTSUPP` | "adapter lacks I²C target mode; PCH SMBus (`i2c-i801`) cannot, DesignWare and AMD ASF can — or use a bridged topology" |
| **P4** | A local source EID on the outbound link | RTM_GETADDR on the link; empty | "`mctp address add <eid> dev <link>` — **required**; gateway routes fail without a source EID" |
| **P5** | A route to the target EID | `sendmsg` → `EHOSTUNREACH` | "no route to EID *n*. Direct: `mctp route add n via <link>`. Bridged: `mctp route add n gw <bridge-eid> net <net>`" |
| **P6** | Neighbour entry for the next hop | RTM_GETNEIGH; send fails at device output | "`mctp neigh add <next-hop-eid> dev <link> lladdr <addr>`" |
| **P7** | Privilege — **`CAP_NET_RAW`, not just bind** | `sendmsg` → `EACCES` | "MCTP send requires `CAP_NET_RAW`; `bind()` requires `CAP_NET_BIND_SERVICE`; setup needs `CAP_NET_ADMIN`" |
| **P8** | `mctpd` running *(optional but recommended)* | D-Bus `NameHasOwner("au.com.codeconstruct.MCTP1")` | "mctpd not running, and it is **unpackaged in every major distro** — build from `github.com/CodeConstruct/mctp`, or supply net/EID manually" |
| **P9** | Endpoint advertises type `0x05` | `SupportedMessageTypes` on the endpoint object, **or** MCTP control cmd `0x05` (Get Message Type Support) issued directly | "endpoint *n* does not advertise SPDM (0x05); reported types: 0x04 — firmware conversation, not a bug" |
| **P10** | Responder actually answers | `poll()` timeout on the first `GET_VERSION` | "no SPDM response within *n* ms; route MTU is *m* bytes" |
| **P11** | Linux only | build-time | Windows stub, `-ENOTSUP` (Part 3) |

**P7 is a correction to what I wrote earlier.** `mctp_sendmsg()` in `net/mctp/af_mctp.c:223` has an
**unconditional `if (!capable(CAP_NET_RAW)) return -EACCES;`**, present since v5.15. `bind()`'s
`CAP_NET_BIND_SERVICE` (`:67`) is only half the story — *sending* needs `CAP_NET_RAW`, i.e.
effectively root. So MCTP's privilege advantage over DOE is narrower than I claimed in 7.7: both
need privilege. MCTP's real advantage is that it is **not blocked by lockdown**, which is the
constraint that actually disqualifies DOE.

**P9 is the pivotal unknown, and there are now two ways to check it.** An endpoint advertising
`0x04` but not `0x05` means the drive's *management firmware* has no SPDM responder — the same class
of finding as the empty `0xE8` SECP list. `MEC = 3` proves the endpoints exist but says nothing
about SPDM on them, so P9 is the first real evidence either way and has **not been observed on any
named shipping SSD**, Micron or otherwise. Note the D-Bus route is unavailable in this tree — see
below — so plan on issuing control command `0x05` directly.

### 7.5a Distro and deployment reality (verified from shipped binary configs)

This determines where the feature can actually run, and it is uneven enough to matter:

| Distro | `CONFIG_MCTP` | `MCTP_TRANSPORT_I2C` | `I2C_SLAVE` |
| --- | --- | --- | --- |
| **Ubuntu 26.04 LTS** (7.0.0-14, amd64+arm64) | y | **m** | y |
| **openSUSE Tumbleweed** (x86_64+arm64) | y | **m** | y |
| **Arch** (7.1.8) | y | **m** | y |
| **Azure Linux** (6.18) | y | **m** | y |
| Fedora 44/45/rawhide | y | **off (explicit)** | y |
| Ubuntu 24.04 LTS | y | off | **n** |
| RHEL 10 / CentOS Stream 10 | **off** | – | n |
| Debian trixie/sid, Amazon Linux 2023, Google COS | **off** | – | n |

`MCTP_TRANSPORT_I2C` appears exactly when a distro flips `I2C_SLAVE=y` (Ubuntu 24.04 off → 26.04
on), consistent with its `depends on I2C_SLAVE`. Fedora disables the I²C transport explicitly;
RHEL disables the whole stack.

**Two deployment gaps that are more actionable than any kernel question:**

1. **`mctpd` is packaged nowhere** — zero packages in Fedora, Debian, Ubuntu/Launchpad, Alpine and
   openSUSE. The kernel module ships, libnvme ships, the daemon ships nowhere. Anyone deploying
   this builds `CodeConstruct/mctp` from source.
2. **This tree builds with D-Bus disabled** — [meson_options.txt:207-211](meson_options.txt#L207-L211)
   sets `'libdbus', type: 'feature', value: 'disabled'`. So `libnvme_mi_scan_mctp()` returns NULL
   here regardless of platform, and **the "discovery is already written" claim in 7.6 does not apply
   to this build as configured.** Net/EID must be supplied explicitly, and P9 detection must issue
   MCTP control command `0x05` itself rather than reading `SupportedMessageTypes` over D-Bus.

### 7.5b `mctpd` needs no changes for type `0x05` — verified exhaustively

Checked across `src/mctpd.c` (6495 lines) and `docs/mctpd.md`:

- **`SupportedMessageTypes` is a verbatim copy of whatever the endpoint reports.**
  `query_get_peer_msgtypes` (`mctpd.c:2756-2805`) does
  `memcpy(peer->message_types, (void *)(resp + 1), resp->msg_type_count)`. The **only** values ever
  compared anywhere are `0x7e`/`0x7f`, and only to decide whether to issue control command `0x06`.
  No allowlist, no `0x05` literal, no per-type policy. **`0x05` appears iff the endpoint reports
  it.**
- **`mctpd` is never in the data path** — it opens only type-`0x00` control sockets. An SPDM
  requester opens its own `AF_MCTP` socket. If the BMC should also *answer* SPDM,
  `RegisterTypeSupport(0x05, ...)` passes the validity check at `mctpd.c:4077`.
- **Bridging is fully implemented.** `endpoint_allocate_eids` (`mctpd.c:6299-6317`) installs the
  gateway route *before* issuing Allocate-EIDs, then publishes
  `au.com.codeconstruct.MCTP.Bridge1` with `PoolStart`/`PoolEnd`.

**Three operational gotchas that belong in a deployment guide:**

1. An endpoint that fails to answer control command **`0x05`** is **dropped, not published**
   (`mctpd.c:3436-3441` → `remove_peer()`, `:3540-3548`). Failures of `0x06`/`0x03` are tolerated.
   So a drive with no Get-Message-Type-Support response simply will not appear.
2. `endpoint_poll_ms` defaults to **0 = disabled**, so bridged downstream endpoints are *not*
   auto-discovered; call `Network1.LearnEndpoint(eid)` per EID.
3. Bridge pools must be contiguous with the bridge EID (`pool_start == bridge_eid + 1`).

### 7.6 What we build, and what it costs

Small, and mostly transcription:

- **~250-350 lines** for the backend. `struct spdm_ctx` gains a `{net, eid, sd}` union member; the
  send/recv pair transcribes the socket mechanics from
  [mi-mctp.c:98-135](libnvme/src/nvme/mi-mctp.c#L98-L135) and
  [:438-530](libnvme/src/nvme/mi-mctp.c#L438-L530) with `smctp_type = 0x05`, **no** `MCTP_TYPE_MIC`
  and **no** MIC computation. Everything from `spdm_xfer()` upward is unchanged.
- **Discovery is written but not compiled here.** `libnvme_mi_scan_mctp()`
  ([mi-mctp.c:749-1048](libnvme/src/nvme/mi-mctp.c#L749-L1048)) walks `mctpd` over D-Bus and
  filters on `SupportedMessageTypes` at [:858](libnvme/src/nvme/mi-mctp.c#L858) — but it is behind
  `CONFIG_DBUS`, and this tree sets `libdbus` to `disabled`
  ([meson_options.txt:207-211](meson_options.txt#L207-L211)), so it returns NULL as configured.
  **Implement P9 by issuing MCTP control command `0x05` (Get Message Type Support) directly** —
  a handful of bytes on a type-`0x00` socket — rather than depending on a build option flip.
- **One real API gap: there is no public accessor for net/EID.** `parse_and_open()` already yields
  an MI handle for an `mctp:` argument ([lib-linux.c:105](libnvme/src/nvme/lib-linux.c#L105),
  [mi.c:49-65](libnvme/src/nvme/mi.c#L49-L65)), but `libnvme-mi.ld` exports only
  `libnvme_mi_endpoint_desc`, which formats the address as the *string* `"net %d eid %d"`
  ([mi-mctp.c:640](libnvme/src/nvme/mi-mctp.c#L640)). Preferred fix: add
  `libnvme_mi_ep_get_mctp_addr(ep, &net, &eid)` in a **new `LIBNVME_MI_4` version section** — per
  CLAUDE.md, never append to an already-published section. That reuses the `mctp:<net>,<eid>`
  syntax the tool already documents. (Alternatives: plugin-local `--mctp-net`/`--mctp-eid`, which
  duplicates parsing; or a full public SPDM transport in libnvme, which is far more review
  surface.)
- **A free bring-up path exists today, before any of this is written.**
  [ioctl-linux.c:267-275](libnvme/src/nvme/ioctl-linux.c#L267-L275) dispatches
  `LIBNVME_TRANSPORT_HANDLE_TYPE_MI` to `libnvme_mi_admin_admin_passthru()`, so
  `nvme micron vs-spdm-cert mctp:1,<eid>` **already runs**, tunnelling the existing DSP0286 flow as
  NVMe-MI Admin commands over MCTP type `0x04` with zero new code — and `SPDM_MAX_XFER_SIZE` (4096)
  fits that path's 4096-byte cap exactly. It does *not* solve the problem, since it still needs the
  drive to answer SECP `0xE8`. But it is a zero-cost way to prove out an MCTP link, the routing, the
  privileges and the timeouts on a real platform **before** writing the type-`0x05` backend, and it
  is the first thing to run once an MCTP-capable server is available.
- **Do not try to reuse `struct libnvme_mi_transport`** (`private-mi.h:81-94`): its
  `(ep, req, resp)` signature has the MIC and "More Processing Required" logic baked in, and it
  lives behind `CONFIG_MI` and the `libnvme-mi.ld` export list. A standalone module in
  `plugins/micron/` is smaller and avoids touching the library's ABI.
- **Old-header compatibility is already solved:**
  [mi-mctp-compat.h](libnvme/src/nvme/mi-mctp-compat.h) hand-rolls `struct sockaddr_mctp` when
  `linux/mctp.h` is absent, selected by the `NVME_HAVE_LINUX_MCTP_H` probe at
  [meson.build:444-451](meson.build#L444-L451). Reuse that gate rather than adding a new one.
- **Gating, and a decision it forces.** [meson.build:55](meson.build#L55) computes
  `want_mi = ... and host_system == 'linux'`. Taking net/EID from an MI *handle* would tie the SPDM
  backend to `CONFIG_MI`, since `parse_and_open()` only accepts `mctp:` names when MI is built.
  **Prefer parsing `mctp:<net>,<eid>` in the plugin itself** — it is a dozen lines, mirrors
  [mi.c:49-65](libnvme/src/nvme/mi.c#L49-L65), keeps the backend independent of `CONFIG_MI`, and lets
  the Meson gate be `host_system == 'linux'` alone. The libnvme accessor above is then a nice-to-have
  rather than a dependency. Ship a `-win.c` stub mirroring
  [micron-utils-win.c:71-85](plugins/micron/micron-utils-win.c#L71-L85).
- **Fragmentation costs throughput, not correctness.** MCTP adds 1 byte of message type atop a
  4-byte transport header the stack owns, but the SMBus/I²C baseline MTU is small (69-byte
  payload), so a multi-kilobyte chain becomes hundreds of fragments. The kernel reassembles, so
  this only means `xfer_size` chunking and the CT-exponent timeouts matter more than on DOE —
  budget time for tuning, and expect a cert read to take noticeably longer than over DOE.

### 7.7 Why MCTP is the fleet-grade transport

- **Immune to kernel lockdown.** A socket API, not config-space poking. `C3` — the blocker that
  disqualifies DOE on Secure Boot production hosts — does not apply. This is the decisive advantage.
  It is *not* a privilege advantage: `mctp_sendmsg()` requires `CAP_NET_RAW` unconditionally
  (`af_mctp.c:223`), so both transports need root in practice. The difference is that no lockdown
  level forbids an MCTP socket, whereas integrity mode forbids every DOE mailbox write.
- **Survives D3hot and non-fundamental resets.** OCP **PCI-29/30/41** *require* the sideband
  endpoint to keep answering in D3hot. A DOE mailbox on a suspended device does not.
- **Stable uAPI today.** `AF_MCTP` has been mainline since v5.15 and is not going to be replaced.
  The DOE path has no uAPI at all and is explicitly a stopgap (`C7`).
- **No contention with the kernel.** No shared mailbox, no `pci_doe()` race, no `flock`, no
  `ABORT` recovery (`C4`/`C5`/`C6` all vanish).
- **Attests the right thing.** The sideband endpoint is independent of the host OS and of the
  controller's admin queue, which is what makes it credible for attestation rather than merely
  convenient.

The trade is coverage: DOE works on any Linux host with root and Secure Boot off, including
hardware we already have; MCTP works on servers built for out-of-band management, which is where
the fleet actually lives. **Neither subsumes the other, so build both** behind the vtable from
Step 1.

**One reliability warning, and it is uncomfortably on-point.** The single public field report of
nvme-cli's `mctp:` transport in four years is
**[linux-nvme/nvme-cli#3190](https://github.com/linux-nvme/nvme-cli/issues/3190)** (2026-03-17):
`nvme smart-log mctp:1,9` against a **Micron 7450**, succeeding roughly **1 attempt in 20** with
`Connection timed out`, triaged by Jeremy Kerr on interface `mctpi2c43`, kernel 6.1.158, and closed
2026-04-08 with *"project decide to use intel mctpd approach"* rather than a fix. Read it before
starting Step 2b. It says nothing about SPDM specifically, but it is the same vendor, the same
transport and the same command shape, and it means **timeout/retry behaviour over MCTP-I²C should
be treated as a first-class engineering problem rather than a tuning afterthought** — which is
consistent with the fragmentation analysis in 7.6. Budget for it, and make timeouts configurable
from the start.

Wider adoption context, for calibration: public `libnvme-mi` consumers outside nvme-cli number
**two** (`NVIDIA/nvidia-nvme-manager`, and Meta/Quanta's vendoring of it — disabled by default),
OpenBMC upstream has **zero** `nvme_mi_` references and monitors drives via the SMBus Basic
Management Command instead, and GitHub code search finds **zero** invocations of nvme-cli with an
`mctp:` device argument anywhere. Genuinely non-BMC MCTP deployments do exist — SONiC ships
`CONFIG_MCTP=y` + `MCTP_TRANSPORT_I2C=m` on x86-64 switches, and AMD Pensando carries a DesignWare
dynamic master/slave switching patch explicitly for MCTP — but neither uses nvme-cli. **We would be
early.** That is not a reason not to build it; it is a reason to expect to find and fix bugs in the
layers below us, and to keep the storage-binding firmware ask alive in parallel.

---

## Recommendation

**Extract a transport vtable behind the existing `spdm_send`/`spdm_recv` seam, then add two
Linux backends: PCIe DOE and SPDM-over-MCTP.** The probe that could have invalidated the DOE half
has been run and came back green — `doe_features/` contains `0001:01`, so a CMA-SPDM responder is
present on this drive model today. Proceed to Step 1.

Rationale in one paragraph: both are OCP-mandated for this class of drive (SPDM-5 for DOE,
SPDM-3/4/21 for MCTP) and neither subsumes the other. **DOE** is reachable from any Linux host with
root and `pread`/`pwrite` on a file the kernel already exposes, with the `nvme` driver still bound
and namespaces intact — so it is testable on the hardware we have this week, but kernel lockdown
disqualifies it on Secure Boot production hosts (`C3`). **MCTP** is the fleet-grade transport —
lockdown-immune, alive in D3hot, stable uAPI since 5.15, no contention with the kernel — and
nvme-cli already ships a working MCTP transport for NVMe-MI that this one sits alongside; what it
needs is an MCTP-capable server platform, which is the primary deployment target. Windows can host
neither, and that is accepted: the existing DSP0286 storage binding stays the default and the only
cross-platform transport.

### Sequencing, and the one thing to acquire

Both backends hang off the same vtable, so the ordering is driven purely by what can be *tested*:

1. **Step 1 (vtable) then Step 2 (DOE)** — DOE first, because the loaner drive has a confirmed
   `0001:01` responder and the only thing standing between us and an end-to-end test is a BIOS
   setting (Step 0). This also shakes out the vtable against a real second backend before the
   harder one.
2. **Step 2b (MCTP) in parallel with acquiring a platform** — the code is smaller than the DOE
   backend and needs no kernel, `mctpd` or spec work (7.5b), but it cannot be validated on the
   loaner. It is also fully unit-testable without hardware via the mock socket ops (Step 4), so
   **implementation is not gated on the platform — only verification is.**

   **The platform qualifier is one command, and it costs nothing to run:**
   `nvme micron vs-spdm-cert mctp:<net>,<eid>` **already works today** over the MI Admin passthru
   path (7.6), so on any candidate server it exercises the link, routing, privileges and timeouts
   before a line of new code. If that returns anything but a transport error, the link is good. Then
   check P9 — does the endpoint advertise type `0x05`? That is the one answer that could turn this
   into a firmware ask, exactly as `0xE8` did.
3. **Where the requester runs is now a materially different question than I first framed it.**
   Research (7.4a) shows the drive's sideband terminates on the **BMC** on every platform reachable
   in public documentation, and that no host↔BMC MCTP link has a mainline driver except
   serial/USB — with PCC 26 months and 45 revisions from merging. So the near-term realistic MCTP
   deployment is **the requester running on the BMC**, where `mctpd` is already bus owner, the I²C
   link to the drive already exists, and OpenBMC already builds `libnvme`/nvme-cli. Host-side
   requesters become straightforward on platforms with a DesignWare-class target-capable adapter
   (now supported upstream, 7.4a) or once PCC merges. **The nvme-cli work is identical either way**,
   which is precisely why this is worth building now: the same binary serves both, and the
   deployment decision can be made later without changing the code.

### Step 0 — Done. One BIOS setting stands between us and validating Step 2.

Results are in Part 1b. The only action item is environmental, and it is now precisely
characterised rather than guessed at: the probe host reads `[integrity]` **solely because Secure
Boot is enabled**. Its kernel has `CONFIG_LOCK_DOWN_IN_SECURE_BOOT=y` together with
`CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE=y` — the compiled-in default is `none` — and the `SecureBoot`
efivar reads `06 00 00 00 01`. So **disabling Secure Boot in firmware is sufficient**: no custom
kernel, no `lockdown=none` cmdline argument, no rebuild. Confirm afterwards with
`cat /sys/kernel/security/lockdown` → `[none] integrity confidentiality`.

Discovery (`ls doe_features/`, `lspci`, the ecap walk's reads) works either way, so Step 1 and the
read-only parts of Step 2 can proceed before anyone touches the BIOS.

### Step 0.5 — Fix two likely DSP0286 conformance defects in the existing storage backend

These fell out of the spec reading, are unrelated to DOE, and are invisible on this drive
(nothing answers `0xE8`) — but they would misbehave on the first drive that *does* answer, and
would look like a device fault rather than a host bug. Do them while touching this code anyway.

1. **SPSP0 operation code is not shifted.**
   [micron-spdm.c:316-320](plugins/micron/micron-spdm.c#L316-L320) is currently:
   ```c
   /* SPSP: the operation code in SPSP0, the connection ID in SPSP1. */
   static uint16_t spdm_spsp(const struct spdm_ctx *ctx, uint8_t op)
   {
   	return (uint16_t)op | ((uint16_t)ctx->conn_id << 8);
   }
   ```
   DSP0286 §7.1.2.1 Table 13 puts **both** fields in SPSP0 — bits[7:2] = SPDMOperation,
   bits[1:0] = ConnectionID — and marks **SPSP1 Reserved**. Two independent implementations
   agree with the spec and not with this code: libspdm encodes
   `security_protocol_specific = OP << 2` and decodes `(spsp0 & 0xFC) >> 2` / `spsp0 & 0x03`,
   and QEMU documents `Bit[7:2] SPDM Operation`. So the correct form is
   `(op << 2) | (conn_id & 0x3)`, with SPSP1 zero. At the default `--conn-id=0` the only on-wire
   difference is SPSP0 `0x05` instead of `0x14` — one byte, but the byte that names the operation.
   The `--conn-id` option's documented meaning in
   [nvme-micron-spdm-cert.txt:79-80](Documentation/nvme-micron-spdm-cert.txt#L79-L80) ("carried in
   SPSP1") needs correcting with it, and the range check must clamp to 0-3.
2. **The unconditional 4-byte length prefix is probably not the header DSP0286 defines.**
   [micron-spdm.c:60-65](plugins/micron/micron-spdm.c#L60-L65) documents
   `SPDM_STORAGE_HDR_SIZE` as a total-length prefix on *every* storage message, written at
   [micron-spdm.c:373](plugins/micron/micron-spdm.c#L373) and consumed at
   [micron-spdm.c:427](plugins/micron/micron-spdm.c#L427). The 4-byte header DSP0286 defines is
   the **SPDM Storage Response Header** — `DataLength[15:0]` + `StorageBindingVersion`
   (`0x1000`) — used on **Discovery and Pending Info responses**, not as a prefix on all traffic.
   **This one is flagged, not confirmed:** DSP0286 is paywalled and was not read directly.
   Re-derive §5.5.1/§5.5.2 against the actual text before changing it, and note that the
   `0x1000` version field gives a cheap way to tell the two framings apart on a live responder.

Both are cheap to validate without hardware once the QEMU bed from Step 4 is up
(`spdm_trans=nvme`), which is a further reason to stand that up early.

### Step 1 — Extract a transport vtable in `plugins/micron/micron-spdm.c`

The refactor is small and mechanical, because everything from `spdm_xfer()` upward is already
binding-neutral:

- Add `struct spdm_transport { const char *name; int (*send)(struct spdm_ctx *, const void *, size_t); int (*recv)(struct spdm_ctx *, void *, size_t, size_t *); int (*probe)(struct spdm_ctx *); void (*report_err)(struct spdm_ctx *, int, const char *); }`.
- Move the current bodies of
  [spdm_send()](plugins/micron/micron-spdm.c#L359-L386),
  [spdm_recv()](plugins/micron/micron-spdm.c#L393-L439),
  [spdm_spsp()](plugins/micron/micron-spdm.c#L317-L320) and
  [spdm_report_xport_err()](plugins/micron/micron-spdm.c#L328-L357) into a
  `spdm_xport_storage` instance; keep the binding constants at
  [micron-spdm.c:43-65](plugins/micron/micron-spdm.c#L43-L65) with it.
- Split `struct spdm_ctx` [micron-spdm.c:175-184](plugins/micron/micron-spdm.c#L175-L184): keep
  `version`, `ct_exponent`, `base_hash_algo`, `hash_size` generic; move `secp`, `conn_id` into a
  storage-specific union member, alongside a DOE member (`bdf`, `cfg_fd`, `doe_off`) and an MCTP
  member (`net`, `eid`, `sd`). `hdl` and `xfer_size` stay shared.
- `check_security_support()` [micron-spdm.c:1147-1166](plugins/micron/micron-spdm.c#L1147-L1166)
  becomes the storage backend's `probe()`; the OACS bit-0 check must not run for DOE or MCTP.
- Note that `hdl` is **not** meaningful for MCTP — the MCTP backend is addressed by
  `mctp:<net>,<eid>`, not by an NVMe device handle — so the vtable must allow a backend that never
  touches `hdl`. Design the seam for that now rather than retrofitting it in Step 2b.
- `spdm_dry_run()` [micron-spdm.c:1118-1144](plugins/micron/micron-spdm.c#L1118-L1144) currently
  hand-builds a Security Receive, so it needs a per-transport hook (a `dry_run` member, or have
  each backend describe its own encoding).

Verify this step alone changes nothing: rebuild and re-run the 17 `micron_spdm_cert_test` cases
and the `--dry-run` output byte-for-byte.

### Step 2 — The DOE backend (Linux only)

New file `plugins/micron/micron-spdm-doe-linux.c`, with a `-win.c` stub returning `-ENOTSUP`
carrying the message from Part 3 — mirroring the existing
[micron-utils-win.c:71-85](plugins/micron/micron-utils-win.c#L71-L85) pattern verbatim.

- Reuse `get_pcie_bdf()`
  [micron-utils-linux.c:72-141](plugins/micron/micron-utils-linux.c#L72-L141) — currently
  `static`; export it via `micron-utils.h` rather than duplicating it. Keep
  `pcie_bdf_is_valid()` as its private helper.
- Open `/sys/bus/pci/devices/<bdf>/config` **once** for the whole handshake (do not repeat
  `spdm-utils`' per-message reopen), and walk the extended-capability chain from `0x100` for
  ECAP ID `0x2E` with 4-byte `pread`s.
- Implement the mailbox sequence from Part 4 with `pread`/`pwrite` of exactly 4 aligned bytes.
  Wrap SPDM messages in the **8-byte DOE data-object header** — `vendor_id = 0x0001` (PCI-SIG),
  `data_obj_type = 0x01` (CMA-SPDM), `reserved`, then `length` **as a DWORD count, not a byte
  count** — replacing the DSP0286 length prefix entirely. Payload is DWORD-granular, which the
  existing dword rounding at [micron-spdm.c:403](plugins/micron/micron-spdm.c#L403) already
  anticipates. `xfer_size` chunking, `RESPOND_IF_READY` retry and CT-exponent backoff are reused
  unchanged. Leave `IntEn` clear and poll, matching the observed `DOECtl: IntEn-`.
- Do **not** shell out to `setpci`: the existing `spawn_and_capture()` precedent at
  [micron-utils-linux.c:225-342](plugins/micron/micron-utils-linux.c#L225-L342) proves the access
  model but a `fork`/`exec` per DWORD is far too slow and racy for a mailbox.
- **Fail with actionable errors for the two environmental blockers, both of which were observed
  during the probe.** `EPERM`/`EACCES` on reads past offset 64 → "requires root
  (CAP_SYS_ADMIN)". `EPERM` on write → read `/sys/kernel/security/lockdown` and, if it is not
  `[none]`, say so explicitly: *"kernel lockdown is in integrity mode, which forbids PCI config
  writes (LOCKDOWN_PCI_ACCESS); boot with Secure Boot disabled or lockdown=none"*. This is the
  single most likely failure an operator will hit — the probe host is in `[integrity]` today —
  so it must never surface as a bare errno.
- `probe()`: read `/sys/bus/pci/devices/<bdf>/doe_features/` first for a privilege-free,
  lockdown-immune answer, and report the three distinguishable states separately —
  `0001:01` present (proceed), only `doe_discovery` (mailbox exists, no SPDM feature; firmware
  ask), directory absent (no DOE or `CONFIG_PCI_DOE=n`, fall back to walking the ecap chain).
  Discovery working under lockdown is what lets the tool tell an operator that a responder
  *is* present even when it cannot talk to it.
- Discover the capability offset at runtime; do **not** hardcode the `0xd00` seen on this drive.
- **Mask every status/capability bit test** (`C4`). `DOE_STATUS` on this drive reads
  `0x00000010` while completely idle and `DOE_CAP` reads `0x00001001`, both with bits set that
  `pci_regs.h` does not define. Test `status & (BUSY | ERROR | DATA_OBJECT_READY)`; never
  `if (status)`. Getting this wrong makes the command fail on the only drive we can test with,
  and fail with a misleading "mailbox busy" diagnosis.
- Refuse to run if `/sys/bus/pci/devices/<bdf>/tsm` exists (`C4`) — measured absent today, so this
  is a cheap forward-compatibility guard, not a speculative one.
- Take an `flock` on the `config` fd for the duration of the handshake (`C5`), and implement
  `ABORT`-based entry recovery (`C6`).

### Step 2b — The MCTP backend (Linux only)

New file `plugins/micron/micron-spdm-mctp-linux.c` with the same `-win.c` stub pattern. Smaller
than the DOE backend and with no kernel-version or lockdown interaction — see Part 7.6 for the
full reuse inventory.

- **Socket mechanics:** transcribe from [mi-mctp.c:98-135](libnvme/src/nvme/mi-mctp.c#L98-L135)
  (open/connect/bind) and [:438-530](libnvme/src/nvme/mi-mctp.c#L438-L530) (addressed
  send/poll/recv), substituting `smctp_type = 0x05` for
  `MCTP_TYPE_NVME | MCTP_TYPE_MIC` and dropping the MIC entirely — SPDM messages go on the wire
  bare. Reuse the `NVME_HAVE_LINUX_MCTP_H` gate at
  [meson.build:444-451](meson.build#L444-L451) and
  [mi-mctp-compat.h](libnvme/src/nvme/mi-mctp-compat.h) for older headers rather than adding a
  new probe. Set `smctp_tag = MCTP_TAG_OWNER` on send, and allocate tags with
  **`SIOCMCTPALLOCTAG2`** — the v1 ioctl is deprecated in `uapi/linux/mctp.h:64-68` and the v2 form
  carries the network ID, which the `mctp:<net>,<eid>` syntax gives us. Reusable mechanics in
  [mi-mctp.c](libnvme/src/nvme/mi-mctp.c): socket create/open/close (~120 lines) and tag
  alloc/drop (~40 lines).
- **Do not reuse `struct libnvme_mi_transport`** (`private-mi.h:81-94`) — its `(ep, req, resp)`
  signature bakes in the MIC and "More Processing Required" logic, and it is behind `CONFIG_MI`
  and the `libnvme-mi.ld` export list. A standalone module avoids touching the library ABI.
- **Addressing:** the target is `mctp:<net>,<eid>`, already parsed by
  [mi.c:48-64](libnvme/src/nvme/mi.c#L48-L64). This is the one backend where the NVMe device
  handle is meaningless, which is why Step 1 must not assume `hdl` is always valid.
- **`probe()` implements the P1-P11 checks from Part 7.5**, each with its own message, using RTNL
  dumps (`RTM_GETLINK` for `ARPHRD_MCTP`, `RTM_GETADDR`, `RTM_GETNEIGH`) rather than shelling out
  to `mctp`. For P9, **issue MCTP control command `0x05` (Get Message Type Support) directly on a
  type-`0x00` socket** — do *not* depend on `libnvme_mi_scan_mctp()`'s `SupportedMessageTypes`
  filter, which is behind `CONFIG_DBUS` and therefore dead in this tree (7.5a). The point of P9 is
  to distinguish "no MCTP link on this host" from "this endpoint speaks NVMe-MI but not SPDM" —
  a platform conversation versus a firmware one.
- **`EHOSTUNREACH` must never surface bare.** It is the single most likely failure and it means
  "no route to that EID"; say so, and name both fixes — `mctp route add <eid> via <link>` for
  direct, `mctp route add <eid> gw <bridge-eid> net <net>` for bridged — and mention that a
  gateway route also needs a local source EID (`mctp address add`), which is a silent failure
  otherwise. `EACCES` on **send** means `CAP_NET_RAW`, not `CAP_NET_BIND_SERVICE`; distinguish the
  two, since they fail at different syscalls.
- **Timeouts and chunking need real attention here.** Fragmentation over SMBus/I²C makes a
  cert read materially slower than over DOE, so the existing CT-exponent backoff and
  `RESPOND_IF_READY` retry logic will be exercised far harder than the storage path ever
  exercised it. Expect to tune, and make the poll timeout configurable rather than fixed.

### Step 3 — Plumbing

- `--transport=storage|doe|mctp` added to the option block at
  [micron-spdm.c:1212-1216](plugins/micron/micron-spdm.c#L1212-L1216), defaulting to `storage`
  so nothing changes for existing users. `--secp`/`--conn-id` stay storage-only. Consider
  inferring the default from the device argument — an `mctp:` device name can only mean
  `--transport=mctp` — rather than making the user state it twice.
- Meson: add the platform-split sources to `plugins/meson.build` following the existing
  `micron-utils-{win,linux}.c` and `nvme-pci-ids-{win,linux}.c` gating. No new dependency —
  do **not** add libpci; sysfs `pread`/`pwrite` needs nothing, and MCTP needs only `AF_MCTP`.
  Note the MCTP backend does *not* need `CONFIG_MI` — do not gate it on `want_mi`, or it will
  disappear whenever MI is disabled; gate it on `host_system == 'linux'` alone.
- Docs: [Documentation/nvme-micron-spdm-cert.txt:30-33](Documentation/nvme-micron-spdm-cert.txt#L30-L33)
  currently asserts "no MCTP endpoint or PCIe DOE mailbox access is needed" — rewrite to describe
  all three transports, and document under `--transport`: the Linux-only restriction on both new
  backends, DOE's root + lockdown requirements, and MCTP's platform prerequisites (P1-P11) with the
  `mctp:<net>,<eid>` device form.

### Step 4 — Tests

- Unit: extend `shared/tests/` with DOE header encode/decode and ecap-walk cases over a
  synthetic 4096-byte config-space buffer — no hardware, no root. For MCTP, cover the framing
  difference that matters: assert the payload is the bare SPDM message with **no** MIC and no
  length prefix, and that `smctp_type` is `0x05`.
- e2e: extend `tests/e2e/plugins/micron/micron_spdm_cert_test.py` with a `--transport=doe`
  variant that skips cleanly when `doe_features/` is absent, when not root, or on Windows, and a
  `--transport=mctp` variant that skips when no non-`lo` MCTP link exists — reusing the
  skip-probe fix already made there (read **both** stdout and stderr — JSON mode writes errors to
  stdout). Both must skip, not fail, on the loaner host.
- No-hardware validation: bring up the QEMU NVMe SPDM responder from WD's
  `qemu-spdm-emulation-guide` — `spdm_trans=doe` to exercise the DOE backend, `spdm_trans=nvme` to
  exercise the storage path and the Step 0.5 conformance fixes that hardware cannot currently
  reach. Point `spdm-utils --doe-pci-cfg` at it first to confirm the bed works.
- **MCTP needs no hardware and no server to test** — libnvme already solved this. Mirror
  `struct __mi_mctp_socket_ops` / `__libnvme_mi_mctp_set_ops()`
  ([private-mi.h:102-114](libnvme/src/nvme/private-mi.h#L102-L114)) to make the backend's
  `socket`/`sendmsg`/`recvmsg`/`poll` injectable, then follow the mock-socket harness in
  [libnvme/tests/mi-mctp.c](libnvme/tests/mi-mctp.c) (1484 lines) to drive a scripted SPDM
  responder. This is a far better bet than the pty/`mctp-serial` loopback I originally sketched:
  it is an established in-tree pattern, runs unprivileged in CI, and lets the whole five-message
  handshake plus fragmentation and timeout paths be exercised before any server arrives. **Design
  the backend for injectability from the first commit** — retrofitting it is the expensive order.

### Explicitly do not build

- **A Windows kernel driver for DOE.** EV signing, permanent ownership of a kernel security
  surface, and a generic config-space IOCTL is blocklist bait (Part 3).
- **Windows MCTP.** No stack, no SMBus DDI, no VDM emission, no `mctpd`/D-Bus; a from-scratch KMDF
  SMBus driver that still could not reach a BMC-owned bus. The MCTP backend is Linux-only with a
  `-win.c` stub, and that is the end of the Windows MCTP story.
- **An MCTP-over-PCIe-VDM binding driver.** Exactly one patch has ever been posted (YH Chung,
  ASPEED, 2025-07-14, patchwork 14155309) and it has sat at `changes-requested` with no v2 for
  14 months. The maintainer's objection sets the real bar: Jeremy Kerr noted DSP0238 *"requires us
  to use Route to Root Complex and Broadcast from Root Complex for certain messages, so we need
  some way to represent that in your proposed lladdr format"*, and that a merge-worthy version would
  be *"a generic PCIe VDM interface … suitable for all messaging types (not just MCTP), and all
  PCIe VDM hardware (not just ASPEED's) … a much larger task"*. The author's own cover letter
  concedes there is no generic PCIe VDM bus framework in-tree, and every out-of-tree copy sits on
  ASPEED's dedicated VDM engine via `/dev/aspeed-mctp`. This is a netdev-subsystem research project,
  not a feature — even though it is the binding `MEC = 3` advertises. Reach the drive through the
  BMC instead.
- **Anything that waits on a new upstream MCTP binding landing.** MCTP-over-PCC is the calibration
  datum: 45 revisions across 26 months, still `changes-requested`, and it is the *most* advanced
  host-side binding in flight. `MMBI`, `PCC`, `KCS` and `UCIe` exist in `enum mctp_phys_binding`
  with zero drivers behind them. Build against what is merged (`i2c`, `i3c`, `serial`, `usb` plus
  6.17 gateway routing) and treat anything else as a bonus that may arrive years out.
- **vfio-pci.** Hides the DOE ecap and destroys the block devices the plugin operates on.
- **An in-band NVMe-MI SPDM tunnel.** Ruled out on spec grounds, not merely deprioritized: MT is
  pinned to `4h`, NMIMT has no opaque-payload value, and "SPDM" appears zero times in NVMe-MI 2.1
  or NVMe Base 2.3 (Part 4).

### Parallel, non-engineering track

The storage binding remains worth a firmware ask, because it is the only transport that works
identically on Windows and Linux with zero new code, no root, and no lockdown interaction: ask
Micron to add a DSP0286 responder on `SECP = 0xE8`. Frame it correctly — **this is a vendor
feature request, not an OCP compliance gap.** OCP §12.3 does not require it, and DSP0286
postdates this firmware by design (published 2025-05-15), so the drive is not defective. The
value of the ask is precisely that it is **the only way `vs-spdm-cert` ever works on Windows**, and
the only way it works on a Linux host that has neither an MCTP link nor the ability to leave
lockdown. The plugin's `--secp` override already
accommodates a pre-standard or vendor-specific value (SPC-4 reserves `0xF0-0xFF` for vendor use),
so even a non-standard code point would work through the existing `IOCTL_SCSI_PASS_THROUGH` path
with no Windows-side work at all.

Worth raising alongside it: the drive exposes `0001:03` (IDE_KM) but **not** `0001:02` (Secured
CMA-SPDM). We do not need `0001:02` — `vs-spdm-cert` establishes no session — but its absence is
worth confirming as intentional rather than an oversight, since OCP SPDM-2 territory and any
future measurement or session work would need it.

### Open items to verify before this report is quoted externally

1. **OCP §12.3 requirement text against the official v2.6/v2.7 PDF.** `opencompute.org` returns
   402/403 to automated fetch; the requirement IDs here came from a verbatim gap-analysis quote
   and a GitHub mirror of the v2.7 Final markdown. The transport list is the load-bearing claim
   in this document — verify it before quoting SPDM-3/4/5/21 externally. Which version first
   introduced SPDM is also unpinned (v2.5 circumstantially).
2. **DSP0286 §7.1.2.1 Table 13 (SPSP0 layout) and §5.5.1/§5.5.2 (framing)** — `dmtf.org` 403s.
   These decide the two Step 0.5 fixes. The SPSP0 shift is corroborated by libspdm *and* QEMU and
   is safe to act on; the length-prefix question is not, and needs the spec text.
3. **Whether Windows' `SysDbgRead/WriteBusData` with `PCIConfiguration` reaches offsets
   `>= 0x100`** — decisive for whether even a lab-only `kldbg` DOE demo is possible. Not
   load-bearing, since a Windows DOE path is out of scope either way.
4. **PCIe Base 6.x §6.30 / CMA-SPDM ECN prose and T10 SPC-6's SECURITY PROTOCOL registry** — both
   member-only/paywalled. The DOE register offsets and object type codes are corroborated across
   the Linux kernel, QEMU and `spdm-utils`, so confidence is high; the normative prose was not
   read.
5. **Nothing about the MCTP path has been validated on hardware, because the loaner cannot host
   it** (no BMC, no MCTP link — Part 7.3). This is the highest-value outstanding item and it gates
   Step 2b's verification, not its implementation — the mock socket ops (Step 4) cover development.
   On an MCTP-capable server, in order: (a) `nvme id-ctrl mctp:<net>,<eid>` returns real data — the
   platform qualifier; (b) `nvme micron vs-spdm-cert mctp:<net>,<eid>` over the existing MI Admin
   passthru path (7.6), which exercises our own code end to end for free; (c) the endpoint's
   advertised message types — Open item 7. `MEC = 3` attests endpoint *presence*, not SPDM support.
6. **Host↔BMC links and bridging — RESOLVED, see 7.4/7.4a/7.5b.** Gateway routing is mainline since
   Linux 6.17 (`ad39c12fcee3`); `mctpd` fully implements bridge EID pools and needs **no change** for
   type `0x05`; DesignWare I²C gained target mode explicitly for MCTP (`cfbcc20d5c02`, 2026-01-20);
   PCH SMBus cannot and never will. Three residual gaps, none blocking:
   - **`mctp-i2c` binding on ACPI platforms is the one point the two research passes disagreed on.**
     One found `mctp_i2c_adapter_match(adap, match_no_of)` — an explicit non-devicetree fallback,
     quoted from source; the other concluded the driver is devicetree-only. The code quote is the
     more credible, but **read `drivers/net/mctp/mctp-i2c.c` directly before specifying the
     validation server**, since it decides whether an ACPI x86 server can host a direct link at all.
   - `mctp-i3c` **is** devicetree-only and this is certain: `of_property_read_bool()` on a NULL
     `of_node` returns false, so an ACPI-enumerated I3C controller can never bind. Fixing it upstream
     means porting `mctp-i2c`'s `match_no_of` fallback or adding an ACPI `_DSD`. Also, NVMe-MI 1.2c
     §1.8.23 defines out-of-band over **SMBus/I²C and PCIe VDM only** — "I3C" appears zero times —
     so I3C's relevance to drives is unconfirmed for NVMe-MI 2.x.
   - Whether **SFF-TA-1009** defines I3C on the EDSFF sideband, and from which revision — SNIA
     returns 403; evidence is snippet-level only.
7. **Whether any named shipping SSD advertises message type `0x05`** — still unobserved, and now the
   single highest-value unknown in the whole document. `mctpd` copies `SupportedMessageTypes`
   verbatim from the endpoint, so the check is trivial *once a platform exists*; but note the trap
   in 7.5b: an endpoint that fails control command `0x05` outright is **dropped by `mctpd`, not
   published**, so "endpoint absent" and "endpoint has no SPDM" can look identical unless the
   control command is issued directly. Confirm against a Micron part with internal sourcing.
8. **`DOE_STATUS` bit 4 and `DOE_CAP` bit 12**, both set on this drive and both undefined in
   `pci_regs.h`. Presumed DOE r1.1 additions postdating the kernel header. Not load-bearing —
   the mitigation is to mask, which is correct regardless — but worth identifying against PCIe
   Base 6.2 / the DOE r1.1 ECN if that text becomes available.
9. **Micron's actual SPDM transport support per model/firmware** is not public, and the `EE`
   prefix in `EEFDLCE1T9THA` and firmware strings `E5MS002`/`E5MS003` map to no public product
   identity. This needs internal sourcing, not the web.
