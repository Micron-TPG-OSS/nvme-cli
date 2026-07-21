# `nvme telemetry-log` — Current Memory & Size Behavior

Reference for TACT-13. This documents **how the command works today**, tracing the
size-determination and memory-allocation code path starting in `nvme.c`. No proposed
changes are described here.

## Command entry

`telemetry-log` is registered in [nvme-builtin.h:37](../nvme-builtin.h#L37):

```c
ENTRY("telemetry-log", "Retrieve FW Telemetry log write to file", get_telemetry_log)
```

The handler is `get_telemetry_log()` at [nvme.c:951](../nvme.c#L951).

CLI options ([nvme.c:992-998](../nvme.c#L992)) and their config defaults
([nvme.c:983-990](../nvme.c#L983)):

| Option | Short | Field | Default |
|--------|-------|-------|---------|
| `--output-file`     | `-O` | `file_name` | (required) |
| `--host-generate`   | `-g` | `host_gen`  | `1` |
| `--controller-init` | `-c` | `ctrl_init` | `false` |
| `--data-area`       | `-d` | `data_area` | `3` |
| `--rae`             | `-r` | `rae`       | `false` |
| `--mcda`            | `-m` | `mcda`      | `0xff` (unset) |

There is currently **no transfer-size option** — the transfer chunk is determined
entirely by the fetch path described below.

## Size-determination code path (traced from `nvme.c`)

### Step 1 — dispatch on mode

After argument parsing, opening the output file, and (for `data-area == 4`) an
identify-controller + ETDAS setup ([nvme.c:1026-1050](../nvme.c#L1026)), the handler
allocates a throwaway header-sized buffer ([nvme.c:1059](../nvme.c#L1059)) and
dispatches to one of three helpers ([nvme.c:1063-1071](../nvme.c#L1063)):

```c
if (cfg.ctrl_init)
    err = __get_telemetry_log_ctrl(hdl, cfg.rae, cfg.data_area, &total_size, &log, da4_support);
else if (cfg.host_gen)
    err = __create_telemetry_log_host(hdl, cfg.data_area, &total_size, &log, da4_support);
else
    err = __get_telemetry_log_host(hdl, cfg.data_area, &total_size, &log, da4_support);
```

- `cfg.ctrl_init` (`-c`) → controller-initiated: `__get_telemetry_log_ctrl` ([nvme.c:878](../nvme.c#L878))
- `cfg.host_gen` (`-g`, default 1) → host create: `__create_telemetry_log_host` ([nvme.c:854](../nvme.c#L854))
- neither → host, no create: `__get_telemetry_log_host` ([nvme.c:926](../nvme.c#L926))

Each returns the full buffer via `**buf` and the byte size via `*total_size`.

### Step 2 — read the header, then size the log

All three helpers follow the same shape: allocate a *small* buffer, read the telemetry
**header**, then call `parse_telemetry_da()` to compute the full size. Example —
`__get_telemetry_log_host` ([nvme.c:926-949](../nvme.c#L926)):

```c
log = libnvme_alloc(sizeof(*log));                       // header-sized alloc
err = nvme_get_log_telemetry_host(hdl, 0, log, NVME_LOG_TELEM_BLOCK_SIZE);  // read 512-byte header
err = parse_telemetry_da(hdl, da, log, size, da4_support);                  // compute *size
return get_log_telemetry_host(hdl, *size, buf);                            // alloc full + fetch
```

The controller-initiated variant additionally reads the header with `rae=true` to avoid
clearing the log, and short-circuits with `*size = NVME_LOG_TELEM_BLOCK_SIZE` (512) if
`log->ctrlavail` is 0 ([nvme.c:896-913](../nvme.c#L896)).

### Step 3 — `parse_telemetry_da()`: the size formula

[nvme.c:765-812](../nvme.c#L765). The size comes from the telemetry header's data-area
"last block" fields:

```c
size_t dalb, da1lb = le16_to_cpu(telem->dalb1), da2lb = le16_to_cpu(telem->dalb2),
       da3lb = le16_to_cpu(telem->dalb3), da4lb = le32_to_cpu(telem->dalb4);

switch (da) {
case NVME_TELEMETRY_DA_CTRL_DETERMINE: dalb = da4_support ? da4lb : da3lb; break;
case NVME_TELEMETRY_DA_1: dalb = da1lb; break;
case NVME_TELEMETRY_DA_2: dalb = da2lb; break;
case NVME_TELEMETRY_DA_3: dalb = da3lb; break;   /* dalb3 >= dalb2 >= dalb1 */
case NVME_TELEMETRY_DA_4: dalb = da4_support ? da4lb : /* error */; break;
...
}
if (dalb == 0) return -ENOENT;                   // "No telemetry data block"
*size = (dalb + 1) * NVME_LOG_TELEM_BLOCK_SIZE;  // nvme.c:810
```

- `NVME_LOG_TELEM_BLOCK_SIZE` = **512** ([nvme-types-base.h:182](../libnvme/src/nvme/nvme-types-base.h#L182)).
- The "last block" values are **cumulative** (DA3 includes DA1+DA2+DA3), which is why
  `--data-area 3` is the default (fetches areas 1–3).
- Header struct `struct nvme_telemetry_log` ([nvme-types-base.h:4214-4233](../libnvme/src/nvme/nvme-types-base.h#L4214)):
  `dalb1/dalb2/dalb3` are `__le16` (max 65535 blocks ≈ 32 MB each); **`dalb4` is
  `__le32`**, so `(dalb4 + 1) * 512` for DA4 can exceed 2 GB.

### Step 4 — allocate the full buffer and fetch it

The two leaf helpers do the full-size allocation and the bulk fetch. `get_log_telemetry_host`
([nvme.c:834-852](../nvme.c#L834)):

```c
log = libnvme_alloc(size);                        // full-size allocation
err = nvme_get_log_telemetry_host(hdl, 0, log, size);
```

`get_log_telemetry_ctrl` ([nvme.c:814-832](../nvme.c#L814)) is identical but calls
`nvme_get_log_telemetry_ctrl(hdl, rae, 0, log, size)`.

### Step 5 — write the whole buffer to file

Back in the handler ([nvme.c:1080-1100](../nvme.c#L1080)), the entire `total_size`-byte
buffer is drained to the output file in a single `write()` loop. The complete log is held
in memory before any bytes reach disk, so **peak memory ≈ full log size**.

## How the transfer chunk size is chosen today

The `len` passed to the leaf fetch = the **full log size**. That `len` flows into the
libnvme wrappers as *both* the buffer length and the transfer chunk size:

`nvme_get_log_telemetry_host` / `nvme_get_log_telemetry_ctrl`
([nvme-cmds.h:560-599](../nvme-cmds.h#L560)):

```c
nvme_init_get_log_telemetry_host(&cmd, lpo, log, len);
return libnvme_get_log_dynamic_chunk(hdl, &cmd, false, len);   // xfer_len == len == full size
```

`libnvme_get_log_dynamic_chunk` ([libnvme/src/nvme/nvme-cmds.c:115-190](../libnvme/src/nvme/nvme-cmds.c#L115))
starts at `xfer_len` and, on a *recoverable* error (negative errno, or NVMe status with
SCT ≤ Command-Specific), **halves** the chunk — masked down to a 4096 multiple — retrying
the same offset until it succeeds or drops below `NVME_LOG_PAGE_PDU_SIZE` (4096,
[libnvme/src/nvme/ioctl.h:28](../libnvme/src/nvme/ioctl.h#L28)):

```c
if (ret < 0 || (ret > 0 && (ret >> NVME_SCT_SHIFT) <= NVME_SCT_CMD_SPECIFIC)) {
    xfer_len = (xfer_len / 2) & ~(__u32)(NVME_LOG_PAGE_PDU_SIZE - 1);
    if (xfer_len < NVME_LOG_PAGE_PDU_SIZE)
        return ret;
    continue;
}
```

**Net effect of the current default:** the telemetry log is requested in the *largest
possible* transfer (the whole log at once) and the chunk size is automatically **halved
on failure** down to 4 KiB. This is *not* a fixed 4 KiB per transfer.

> Note: this differs from upstream nvme-cli, where telemetry transfers are fixed at 4 KiB.
> This fork already carries the dynamic-chunk (`libnvme_get_log_dynamic_chunk`) behavior.

### The 4 KiB clamp: `force-4k`

A hard 4 KiB clamp is available but **off by default**. Setting
`nvme --set-options force-4k=1 ...` calls `libnvme_set_force_4k` ([nvme.c:426](../nvme.c#L426)),
which sets `ctx->force_4k`. Inside libnvme this unconditionally forces `xfer_len` to 4096
([libnvme/src/nvme/nvme-cmds.c:67-68, 133-134](../libnvme/src/nvme/nvme-cmds.c#L67)),
overriding the full-size start. In this fork it is a global-context set-option, not the
`LIBNVME_FORCE_4K` environment variable used upstream.

## Memory allocator notes

- `libnvme_alloc(len)` ([libnvme/src/nvme/mem-linux.c:22](../libnvme/src/nvme/mem-linux.c#L22)):
  page-aligned (`posix_memalign`), zero-initialized, **rounds `len` up to a 4 KiB
  multiple**. So actual allocation for a telemetry log is always a 4 KiB multiple ≥ the
  computed `(dalb+1)*512`.
- The handler's `log` and `id_ctrl` use the `__cleanup_libnvme_free` scope-guard
  ([nvme.c:962-963](../nvme.c#L962)); the leaf helpers free explicitly on error.
- `libnvme_alloc_huge`/`__cleanup_huge` exist for large contiguous buffers but are **not**
  used by this command today.

## Summary of key locations

| Concern | Location |
|---------|----------|
| Handler | `get_telemetry_log()` [nvme.c:951](../nvme.c#L951) |
| Size formula | `parse_telemetry_da()` [nvme.c:765](../nvme.c#L765) — `(dalb+1)*512` |
| Full-size alloc + fetch | `get_log_telemetry_{host,ctrl}` [nvme.c:814-852](../nvme.c#L814) |
| Mode dispatch | [nvme.c:1063-1071](../nvme.c#L1063) |
| Write-to-file loop | [nvme.c:1080-1100](../nvme.c#L1080) |
| Transfer wrappers | `nvme_get_log_telemetry_{host,ctrl}` [nvme-cmds.h:560-599](../nvme-cmds.h#L560) |
| Halving-on-error transport | `libnvme_get_log_dynamic_chunk` [libnvme/src/nvme/nvme-cmds.c:115](../libnvme/src/nvme/nvme-cmds.c#L115) |
| 4 KiB clamp | `force_4k` [nvme.c:426](../nvme.c#L426), [libnvme/src/nvme/nvme-cmds.c:67](../libnvme/src/nvme/nvme-cmds.c#L67) |
| Header struct | `struct nvme_telemetry_log` [nvme-types-base.h:4214](../libnvme/src/nvme/nvme-types-base.h#L4214) |
