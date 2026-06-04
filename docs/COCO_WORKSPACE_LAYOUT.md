# COCO Workspace Layout

This workspace is organized around one rule:

```text
Source trees stay in component directories.
Local build intermediates land in artifacts/.
Remote host runtime artifacts land in COCO-SFTP.
Guest-side binaries are installed into COCO-SFTP/images/kata-containers-cca.img locally.
Remote deployment mirrors COCO-SFTP to /root/COCO-SFTP.
```

## Component Semantics

| Directory | Meaning | Main scripts |
| --- | --- | --- |
| `COCO-SFTP/` | Deployable runtime tree for the remote OpenCCA board, excluding host kernel and firmware installation. | `scripts/package/prepare-coco-sftp.sh`, `scripts/deploy/sync-coco-sftp.sh` |
| `artifacts/` | Local build outputs that are not directly synced to the remote board. | Build scripts write here. |
| `kata-containers-cca/` | Host-side Kata runtime used by containerd to launch CoCo VMs. | `scripts/build/build-kata-containers.sh` |
| `guest-components/` | Guest-side AA/CDH/ASR/image transfer components installed into guest images. | `scripts/build/build-guest-components.sh` |
| `guest-pull-snapshotter/` | Host-side containerd guest-pull snapshotter source. | `scripts/build/build-guest-pull-snapshotter.sh` |
| `Firecracker-CCA/` | CCA-capable Firecracker VMM. | `scripts/build/build-firecracker.sh` |
| `firecracker-deps/` | Local rust-vmm path dependencies required by `Firecracker-CCA/src/vmm/Cargo.toml`. | Required before building Firecracker |
| `linux-image-share/` | Reusable guest kernel source for the Image CVM and Runtime CVM. | `scripts/build/build-linux-image-share.sh` |
| `opencca/` | Board firmware, host kernel, RMM, U-Boot, and OpenCCA system image materials. This is outside the default COCO-SFTP runtime install flow. | `scripts/build/build-opencca.sh` |
| `docs/design/` | Design notes for MicroVM fast boot and GPC image cache/transfer. | Documentation only |
| `docs/env/` | Board/environment setup notes. | Documentation only |
| `docs/skills/` | Project-management and remote-host operating principles. | Documentation only |

## Build Outputs

| Script | Output |
| --- | --- |
| `scripts/build/build-firecracker.sh` | `COCO-SFTP/firecracker-bins/firecracker` |
| `scripts/build/build-linux-image-share.sh` | `COCO-SFTP/firecracker-bins/Image` |
| `scripts/build/build-kata-containers.sh` | `COCO-SFTP/kata-bins/kata-runtime`, `containerd-shim-kata-v2`, `kata-monitor` |
| `scripts/build/build-guest-components.sh` | stripped deployable binaries in `artifacts/guest-components/bin/*`; `scripts/image/install-guest-components-into-kata-image.sh` installs them into `COCO-SFTP/images/kata-containers-cca.img` |
| `scripts/build/build-guest-pull-snapshotter.sh` | `COCO-SFTP/guest-pull/*` and `artifacts/guest-pull-snapshotter/bin/*` |
| `scripts/build/build-opencca.sh collect` | Optional board-level collection only; not part of default runtime build/install |

The old component-local scripts now call these workspace-level scripts so there
is one default destination for build results.

## Fixed Artifacts

Some files in `COCO-SFTP` are fixed downloads or restored binary assets rather
than products of source trees currently present in this workspace. Examples are
`COCO-SFTP/cni/bin/*`, `COCO-SFTP/nerdctl-bin/*`, `COCO-SFTP/qemu-bins/*`,
and guest rootfs images under `COCO-SFTP/images/`.

These files should be organized and documented, but not rebuilt by unrelated
source scripts.

## Remote Naming

Use the semantic remote path:

```text
/root/COCO-SFTP
```

Avoid old generic names such as `/root/sftp_folder` or `SFTP_folder` in new
scripts and configs. They hide project intent and make cross-project machines
harder to inspect.

## Typical Local Workflow

The local end-to-end goal is:

```text
check fixed runtime artifacts
build source-backed runtime outputs
refresh COCO-SFTP manifest
verify COCO-SFTP is deployable
optionally archive or sync when the remote board is reachable
```

```bash
./scripts/run/coco-local-flow.sh
```

Build every source-backed runtime component and then check the runtime tree:

```bash
./scripts/run/coco-local-flow.sh --check-prereqs
./scripts/run/coco-local-flow.sh --build
```

The default `--build` set is Firecracker, `linux-image-share`, Kata,
guest-pull-snapshotter, and guest-components. It deliberately excludes OpenCCA
firmware and the remote host Linux kernel.

If `firecracker-deps/` is not present yet, the Firecracker build is the only
known blocked source-backed component in this workspace. You can still validate
the remaining local flow with:

```bash
./scripts/run/coco-local-flow.sh --build --skip firecracker
```

Restore `firecracker-deps/{kvm-bindings,kvm-ioctls,linux-loader,vm-memory}` next
to `Firecracker-CCA/` before running the full build.

Build only one changed component:

```bash
./scripts/run/coco-local-flow.sh --component guest-components
./scripts/run/coco-local-flow.sh --component guest-pull-snapshotter
./scripts/run/coco-local-flow.sh --component kata
./scripts/run/coco-local-flow.sh --component linux-image-share
```

When the board is reachable, sync is explicit:

```bash
./scripts/run/coco-local-flow.sh --sync
```

Default sync excludes `linux-host-kernel/` and `opencca-assets/`. Use
`COCO_SYNC_BOARD_ASSETS=1` only for manual board-asset experiments.

For a changed component, build, check, sync, and optionally reinstall only that
component:

```bash
./scripts/deploy/update-remote-component.sh --component kata --remote-reinstall --remote-restart
./scripts/deploy/update-remote-component.sh --component guest-pull-snapshotter --remote-reinstall --remote-restart
./scripts/deploy/update-remote-component.sh --component guest-components --remote-reinstall --remote-restart
```

The default remote install does not change firmware or the host Linux kernel.
After syncing to `/root/COCO-SFTP`, run
`/root/COCO-SFTP/scripts/remote/install/all.sh` for the container runtime stack.
Before installing on the remote board, run
`/root/COCO-SFTP/scripts/remote/check/preflight.sh`. After installing, run
`/root/COCO-SFTP/scripts/remote/run/start-container-runtime.sh`, then
`/root/COCO-SFTP/scripts/remote/run/run-image-cache-smoke.sh` for the
design-level Image CVM/Runtime CVM check.
