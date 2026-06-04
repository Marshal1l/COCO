---
name: gpu-passthrough-autotest
description: Use when building, deploying, or testing the single-VM GPU passthrough path on the remote GPU host, including pmthor/Firecracker passthrough, guest or host Panthor kernel changes, GPA-to-HPA/page-table work, host-vs-passthrough GLES performance sweeps, passthrough diagnostics, run-log collection, and performance-result reporting.
---

# GPU Passthrough Autotest

## Scope

Use this skill for the single-VM Mali/Panthor GPU passthrough path:

```text
remote host pmthor / KVM / Firecracker
  -> one passthrough VM
  -> guest panthor driver owns the passed-through GPU view
  -> GLES compute workload or passthrough probe test
```

Do not use this skill for vmshm proxy/client GPU sharing. Use `gpu-shared-virtualization-autotest` for that path.

## Fixed Environment

Work from `/home/mzh/gpu` unless the user gives another checkout.

- Remote SSH target: `root@192.168.137.10`
- Remote password: `root`
- Local artifact root: `/home/mzh/gpu/GPU-SFTP`
- Remote artifact root: `/root/GPU-SFTP`
- Local runtime artifact tree: `/home/mzh/gpu/GPU-SFTP/firecracker-bins`
- Remote runtime artifact tree: `/root/GPU-SFTP/firecracker-bins`
- Local perf logs: `/home/mzh/gpu/GPU-SFTP/log/passthrough/perf`
- Remote perf logs: `/root/GPU-SFTP/log/passthrough/perf`
- Local probe logs: `/home/mzh/gpu/GPU-SFTP/log/passthrough/probe`
- Remote probe logs: `/root/GPU-SFTP/log/passthrough/probe`
- Main guide: `/home/mzh/gpu/docs/passthrough/GPU_HOST_VS_PASSTHROUGH_PERF_TEST_GUIDE.md`
- Artifact layout: `/home/mzh/gpu/docs/shared/GPU_SFTP_ARTIFACT_LAYOUT.md`
- Design/lessons: `/home/mzh/gpu/docs/passthrough/GPU_PASSTHROUGH_IMPLEMENTATION_ANALYSIS.md`, `/home/mzh/gpu/docs/passthrough/GPU_PASSTHROUGH_EFFECTIVE_OPTIMIZATIONS.md`

Prefer the repo scripts over ad hoc SSH. If manual SSH is needed:

```bash
ssh -p 22 -oBatchMode=no -oStrictHostKeyChecking=accept-new root@192.168.137.10 '<command>'
```

Use existing `setsid`/`SSH_ASKPASS` wrappers in scripts for noninteractive password auth.

Current passthrough runtime layout under `GPU-SFTP/firecracker-bins/`:

- `bin/firecracker`: Firecracker binary.
- `configs/passthrough/gpu-panfrost-vm-config.json`: Panfrost/Mesa rootfs performance VM config.
- `configs/passthrough/gpu-passthrough-vm-config.json`: lightweight passthrough probe VM config.
- `kernels/passthrough/Image`: single passthrough guest kernel.
- `rootfs/`: passthrough rootfs images such as `rootfs.ext2` and `rootfs-panfrost.ext4`.
- `scripts/passthrough/`: VM launchers.

Passthrough workload source lives at `GPU-SFTP/tests/gpu-compute-smoke`.
Firecracker DTB dumps live under `GPU-SFTP/artifacts/dtb/` via optional
`machine-config.dump_fdt_path`.

## Build And Deploy Selection

Rebuild only affected components.

- Guest passthrough kernel work: use `scripts/build/build-guest-passthrough-kernel.sh`. It builds one ordinary guest `Image` and installs it to `GPU-SFTP/firecracker-bins/kernels/passthrough/Image`. Do not build vmshm proxy/client role kernels for passthrough perf iteration.
- Host kernel work: use `/home/mzh/gpu/scripts/deploy/deploy-host-kernel-and-test.sh`. Prefer Image-only deployment unless module contents, module dependencies, or module install paths changed.
- Firecracker passthrough changes: inspect/build through `scripts/build/build-firecracker-runtime.sh`; it installs `firecracker` under `GPU-SFTP/firecracker-bins/bin/`.
- Passthrough config/script-only changes under `GPU-SFTP/firecracker-bins/configs/passthrough/` or `GPU-SFTP/firecracker-bins/scripts/passthrough/`: sync only unless the config uses a new Firecracker JSON field.
- GLES smoke source changes under `GPU-SFTP/tests/gpu-compute-smoke/`: rebuild the remote smoke binary through the perf script; do not rebuild kernels or Firecracker.

Fast host Image-only deployment:

```bash
cd /home/mzh/gpu
./scripts/deploy/deploy-host-kernel-and-test.sh \
  --skip-firecracker-build \
  --skip-tests \
  --run-id-prefix host-image-only
```

Selected host module deployment, only when a small `.ko` changed:

```bash
cd /home/mzh/gpu
./scripts/deploy/deploy-host-kernel-and-test.sh \
  --skip-firecracker-build \
  --skip-tests \
  --host-modules drivers/gpu/drm/panthor/panthor.ko \
  --run-id-prefix host-image-panthor-module
```

Use full `--install-host-modules` only for broad module ABI/dependency/Kconfig/install-path changes.

## Sync Policy

Passthrough scripts sync `/home/mzh/gpu/GPU-SFTP/` to
`root@192.168.137.10:/root/GPU-SFTP/` after relevant builds and exclude
`log/`, old `firecracker-bins/run-logs/`, and `firecracker-bins/rootfs/` unless
rootfs sync is explicitly requested. Do not send or overwrite historical logs
during artifact sync. The repo sync scripts also run
`scripts/lib/gpu_sftp_layout.sh` to migrate old remote top-level binaries,
configs, kernels, rootfs images, tests, and DTB files into the semantic layout.

## Formal Performance Test

For host-vs-passthrough GLES compute performance work, follow the guide exactly. Formal baselines must keep no tracing and no diagnostic knobs:

```bash
cd /home/mzh/gpu
RUN_ID=gpu-perf-host-vs-passthrough-$(date +%Y%m%d-%H%M%S) \
  ./scripts/run/run-host-vs-passthrough-gles-perf.sh \
  --host-rootfs-userspace \
  --exclude-cpu-prepare \
  --iterations 100 \
  --warmup 5 \
  --large-count-iterations 20 \
  --large-count-warmup 5 \
  --vm-timeout 900 \
  --host-timeout 900
```

Default formal sweep is 4 MiB, 16 MiB, and 64 MiB. Report the `Formal Host/VM performance ratio table`; values are `host/vm`, closer to `1.000` is better. Current formal runs exclude the per-iteration `input[]` CPU fill from `PERF_ITER_US` / `iter_total`; `cpu_prepare` is still printed as a phase, but the formal `metadata` group is `buffer_upload` only. Do not report old overhead tables unless the user explicitly asks.

Do not enable these for a formal baseline: `--guest-panthor-pt-timing`, `--pmthor-irq-stats`, `--guest-panthor-irq-stats`, `--guest-panthor-submit-stats`, `--vm-huge-pages-2m`, `--vm-taskset-cpu`, `--pmthor-irq-affinity-cpu`, tracing wrappers, or perf-record.

## Diagnostic Runs

Use diagnostics only to explain a formal-result anomaly, and clearly label them as non-baseline.

Page-table timing:

```bash
cd /home/mzh/gpu
RUN_ID=gpu-perf-pttiming-vmonly-$(date +%Y%m%d-%H%M%S) \
  ./scripts/run/run-host-vs-passthrough-gles-perf.sh \
  --host-rootfs-userspace \
  --exclude-cpu-prepare \
  --skip-host \
  --iterations 100 \
  --warmup 5 \
  --large-count-iterations 20 \
  --large-count-warmup 5 \
  --guest-panthor-pt-timing \
  --vm-timeout 900
```

IRQ/completion timing:

```bash
cd /home/mzh/gpu
RUN_ID=gpu-perf-irqstats-vmonly-$(date +%Y%m%d-%H%M%S) \
  ./scripts/run/run-host-vs-passthrough-gles-perf.sh \
  --host-rootfs-userspace \
  --exclude-cpu-prepare \
  --skip-host \
  --iterations 100 \
  --warmup 5 \
  --large-count-iterations 20 \
  --large-count-warmup 5 \
  --pmthor-irq-stats \
  --guest-panthor-irq-stats \
  --vm-timeout 900
```

Before trusting IRQ/completion numbers, inspect host and guest logs for hot-path `printk/pr_info/dev_info` in IRQ, EOI, irqfd/resample, ACK notifier, submit, fence completion, and page-table map paths.

## Rejected Defaults

Do not reintroduce these as default or optional baseline optimizations unless the user asks for a new research attempt and the design is changed first:

- BO preallocation/reuse/resident/bucket/capacity/lazy_unmap/suballocation.
- Guest raw-unmask HVC.
- Raw ack/raw prequeue/hardirq job IRQ fast path.
- Guest Panthor IRQ thread boost.
- `WQ_HIGHPRI`, `CPU_INTENSIVE`, deferred scheduler wake.
- Firecracker `nice -10`, guest `nohlt`, or cpuidle-off boot.
- Hot-path logging.

## Reporting

A good report includes:

- Run ID and `RESULT: PASS/FAIL`.
- Local log path.
- Components rebuilt, deployed, synced, or deliberately skipped.
- Active rootfs/config and userspace when relevant.
- The formal Host/VM ratio table for performance runs.
- First meaningful failure symptom and log file when a run fails.

Always fetch and inspect local logs before reporting success. Do not infer success from exit code alone.
