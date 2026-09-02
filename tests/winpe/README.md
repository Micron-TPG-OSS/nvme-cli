<!-- SPDX-License-Identifier: GPL-2.0-or-later -->

# WinPE batch tests

Hardware tests for a WinPE host that has nothing but `cmd.exe` — no Python, so
the suites under `tests/e2e/` cannot run there. These scripts drive the `nvme`
binary directly and cover the commands whose Windows implementation depends on
WinPE:

- **Format NVM** (admin opcode 80h, `submit_admin_format_nvm()` in
  `libnvme/src/nvme/ioctl-win.c`)
- **Compare** (NVM opcode 05h, `libnvme_exec_io_passthru()` in the same file)
- **NVMe-MI Send and NVMe-MI Receive** (admin opcodes 1Dh and 1Eh,
  `submit_storage_protocol_command()` in the same file)

Every suite reads the identify data first and adapts to the drive, so a
controller that does not support Compare, an LBA format with metadata, or an
NVMe-MI command the drive does not implement, produces skips rather than
failures.

**Two of the three tests destroy data.** The compare suite overwrites the LBA
range it uses; the format suite erases the whole namespace. Both refuse to run
without `--yes`. The nvme-mi suite reads only and needs no confirmation.

## Files

| File | Purpose |
| --- | --- |
| `nvme-mi-test.bat` | NVMe-MI Send and Receive suite, read only |
| `nvme-compare-test.bat` | Compare command suite |
| `nvme-format-test.bat` | Format NVM suite |
| `nvme-run-tests.bat` | Runs all three and reports a combined result |
| `nvme-test-lib.bat` | Shared helpers: case bookkeeping, command runner, identify field parsing, NVMe-MI response parsing, pattern files |

## Running

Copy this directory and an `nvme.exe` onto the WinPE media, then:

```bat
rem Print the case plan. Only the identify queries run, nothing is written.
nvme-compare-test.bat --list --nvme X:\nvme.exe

rem The nvme-mi suite changes nothing, so it needs no --yes.
nvme-mi-test.bat --nvme X:\nvme.exe --ctrl nvme0

rem Run against a device.
nvme-compare-test.bat --yes --nvme X:\nvme.exe --ns nvme0n1
nvme-format-test.bat  --yes --nvme X:\nvme.exe --ns nvme0n1 --ctrl nvme0

rem All three, in order of what they disturb: nvme-mi reads only, compare
rem leaves the namespace intact, format erases it.
nvme-run-tests.bat --yes --nvme X:\nvme.exe --ns nvme0n1 --ctrl nvme0
```

Device names may be either the libnvme style names (`nvme0`, `nvme0n1`) or raw
Windows paths (`\\.\PhysicalDrive1`). Run `nvme list` first to see the mapping.

Each suite writes a log and its scratch files under `%TEMP%\nvme-<suite>-test`;
`--out DIR` puts them somewhere else, which matters when `%TEMP%` lives on a
read-only or tiny RAM disk. `--help` lists the remaining options
(`--timeout`, `--start-block`, `--nsid`, `--alt-lbaf`, `--verify-block`,
`--skip-crypto`, `--big`, `--assume-winpe`).

The exit code is 0 when no case failed, 1 when one did, and 2 when the suite
never started (missing `--yes`, bad option, unusable work directory). Skips do
not fail a suite.

## What the nvme-mi suite checks

NVMe-MI Send (1Dh) and NVMe-MI Receive (1Eh) are ordinary admin commands that
carry the NVMe-MI *in-band tunneling mechanism*, so no out-of-band MCTP
transport is involved. On Windows they are only dispatched under WinPE. Field
layouts follow NVM Express Management Interface Specification 1.2c, section 4.3.

Expectations follow `id-ctrl` and the environment:

- OACS bit 6 clear means the controller does not implement the two commands at
  all, so the suite only checks that it says so and stops.
- Outside WinPE both commands must be refused with "not supported".

Under WinPE:

1. **Argument handling** — a receive with no `--opcode` is rejected inside
   nvme-cli, so the drive never sees it.
2. **Message header encoding** — two `--dry-run` cases confirm that command
   dword 10 carries the NVMe-MI message header, MCTP message type 4h in bits
   7:0 and the NVMe-MI message type in bits 14:11, for both a legal message
   type and one that is prohibited in band. Nothing is submitted.
3. **The three mandatory in-band reads** — VPD Read with a zero data length,
   which the specification requires to answer Success with no response data;
   NVM Subsystem Health Status Poll with the Clear Status bit clear; and
   Controller Health Status Poll with Report All set and Clear Changed Flags
   clear. Each is two cases: the admin command completing, and the tunneled
   status being Success. Both response data structures are then decoded and
   logged, and the two composite temperatures are cross-checked — one is
   reported in Celsius and the other in Kelvin, so agreement within 5 degrees
   means both transfers landed at the right offset in the right byte order.
4. **The optional in-band reads** — Read NVMe-MI Data Structure for the NVM
   Subsystem Information, whose major version the specification fixes at 1, and
   for the Optionally Supported Command List. The command list is decoded and
   drives the expectations of the send cases below, so a command the drive
   simply does not implement is told apart from one that failed.
5. **Sends that select no work** — a reserved NVMe-MI opcode and a prohibited
   message type, both of which the drive must reject; a VPD Write of length 0,
   which the specification says writes nothing; and a Configuration Set for
   Health Status Change whose clear mask is empty, so no status bit is cleared.
   After the VPD Write the `vwci` write cycle budget is re-read and must not
   have moved.
6. **Dispatch** — the deprecated `nvme-mi-recv` and `nvme-mi-send` aliases still
   forward to the plugin with a deprecation warning, and a receive issued on the
   namespace handle is recorded.

Two things are worth knowing when reading a run:

- A tunneled NVMe-MI error is reported as NVMe *Successful Completion* with the
  error in completion queue entry dword 0, so `nvme` exits 0 either way. That is
  why the admin command and the tunneled status are separate cases; checking the
  exit code alone would pass a rejected command.
- The sends carry no request data, which is the case that needs the zero length
  data-out padding in `submit_storage_protocol_command()`. If the reserved
  opcode case fails with a non-zero exit code and "Invalid argument" rather than
  reporting a tunneled status, that padding is what regressed, and the log says
  so.

Because every command tunneled via NVMe-MI Send writes something, a drive that
implements no optional in-band send has no reachable successful send. That is
normal, and the suite still covers the whole data-out path through the
rejections.

## What the compare suite checks

Compare is only submitted on Windows when the MiniNT registry key says WinPE, so
the expectations flip with the environment:

- Outside WinPE: one case, `nvme compare` must fail with "not supported".
- Under WinPE: write a pattern, then confirm that Compare accepts the matching
  buffer and reports *Compare Failure* (status 0x285) for a different one; that a
  mismatch confined to the last block of a multi-block compare is still caught;
  that the start block is honoured, by comparing two regions holding different
  patterns; that `--dry-run` never reaches the drive; and, at the end, that the
  data is still intact so that none of the failing compares wrote anything.

A read-back of the compared range is byte-compared so that a Compare which
succeeds for the wrong reason does not pass unnoticed. The log records which
method decided it (see *External tools* below).

`--big` adds a compare at the largest allowed transfer — the smaller of MDTS and
the 512 pages (2 MiB) that `IOCTL_STORAGE_PROTOCOL_COMMAND` may carry — plus one
above that limit, which has to be rejected. It is off by default because filling
that region takes one 4 KiB write per block: the Windows SCSI pass-through path
that carries writes does not accept a payload of that size in one command.

## What the format suite checks

1. **Option validation** — `--ses=8`, `--lbaf=64`, `--pi=8`, `--pil=2`,
   `--ms=2`, `--lbaf` together with `--block-size`, a block size that is not a
   power of two, and a block size no LBA format provides. These fail inside
   nvme-cli, so the drive never sees a format.
2. **Rejections by the drive** — an LBA format index the namespace does not
   report, and a namespace id the controller does not have.
3. **Formatting** — SES=0 (no erase), SES=1 (user data erase) and SES=2
   (cryptographic erase), each followed by a check that the pattern written
   beforehand is gone; a reformat to a second LBA format and back, verified
   through the LBA format that `nvme id ns` reports in use; the broadcast
   namespace id; and a format issued on the controller handle instead of the
   namespace handle.

Expectations follow the identify data and the environment:

- `FNA` bit 2 clear means the drive must reject SES=2.
- `FNA` bit 3 set means the drive must reject nsid FFFFFFFFh.
- `FNA` bit 0 set makes nvme-cli turn *every* format into a broadcast format, so
  the invalid namespace id case is skipped.
- Outside WinPE, SES=0 and formats on the controller handle must be refused with
  "not supported", SES=1 goes through `IOCTL_SCSI_PASS_THROUGH` with SANITIZE and
  SES=2 through `IOCTL_STORAGE_REINITIALIZE_MEDIA`. Since the LBA format is not
  carried by either IOCTL, the reformat cases only run under WinPE.

That last point is worth keeping in mind when reading a non-WinPE run: the cases
that expect the drive to reject something pass there because libnvme refuses
SES=0 before the drive is ever reached. Only a WinPE run exercises them for real.

## External tools

A WinPE image carries no guaranteed set of System32 tools, so nothing the suites
must have is external: identify output is parsed with `for /f` over the file and
substring tests use cmd's own case insensitive substitution. `findstr` in
particular is missing from some images, which used to make every parse fail with
"could not parse the LBA format in use". The preflight logs what is present:

```
tools present: fc=1 certutil=1 fsutil=1 reg=1 findstr=1
```

Where an optional tool improves a check, it is used when available and degraded
when not:

| Tool | Used for | Without it |
| --- | --- | --- |
| `fc` | byte exact file comparison | falls back to `certutil` MD5, then to comparing the first 1023 bytes; the log names the method |
| `certutil` | MD5 fallback for the above | as above |
| `reg` | WinPE detection | falls back to the presence of `startnet.cmd`, and `--assume-winpe` overrides either way |
| `fsutil` | metadata buffer for a namespace with `ms>0` | those cases skip |

The first 1023 byte comparison is not exact. It is enough to tell the two
generated patterns apart and to see that a formatted block no longer holds one,
which is all the suites ask of it, and the log says `method: prefix` when it was
used so a reader knows.

## Limitations

- A namespace with protection information enabled, or with metadata transferred
  at the end of the LBA, makes the compare suite skip: the data buffer layout
  and the tag options needed for those formats are out of scope. Format the
  namespace to an LBA format with `ms=0` and `pi=0` first.
- The suites use one namespace. Multi-namespace behaviour of a broadcast format
  is not verified beyond the command completing.
- The nvme-mi suite reads response data out of the hex dump, which means only
  the first 16 bytes are available to it. That covers every structure it
  decodes, but only the first seven entries of the Optionally Supported Command
  List; the log says so when the drive reports more.
- Vendor specific NVMe-MI commands, opcodes C0h to FFh, are not exercised.
- Progress and results are plain text; there is no TAP or JSON output, so
  `--out` plus the log file is the artifact to collect from a WinPE run.
