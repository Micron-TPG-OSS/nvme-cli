<!-- SPDX-License-Identifier: GPL-2.0-or-later -->

# Micron CI helpers

This directory holds the scripts that Micron's own workflows call, on top of
upstream `linux-nvme/nvme-cli`.

```
.github/micron/
├── README.md
├── scan_deps_pe.sh                             # gate: no MinGW runtime in nvme.exe
├── sharepoint-publish.py                       # called by the sharepoint job
├── smoke-test.sh                               # called by the build job
└── tests/
    └── test_scan_deps_pe.sh                    # the gate, against known-bad input
```

## Why the files live where they do

The upstream sync (`micron-sync-and-merge.yml`) is a plain `git merge` of
`linux-nvme/nvme-cli` master into this fork. Files introduced only in this fork
have no upstream-side change to merge, so a sync leaves them untouched. That
covers this directory and the Micron workflows in `.github/workflows/` too:
`micron-release.yml`, `micron-sync-and-merge.yml` and `micron-ci.yml` are
Micron-only names, so they are edited in place like any other file.

Keep Micron-only files under Micron-only names. A file that shares a name with
an upstream file is the one case that can conflict on a sync.

## The release gate: `scan_deps_pe.sh`

The Windows release is a single `nvme.exe` in a zip. There is no installer to
carry a dependency, so an exe that imports `libwinpthread-1.dll` does not start
on the recipient's machine and nothing can be done about it after the zip has
been sent. `scan_deps_pe.sh` reads the artifact's PE import table and fails if a
MinGW/MSYS2 runtime DLL appears — it asserts that meson's
`--default-library=static` actually took, rather than trusting the build flags.

```bash
.github/micron/scan_deps_pe.sh .build-release/nvme.exe
.github/micron/scan_deps_pe.sh --imports-from imports.txt   # check a list
.github/micron/scan_deps_pe.sh --out imports.txt nvme.exe   # and keep the list
```

Exit `0` clean, `1` a runtime leak, `2` nothing was checked. The last is the
point of the split: "I could not read the import table" and "the import table is
clean" must not produce the same answer, because a pass on a binary nobody looked
at also produces a record saying the binary was checked.

Two things are worth knowing before copying this gate anywhere:

- **It reads the import table, not `ldd`.** `ldd` resolves through the MSYS2
  runtime, which is x86_64 even on `windows-11-arm`, so it cannot be trusted for
  the aarch64 binary. Import names are host-independent.
- **There is no network gate here, and one must not be added.** The sibling tools
  `mld` and `mldcli` fail if the binary imports any networking DLL, because they
  read customer logs and must be unable to transmit them. nvme-cli speaks NVMe-oF
  over TCP: `ws2_32.dll` is correct behaviour here, and a gate that fires on a
  working build is a gate somebody switches off.

`tests/test_scan_deps_pe.sh` runs the denylist against real import tables — clean
x64 (including `WS2_32.dll`) and arm64, one case per denied runtime, an uppercase
case, `vcruntime140.dll` and `ucrtbase.dll` asserted *not* to fire, and an empty
list asserted to exit 2. It needs no Windows runner and no build. It exists
because this check used to be inline YAML in `micron-release.yml`, which meant its
denylist ran once per release against one input and its failing branch — the one
that matters — had never executed. The empty-list case failed on the suite's
first run and found a real hole.

## What carries a Micron delta on an upstream file

**`build.yml`, `check-accessors.yml`.** On `mingw` these carry a
one-line Micron change (adding `mingw` to the CI branch triggers). Git merges
upstream changes around that line, so it survives a sync unless upstream edits
the same trigger list, in which case the `mingw` merge fails and needs resolving
by hand. Do not replace these with whole-file Micron copies: that would pin them
at a Micron snapshot and silently discard future upstream CI improvements.

## Shared conventions with the sibling tools

Micron ships three tools that hand a binary to someone outside the team: this
fork of nvme-cli, **swworkbench** (`mldcli`, `msecli2`) and **mldcs** (`mld`).
They share one set of CI conventions, each stated with its reasoning in
`docs/CI_CONVENTIONS.md` in the **mldcs** repository. The notes here are only
about how they land in a *fork*, which is the thing that makes this repository
different from the other two.

**Micron-only paths are the fork-specific convention.** Everything Micron adds
lives at a path upstream does not have (`.github/micron/`, `micron-*.yml`).
Nothing else in the tree is edited for Micron's benefit — not `docs/`, not
`meson.build`, not upstream's workflows — because every such edit is a merge
conflict on every sync, forever, resolved by whoever is on sync duty that day.
When a convention cannot be met without editing an upstream file, it does not
get met here; that is the trade the fork makes.

Met here:

- **Gates fail closed, and "could not check" is not "clean".** `scan_deps_pe.sh`
  exits 2 for the first and 0 for the second.
- **Actions pinned to a commit SHA with the version in a trailing comment.** All
  Micron-owned workflow files. Upstream's own workflows are already pinned and are
  not ours to change; Dependabot (upstream's config) keeps both current.
- **Permissions declared per job, defaulting to read.** Every job in
  `micron-release.yml` names what it needs, including the OIDC job's
  `id-token: write`.
- **Every run records what it produced.** Three step-summary blocks: the resolved
  upstream release, per-architecture version and imports, and the published
  assets.
- **The gate is adapted to the tool, not ported.** No no-network gate here; see
  above.

Still open, in the order they would pay off:

1. **The gate never meets a real binary before a release.** Upstream's
   `build.yml` does build Windows on every pull request — `windows-msys2-ucrt64`
   and `windows-msys2-clangarm64` — but those are `scripts/build.sh -b release`
   CI builds into `.build-ci`, without the release job's
   `--default-library=static` and `EXTRA_LINK_ARGS`. Pointing
   `scan_deps_pe.sh` at that exe would report a leak on a perfectly correct CI
   build, which is the anti-pattern the script's own header warns about. So
   `micron-ci.yml` tests the *gate*, and the gate still first sees a shipping
   binary at release. Closing this means a Micron job that builds with the
   release's link configuration, not reusing upstream's.
2. **The build is not attested.** `actions/attest-build-provenance` would let a
   recipient verify with `gh attestation verify` that a given zip came from this
   workflow, from this commit — the one convention swworkbench meets and the other
   two do not.
3. **No PR template.** Deliberate for now: most pull requests here are upstream
   syncs, and a Micron-specific template on a fork of an upstream project is
   mostly noise. Revisit if hand-written Micron changes become common.
