# COCO Runtime Build And Deploy

This document describes the runtime workflow owned by `COCO-SFTP`.
Host kernel module installation and firmware flashing use separate board-level
scripts because they affect the running RK3588 system, not just the runtime
payload under `/root/COCO-SFTP`.

## Scope

`COCO-SFTP` installs and updates these remote runtime pieces:

| Piece | Local source or artifact | Remote install target |
| --- | --- | --- |
| CNI plugins and config | `COCO-SFTP/cni/`, `COCO-SFTP/configs/cni/` | `/opt/cni/bin`, `/etc/cni/net.d` |
| containerd config | `COCO-SFTP/configs/containerd/config.toml` | `/etc/containerd/config.toml` |
| Kata config | `COCO-SFTP/configs/kata-containers/configuration-fc.toml` | `/etc/kata-containers/configuration.toml`, `/opt/kata/share/defaults/kata-containers/configuration.toml` |
| Kata runtime/shim/monitor | `kata-containers-cca/src/runtime` | `/opt/kata/bin`, `/usr/local/bin/containerd-shim-kata-v2` |
| guest-pull snapshotter | `guest-pull-snapshotter` | `/usr/local/bin`, `guest-pull-snapshotter.service` |
| nerdctl | `COCO-SFTP/nerdctl-bin/` | `/usr/local/bin` |
| Firecracker VMM | `Firecracker-CCA` | Used in place from `/root/COCO-SFTP/firecracker-bins/firecracker` |
| guest kernel for CVMs | `linux-image-share` | Used in place from `/root/COCO-SFTP/firecracker-bins/Image` |
| Kata guest image | `COCO-SFTP/images/kata-containers-cca.img` | Used in place by Kata config |
| guest-components | `guest-components` | Built locally, then injected into `kata-containers-cca.img` |

The remote base system must already provide `systemd`, `containerd`, and a
working `containerd.service`. `COCO-SFTP` installs the containerd config, not
the containerd package itself.

## Local Build

Check local prerequisites for the runtime stack:

```bash
./scripts/build/check-build-prereqs.sh
```

Build every runtime component and verify the deployable tree:

```bash
./scripts/build/build-all.sh
```

Equivalent flow with optional sync/archive controls:

```bash
./scripts/run/coco-local-flow.sh --build
```

Build one component after code changes:

```bash
./scripts/run/coco-local-flow.sh --component kata
./scripts/run/coco-local-flow.sh --component guest-pull-snapshotter
./scripts/run/coco-local-flow.sh --component guest-components
./scripts/run/coco-local-flow.sh --component firecracker
./scripts/run/coco-local-flow.sh --component linux-image-share
```

`guest-components` are special: the build output lands in
`artifacts/guest-components/`, then
`scripts/image/install-guest-components-into-kata-image.sh` injects those
binaries and configs into `COCO-SFTP/images/kata-containers-cca.img`.

`guest-components/image-rs` is linked into more than one guest binary. Changes
under `image-rs` that affect Runtime CVM behavior, such as image sharing RPC,
RMM share metadata, rootfs image creation, or mount logic, must be rebuilt into
both sides:

```bash
./scripts/build/build-guest-components.sh
./scripts/build/build-kata-agent.sh
./scripts/image/install-guest-components-into-kata-image.sh
./scripts/image/install-kata-agent-into-kata-image.sh
COCO_REMOTE_PASSWORD=root ./scripts/deploy/sync-coco-sftp.sh
```

Rebuilding only `guest-components` updates the Image CVM service binaries, but
does not update the Runtime CVM `kata-agent`. A common symptom is that the
remote log still shows an old path or old control flow from `image-rs`, for
example `/run/kata-containers/<cid>/shared-rootfs-image/...`, even after the
local `image-rs` code has been changed.

The old `read_rootfs_chunk` copy-mode path has been removed from the default
ImageCache control plane. A Runtime CVM should fail loudly if the RMM share fast
path does not return `share_id` and `source_rd_addr`; do not silently re-add the
copy-mode path as a fallback.

## Local Verification

Run these before syncing:

```bash
./scripts/package/prepare-coco-sftp.sh
./scripts/package/check-coco-sftp.sh
./scripts/package/check-remote-install-flow.sh
```

The checks confirm:

- required runtime artifacts exist in `COCO-SFTP`;
- CNI plugins are AArch64;
- guest-components are present in the Kata guest image;
- containerd uses `guest-pull` and passes `io.kubernetes.cri.image-name` plus `io.kata-containers.*` annotations;
- Kata Firecracker config points at `/root/COCO-SFTP/firecracker-bins/firecracker`, `/root/COCO-SFTP/firecracker-bins/Image`, and `/root/COCO-SFTP/images/kata-containers-cca.img`;
- the default remote installer does not call host-kernel or firmware install logic.

## Sync To Remote

When the remote board is reachable:

```bash
./scripts/deploy/sync-coco-sftp.sh
```

or:

```bash
./scripts/run/coco-local-flow.sh --sync
```

The default remote target is:

```text
root@192.168.31.18:/root/COCO-SFTP
```

Override it when needed:

```bash
COCO_REMOTE_HOST=root@192.168.31.18 COCO_REMOTE_SSH_PORT=22 ./scripts/deploy/sync-coco-sftp.sh
```

If the board does not have an SSH key installed yet, use `sshpass` through the
optional password variable:

```bash
COCO_REMOTE_PASSWORD=root ./scripts/deploy/sync-coco-sftp.sh
```

The default sync also excludes `linux-host-kernel/` and `opencca-assets/`.
Those board assets belong to the later host-kernel/firmware scripts. To include
them explicitly for a manual experiment:

```bash
COCO_REMOTE_PASSWORD=root COCO_SYNC_BOARD_ASSETS=1 ./scripts/deploy/sync-coco-sftp.sh
```

## Host Kernel Modules

If the running RK3588 kernel is missing a single module, use the dedicated
helper instead of rebuilding or replacing the whole host kernel:

```bash
COCO_REMOTE_PASSWORD=root ./scripts/deploy/install-host-kernel-modules.sh
```

The default helper installs `xt_comment.ko` for CNI/iptables comment matching.
It refreshes `.config` from the running board's `/boot/config-$(uname -r)`,
enables only the requested module symbols, and builds with `LOCALVERSION=` so a
dirty kernel tree does not create a `6.12.0-opencca-wip+` module release.
After `olddefconfig`, it checks `make ... kernelrelease` against the remote
`uname -r`, removes stale target `.ko` files, rebuilds them, then checks each
install module's `modinfo -F vermagic` before copying anything to the board.
For the default `xt_comment` case it builds `x_tables.ko` as a modpost
dependency but installs only `xt_comment.ko`.

Build only:

```bash
COCO_REMOTE_PASSWORD=root ./scripts/deploy/install-host-kernel-modules.sh --build-only
```

Use `--merge-fragment --full-modules` only for a full host module set. Do not
use it as the default for one missing module; it can enable unrelated
netfilter/xfrm/tunnel modules and turn a small fix into a larger modpost
failure.

Before installing any manual module, verify:

```bash
modinfo -F vermagic <module.ko>
```

The first field must exactly match:

```text
6.12.0-opencca-wip
```

Do not install modules whose vermagic is `6.12.0-opencca-wip+`.
If such a module was produced, delete the stale `.ko`, keep `LOCALVERSION=`
fixed for every rebuild command, and rebuild until both `kernelrelease` and
`vermagic` exactly match the running RK3588 release.

## Fast Remote Updates After Code Changes

Use the component update helper to rebuild, verify, sync, and optionally run the
matching remote install steps:

```bash
./scripts/deploy/update-remote-component.sh --component kata --remote-reinstall --remote-restart
./scripts/deploy/update-remote-component.sh --component guest-pull-snapshotter --remote-reinstall --remote-restart
./scripts/deploy/update-remote-component.sh --component guest-components --remote-reinstall --remote-restart
./scripts/deploy/update-remote-component.sh --component firecracker --remote-reinstall --remote-restart
./scripts/deploy/update-remote-component.sh --component linux-image-share --remote-reinstall --remote-restart
```

Use `--no-sync` for local-only verification while the remote host is
unreachable.

For `image-rs` changes, prefer the explicit rebuild sequence in the local build
section until the helper grows a combined `image-rs` component. The `kata`
component updates the host-side Kata runtime/shim/monitor; it is not a
substitute for rebuilding and injecting `/usr/bin/kata-agent`.

## Remote Environment Setup

After `COCO-SFTP` is synced to `/root/COCO-SFTP`, run on the remote host:

```bash
cd /root/COCO-SFTP
./scripts/remote/check/preflight.sh
./scripts/remote/install/all.sh
./scripts/remote/run/start-container-runtime.sh
```

`preflight.sh` checks the copied payload and the remote base service
requirements. `install/all.sh` installs CNI, containerd/Kata configs,
guest-pull snapshotter, Kata binaries, and nerdctl. `start-container-runtime.sh`
prepares the verified ImageCache network once, then starts
`guest-pull-snapshotter` before restarting `containerd`, matching the containerd
proxy snapshotter socket requirement.

For repeated ImageCache tests in the same boot, avoid unnecessary CNI reinstall
and service restarts. Use the lightweight readiness check:

```bash
cd /root/COCO-SFTP
./scripts/remote/run/check-image-cache-network.sh
```

## Runtime Smoke Test

Run the design-level Image CVM and Runtime CVM smoke test:

```bash
cd /root/COCO-SFTP
./scripts/remote/run/run-image-cache-smoke.sh
```

From the local host, the same verified test can be run through SSH without
restarting services:

```bash
COCO_REMOTE_PASSWORD=root ./scripts/run/run-image-cache-smoke-remote.sh
```

Use `--prepare` only when the board was just rebooted, CNI/NAT is missing, or
the services need to be reset:

```bash
COCO_REMOTE_PASSWORD=root ./scripts/run/run-image-cache-smoke-remote.sh --prepare
```

The smoke test uses:

```text
--snapshotter guest-pull
--runtime io.containerd.kata.v2
--annotation io.kubernetes.cri.image-name=...
--annotation io.kata-containers.is-image-cvm=true
--annotation io.kata-containers.is-image-cvm=false
```

Use another image or wait time if needed:

```bash
COCO_IMAGE=docker.m.daocloud.io/library/busybox:latest COCO_NERDCTL_DNS=192.168.31.1 COCO_IMAGE_CVM_BOOT_WAIT=15 ./scripts/remote/run/run-image-cache-smoke.sh
```

In the current `192.168.31.0/24` lab network, `192.168.31.1` is the working
DNS resolver for Image CVM and Runtime CVM tests. Public DNS such as `8.8.8.8`
is not reachable from the CNI bridge path in this environment.

The verified successful run on 2026-06-10 used:

```text
image=docker.m.daocloud.io/library/busybox:latest
net=coco-bridge
dns=192.168.31.1
Image CVM wait=15s
```

The success markers were `Image manifest`, `Created RMM rootfs share`,
`guest_pull took`, and `coco-runtime-cvm-ok`.

## Firmware Flash Helper

For RMM changes, use the fixed local firmware loop:

```bash
./scripts/firmware/build-rmm-uboot.sh
COCO_RPI_PASSWORD=root ./scripts/firmware/flash-rk3588-firmware-via-pi.sh --flash-mmc --wait-rk
```

The combined flow is:

```bash
COCO_RPI_PASSWORD=root COCO_REMOTE_PASSWORD=root \
  ./scripts/firmware/rmm-uboot-flash-flow.sh --flash-mmc --wait-rk --test-imagecache
```

By default the ImageCache test after flashing only checks readiness and does not
restart CNI/containerd. Set `COCO_IMAGE_CACHE_PREPARE=1` when a full remote
runtime reset is needed.
