# COCO Runtime Build And Deploy

This document describes the runtime workflow owned by `COCO-SFTP`.
Host kernel installation and firmware flashing are intentionally outside this
flow and should be added later as separate board-level scripts.

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
root@192.168.137.10:/root/COCO-SFTP
```

Override it when needed:

```bash
COCO_REMOTE_HOST=root@192.168.137.20 COCO_REMOTE_SSH_PORT=22 ./scripts/deploy/sync-coco-sftp.sh
```

The default sync also excludes `linux-host-kernel/` and `opencca-assets/`.
Those board assets belong to the later host-kernel/firmware scripts. To include
them explicitly for a manual experiment:

```bash
COCO_SYNC_BOARD_ASSETS=1 ./scripts/deploy/sync-coco-sftp.sh
```

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
starts `guest-pull-snapshotter` before restarting `containerd`, matching the
containerd proxy snapshotter socket requirement.

## Runtime Smoke Test

Run the design-level Image CVM and Runtime CVM smoke test:

```bash
cd /root/COCO-SFTP
./scripts/remote/run/run-image-cache-smoke.sh
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
COCO_IMAGE=docker.io/library/busybox:latest COCO_IMAGE_CVM_BOOT_WAIT=15 ./scripts/remote/run/run-image-cache-smoke.sh
```
