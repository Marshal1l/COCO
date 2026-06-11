# ImageCache Performance Run - 2026-06-11

## Test Setup

- Local time: 2026-06-11 06:03 CST
- RK time window: 2026-06-10 22:03:00..22:06:00 UTC
- Image: `docker.m.daocloud.io/library/busybox:latest`
- Network: `coco-bridge`
- DNS: `192.168.31.1`
- Image CVM boot wait: `15s`
- Command: `COCO_REMOTE_PASSWORD=root ./scripts/run/run-image-cache-smoke-remote.sh`

## Result

```text
coco-runtime-cvm-ok
```

## Timing Summary

| Metric | Value |
| --- | ---: |
| Local wrapper wall time | 118.36 s |
| Image CVM `createContainers TIME` | 5.963917334 s |
| Image CVM shim restore -> process command | 29.722779658 s |
| Runtime CVM `createContainers TIME` | 26.26431284 s |
| Runtime CVM internal `guest_pull took` | 23.764 s |
| Runtime overhead outside `guest_pull` inside `createContainers` | 2.50031284 s |
| Runtime shim restore -> process command | 65.58098123 s |
| Rootfs image size | 4,194,304 bytes |
| RMM share pages | 1024 |

## Key Timeline

```text
22:03:25.517162293Z Image CVM shim restore
22:03:54.720832751Z Image CVM createContainers TIME: 5.963917334s
22:03:55.239941951Z Image CVM process command: sleep 600

22:04:11.113212520Z Runtime CVM shim restore
22:04:59.128234203Z Image manifest visible in Image CVM log
22:05:14.808077167Z Created RMM rootfs share: share_id=3, size=4194304, pages=1024
22:05:15.052224350Z guest_pull took: 23764 ms
22:05:16.694193750Z Runtime process command: echo coco-runtime-cvm-ok
22:05:16.897030687Z Runtime createContainers TIME: 26.26431284s
```

## Source Logs

- `docs/log/imagecache-debug/perf/imagecache-perf-smoke-20260611.out`
- `docs/log/imagecache-debug/perf/imagecache-perf-smoke-20260611.time`
- `docs/log/imagecache-debug/perf/containerd-imagecache-perf-20260611.log`

## Notes

- Only one smoke run was executed for this record.
- `createContainers TIME` appears once for the Image CVM container and once for the Runtime CVM container; the Runtime CVM value is the one that includes `guest_pull`.
- Post-success cleanup emitted existing Kata/containerd teardown warnings, but the smoke command exited successfully and no container was left running.

## Optimization Follow-up

### Warm Shared Rootfs Cache

Verified on 2026-06-11 with the same image, network, DNS and 15s Image CVM wait:

| Metric | Baseline | Warm cache |
| --- | ---: | ---: |
| Runtime CVM internal `guest_pull took` | 23.764 s | 1.551 s |
| Runtime CVM `createContainers TIME` | 26.264 s | 3.760 s |

Evidence:

```text
Image CVM pull took: 5647 ms
shared rootfs cache warmup completed: elapsed_ms=1354, share_id=4
Shared rootfs cache hit: share_id=4, total_ms=0
guest_pull took: 1551 ms
Runtime createContainers TIME: 3.760392675s
```

Source log:

```text
docs/log/imagecache-debug/perf/containerd-imagecache-warm-cache-20260611.log
```

Conclusion: the previous 23.7s Runtime pull was dominated by Image CVM-side duplicated `pull_image` plus rootfs image/share creation during Runtime `prepare_rootfs`. Moving rootfs image/share creation into Image CVM warmup removes that wait from Runtime startup.

### Fast Vsock Control Plane

Verified on 2026-06-11 after adding a small length-prefixed protobuf protocol on vsock port `54322`, with tonic/HTTP2 port `54321` kept as fallback:

| Metric | Warm cache / tonic | Fast vsock / EROFS |
| --- | ---: | ---: |
| Runtime CVM internal `guest_pull took` | 1.551 s | 1.517 s |
| Runtime CVM `createContainers TIME` | 3.760 s | 3.725 s |
| Runtime `prepare_rootfs_fast` | n/a | 1.162 s |
| Runtime `create_device` | n/a | 0 ms |
| Runtime preflight | n/a | 5 ms |
| Runtime mount fast path | n/a | 98 ms |

Evidence:

```text
shared rootfs cache warmup completed: elapsed_ms=1298, share_id=6
Shared rootfs cache hit: share_id=6, total_ms=6
Fast image share request completed: elapsed_ms=921
Runtime shared rootfs stage prepare_rootfs_fast completed: elapsed_ms=1162
Runtime shared rootfs stage create_device completed: elapsed_ms=0
Runtime shared rootfs stage preflight_device completed: fs_type=erofs, elapsed_ms=5
Runtime shared rootfs stage mount_fast_path completed: elapsed_ms=98
guest_pull took: 1517 ms
Runtime createContainers TIME: 3.724841216s
```

Source logs:

```text
docs/log/imagecache-debug/perf/containerd-imagecache-fast-vsock-20260611.log
docs/log/imagecache-debug/perf/containerd-imagecache-fast-vsock-format-20260611.log
```

Conclusion: RMM attach/device creation and mount are already sub-100ms scale. The remaining Runtime `guest_pull` cost is dominated by control-plane connection/request latency and Kata agent/RPC flow around it, not by rootfs data transfer.

### Prefetch And Image CVM Build Cost

Verified on 2026-06-11 after adding Runtime startup prefetch and Image CVM bundle-index/pending coordination. The RK runtime was prepared once with `--prepare` after reboot, then one ImageCache smoke was run with the same busybox image, `coco-bridge`, DNS `192.168.31.1`, and 15s Image CVM wait.

| Metric | Value |
| --- | ---: |
| Image CVM pull/unpack | 6.040 s |
| Image CVM EROFS build | 1.325 s |
| Image CVM warmup total | 1.351 s |
| Shared rootfs image size | 4,194,304 bytes |
| RMM share pages | 1024 |
| Runtime prefetch | 0.261 s |
| Runtime `prepare_rootfs_fast` using prefetched response | 0.009 s |
| Runtime RMM attach/create device | 0.001 s |
| Runtime EROFS preflight | 0.002 s |
| Runtime mount fast path | 0.113 s |
| Runtime `guest_pull took` | 0.165 s |
| Runtime `createContainers TIME` | 3.422 s |

Evidence:

```text
Image CVM pull took: 6040 ms
Shared rootfs image build selected: fs_type=erofs, size=4194304, elapsed_ms=1325
shared rootfs cache warmup completed: elapsed_ms=1351, fs_type=erofs, image_size=4194304, pages=1024
Shared rootfs cache hit: share_id=1, total_ms=8
Runtime fast image share prefetch completed: share_id=1, elapsed_ms=261
Runtime shared rootfs stage prepare_rootfs_fast completed: elapsed_ms=9
Runtime shared rootfs stage create_device completed: elapsed_ms=1
Runtime shared rootfs stage preflight_device completed: fs_type=erofs, elapsed_ms=2
Runtime shared rootfs stage mount_fast_path completed: elapsed_ms=113
guest_pull took: 165 ms
Runtime createContainers TIME: 3.422146663s
coco-runtime-cvm-ok
```

Conclusion: for this busybox cache-miss sample, Image CVM rootfs build/RMM share work is real but only about 1.35s. The earlier 23s Runtime miss was not explained by EROFS/RMM share alone; it came from Runtime entering the prepare path before Image CVM exposed the in-progress result, causing duplicated pull/build/share work or long waiting in Runtime. The new path marks cache pending before Image CVM pull, writes a bundle-index after pull, lets Runtime wait for the in-progress cache up to the image pull timeout, and lets Runtime build from the already-pulled bundle before doing any fallback network pull.

Invalid run note: one smoke immediately after a concurrent guest image injection was discarded because the RK board dropped off the network before Image CVM emitted `Image manifest` or rootfs build logs. The guest image was then re-injected sequentially and both image writer scripts were changed to use a shared `flock` under `artifacts/locks/`.

### Runtime Without Startup Prefetch

Verified on 2026-06-11 with `COCO_DISABLE_IMAGE_CVM_PREFETCH=true`. This disables the Runtime CVM startup `prepare_rootfs_fast` prefetch by omitting `agent.image_cvm_ref`, while keeping `agent.image_cvm_role=runtime` and the Image CVM shared-rootfs path.

| Metric | Value |
| --- | ---: |
| Image CVM pull/unpack | 5.361 s |
| Image CVM EROFS/RMM warmup total | 1.280 s |
| Runtime startup preconnect | 0.045 s |
| Runtime `prepare_rootfs_fast` during `guest_pull` | 1.437 s |
| Runtime RMM attach/create device | 0.000 s |
| Runtime EROFS preflight | 0.002 s |
| Runtime mount fast path | 0.119 s |
| Runtime `guest_pull took` | 1.601 s |
| Runtime `createContainers TIME` | 3.605 s |

Evidence:

```text
Runtime kernel params: agent.image_cvm_role=runtime, no agent.image_cvm_ref
Runtime agent config: image_cvm_role: Runtime, image_cvm_ref: ""
Image CVM pull took: 5361 ms
shared rootfs cache warmup completed: elapsed_ms=1280, fs_type=erofs, image_size=4194304, pages=1024
Runtime fast image share preconnect completed: elapsed_ms=45
Shared rootfs cache hit: share_id=3, total_ms=0
Runtime shared rootfs stage prepare_rootfs_fast completed: elapsed_ms=1437
Runtime shared rootfs stage create_device completed: elapsed_ms=0
Runtime shared rootfs stage preflight_device completed: fs_type=erofs, elapsed_ms=2
Runtime shared rootfs stage mount_fast_path completed: elapsed_ms=119
guest_pull took: 1601 ms
Runtime createContainers TIME: 3.604692253s
coco-runtime-cvm-ok
```

Source log:

```text
docs/log/imagecache-debug/perf/containerd-imagecache-no-prefetch-true-20260611.log
```

Conclusion: without Runtime startup prefetch, the current Image CVM sharing path still does not show the old 23s-class Runtime pull cost. The Image CVM-side cache hit and response preparation are effectively immediate (`Shared rootfs cache hit total_ms=0`, `Fast image share request completed elapsed_ms=119`), and Runtime attach/mount remains about 0.12s. The 1.4s delta appears on the Runtime client side while waiting for the fast-vsock response; earlier preconnect-path logs also showed a 66ms case, so this is not evidence of a stable RMM/rootfs data-path cost. A large debug log that printed the full container spec on every sandbox create was removed after this run to avoid adding console/logging noise to future timings.

Invalid run note: a first `--no-prefetch` attempt passed `COCO_DISABLE_IMAGE_CVM_PREFETCH=1` while the runtime check only matched `true`, so it still added `agent.image_cvm_ref` and performed prefetch. That log was discarded and the script now normalizes boolean values before setting the annotation.

### Image CVM Rootfs Prepare Optimization

Verified on 2026-06-11 with the same busybox image, `coco-bridge`, DNS `192.168.31.1`, and 15s Image CVM wait. Two changes were tested:

- EROFS build now calls `mkfs.erofs -x-1` by default to skip xattr scanning for the demo path. Set `COCO_SHARED_ROOTFS_EROFS_PRESERVE_XATTRS=1` to keep xattrs.
- ImageCache fast path no longer computes an unused full rootfs-image SHA256 by default. `rootfs_digest` is reported as `image-id:<OCI image_id>` because Runtime/RMM currently do not verify this field. Set `COCO_SHARED_ROOTFS_HASH_IMAGE=1` to restore full rootfs image SHA256.

| Metric | Before split/optimization | After `-x-1` | After no default rootfs SHA256 |
| --- | ---: | ---: | ---: |
| Image CVM rootfs image build selected | 1.260 s | 0.980 s | 0.426 s |
| `mkfs.erofs` | unknown | 0.358 s | 0.426 s |
| rootfs SHA256 | included | 0.622 s | 0.000 s |
| Image CVM warmup total | 1.280 s | 1.261 s | 0.458 s |
| Runtime `guest_pull took` | 0.165-1.601 s depending on prefetch | 0.161 s | 0.174 s |
| Runtime `createContainers TIME` | 3.42-3.61 s | 3.44 s | 3.61 s |

Evidence:

```text
Shared rootfs image build selected: elapsed_ms=426, mkfs_ms=426, stat_ms=0, sha256_ms=0, sha256_computed=false
shared rootfs cache warmup completed: elapsed_ms=458, fs_type=erofs, image_size=4194304, pages=1024
Prepared RMM shared rootfs: digest=image-id:sha256:e0e8b3cbfed68a90084781e2962f9c0deead51c5a3f11a488eef0283a4284bc2
Runtime shared rootfs stage prepare_rootfs_fast completed: elapsed_ms=15
guest_pull took: 174 ms
Runtime createContainers TIME: 3.612238288s
coco-runtime-cvm-ok
```

Source logs:

```text
docs/log/imagecache-debug/perf/containerd-imagecache-rootfs-prepare-opt-20260611.log
docs/log/imagecache-debug/perf/containerd-imagecache-rootfs-nohash-20260611.log
```

No-prefetch follow-up after the same optimization:

| Metric | No-prefetch, no rootfs SHA256 |
| --- | ---: |
| Image CVM rootfs image build selected | 0.304 s |
| `mkfs.erofs` | 0.299 s |
| rootfs SHA256 | 0.000 s |
| Image CVM warmup total | 0.367 s |
| Runtime fast image share preconnect | 0.048 s |
| Image CVM fast response preparation | 0.000 s |
| Image CVM fast request handling | 0.001 s |
| Runtime `prepare_rootfs_fast` inside `guest_pull` | 0.092 s |
| Runtime device creation | 0.005 s |
| Runtime EROFS mount | 0.123 s |
| Runtime `guest_pull took` | 0.258 s |
| Runtime `createContainers TIME` | 3.914 s |

Evidence:

```text
AgentConfig { ... image_cvm_role: Runtime, image_cvm_ref: "" }
Shared rootfs image build selected: elapsed_ms=304, mkfs_ms=299, stat_ms=0, sha256_ms=0, sha256_computed=false, digest_cache_hit=false
shared rootfs cache warmup completed: elapsed_ms=367, fs_type=erofs, image_size=4194304, pages=1024
Runtime fast image share preconnect completed: elapsed_ms=48
Fast image share stage prepare_response completed: share_id=6, elapsed_ms=0
Fast image share request completed: elapsed_ms=1, connection_idle_ms=1621
Runtime shared rootfs stage prepare_rootfs_fast completed: share_id=6, elapsed_ms=92
Runtime shared rootfs stage create_device completed: elapsed_ms=5
Runtime shared rootfs stage mount_fast_path completed: elapsed_ms=123
guest_pull took: 258 ms
Runtime createContainers TIME: 3.91356702s
coco-runtime-cvm-ok
```

Source log:

```text
docs/log/imagecache-debug/perf/containerd-imagecache-no-prefetch-nohash-20260611.log
```

Conclusion: Image CVM rootfs preparation was a real cache-miss cost, but it is now below 0.5s for busybox even when Runtime CVM does not receive a startup prefetch reference. The largest removable cost was the full rootfs image SHA256 read, which did not contribute to the current security boundary because Runtime/RMM did not verify it. A future secure path should move integrity into RMM metadata, dm-verity, or EROFS/fs-verity rather than reintroducing a startup-only hash that is not enforced.
