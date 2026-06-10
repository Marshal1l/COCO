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
