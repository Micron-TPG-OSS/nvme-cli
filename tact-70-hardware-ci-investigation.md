# TACT-70 — Real-Hardware CI for nvme-cli & blktests (Windows + Linux)

**Status:** Draft for review · **Owner:** Jim Munn · **Type:** Investigation (no infrastructure changes under this ticket)
**Purpose:** Feed a Micron ART (Architecture Request Tracker) architecture + security review. This document explains how the upstream linux-nvme community runs its automated real-hardware tests, why that stack is built the way it is, and what Micron would actually need to stand up an equivalent that also covers Windows.

---

## What Micron actually needs (the two requirements)

Stripped of all the upstream complexity, this work exists to satisfy **two requirements**:

1. **Run the `nvme-cli` e2e/plugin tests on Linux against a real Micron drive.** Upstream already runs these on Linux — but against **WDC** drives. The Micron-specific code in the e2e suite and the `micron` plugin is therefore **never exercised on Micron hardware today**. A Linux runner with a Micron drive closes that gap.
2. **Run the `nvme-cli` e2e/plugin tests on Windows against a real Micron drive.** nvme-cli's Windows code paths have **no real-hardware coverage anywhere** — upstream is Linux-only. This is the net-new half of the work.

Everything else in this document — the disposable-VM machinery, Kubernetes, and the rest of the upstream stack — is background for figuring out *how* to meet these two requirements as simply as possible.

> **A note on blktests scope.** The ticket (TACT-70) commissions `nvme-cli` **and** blktests as co-equals. This investigation concludes blktests is better treated as **bonus coverage than a co-equal requirement**: it tests the **Linux kernel**, not `nvme-cli`, and has no Windows counterpart. It rides along on the Linux runner at no extra cost, but it does not drive the design and is out of scope on Windows. Flagging the divergence here so it is a deliberate scoping decision, not an omission.

---

## How to read this document

The upstream system is built from about a dozen infrastructure technologies that most application developers never touch. This document assumes **no prior knowledge** of Kubernetes, virtualization, or PCIe device passthrough.

- **Every unfamiliar term is bolded and explained in plain language the first time it appears.**
- **There is also a full [Glossary](#glossary) at the end** — a one-line definition of every term, for quick lookup while reading or reviewing.
- **[Part 2](#part-2--the-building-blocks-explained-from-zero) is a from-scratch tour of every technology** in the stack. If a term confuses you later, that's the section to jump back to.

If you read nothing else, read the [TL;DR](#tldr) and [Part 5 (Recommendation)](#part-5--recommended-approach-for-micron).

---

## TL;DR

- The upstream test rig exists to solve **one hard problem**: let an automated test grab a **real, physical NVMe SSD** and run destructive tests on it, inside a **disposable virtual machine** that can boot **any kernel version**, triggered automatically from a GitHub workflow — over and over, unattended, on shared hardware.
- To do that at the scale of the whole Linux kernel community, they built a **Kubernetes cluster** (a fleet-management system) with roughly ten cooperating subsystems. **Most of that complexity is a consequence of scale and of kernel-development needs that Micron does not share.**
- The genuinely essential core is small: dedicate a **real, physical SSD** to the tests, run them, wipe the drive, repeat. Everything beyond that is a cost-and-logistics choice — chiefly whether to use two machines (one per OS, bare metal) or consolidate onto one, which then runs each OS in a virtual machine with the SSD handed over via **PCIe passthrough** (requiring the platform's **IOMMU**, the I/O Memory Management Unit).
- **Recommendation:** Micron almost certainly does **not** need the Kubernetes machinery. Start with the simplest thing that works and only add complexity if a concrete need forces it. Three configurations fit, all solid starting points (detailed in [Part 5](#part-5--recommended-approach-for-micron)):
  1. **Two bare-metal boxes** — one Linux, one Windows, each with its own drive; tests run directly on each host.
  2. **One consolidated host, shared drive** — both OSes as VMs against a single drive; runs go sequentially.
  3. **One consolidated host, one drive per OS** — two drives; runs go concurrently.

  The choice is a cost/fidelity/throughput call for the infrastructure owner.
- nvme-cli builds on Windows, and its end-to-end (e2e) test suite is already Windows-aware. The net-new engineering is **infrastructure**: a Windows test target with a real Micron drive and the CI wiring to run the existing suite against it.

---

## Part 1 — The one problem, in plain English

The goal is to automatically test `nvme-cli` and `blktests` (a Linux storage test suite) against a **real Micron SSD** every night, kicked off by a CI workflow — the same way unit tests run on GitHub today, but touching actual hardware.

Three things make this much harder than a normal CI job:

1. **It must use a real, physical drive.** nvme-cli and blktests issue real NVMe admin/IO commands, and an emulated disk will not answer them faithfully — so the tests need a real controller to talk to. Something has to give the test *exclusive, direct* access to the actual PCIe SSD.
2. **The tests are destructive.** blktests and the device-prep scripts erase the drive, delete and recreate namespaces, and reformat it. The drive must be **dedicated and sacrificial** — nothing on it survives a run — so this can never be pointed at a drive holding data you want to keep.
3. **(Upstream only) It must be able to boot any kernel.** The kernel community tests *unreleased, in-development* kernels. Every test run may need a *different* kernel booted fresh.

The obvious solution — "put the drive in a PC, install a test runner on it, run the tests there" — breaks on requirement #3 for a subtle reason that drives the entire upstream design:

> A **CI runner** is a long-running program that stays connected to GitHub, waiting for jobs. To test a brand-new kernel, the machine would have to **reboot** into that kernel. Rebooting kills the runner program and its connection to GitHub — so the job fails.

Upstream's answer: **don't reboot the physical machine.** Instead, for every job, create a brand-new **virtual machine**, boot the requested kernel *inside that VM*, hand the physical SSD into the VM, run the test, collect the results, and then **throw the entire VM away**. The runner program never reboots; it just keeps spawning and destroying VMs.

That single decision — *a fresh throwaway VM per job* — is the seed from which all the complexity grows. Everything else in the upstream stack exists to make that pattern work **automatically, at scale, on shared hardware, behind a corporate firewall.**

**The key insight for Micron:** requirement #3 (arbitrary kernels) is a *kernel-developer* need. Micron wants to test `nvme-cli` (a normal user-space program) against a **normal, fixed kernel**. Remove requirement #3 and the whole justification for the disposable-VM machinery — and most of the stack — evaporates. We return to this in [Part 4](#part-4--why-is-it-so-complex) and [Part 5](#part-5--recommended-approach-for-micron).

### What is this stack actually *for*? (and why that matters to Micron)

It is easy to assume the upstream rig was built to test `nvme-cli`. It was not.

- **blktests is a *Linux-kernel* test suite.** It exercises the kernel's block layer and storage drivers — the in-kernel NVMe driver, SCSI, zoned-block support, block-layer ioctls. It tests the **kernel**, not the `nvme-cli` command-line tool.
- **The `blktests-ci` infrastructure exists to catch regressions in the Linux kernel storage stack.** That is *why* it needs to boot an arbitrary, in-development kernel for every job (requirement #3) and run across a shared pool of machines. Kernel testing is the entire reason for the complexity.
- **`nvme-cli` is a tenant, not the owner.** The nvme-cli project did not build this rig. Its nightly workflow simply *reuses* the community's runner and VM machinery to get "free" real-drive coverage — in one job it runs both blktests and the nvme-cli e2e suite against the passed-through drive.

Why this matters: **Micron does not inherit the reason the stack is complex.** Micron's goal is to run `nvme-cli` against a real Micron drive — a tenant workload — which a single host-level rig delivers without any kernel-CI machinery. The drive is the *target* the tests run against, not the thing being qualified. (blktests rides along on the Linux rig but tests the kernel, not `nvme-cli`, and does not run on Windows — see [the two requirements](#what-micron-actually-needs-the-two-requirements) above.)

---

## Part 2 — The building blocks explained from zero

This is a tour of every technology in the upstream stack, in the order they build on each other. Each entry says **what it is**, in plain terms, and **why it's in the stack**.

### <a name="vm"></a>Virtual machine (VM) and hypervisor

A **virtual machine (VM)** is a complete fake computer that runs as a program inside a real computer. It has its own pretend CPU, memory, disk, and operating system, but it's really just software. The real computer is called the **host**; the fake computer running inside it is the **guest**.

A **hypervisor** is the software layer that creates and runs VMs. On Linux, the hypervisor is built into the kernel and is called **KVM** (Kernel-based Virtual Machine). On Windows, Microsoft's hypervisor is called **Hyper-V**.

*Why it's in the stack:* VMs give you the disposability and isolation the problem needs — you can create one, trash a drive inside it, and delete it without harming the host.

### <a name="qemu"></a>QEMU and libvirt

**QEMU** is the actual program that runs a VM (it emulates the fake hardware and, together with KVM, runs the guest). It's powerful but low-level — you drive it with long, fiddly command lines.

**libvirt** is a management layer over QEMU/KVM: it lets you define a VM in a config file and start, stop, and snapshot it through a stable interface, instead of hand-writing QEMU's long command line.

*Why it's in the stack:* QEMU/KVM is what every higher layer (including KubeVirt, below) ultimately uses to run a VM. libvirt is the "no Kubernetes" alternative we evaluate for Micron.

### <a name="iommu"></a>IOMMU (the hardware feature that makes passthrough safe)

Normally a VM only sees *fake* hardware. But we need the VM to touch a *real* SSD directly. That's dangerous: a device given direct hardware access could, in principle, read or corrupt any memory in the host. The **IOMMU** (I/O Memory Management Unit) is a hardware feature of the platform (standard on modern server systems) that acts as a *safety fence* — it restricts a physical device so it can only touch the memory belonging to the one VM it was assigned to.

- On Intel platforms this feature is called **VT-d**; on AMD it's called **AMD-Vi**. It usually has to be **turned on in the computer's BIOS/firmware**.
- The Linux kernel is told to use it with boot settings like `intel_iommu=on iommu=pt` (or `amd_iommu=on`).

*Why it's in the stack:* it is the mandatory precondition for safely handing a real SSD to a VM. No IOMMU, no passthrough.

### <a name="passthrough"></a>PCIe passthrough and vfio-pci

**PCIe** is the high-speed bus that connects an SSD (and GPUs, network cards, etc.) to the CPU. **PCIe passthrough** is the technique of detaching a physical PCIe device from the host operating system and giving it *directly and exclusively* to a guest VM. The guest then sees a real Micron NVMe controller, not a fake disk.

To do this on Linux you rebind the device from its normal driver to a special stub driver called **vfio-pci**. `vfio-pci` "parks" the device so the host ignores it, making it available for a VM to claim. You tell the kernel which devices to park with a boot setting like `vfio-pci.ids=1344:5410` (where `1344` is Micron's PCI vendor ID and `5410` would be a specific product ID — you find these with the `lspci` command).

Two wrinkles the upstream code handles:
- **Timing:** for some devices (notably SAS storage controllers) the normal driver grabs the device very early in boot, before `vfio-pci` gets a chance. Upstream forces `vfio-pci` to load first using kernel config files. For a plain NVMe SSD this is usually not needed.
- **A reboot is required** for these boot settings to take effect.

*Why it's in the stack:* this is the actual mechanism that delivers a real SSD into a VM. **This part is essential to any real-hardware VM approach — but it's plain Linux kernel functionality and does not require Kubernetes.**

### <a name="containers"></a>Containers, container images, and registries

A **container** is a lighter-weight cousin of a VM. Instead of faking a whole computer, it packages *just an application plus its files* and runs it isolated on the host's existing kernel. A **container image** is the frozen, shippable bundle those files come from. A **registry** is a server that stores and serves container images — like a package repository for containers. GitHub's public registry is `ghcr.io`; upstream also runs its **own private registry**.

A **containerdisk** is a KubeVirt-specific trick: it packages a *VM's disk image* inside a container image, so the same registry that ships containers can also ship the disk a VM boots from.

*Why it's in the stack:* the test VMs boot from containerdisks; the freshly-built kernels are shipped as containerdisks; and the private registry stores all of these close to the machines so they don't re-download from the internet constantly.

### <a name="kubernetes"></a>Kubernetes (k8s) and k3s

**Kubernetes** (abbreviated **k8s**) is a system for running lots of containers across a *fleet* of many machines. You tell it "I want these workloads running" and it decides *which machine* each one runs on, restarts them if they die, and manages their networking and storage. It is designed for operating **many machines as one pool**. **k3s** is a lightweight, easy-to-install version of Kubernetes (used by upstream).

Kubernetes has three terms worth fixing in mind:
- **node** — a single machine Kubernetes manages.
- **cluster** — the whole pool of machines it manages.
- **pod** — the unit of work it runs on a node (one or more containers scheduled together).

*Why it's in the stack:* upstream runs a **3-machine shared pool** feeding many concurrent test jobs. Kubernetes is the fleet manager that schedules each job's VM onto whichever machine physically holds the requested drive. **This is the single biggest source of complexity — and it only earns its keep when you have multiple machines and many concurrent jobs.**

### <a name="kubevirt"></a>KubeVirt

Kubernetes was built to run *containers*, not *VMs*. **KubeVirt** is an add-on that teaches Kubernetes to also run full virtual machines (via QEMU/KVM under the hood). It also includes a **device plugin** that advertises "this machine has a Micron SSD available for passthrough" so Kubernetes can schedule a VM onto the right machine, and a feature (`kernelBoot`) to boot a VM with a specific, externally-supplied kernel.

*Why it's in the stack:* it's the glue that lets the Kubernetes fleet manager run *passthrough VMs* and inject *arbitrary kernels*. If you remove Kubernetes, you remove KubeVirt too and use plain libvirt/QEMU instead.

### <a name="cdi"></a>CDI (Containerized Data Importer)

**CDI** is a KubeVirt companion that imports disk images into the cluster's storage. Minor supporting piece.

*Why it's in the stack:* used to load VM base images. Not needed if VMs boot directly from containerdisks.

### <a name="ansible"></a>Ansible

**Ansible** is an automation tool for *setting up machines*. You write "playbooks" (recipes) describing the desired state — install this, configure that — and Ansible applies them to your machines over SSH. It's how you build the cluster in the first place, as opposed to what runs on it.

*Why it's in the stack:* the entire upstream `blktests-ci` repository is essentially a big set of Ansible playbooks that install and configure everything described in this document.

### <a name="runners"></a>CI runners, GitHub Actions, and ARC

A **CI runner** is the machine/process that actually executes a CI job. GitHub's cloud runners are "hosted"; a runner you provide yourself is a **self-hosted runner**. **Actions Runner Controller (ARC)** is software that runs *self-hosted runners as Kubernetes pods*, automatically creating and destroying them on demand and scaling to zero when idle. (**GitLab Runner** is the equivalent for GitLab; upstream supports both, interchangeably.)

*Why it's in the stack:* ARC is what keeps a runner "alive" (as a pod) while it spawns and destroys the per-job test VMs — the workaround for the "can't reboot a runner" problem from [Part 1](#part-1--the-one-problem-in-plain-english).

### <a name="storage"></a>Longhorn and Rook-Ceph (cluster storage)

When you have many machines, you often want disk storage that is *replicated* across them, so a workload can move between machines and survive a machine failing. **Longhorn** and **Rook-Ceph** are two such distributed-storage systems (upstream uses Longhorn by default; Rook-Ceph is a documented alternative it doesn't actually enable). In Kubernetes terms they provide a **StorageClass** — a named kind of storage that workloads can request.

*Why it's in the stack:* multi-machine resilience for VM boot disks and cached images. **On a single machine this is pointless** — Kubernetes has a built-in "local-path" storage option that just uses the local disk.

### <a name="registry-svc"></a>Private container registry + CI binary cache

The **private registry** ([see containers](#containers)) stores images inside the cluster. The **CI binary cache** is a small web server inside the cluster that hands out command-line tools (`kubectl`, `virtctl`, `logcli`) to jobs so they don't re-download them from the internet every time.

*Why it's in the stack:* to avoid hammering the internet from a large fleet, and to keep working if the internet is slow or blocked. **On a single machine you install those tools once and skip both.**

### <a name="logging"></a>Loki, Grafana, Alloy (log collection)

**Grafana Loki** stores logs; **Alloy** ships logs into it; **Grafana** is the dashboard you view them in. Together they centralize logs from across the fleet — important because a test VM is *deleted* right after the job, taking its logs with it unless they were captured centrally.

*Why it's in the stack:* fleet-wide log history. Notably, upstream marks these as non-critical (the install is allowed to fail). **On a single machine you just read the VM's console/serial log directly.**

### <a name="mitmproxy"></a>mitmproxy (corporate-firewall support)

Many companies run a **[TLS](#tls)-inspecting firewall**: it intercepts encrypted internet traffic, decrypts it to inspect it, and re-encrypts it, using a company **[CA certificate](#ca)** that every internal machine is told to trust. Software that doesn't trust that certificate can't reach the internet. **mitmproxy** is a proxy upstream *optionally* deploys inside the cluster to make all the short-lived, auto-created VMs and pods route through one place and trust one certificate.

*Why it's in the stack:* it's an *optional* feature (off by default) for sites behind such a firewall. **Micron is such a site — but Micron already owns a real corporate proxy and CA, so the right move is to trust the existing Micron certificate, not stand up a second interceptor.** (More in [Part 8](#firewall).)

### <a name="kernel-pipeline"></a>Kernel-builder + kpd (patchwork automation)

Two upstream-specific subsystems:
- A nightly job that **downloads and compiles the latest Linux kernel** from Linus Torvalds' tree, with debugging features enabled, and packages it as a containerdisk.
- **kpd (kernel-patches-daemon):** watches the kernel-developer mailing lists for newly-emailed patches, automatically builds and tests each one on real hardware, and reports pass/fail back to the mailing list.

*Why it's in the stack:* this is pure **kernel-development** automation — testing proposed kernel changes before they're merged. **It has zero relevance to testing nvme-cli against a released kernel. Micron drops it entirely.**

### <a name="dda"></a>Hyper-V DDA (the Windows-native equivalent)

**Discrete Device Assignment (DDA)** is Microsoft's version of PCIe passthrough. On a Windows Server with Hyper-V, you "dismount" a physical device from the host (`Dismount-VMHostAssignableDevice`) and assign it to a VM (`Add-VMAssignableDevice`). It's the Windows-native way to hand a real SSD to a VM, and it requires server-class hardware.

*Why it's mentioned:* it's the alternative to running Windows tests inside the Linux/KubeVirt stack. We evaluate it as **[Config 4](#config-4)** in [Part 5](#part-5--recommended-approach-for-micron).

---

## Part 3 — How upstream does it, end to end

Now that the vocabulary exists, here is what actually happens for **one test run**. (Sources: the `blktests-ci` repository and the nvme-cli `run-nightly-tests.yml` workflow.)

**One-time setup (done by Ansible playbooks):**
1. Three server machines (Dell R6525, Ubuntu) are wired together into a **k3s** ([Kubernetes](#kubernetes)) cluster with fast (ConnectX-6) network cards.
2. Each machine's BIOS has **IOMMU** ([VT-d/AMD-Vi](#iommu)) enabled. A playbook edits each machine's kernel boot settings to turn on IOMMU and to **park the test SSDs on the `vfio-pci` driver** ([passthrough](#passthrough)), then the machine is rebooted.
3. **[KubeVirt](#kubevirt)** is installed on the cluster and told which physical SSD models are allowed to be passed through, each under a friendly name (e.g. `nvme-wdc-zn540`). KubeVirt then advertises "machine X has an `nvme-wdc-zn540` available."
4. Supporting services are installed on the cluster: [Longhorn storage](#storage), a [private registry](#registry-svc), the [binary cache](#registry-svc), [Loki logging](#logging), and (optionally) [mitmproxy](#mitmproxy).
5. **[ARC](#runners)** is installed on the cluster and connected to the GitHub repo, creating a "runner scale set" whose runners can be selected by a job.
6. A nightly job compiles the latest kernel into a [containerdisk](#containers) ([kernel-builder](#kernel-pipeline)).

**Every night, per test run:**
1. GitHub triggers the `run-nightly-tests` workflow. It asks for a runner tagged with the drive it needs (e.g. `nvme-wdc-zn540`) and a kernel version (`linus-master`).
2. **ARC** starts a runner **pod** on the cluster. That pod does *not* run the tests directly — it runs a script (the `kubevirt-action`) that provisions a VM.
3. The script writes out a VM definition and asks KubeVirt to create a **fresh VM**: 4 CPUs, 8 GB RAM, booting the requested kernel via `kernelBoot`, with the physical SSD **passed through** into it.
4. Kubernetes schedules that VM **onto the specific machine that physically has that SSD**.
5. The script waits for the VM to boot, then connects into it over SSH and runs a **device-prep script** (`prepare-nvme-devices.sh`) that wipes the SSD and creates one clean, full-capacity namespace, then exposes the drive to the test as an environment variable named **`BDEV0`** (or `ZBD0` for zoned/ZNS drives).
6. The actual tests run inside the VM: **blktests** and the **nvme-cli** test suite.
7. Results and logs are copied back out and uploaded as workflow artifacts; code-coverage data is uploaded to Codecov.
8. The **VM is deleted.** The next run starts from a clean slate.

That's the whole cycle. Note how many of the moving parts (steps 1–6 of setup) exist only because there are *three machines* and *arbitrary kernels* and *a corporate firewall*.

---

## Part 4 — Why is it so complex?

The complexity is real, but it is not arbitrary. It comes from **three needs upstream has that Micron very likely does not**:

| Upstream need | What it forces into the stack | Does Micron have this need? |
|---|---|---|
| **Boot any kernel, per job** | Disposable VMs, [KubeVirt](#kubevirt) `kernelBoot`, the nightly [kernel-builder](#kernel-pipeline), [kpd](#kernel-pipeline) patch automation | **No** — Micron tests a *fixed, released* kernel. |
| **Many machines, many concurrent jobs (shared pool)** | [Kubernetes/k3s](#kubernetes), the KubeVirt device-plugin scheduling, [Longhorn](#storage), [private registry](#registry-svc), [binary cache](#registry-svc), [Loki](#logging), fleet-recovery tooling | **No** — one or two machines, run at night. |
| **Ephemeral workloads behind a TLS-inspecting firewall** | in-cluster [mitmproxy](#mitmproxy) + a self-signed certificate injected everywhere | **Partly** — Micron *has* the firewall, but already owns the proxy + certificate, so it needs a much smaller solution. |

Here is the same idea as a component-by-component verdict. "Essential" means *you genuinely need it to test a drive*; "scale artifact" means *it only exists because of the three requirements above*.

| Component | Plain-language role | Verdict for a minimal Micron rig |
|---|---|---|
| **IOMMU + vfio-pci binding** | The safety fence + the mechanism that hands a real SSD to a VM | **Essential** (if using a VM at all). But it's plain Linux — no Kubernetes needed. |
| **QEMU/KVM + libvirt** | Runs the VM | **Essential** (if using a VM). |
| **KubeVirt** | Lets Kubernetes run passthrough VMs + inject kernels | **Scale artifact.** Only needed with Kubernetes and arbitrary kernels. |
| **Kubernetes / k3s** | Fleet manager for many machines | **Scale artifact.** Meaningless on one machine. |
| **ARC** | Keep the CI runner alive while spawning VMs | **Scale artifact.** A plain self-hosted runner (one per machine) replaces it. |
| **Kernel-builder + kpd** | Build/test in-development kernels | **Drop entirely.** Kernel-developer machinery, irrelevant to Micron. |
| **Longhorn / Rook-Ceph** | Replicated storage across machines | **Drop.** Use each machine's built-in local-disk storage. |
| **Private registry + binary cache** | Local copies of images/tools for a big fleet | **Drop.** Install tools once; import images locally. |
| **Loki / Grafana / Alloy** | Central logs across a fleet | **Drop.** Read the test VM's log directly. |
| **mitmproxy** | Uniform firewall traversal for ephemeral pods | **Replace** with "trust Micron's existing certificate + point at Micron's existing proxy." |

**Bottom line:** the essential core is small — a dedicated drive, a drive-prep script, and a test runner. Only if you consolidate both OSes onto one machine do you add the VM layer (IOMMU + vfio-pci + QEMU/KVM). Everything else is scale management or kernel-development automation Micron can shed.

---

## Part 5 — Recommended approach for Micron

Two decisions define the architecture, and they are **independent axes**:

1. **How much isolation does the rig need?** This turns on one question: *does Micron's CI ever run untrusted, outside-contributor code, or test unreleased kernels?* If not — the likely case for internal testing against a released kernel — the tests can run directly on the host. If yes, you need disposable-VM isolation, and at the extreme, the full upstream cluster.
2. **How is Windows covered?** Either one host runs both operating systems as VMs, or a second machine is dedicated to Windows.

Rather than present these as two separate menus, the sections below give the **end-to-end configurations** those axes actually produce, in increasing cost and complexity. **Config 1, 2, or 3 is the right starting point; escalate only if a concrete need forces it.** (The Windows-specific mechanics each configuration relies on are detailed in [Part 6](#part-6--windows-mechanics--drive-handling).)

### <a name="config-1"></a>Config 1 — Two bare-metal boxes (simplest)
One Linux box and one Windows box, each with its own dedicated, sacrificial Micron SSD. Tests run **directly on each host** — no VM, no passthrough, no Kubernetes. The Linux box runs `nvme-cli` + blktests against `/dev/nvmeX`; the Windows box runs the e2e suite against its physical `\\.\PhysicalDriveN`.
- **Machines / drives:** 2 machines, 1 drive each (2 drives total, one per host).
- **Isolation:** none — a catastrophic test bug could disrupt a box. Fine when each box is dedicated and the code is trusted-internal.
- **Windows fidelity:** highest — the drive behaves exactly as it would in a customer's Windows machine.
- **Build / maintain:** least of any option; nothing to virtualize.

### <a name="config-2"></a>Config 2 — One consolidated host, shared drive (fewest machines)
A single Linux host runs **both** operating systems, each inside a disposable [libvirt/QEMU](#qemu) VM with the SSD [passed through](#passthrough) ([IOMMU](#iommu) on, drive parked on `vfio-pci`). A Linux run boots a Linux VM; a Windows run boots a Windows VM — against the **same drive, sequentially**: a single passed-through drive has one owner at a time, so the runs alternate (wiped between).
- **Machines / drives:** 1 machine, 1 drive.
- **Isolation:** VM-level — the destructive tests can't harm the host, and it can boot a non-stock kernel when needed (QEMU boots a specific kernel directly, the same feature KubeVirt wraps).
- **Windows fidelity:** slightly lower — Windows runs in a KVM guest rather than on bare metal.
- **Build / maintain:** a small VM-launch script (salvage upstream's ~40-line host-binding logic and the `prepare-nvme-devices.sh` drive-prep script), **plus** a Windows VM image (`virtio-win` drivers, unattended first-boot, OpenSSH, UEFI firmware) and Windows licensing/activation.

### <a name="config-3"></a>Config 3 — One consolidated host, one drive per OS (concurrent)
The same single-host passthrough setup as [Config 2](#config-2), but with **two drives — one bound to each VM**. Because each VM owns its own drive, the Linux and Windows runs execute **concurrently** rather than sequentially, removing the one-drive bottleneck.
- **Machines / drives:** 1 machine, 2 drives.
- **Isolation:** VM-level, same as Config 2.
- **Windows fidelity:** same as Config 2 — Windows in a KVM guest.
- **Build / maintain:** same as Config 2, plus a second passed-through drive. Micron builds its own drives and the group already has spare hosts/drives, so the extra drive is a cost input, not a blocker.

### <a name="config-4"></a>Config 4 — Separate Hyper-V/DDA Windows host (only if required)
The Linux rig (bare-metal or single-VM) plus a **dedicated Windows Server** machine using Microsoft's native [DDA](#dda) passthrough for the Windows runs.
- **Machines / drives:** 2 machines; a drive cannot move between them without manual re-cabling and a reboot, so in practice 1 drive per host.
- **When:** only if Micron IT policy forbids running Windows under Linux/KVM *and* the native Microsoft-supported path is required.
- **Cost:** a second, server-class machine plus a separate automation stack to maintain.

### <a name="config-5"></a>Config 5 — Full upstream cluster (only if scale demands)
Adopt the upstream KubeVirt/Kubernetes stack **only if all three are true at once:** many drives/machines tested *concurrently*, a per-job *arbitrary-kernel* matrix, **and** isolation of *untrusted outside code*. Absent all three, this is far more machinery — and more security-review liability (privileged containers, an insecure internal registry, a self-signed certificate, broad GitHub permissions) — than the job requires.

**Choosing among Config 1, 2, and 3:** all three are solid; the difference is **cost vs. fidelity vs. throughput**. Config 1 is two simple machines, the most faithful Windows setup, and nothing to virtualize. Config 2 is one machine (adds a Windows VM image to build and maintain) running the two OSes sequentially against a single drive. Config 3 is that same machine with a second drive, trading a drive's cost for concurrent Linux and Windows runs. Machine and drive count is a cost input — above this investigation's pay grade — so all three are presented as valid choices; the BOM/budget decision belongs to the infrastructure owner.

---

## Part 6 — Windows mechanics & drive handling

Upstream runs only on Linux; the Windows path has no upstream precedent and must be designed. The configurations in [Part 5](#part-5--recommended-approach-for-micron) rest on a few Windows-specific facts. Two set the scope:
- **blktests is a Linux-kernel test suite and does not run on Windows.** Only the **nvme-cli** tests have a Windows counterpart.
- **The test code is already Windows-ready.** nvme-cli builds on Windows (Windows build jobs run in CI), and the e2e test suite is Windows-aware: it detects the platform (`is_windows()`), skips commands Windows does not support (Compare, Verify, Write Zeroes, Write Uncorrectable, and integral-attribute DSM), takes the target device as a parameter rather than assuming `/dev/nvme0`, guards its Linux-only `/sys` PCI check, and includes Windows-specific expected results in the Micron plugin tests. The remaining work is **infrastructure and CI wiring**, not test-code porting.

### <a name="reprovision"></a>Can a drive be re-provisioned between a Windows run and a Linux run automatically?
Two separate questions:
- **Wiping the media between runs:** **Yes, fully automatable.** `nvme format` and `nvme sanitize` are controller-level commands that work identically from Linux or Windows; the existing drive-prep script already does this reset at the start of every run.
- **Handing the physical drive from one OS to the other:**
  - **[Config 2](#config-2) / [Config 3](#config-3) (one consolidated host):** the drive(s) never move — they stay attached to the one host, and "Windows vs Linux" is just *which VM image boots* (Config 2) or *which VM owns which drive* (Config 3). **Fully automatable, no human, no reboot.**
  - **[Config 4](#config-4) (separate Hyper-V/DDA host):** the drive is physically bound to *different machines* for Windows vs Linux. Switching means unbind → re-cable/move → rebind → reboot. **Manual**, unless each machine has its own drive.
  - **[Config 1](#config-1) (two bare-metal boxes):** Windows and Linux run on *different machines* with their own dedicated drives, so no handoff happens — each side wipes its own drive at the start of its run. No sharing, no manual step.

### <a name="windows-device"></a>How is the drive identified to the test on Windows?
On Linux, upstream injects the drive via the `BDEV0` environment variable ([Part 3](#part-3--how-upstream-does-it-end-to-end)). The nvme-cli **e2e suite itself, however, does not read `BDEV0`** — it takes the device as explicit **`--controller` / `--ns1`** parameters (e.g. `--controller /dev/nvme0 --ns1 /dev/nvme0n1`), which the harness fills in.
- **On Windows** the same parameters take the Windows physical-disk path — **`\\.\PhysicalDriveN`** — which is how nvme-cli/libnvme address a controller on Windows (`libnvme/src/nvme/scan-win.c`, `tree-win.c`). The runner enumerates which `PhysicalDriveN` the passed-through Micron drive received (e.g. via `Get-PhysicalDisk`/WMI) and passes that as `--controller`/`--ns1`.
- **Drive prep is OS-agnostic:** `nvme format` and `nvme sanitize` are controller-level commands that behave identically on Windows, so the reset step needs no Windows-specific logic — only the device path differs.

---

## Part 7 — Rough bill of materials & effort estimate

> ⚠️ **Draft estimates — to be validated with Kevin Kennedy and Micron IT.** These are order-of-magnitude, for the ART request.

**Hardware ([Config 2](#config-2) / [Config 3](#config-3) — single consolidated host):**
- 1 × server-class machine with a CPU/board supporting **[IOMMU](#iommu)** (Intel VT-d or AMD-Vi) — this is standard on server platforms.
- 1+ × **dedicated/sacrificial Micron NVMe SSD(s)** for testing, in **non-boot** slots. (One per drive model you want covered; a ZNS model too if you test zoned. Config 3 needs at least two so Linux and Windows runs can go concurrently.)
- A separate boot drive for the host OS.
- No special networking or switch requirements at single-node scale. (Upstream's ConnectX-6 NICs and 3-node cluster are scale features you don't need.)

> This BOM is for the **single consolidated host** ([Config 2](#config-2), one shared drive; [Config 3](#config-3), one drive per OS). **[Config 1](#config-1)** (two bare-metal boxes) instead uses two simpler machines — one Linux, one Windows — each with its own dedicated Micron drive, and needs no IOMMU/passthrough.

**Software (all open-source, no license cost except Windows):**
- Linux host OS; QEMU/KVM + libvirt (Config 2 / Config 3); a self-hosted CI runner.
- **Windows Server license + activation** (KMS/MAK) for the Windows test VM under Config 2 / Config 3.

**Rough effort (engineering):**
- Config 1 bare-metal rig + wire up a self-hosted runner: **small** (days).
- Config 2 / Config 3 passthrough + VM-launch script (salvaging upstream's host-binding + drive-prep logic): **small–medium** (≈1–2 weeks).
- Build + maintain the **Windows test VM image** (drivers, unattended boot, OpenSSH, nvme-cli): **medium**.
- Wire up the CI job that runs the existing Windows-aware e2e suite against the drive: **small**. (The test code already runs on Windows; a short gap-review confirms which commands stay skipped versus become testable.)
- Approvals (ART architecture + security review, IT provisioning): **calendar time, not engineering time** — start early.

---

## Part 8 — External dependencies & approvals (what ART will want)

**Architecture review will want to see:**
- The chosen configuration (Config 1–5), with this document's justification.
- A network/data-flow description: what the rig talks to (GitHub/internal Git, any image sources) and through which proxy.
- The single-node vs cluster decision and why.

**Security review will want to see (and these are the upstream red flags to explicitly *not* inherit):**
- **Untrusted-code isolation:** whether outside-contributor PRs can ever run on this hardware. If yes, the ephemeral-VM isolation and GitHub "require approval for outside collaborators" settings matter; if no, the risk drops sharply.
- **Privileged containers:** upstream runs privileged Docker-in-Docker containers — a likely policy violation. Only the full upstream cluster (Config 5) brings these; Configs 1–4 avoid them entirely.
- **Insecure internal registry:** upstream's registry runs over plain HTTP — avoid by not having one.
- **TLS interception:** do **not** stand up a second in-cluster interceptor with a self-signed certificate; instead trust Micron's existing corporate CA and route through Micron's existing proxy.
- **CI credential scope:** if using GitHub, the runner needs a GitHub App or token — scope it to the single repo with least privilege (the upstream README documents the exact minimal permission set).
- **Supply chain:** where do container/VM base images come from; pin versions (no `:latest`); mirror or vet anything pulled from the public internet.

**External dependencies / open questions for Micron (need Kevin Kennedy — IT MFG):**
- <a name="firewall"></a>**Firewall/proxy:** the corporate CA certificate and proxy endpoint; whether the rig sits inside or outside the corporate firewall; whether outbound GitHub/registry access is permitted or must be mirrored internally.
- **Git host:** GitHub.com vs a Micron-internal Git host (changes the runner setup).
- **Bare-metal provisioning + reboot approval:** IT process for a dedicated lab machine and for the one-time reboot needed to enable passthrough.
- **Windows licensing:** a Windows license + activation for whichever Windows test environment the chosen config uses (a KMS-activatable Windows Server image from IT for the Config 2 / Config 3 VM, or a license for the bare-metal/DDA Windows box under Config 1/Config 4).
- **Whether an existing Micron VM farm or lab could host this** instead of new hardware.
- **Contribute-to-upstream question:** can Micron borrow capacity from / donate drives to the upstream cluster instead of building its own? Likely **no** for internal-only firmware, but worth confirming as it may cover *public* firmware testing cheaply.

---

## Part 9 — Proposed follow-up JIRAs

*(Investigation only under TACT-70; these are the build tickets.)*

1. **Confirm requirements with Kevin Kennedy** — firewall/proxy, Git host, bare-metal provisioning, Windows licensing, existing-lab reuse. *(Blocks the rest.)*
2. **File the ART architecture + security review** (Brandon Busacker to initiate) using this document as input.
3. **Gap-review the Windows e2e coverage** — confirm which nvme-cli commands stay skipped versus become testable on Windows, and add coverage where the Windows path is exercisable. *(Independent of infrastructure.)*
4. **Stand up the Config 1 bare-metal Linux rig** + self-hosted runner; get Linux nvme-cli + blktests running nightly against a Micron drive.
5. **(If isolation required) Add Config 2 / Config 3 passthrough + VM-launch script**, salvaging upstream's host-binding and drive-prep logic.
6. **Build the Windows test VM image** (drivers, unattended boot, OpenSSH, nvme-cli) — Config 2 / Config 3.
7. **Wire up the Windows nvme-cli e2e run** against the same drive; automate the `nvme format`/`sanitize` reset between Windows and Linux runs.

---

## Glossary

| Term | Plain-language meaning |
|---|---|
| **Alloy** | Agent that ships logs into Loki. |
| **AMD-Vi (AMD Virtualization for I/O)** | AMD's name for the [IOMMU](#iommu) feature. |
| **Ansible** | Automation tool that configures machines from recipe files ("playbooks"). |
| **ARC (Actions Runner Controller)** | Software that runs GitHub CI runners as disposable Kubernetes pods, auto-created per job. |
| **ART (Architecture Request Tracker)** | Micron's intake and tracking system for architecture and security governance reviews. |
| **BDEV0 / ZBD0** | Environment variables the rig sets to tell the test which drive to use (`ZBD0` = a zoned/ZNS drive). |
| **BIOS (Basic Input/Output System) / firmware** | The low-level software on a machine's motherboard; where IOMMU is enabled. |
| **blktests** | A Linux-kernel storage test suite. Linux-only. |
| **BOM (bill of materials)** | The list of hardware and software a rig requires. |
| **<a name="ca"></a>CA (Certificate Authority) certificate** | A trust anchor; software checks it to decide whether to trust an encrypted connection. |
| **CDI (Containerized Data Importer)** | KubeVirt add-on that imports VM disk images into the cluster. |
| **CI (Continuous Integration)** | Automated build/test triggered by code changes. |
| **Container** | A lightweight package of an app + its files, run isolated on the host's kernel. |
| **Container image** | The frozen, shippable bundle a container starts from. |
| **containerdisk** | A VM disk image packaged as a container image so a registry can serve it. |
| **DDA (Discrete Device Assignment)** | Microsoft/Hyper-V's version of PCIe passthrough. |
| **Guest** | The virtual machine (as opposed to the host it runs on). |
| **Host** | The real physical machine running the VM(s). |
| **Hyper-V** | Microsoft's hypervisor (VM engine) for Windows. |
| **Hypervisor** | Software that creates and runs virtual machines. |
| **IOMMU (I/O Memory Management Unit)** | Platform hardware feature that fences a passed-through device so it can only touch its VM's memory. |
| **k3s** | A lightweight, easy-to-install version of Kubernetes. |
| **k8s (Kubernetes)** | System for running many containers/VMs across a fleet of machines. |
| **kpd (kernel-patches-daemon)** | Upstream automation that tests emailed kernel patches and reports to mailing lists. |
| **KubeVirt** | Add-on that lets Kubernetes run full VMs (and pass through devices, boot custom kernels). |
| **KVM (Kernel-based Virtual Machine)** | The Linux kernel's built-in hypervisor. |
| **kernelBoot** | KubeVirt feature to boot a VM with a specific, externally-supplied kernel. |
| **libvirt** | Friendly management layer over QEMU/KVM. |
| **Loki / Grafana** | Log storage (Loki) and dashboard (Grafana). |
| **Longhorn / Rook-Ceph** | Distributed storage systems that replicate data across cluster machines. |
| **mitmproxy (man-in-the-middle proxy)** | A proxy that lets many workloads traverse a TLS-inspecting firewall with one trusted certificate. |
| **namespace (NVMe)** | A logical partition of an NVMe SSD presented as a block device. |
| **node** | A single machine within a Kubernetes cluster. |
| **NVMe (Non-Volatile Memory Express)** | The protocol/interface modern SSDs use over PCIe. |
| **PCIe (Peripheral Component Interconnect Express)** | The high-speed bus connecting SSDs, GPUs, NICs to the CPU. |
| **PCIe passthrough** | Giving a physical PCIe device directly and exclusively to a VM. |
| **pod** | The unit of work Kubernetes runs (one or more containers together). |
| **QEMU (Quick Emulator)** | The program that actually runs a VM (emulates the hardware). |
| **registry** | A server that stores and serves container images. |
| **runner (CI)** | The machine/process that executes a CI job. "Self-hosted" = one you provide. |
| **StorageClass** | A named kind of storage a Kubernetes workload can request. |
| **<a name="tls"></a>TLS (Transport Layer Security)-inspecting firewall** | A corporate firewall that decrypts, inspects, and re-encrypts internet traffic. |
| **UEFI (Unified Extensible Firmware Interface)** | Modern boot firmware that replaces the legacy BIOS; Windows guests require it. |
| **vfio-pci (Virtual Function I/O)** | The Linux driver that "parks" a device so a VM can claim it for passthrough. |
| **VM (virtual machine)** | A complete fake computer running as software inside a real one. |
| **VT-d (Virtualization Technology for Directed I/O)** | Intel's name for the [IOMMU](#iommu) feature. |
| **ZNS (Zoned Namespace)** | A type of NVMe namespace organized into sequential-write zones. |

---

## Appendix — Source references (upstream `blktests-ci`)

For reviewers who want to verify specifics against the upstream code:

- **Architecture rationale (why fresh VM per job):** `README.md` lines 47–58.
- **PCIe passthrough / host binding:** `playbooks/roles/configure-physical-k8s-cluster-node/tasks/main.yaml` (IOMMU args, `vfio-pci.ids` derivation, initramfs handling); `playbooks/roles/k8s-install-kubevirt/tasks/kubevirt-config.yaml` (allowed device list).
- **Per-job VM lifecycle:** `.github/actions/kubevirt-action/{action.yaml,entrypoint.sh,vars.sh}` and `.../templates/vm.yaml.j2`, `vm-init.sh.j2`.
- **Drive-prep / `BDEV0` injection:** `prepare-nvme-devices.sh`, embedded in `playbooks/roles/k8s-install-kubevirt-actions-runner-controller/tasks/main.yaml`.
- **Runner setup + security hardening checklist:** `README.md` lines ~436–600.
- **Kernel-builder + kpd:** `playbooks/roles/kernel-builder-k8s-job/` and `playbooks/roles/k8s-install-kernel-patches-daemon/`.
- **Cluster services:** `playbooks/install-k8s-requirements.yaml` and the `k8s-install-*` roles.
- **Corporate proxy:** `playbooks/roles/k8s-install-mitmproxy/`.
- **GitLab alternative:** `ci/gitlab/kubevirt.gitlab-ci.yml`.
- **nvme-cli nightly workflow (the consumer):** `linux-nvme/nvme-cli` → `.github/workflows/run-nightly-tests.yml`.
