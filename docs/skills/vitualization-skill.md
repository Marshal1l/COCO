---
name: gpu-shared-virtualization-autotest
description: Use when building, deploying, or testing the multi-VM GPU sharing virtualization path on the remote GPU host, including vmshm, Firecracker broker, proxy VM/client VM Panthor IOCTL forwarding, Panthor client/proxy drivers, one-proxy-one-client tests, explicit two-client experiments, handle/session namespace tests, shared-memory transport, and shared virtualization run-log reporting.
---

# GPU Shared Virtualization Autotest

## Scope

Use this skill for the vmshm-based GPU sharing path:

```text
client VM userspace /dev/panthor ioctl
  -> panthor-client DRM frontend
  -> client_vmshm_comm / shared-memory RPC
  -> vmshm-broker eventfd relay
  -> proxy_vmshm_comm
  -> panthor-proxy
  -> real panthor driver in proxy VM
```

Default tests use one Proxy VM and one Client VM. Use two Client VMs only when the user explicitly asks for multi-client behavior such as namespace isolation, sharing, fairness, or scheduling.

Do not use this skill for single-VM passthrough host-vs-VM performance testing. Use `gpu-passthrough-autotest` for that path.

## Fixed Environment

Work from `/home/mzh/gpu` unless the user gives another checkout.

- Remote SSH target: `root@192.168.137.10`
- Remote password: `root`
- Local artifact root: `/home/mzh/gpu/GPU-SFTP`
- Remote artifact root: `/root/GPU-SFTP`
- Local runtime artifact tree: `/home/mzh/gpu/GPU-SFTP/firecracker-bins`
- Remote runtime artifact tree: `/root/GPU-SFTP/firecracker-bins`
- Local one-client logs: `/home/mzh/gpu/GPU-SFTP/log/shared/vmshm-1client`
- Remote one-client logs: `/root/GPU-SFTP/log/shared/vmshm-1client`
- Local two-client logs: `/home/mzh/gpu/GPU-SFTP/log/shared/vmshm-2client`
- Remote two-client logs: `/root/GPU-SFTP/log/shared/vmshm-2client`
- Shared docs: `/home/mzh/gpu/docs/shared/GPU_VIRTUALIZATION_DRIVER_ANALYSIS.md`, `/home/mzh/gpu/docs/shared/PANTHOR_IOCTL_VIRTUALIZATION_DESIGN.md`
- Artifact layout: `/home/mzh/gpu/docs/shared/GPU_SFTP_ARTIFACT_LAYOUT.md`
- Context notes: `/home/mzh/gpu/docs/codex-context/2026-05-28-vmshm-panthor-context.md`

Current semantic layout under `GPU-SFTP/firecracker-bins/`:

- `bin/`: `firecracker`, `vmshm-broker`, `vmshm-client-test`, `panthor_ioctl_smoke`, and other small runtime binaries.
- `configs/shared/vmshm-1client/`: one-proxy-one-client broker/proxy/client configs.
- `configs/shared/vmshm-2client/`: explicit two-client experiment configs.
- `kernels/shared/client/Image` and `kernels/shared/proxy/Image`: role-specific guest kernels.
- `rootfs/`: reusable rootfs images such as `rootfs.ext2`; excluded from ordinary sync unless requested.
- `scripts/shared/vmshm-1client/` and `scripts/shared/vmshm-2client/`: semantic launch/config helper scripts.

Test source trees live under `GPU-SFTP/tests/`:

- `GPU-SFTP/tests/panthor-ioctl-smoke`
- `GPU-SFTP/tests/gpu-compute-smoke`
- `GPU-SFTP/tests/vmshm-test`

Generated/dumped Firecracker device trees live under
`GPU-SFTP/artifacts/dtb/`. Firecracker accepts optional
`machine-config.dump_fdt_path`; configs should write DTB dumps there, not at
the old top-level DTB dump path.

Prefer the repo scripts over ad hoc SSH. If manual SSH is needed:

```bash
ssh -p 22 -oBatchMode=no -oStrictHostKeyChecking=accept-new root@192.168.137.10 '<command>'
```

Use existing `setsid`/`SSH_ASKPASS` wrappers in scripts for noninteractive password auth.

## Build Selection

Rebuild only affected components. Treat the artifacts already installed under
`GPU-SFTP/firecracker-bins/` as the cache for the next run, not as disposable
state. Before starting a test, classify what changed and preserve existing
outputs unless that change invalidates them.

- No relevant code/config changes since a known-good run: do not build. Use
  `scripts/run/run-vmshm-e2e.sh --skip-build` and reuse the existing local/remote
  `kernels/shared/client/Image`, `kernels/shared/proxy/Image`, `bin/firecracker`,
  `bin/vmshm-broker`, and `bin/panthor_ioctl_smoke`.
- `Linux-Guest-GPU/` Panthor client/proxy, vmshm comm/manager, Kconfig, UAPI,
  or kernel config changes: rebuild only the proxy/client role kernels with
  `scripts/build/build-guest-vmshm-kernels.sh`. It installs images to
  `GPU-SFTP/firecracker-bins/kernels/shared/client/Image` and
  `GPU-SFTP/firecracker-bins/kernels/shared/proxy/Image`. Keep
  `Linux-Guest-GPU/out/vmshm-arm64/{client,proxy}` so the kernel build remains
  incremental; do not delete output directories unless explicitly requested or
  diagnosing a corrupted build.
- `firecracker/Firecracker-CCA-MZH/`, `firecracker/vmshm-broker/`, or vmshm
  broker protocol/userspace relay changes: rebuild only Firecracker/broker
  through `scripts/build/build-firecracker-runtime.sh`; it installs to `firecracker-bins/bin/`.
  Skip the kernel build.
- `GPU-SFTP/tests/panthor-ioctl-smoke/` changes: rebuild only the userspace
  smoke payload with `GPU-SFTP/tests/panthor-ioctl-smoke/build.sh`. Skip both
  kernel and Firecracker/broker builds.
- `GPU-SFTP/tests/gpu-compute-smoke/` changes for shared GLES performance:
  sync the source; `scripts/run/run-vmshm-e2e.sh --gles-compute-smoke`
  compiles the current `gles-compute-smoke` on the remote host and injects it
  into the temporary Panfrost rootfs. Skip kernel and Firecracker/broker builds
  unless guest driver or vmshm runtime code also changed.
- `GPU-SFTP/firecracker-bins/configs/shared/...` or config installer changes:
  regenerate and sync configs only. Skip kernel and Firecracker/broker builds
  unless the config change depends on new Firecracker code, such as a new JSON
  field.
- Rootfs changes are not part of ordinary IOCTL/vmshm smoke testing. Sync
  rootfs images only when the user asks, when the selected test requires a new
  rootfs, or when remote preflight shows the rootfs is missing.
- A full build is reserved for first setup, missing/corrupted artifacts, broad
  build-system or Kconfig changes that invalidate both roles, or an explicit
  user request to refresh all artifacts.

SFTP vmshm configs live under
`GPU-SFTP/firecracker-bins/configs/shared/vmshm-1client/` and
`GPU-SFTP/firecracker-bins/configs/shared/vmshm-2client/`; do not store
`broker-config.toml` or VM config JSON in the Linux kernel repos.

## Sync Policy

Sync `/home/mzh/gpu/GPU-SFTP/` to `root@192.168.137.10:/root/GPU-SFTP/` after relevant builds. Exclude `log/` and old `firecracker-bins/run-logs/`; do not overwrite or fetch historical logs during artifact sync.

Default rsync exclusions:

```bash
rsync -av --info=stats2,name1 \
  --exclude='.vscode/' \
  --exclude='.git/' \
  --exclude='node_modules/' \
  --exclude='log/' \
  --exclude='firecracker-bins/run-logs/' \
  --exclude='firecracker-bins/rootfs/' \
  --exclude='linux-host-kernel/' \
  /home/mzh/gpu/GPU-SFTP/ \
  root@192.168.137.10:/root/GPU-SFTP/
```

Sync rootfs images only when the user asks, when a script explicitly requires it, or when remote preflight shows the needed rootfs is missing.
The repo sync scripts call `scripts/lib/gpu_sftp_layout.sh` after rsync to
migrate old remote top-level binaries, `config/`, `config-2client/`,
`kernel-client/`, `kernel-proxy/`, old test source directories, and top-level
DTB files into the semantic layout. Prefer those scripts to ad hoc `rsync`.

## Default One-Client Test

Use `/home/mzh/gpu/scripts/run/run-vmshm-e2e.sh` for the default one Proxy VM plus one Client VM GPU sharing path. It validates the vmshm transport and current Panthor DEV_QUERY-style IOCTL forwarding.

After a known-good build, start from artifact reuse. The default retest of the
current `OPEN_SESSION -> DEV_QUERY -> VM_CREATE -> VM_DESTROY -> CLOSE_SESSION`
surface should be a skip-build run unless local context shows that one of the
components above changed. If something did change, rebuild only that component,
then run the smoke test with the complementary skip flags.

Useful commands:

```bash
cd /home/mzh/gpu
./scripts/run/run-vmshm-e2e.sh --skip-build --run-id vmshm-1client-devquery-$(date +%Y%m%d-%H%M%S)
./scripts/run/run-vmshm-e2e.sh --skip-build --vm-create-smoke --run-id vmshm-1client-vm-create-$(date +%Y%m%d-%H%M%S)
./scripts/run/run-vmshm-e2e.sh --skip-kernel-build --skip-firecracker-build --run-id vmshm-1client-devquery-$(date +%Y%m%d-%H%M%S)
```

Use the full build form only when intentionally refreshing all artifacts, or
when the artifact cache is missing/corrupted:

```bash
cd /home/mzh/gpu
RUN_ID=vmshm-1client-devquery-fullbuild-$(date +%Y%m%d-%H%M%S) ./scripts/run/run-vmshm-e2e.sh
```

Common options:

- `--skip-kernel-build`
- `--skip-firecracker-build`
- `--skip-build`
- `--skip-sync`
- `--skip-remote-run`
- `--skip-fetch-logs`
- `--sync-rootfs`
- `--ioctl-smoke`
- `--vm-create-smoke`
- `--run-id ID`

## Shared GLES Performance Smoke

Use `--gles-compute-smoke` for the shared client/proxy GLES compute path. For
performance comparisons, exclude the CPU-side `input[]` fill from the primary
metric so shared, passthrough, and host use the same formal timing definition.
The smoke still prints `cpu_prepare`, but `PERF_ITER_US` / `iter_total` and the
formal `metadata` group exclude it; `metadata=buffer_upload`.

Current one-client commands:

```bash
cd /home/mzh/gpu
GLES_SMOKE_ARGS="--count 1048576 --iterations 100 --warmup 5 --perf --exclude-cpu-prepare" \
  ./scripts/run/run-vmshm-e2e.sh --skip-build --skip-config-install \
    --gles-compute-smoke \
    --run-id vmshm-1client-perf-4m-$(date +%Y%m%d-%H%M%S)

GLES_SMOKE_ARGS="--count 4194304 --iterations 100 --warmup 5 --perf --exclude-cpu-prepare" \
  ./scripts/run/run-vmshm-e2e.sh --skip-build --skip-config-install \
    --gles-compute-smoke \
    --run-id vmshm-1client-perf-16m-$(date +%Y%m%d-%H%M%S)

GLES_SMOKE_ARGS="--count 16777216 --iterations 20 --warmup 5 --perf --exclude-cpu-prepare" \
  ./scripts/run/run-vmshm-e2e.sh --skip-build --skip-config-install \
    --gles-compute-smoke \
    --run-id vmshm-1client-perf-64m-$(date +%Y%m%d-%H%M%S)
```

Before reporting PASS, fetch and inspect local logs for
`PERF_CPU_PREPARE_EXCLUDED=1`, `GPU_SMOKE_RESULT=PASS`,
`COMPUTE_CHECK=PASS`, a Mali/Panfrost renderer, and absence of software
renderer, mismatch, GPU fault, job timeout, panic, or Oops markers.

## Two-Client Experiments

Use `/home/mzh/gpu/scripts/run/run-vmshm-2client-e2e.sh` only for explicit two-client or namespace-isolation coverage. It uses `firecracker-bins/configs/shared/vmshm-2client` and should not be the default.

```bash
cd /home/mzh/gpu
RUN_ID=vmshm-2client-devquery-$(date +%Y%m%d-%H%M%S) ./scripts/run/run-vmshm-2client-e2e.sh
```

## Rootfs Selection

- Lightweight vmshm/IOCTL tests use `firecracker-bins/rootfs/rootfs.ext2` with `init=/bin/sh`, commonly through `firecracker-bins/configs/shared/vmshm-1client/*-vm-config.json` or `firecracker-bins/configs/shared/vmshm-2client/*-vm-config.json`.
- Full GPU userspace workloads require a rootfs with Mesa/Panthor or Panfrost userspace. Do not switch rootfs assumptions without inspecting the active Firecracker JSON config or launcher script.

## Current Functional Surface

At the time of the shared docs, the client frontend is discovery-oriented: DEV_QUERY is validated, while full GPU work submission, BO lifecycle virtualization, VM_BIND, fences/syncobj, event delivery, and command stream execution are design work or partial work. When adding IOCTL coverage, prefer focused payloads/tests that validate one semantic boundary at a time.

For IOCTL design details, read `/home/mzh/gpu/docs/shared/PANTHOR_IOCTL_VIRTUALIZATION_DESIGN.md` before changing handle mapping, user-pointer copying, mmap/BO sharing, VM_BIND, group submit, or syncobj behavior.

## Reporting

A good report includes:

- Run ID and `RESULT: PASS/FAIL`.
- Local log path.
- Which components were rebuilt, synced, skipped, or deployed.
- Which rootfs/config path was used.
- Key evidence such as `panthor-client: DEV_QUERY selftest passed`, `proxy_comm_vmshm: selftest passed`, `panthor-proxy: vmshm handler registered`, or IOCTL smoke output.
- First meaningful failure symptom and the specific proxy/client/broker log where it appears.

Always fetch and inspect local logs before reporting success. Do not infer success from exit code alone. Keep complete logs under the selected `GPU-SFTP/log/shared/<test-kind>/${RUN_ID}` directory.
