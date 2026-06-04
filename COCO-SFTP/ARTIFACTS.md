# COCO-SFTP Artifact Policy

This file records which payloads are source-built and which are fixed runtime
artifacts. The goal is that every file in `COCO-SFTP` is either rebuildable,
restorable, or deliberately generated at runtime.

## Source-Built Components

| Component | Source tree | Install target |
| --- | --- | --- |
| Firecracker CCA VMM | `../Firecracker-CCA` | `firecracker-bins/firecracker` |
| Shared guest kernel | `../linux-image-share` | `firecracker-bins/Image` |
| Kata runtime/shim/monitor | `../kata-containers-cca/src/runtime` | `kata-bins/` |
| Guest Components | `../guest-components` | Stripped binaries and configs in `../artifacts/guest-components/`, then local `debugfs` install into `images/kata-containers-cca.img` |
| Guest-pull snapshotter | `../guest-pull-snapshotter` | `guest-pull/` |
| OpenCCA firmware/kernel outputs | `../opencca/snapshot` | Out of scope for the default COCO-SFTP runtime installer; keep future board-level scripts separate. |

## Fixed Runtime Artifacts

These files are downloaded or restored as a known-good container stack and are
only organized here. Existing scripts should not rebuild them until a source
tree is added to the workspace:

| Path | Notes |
| --- | --- |
| `cni/bin/*` | CNI plugin set from official `containernetworking/plugins` linux-arm64 release; provenance is recorded in `cni/SOURCE.md`. |
| `configs/cni/*.conf` | CNI network configuration installed to `/etc/cni/net.d`. |
| `nerdctl-bin/*` | nerdctl and helper scripts. |
| `images/*.img`, `images/*.ext4` | Guest images/rootfs files. |
| `qemu-bins/*` | QEMU/kvmtool binaries and experiments. |

The local flow checks these fixed artifacts with
`../scripts/package/check-coco-sftp.sh`; it does not modify or rebuild them.

## Generated Files

| Path | Notes |
| --- | --- |
| `MANIFEST.generated.txt` | Written by `../scripts/package/prepare-coco-sftp.sh`. |
| `log/` | Remote runtime logs, excluded from normal sync. |
| `images/mnt-*` | Temporary mount points, not source artifacts. |

## Remote Install Entrypoints

Use `scripts/remote/install/all.sh` on the remote host to install the host-side
runtime stack from `/root/COCO-SFTP`. Guest-side binaries are not installed on
the remote host directly; they are injected into the Kata guest image locally
with `../scripts/image/install-guest-components-into-kata-image.sh`.

The default remote install is deliberately scoped to the container runtime
stack: CNI, containerd/Kata configs, guest-pull snapshotter, Kata binaries, and
nerdctl. Host kernel and firmware flashing are out of scope for this installer.

Run `scripts/remote/check/preflight.sh` before installing on a copied remote
tree. Run `scripts/remote/run/start-container-runtime.sh` after installing to
restart `guest-pull-snapshotter` and `containerd` in the order expected by the
containerd proxy snapshotter configuration. Run
`scripts/remote/run/run-image-cache-smoke.sh` to exercise the design-level
Image CVM and Runtime CVM annotations.
