# [TACT-70] PCIe DDA / Passthrough VM CI for NVMe Testing (Linux & Windows)

## Goal
We want to enable a VM inside Micron that supports DDA (Discrete Device Assignment / PCIe device passthrough) testing of NVMe drives, so we can run nvme-cli and blktests against real hardware from an automated CI job.
**Both Windows and Linux must be supported as test targets.** See the _Windows and Linux_ section below — this is the main place where we diverge from upstream, which is Linux-only.
The upstream linux-nvme community already does exactly this on the Linux side: WDC hosts the hardware and hands physical NVMe SSDs to ephemeral VMs. This task is to investigate their implementation and report back what Micron would need to stand up an equivalent.

## Starting point
Upstream nightly workflow: https://github.com/linux-nvme/nvme-cli/blob/master/.github/workflows/run-nightly-tests.yml
Key observations:
* The job runs on a self-hosted runner labelled `arc-vm-nvme-cli` (GitHub Actions Runner Controller, i.e. an ARC runner scale set backed by Kubernetes).
* It checks out `linux-blktests/blktests-ci` and uses the composite action `./.github/actions/kubevirt-action` to boot the VM.
* Devices are requested by logical name via the `host_devices` input — e.g. `"nvme-wdc-zn540,nvme-wdc-sn640"`.
* `kernel_version: linus-master` — the kernel is prebuilt nightly by a cron job on the k8s cluster and shipped to the VM as a KubeVirt containerdisk.
* `run_cmds` is the script executed inside the VM; the assigned namespace shows up as the `$BDEV0` env var.
* `vm_artifact_upload_dir` pulls results back out as workflow artifacts.
* The second job step runs the nvme-cli e2e/plugin tests (including the `micron` plugin) inside a privileged podman container in that same VM.

## Supporting infrastructure repo
The actual passthrough plumbing lives in https://github.com/linux-blktests/blktests-ci (Ansible playbooks; author Dennis Maisenbacher, WDC). Relevant pieces to review:
* `README.md` — Architecture section, _Declare PCIe passthrough devices_, _Add PCIe passthrough devices_, _GitHub runner scale sets_.
* `playbooks/roles/k8s-install-kubevirt/tasks/kubevirt-config.yaml` — `pciHostDevices` is the single source of truth for which PCIe devices KubeVirt may hand to a VM.
* `playbooks/roles/configure-physical-k8s-cluster-node/tasks/main.yaml` — derives the `vfio-pci.ids=` kernel argument from that list and binds devices to `vfio-pci` on the bare-metal host at boot.
* `.github/actions/kubevirt-action/` — `action.yaml`, `entrypoint.sh`, `vars.sh`: renders the VM manifest, boots it, SSHes in, runs the commands, uploads artifacts, tears the VM down.
* `playbooks/roles/k8s-install-kubevirt-actions-runner-controller/templates/vm.yaml.j2` — the VM template (note the `disable-hostdev-rom` KubeVirt sidecar hook).
* `ci/gitlab/kubevirt.gitlab-ci.yml` — a GitLab-runner equivalent of the same flow, in case we prefer GitLab CI over GitHub ARC.
* The corporate-proxy (mitmproxy) support — likely relevant behind Micron's TLS-inspecting firewall.

## Windows and Linux
We need to test on both OSes. Upstream has **no** Windows path, so there is no precedent to copy here — this part has to be designed. Two broad options to evaluate:
1. **One Linux host, both guests.** Keep the KubeVirt/QEMU + `vfio-pci` host stack from upstream and boot a Windows guest instead of a Fedora one for the Windows runs. KubeVirt does support Windows guests with PCI passthrough. Upside: one hardware pool, one orchestration layer, one set of playbooks. To verify: virtio/NVMe driver availability in the guest, whether the Windows-side test tooling runs unattended, guest licensing, and how we inject the equivalent of `$BDEV0` on Windows.
2. **Separate Hyper-V host using Windows DDA.** Hyper-V's Discrete Device Assignment (`Dismount-VMHostAssignableDevice` / `Add-VMAssignableDevice`) is the native Windows equivalent. Upside: first-class Microsoft-supported path, likely more familiar to Micron IT. Downside: a second, completely separate hardware pool and automation stack, and drives can't be shared between pools without physically moving them.

Call out explicitly which of these you recommend and why, since it drives the hardware BOM (one pool vs. two) and therefore the architecture review.
Also worth determining: is drive re-provisioning between a Windows run and a Linux run automatable (format/sanitize between jobs), or does switching OS require manual intervention?

## Contacts and internal process
* **Kevin Kennedy** (kkennedy@micron.com), IT MFG — start here. Kevin is the most experienced with Micron's setup and with enabling GitHub runners internally.
* **James Vineyard** (jvineyard@micron.com) — guidance: running this testing against upstream requires an architecture review and security review via ART (http://art).
* Brandon Busacker can kick off the ART request once the design is set.

## Questions to answer
1. Why a fresh VM per job at all? Does that reasoning apply to us?
2. What is the minimum hardware footprint? Could we do this on one node, and what do we give up? Does supporting Windows change the answer?
3. What is the full software stack we'd have to own (k3s, KubeVirt + CDI, Longhorn/Rook Ceph, container registry, ARC/GitLab Runner, Loki, binary cache)?
4. How does PCIe passthrough work end to end (IOMMU groups, `vfio-pci` binding, KubeVirt `pciHostDevices`, reboot requirements)?
5. How is a drive identified to the test (`BDEV0` injection, `prepare-nvme-devices.sh`, runner labels)? What is the Windows equivalent?
6. What are the Micron-specific blockers (bare-metal host approvals, firewall/mitmproxy, self-hosted runner security, internal vs github.com git host)?
7. Alternatives: Hyper-V DDA, plain libvirt/QEMU with `vfio-pci` without Kubernetes, or reusing existing Micron VM farms.
8. Can we contribute drives to or borrow capacity from the upstream cluster instead?

## Deliverable
A written summary covering:
* How upstream implements it.
* Recommended option for Micron covering **both Windows and Linux**, with rough BOM and effort estimate.
* External dependencies and approvals needed (ART architecture and security reviews).
* Proposed set of follow-up Jira issues to build it.
