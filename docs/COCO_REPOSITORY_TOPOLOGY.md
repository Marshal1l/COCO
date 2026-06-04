# COCO Repository Topology

All project repositories are named with the `COCO-` prefix under the
`Marshal1l` GitHub account.

## Root Repository

| Repository | Local path | Role |
| --- | --- | --- |
| `COCO` | workspace root | Top-level project, docs, scripts, runtime tree layout, release download helpers, and submodule pointers. |

The root `COCO` repository contains the other repositories as submodules.
Large runtime artifacts such as rootfs images are not committed to git; they are
published as GitHub Release assets on `Marshal1l/COCO`.

Repositories with large upstream histories use a COCO snapshot-style `main`
branch on GitHub. The snapshot branch keeps the current source tree while
limiting the public COCO history to at most the latest 20 commits. The local
workspace may still keep the original upstream branches for development and
reference.

## Runtime Component Repositories

| Repository | Local path |
| --- | --- |
| `COCO-Firecracker-CCA` | `Firecracker-CCA` |
| `COCO-firecracker-deps` | `firecracker-deps` |
| `COCO-kvm-bindings` | `firecracker-deps/kvm-bindings` |
| `COCO-kvm-ioctls` | `firecracker-deps/kvm-ioctls` |
| `COCO-linux-loader` | `firecracker-deps/linux-loader` |
| `COCO-vm-memory` | `firecracker-deps/vm-memory` |
| `COCO-guest-components` | `guest-components` |
| `COCO-guest-pull-snapshotter` | `guest-pull-snapshotter` |
| `COCO-kata-containers-cca` | `kata-containers-cca` |
| `COCO-linux-image-share` | `linux-image-share` |

## OpenCCA Repository Set

| Repository | Local path |
| --- | --- |
| `COCO-opencca` | `opencca` |
| `COCO-linux` | `opencca/linux` |
| `COCO-tf-rmm` | `opencca/tf-rmm` |
| `COCO-trusted-firmware-a` | `opencca/trusted-firmware-a` |
| `COCO-opencca-build` | `opencca/opencca-build` |
| `COCO-opencca-flash` | `opencca/opencca-flash` |
| `COCO-opencca-manifest` | `opencca/opencca-manifest` |
| `COCO-u-boot` | `opencca/u-boot` |
| `COCO-kvmtool` | `opencca/kvmtool` |
| `COCO-debian-image-recipes` | `opencca/debian-image-recipes` |
| `COCO-opencca-assets` | `opencca/opencca-assets` |

`COCO-opencca` is a nested superproject. It keeps the OpenCCA workspace shape
and points at the `COCO-linux`, `COCO-tf-rmm`, `COCO-trusted-firmware-a`, and
other OpenCCA component repositories.

## Release Artifacts

The root `COCO` release tag used by scripts is:

```text
coco-runtime-artifacts
```

The release is used for large files that should not enter git history, such as:

```text
COCO-SFTP/images/kata-containers-cca.img
COCO-SFTP/images/rootfs.ext4
COCO-SFTP/qemu-bins/qemu-special
opencca/rootfs/opencca-image-rockchip-rock5b-rk3588.img
```
