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
