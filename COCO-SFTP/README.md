# COCO-SFTP Runtime Tree

`COCO-SFTP` is the local tree that should be mirrored to the remote OpenCCA
host as `/root/COCO-SFTP`. The name is intentional: it identifies this as the
Confidential Containers runtime payload, not a temporary transfer folder.

## Directory Map

| Path | Role | Rebuild or restore path |
| --- | --- | --- |
| `cni/bin/` | Fixed CNI plugin binaries for containerd networking. | Download/restore as a fixed container stack artifact. |
| `configs/cni/` | Remote CNI network configuration consumed by containerd. | Maintained in this tree. |
| `configs/containerd/` | Host containerd configuration for `guest-pull` and Kata. | Maintained in this tree. |
| `configs/kata-containers/` | Host Kata configuration for Firecracker/QEMU CCA runs. | Maintained in this tree; defaults reference `/root/COCO-SFTP`. |
| `firecracker-bins/` | Firecracker binary, guest kernel Image, and direct VM test configs. | `../scripts/build/build-firecracker.sh` and `../scripts/build/build-linux-image-share.sh`. |
| `guest-pull/` | Host-side guest-pull snapshotter binaries. | `../scripts/build/build-guest-pull-snapshotter.sh`. |
| `images/` | Guest rootfs images used by Firecracker/Kata. Guest components are installed into `kata-containers-cca.img` locally. | `../scripts/image/install-guest-components-into-kata-image.sh` uses offline `debugfs` by default. |
| `kata-bins/` | Host-side Kata runtime binaries. | `../scripts/build/build-kata-containers.sh`. |
| `linux-host-kernel/` | Reserved for future host OpenCCA kernel transfer materials. Not installed by the default runtime installer. | Managed by future board/kernel scripts. |
| `nerdctl-bin/` | Host nerdctl binary and rootless helper scripts. | Fixed artifact unless a nerdctl source tree is added later. |
| `opencca-assets/` | Reserved for future firmware/RMM/U-Boot transfer materials. Not installed by the default runtime installer. | Managed by future board/firmware scripts. |
| `qemu-bins/` | QEMU/kvmtool experiments and fixed helper binaries. | Fixed artifacts in the current workspace. |
| `log/` | Runtime logs on the remote host. | Generated on the remote host; excluded from normal sync. |
| `scripts/remote/check/` | Remote preflight checks for the copied COCO-SFTP tree and host base services. | Maintained in this tree. |
| `scripts/remote/install/` | Remote install scripts for the host-side runtime stack. | Maintained in this tree. |
| `scripts/remote/run/` | Remote runtime start and smoke-test entrypoints. | Maintained in this tree. |

## Remote Contract

The default remote runtime root is:

```bash
/root/COCO-SFTP
```

Scripts use this name by default and can be overridden with:

```bash
COCO_ROOT=/custom/path ./scripts/remote/install/all.sh
```

Local build and packaging scripts use:

```bash
COCO_SFTP_ROOT=/path/to/COCO-SFTP
COCO_SFTP_REMOTE_ROOT=/root/COCO-SFTP
```

## Common Local Commands

Run these from the workspace root, one directory above `COCO-SFTP/`:

```bash
./scripts/run/coco-local-flow.sh
./scripts/run/coco-local-flow.sh --check-prereqs
./scripts/run/coco-local-flow.sh --component guest-components
./scripts/run/coco-local-flow.sh --build
./scripts/run/coco-local-flow.sh --build --skip firecracker
./scripts/deploy/update-remote-component.sh --component kata --remote-reinstall --remote-restart
```

Remote sync is intentionally separate:

```bash
./scripts/run/coco-local-flow.sh --sync
```

Do not run the sync script while the board is unreachable.
Default sync excludes `linux-host-kernel/` and `opencca-assets/`; those are for
future board-level scripts.

On the remote board, install host-side binaries and configs with:

```bash
cd /root/COCO-SFTP
./scripts/remote/check/preflight.sh
./scripts/remote/install/all.sh
./scripts/remote/run/start-container-runtime.sh
```

That default install intentionally excludes firmware and host-kernel changes.
Those board-level operations should be handled by separate scripts.

After the runtime services are active, run the design-level image-cache smoke
test with:

```bash
./scripts/remote/run/run-image-cache-smoke.sh
```

The smoke test starts one Image CVM with
`io.kata-containers.is-image-cvm=true` and one Runtime CVM with
`io.kata-containers.is-image-cvm=false`, both through `guest-pull` and
`io.containerd.kata.v2`.

Before a remote machine is reachable, the local structure can still be checked:

```bash
../scripts/package/check-coco-sftp.sh
../scripts/package/check-remote-install-flow.sh
```
