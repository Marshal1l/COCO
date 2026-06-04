# GPU Workspace Project Management Principles

This document records the project-management ideas behind the current GPU
workspace layout. It is meant to be reused when the project grows, when a new
machine is set up, or when scripts/artifacts need to be reorganized again.

The core idea is simple:

```text
Keep source and intent in Git.
Keep generated runtime artifacts out of Git.
Make every ignored artifact either rebuildable or restorable.
Preserve the remote GPU host as a persistent runtime cache.
Prefer semantic directories and scripted workflows over scattered files.
```

## 1. Repository Boundary

The top-level `gpu` repository is the project workspace. It owns the files that
describe how the pieces are used together:

```text
docs/
GPU-SFTP/
scripts/
.vscode/
README.md
```

Large component source trees remain separate repositories and are recorded as
submodules:

```text
Linux-Host-GPU
Linux-Guest-GPU
firecracker/Firecracker-CCA-MZH
firecracker/firecracker-deps
firecracker/vmshm-broker
```

This split keeps two kinds of history separate:

- Component history: kernel, Firecracker, broker, and dependency source changes.
- Workspace history: orchestration scripts, runtime layout, docs, configs, test
  workflows, and artifact policy.

When a component changes, commit and push the component repository first, then
commit the updated submodule pointer in the top-level `gpu` repository.

`docs` and `GPU-SFTP` are not independent Git repositories in this workspace.
They are tightly tied to the runtime scripts and should be managed by the
top-level repository.

## 2. Directory Semantics

Every top-level directory should answer a clear question:

```text
docs/       What do we know, and how should the project be operated?
scripts/    How do we build, deploy, sync, and run repeatable workflows?
GPU-SFTP/   What is the deployable runtime tree mirrored to the remote host?
.vscode/    How should this workspace appear in the editor?
```

Avoid scattering scripts and binaries at the root of `GPU-SFTP` or
`firecracker-bins`. Prefer directories that describe intent:

```text
scripts/build/
scripts/deploy/
scripts/run/
scripts/artifacts/
scripts/lib/

GPU-SFTP/firecracker-bins/bin/
GPU-SFTP/firecracker-bins/configs/
GPU-SFTP/firecracker-bins/kernels/
GPU-SFTP/firecracker-bins/rootfs/
GPU-SFTP/firecracker-bins/scripts/
GPU-SFTP/tests/
GPU-SFTP/artifacts/dtb/
GPU-SFTP/log/
```

The runtime tree should be easy to inspect even when generated files are
missing. Use `.gitkeep` files to preserve important empty directories.

## 3. Script Organization

Scripts should be grouped by workflow stage:

```text
scripts/build/       Build local artifacts from source repositories.
scripts/deploy/      Install/sync host-side payloads and reboot remote hosts.
scripts/run/         Run end-to-end tests and collect logs.
scripts/artifacts/   Fetch or verify externally stored large artifacts.
scripts/lib/         Shared shell helpers.
```

Use repo-level scripts as the primary entrypoints. Subtree-local scripts can
exist for legacy or low-level usage, but the preferred user-facing command
should live under `scripts/`.

Good script behavior:

- Derive `ROOT_DIR` from the script path instead of assuming the current working
  directory.
- Keep default paths explicit and overrideable through environment variables.
- Fail early when required commands or generated artifacts are missing.
- Print the exact artifact paths being built, installed, synced, or tested.
- Preserve incremental build directories such as kernel `out/` trees unless a
  user explicitly asks for a clean rebuild.
- Use `rsync` exclusions consistently so logs, rootfs images, and local editor
  state are not overwritten accidentally.

Bad script behavior to avoid:

- Hardcoding local generated binary paths without documenting rebuild commands.
- Writing runtime outputs into source directories without `.gitignore` coverage.
- Deleting remote state as a normal setup step.
- Copying random files into remote directories outside the semantic layout.

## 4. Source, Config, And Artifact Policy

The rule is:

```text
Git tracks sources, configs, docs, manifests, launch scripts, and directory
skeletons.

Git ignores generated binaries, kernel Images, rootfs images, mounted rootfs
workdirs, logs, sockets, and local editor credentials.
```

Tracked examples:

```text
GPU-SFTP/firecracker-bins/configs/
GPU-SFTP/firecracker-bins/scripts/
GPU-SFTP/tests/
GPU-SFTP/rootfs-manifest.json
GPU-SFTP/artifacts/dtb/trans_dtb.sh
GPU-SFTP/linux-host-kernel/cp_host_kernel.sh
docs/
scripts/
```

Ignored examples:

```text
GPU-SFTP/firecracker-bins/bin/firecracker
GPU-SFTP/firecracker-bins/bin/vmshm-broker
GPU-SFTP/firecracker-bins/bin/panthor_ioctl_smoke
GPU-SFTP/firecracker-bins/kernels/**/Image
GPU-SFTP/firecracker-bins/rootfs/*.ext2
GPU-SFTP/firecracker-bins/rootfs/*.ext4
GPU-SFTP/linux-host-kernel/Image
GPU-SFTP/log/**
GPU-SFTP/.vscode/sftp.json
```

Every ignored artifact must have one of these recovery paths:

- Rebuild from tracked source using a tracked script.
- Restore from a pinned external artifact manifest.
- Regenerate during a test workflow.

If none of those is true, the artifact policy is incomplete.

## 5. Large Files And Rootfs Images

Rootfs images are large, slow to diff, and easy to corrupt through accidental
commits. They should not live in Git history.

Current policy:

- `rootfs.ext2` and `rootfs-panfrost.ext4` are GitHub Release assets.
- `GPU-SFTP/rootfs-manifest.json` records release tag, URL, size, SHA-256,
  source, and purpose.
- `scripts/artifacts/fetch-rootfs.sh` restores them into
  `GPU-SFTP/firecracker-bins/rootfs/` and verifies them.
- `.gitignore` keeps `*.ext2`, `*.ext4`, and `*.img` out of Git.

This gives the project a stable artifact contract:

```text
Source code stays small.
Rootfs images remain versioned by release tag.
Checksums make corruption visible.
New control machines can restore the exact expected rootfs files.
```

When a rootfs intentionally changes:

1. Build or update the rootfs through a documented workflow.
2. Compute its size and SHA-256.
3. Upload it as a new GitHub Release asset or replace it under a deliberate tag.
4. Update `GPU-SFTP/rootfs-manifest.json`.
5. Run `scripts/artifacts/fetch-rootfs.sh --force` on a clean machine or temp
   directory to verify the manifest.
6. Commit only the manifest/doc changes, never the rootfs image itself.

## 6. Remote Runtime Synchronization

The remote GPU host directory is:

```text
/root/GPU-SFTP
```

Treat this directory as a persistent runtime cache. Do not delete it as part of
ordinary setup, testing, or cleanup.

Why preserve it:

- Rootfs images are large and do not need to be resent every run.
- Remote logs are useful for historical debugging.
- Runtime generated files may capture useful state between test iterations.
- The remote host state normally changes slower than the local checkout.

Preferred remote update model:

- Build locally.
- Sync `GPU-SFTP/` with `rsync`.
- Exclude local editor state.
- Exclude logs by default.
- Exclude rootfs images by default.
- Include rootfs images only with an explicit `--sync-rootfs`.
- Let `scripts/lib/gpu_sftp_layout.sh` migrate old scattered files into the
  semantic layout.

Normal sync exclusions should include:

```text
.vscode/
.git/
node_modules/
log/
firecracker-bins/run-logs/
firecracker-bins/rootfs/      unless explicitly syncing rootfs
linux-host-kernel/            unless deploying host payloads
```

Remote synchronization is an update operation, not a remote reset operation.

## 7. Test Workflow Separation

Keep GPU sharing and GPU passthrough workflows separate in scripts, docs, and
mental model.

Shared GPU virtualization:

```text
client VM userspace /dev/panthor ioctl
  -> panthor-client DRM frontend
  -> vmshm shared-memory RPC
  -> vmshm-broker eventfd relay
  -> proxy VM panthor-proxy
  -> real Panthor driver access
```

Primary entrypoint:

```bash
./scripts/run/run-vmshm-e2e.sh
```

Passthrough:

```text
remote host pmthor / KVM / Firecracker
  -> one passthrough VM
  -> guest Panthor driver
  -> GLES compute workload or probe
```

Primary entrypoints:

```bash
./scripts/deploy/deploy-host-kernel-and-test.sh
./scripts/run/run-host-vs-passthrough-gles-perf.sh
```

Do not mix defaults:

- Do not run shared client/proxy kernel builds for passthrough-only work.
- Do not use passthrough performance scripts for vmshm sharing tests.
- Do not enable performance diagnostics during formal baseline runs unless the
  run is explicitly a diagnostic run.

## 8. Incremental Build Discipline

Full rebuilds are expensive. Use them only when the artifact cache is missing,
corrupted, or invalidated by broad changes.

Default incremental mapping:

```text
Linux-Guest-GPU shared client/proxy code:
  scripts/build/build-guest-vmshm-kernels.sh

Linux-Guest-GPU passthrough guest kernel code:
  scripts/build/build-guest-passthrough-kernel.sh

Firecracker or vmshm-broker code:
  scripts/build/build-firecracker-runtime.sh

Panthor IOCTL smoke source:
  scripts/build/build-panthor-ioctl-smoke.sh

vmshm demo source:
  scripts/build/build-vmshm-demo.sh

Host kernel code:
  scripts/deploy/deploy-host-kernel-and-test.sh
```

After a known-good run, reuse existing local and remote artifacts unless the
changed files invalidate them. This keeps iteration fast and avoids rebuilding
kernel trees from scratch.

## 9. Logs And Evidence

Logs are runtime evidence, not source. Keep log directory skeletons in Git with
`.gitkeep`, but ignore actual log contents.

Local log roots:

```text
GPU-SFTP/log/shared/vmshm-1client/
GPU-SFTP/log/shared/vmshm-2client/
GPU-SFTP/log/passthrough/perf/
GPU-SFTP/log/passthrough/probe/
```

A test report should include:

- Run ID.
- Result status.
- Local log path.
- Components rebuilt, deployed, synced, or skipped.
- Rootfs/config used.
- Key PASS/FAIL markers.
- First meaningful failure symptom and log file when failed.

Do not infer success from exit code alone. Fetch and inspect the generated
`result` file and relevant logs.

## 10. Editor And Git View

VSCode should show the top-level workspace plus only real component
repositories. It should not treat `docs` or `GPU-SFTP` as nested repositories.

The workspace settings should scan:

```text
Linux-Host-GPU
Linux-Guest-GPU
firecracker/Firecracker-CCA-MZH
firecracker/firecracker-deps
firecracker/vmshm-broker
```

And ignore:

```text
docs
GPU-SFTP
```

Local editor connection files such as `GPU-SFTP/.vscode/sftp.json` may contain
machine-specific state or credentials. Keep examples in Git and real local
files ignored.

## 11. Documentation Layers

Use different docs for different jobs:

```text
README.md
  Short workspace overview and first clone commands.

docs/start/
  Start-here runbooks and project-management principles.

docs/shared/
  Shared GPU virtualization design, artifact layout, and driver analysis.

docs/passthrough/
  Passthrough implementation, performance, and optimization notes.

docs/skills/
  Repo-managed copies of Codex skill guidance.

docs/codex-context/
  Historical context snapshots and handoff notes.
```

Keep the start docs practical and operational. Put deeper design reasoning in
the workflow-specific docs.

## 12. Reusable Checklist For Reorganization

When reorganizing scripts, configs, or artifacts:

1. Identify the semantic owner of each file.
2. Move files into purpose-named directories.
3. Update scripts, configs, docs, and skills in the same change.
4. Preserve directory skeletons with `.gitkeep`.
5. Add or update `.gitignore` rules for generated outputs.
6. Make every ignored artifact rebuildable or restorable.
7. Keep remote sync non-destructive.
8. Run syntax checks on changed scripts.
9. Run the smallest relevant workflow test or document why it was not run.
10. Commit source/config/doc changes without generated artifacts.

The goal is not only a clean tree. The goal is a tree whose structure teaches
the next person, or future you, how the system should be operated.

