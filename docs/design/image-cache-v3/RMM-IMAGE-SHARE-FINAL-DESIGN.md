# Image CVM 到 Runtime CVM 镜像共享机制最终版

日期：2026-06-11

状态：当前主线实现文档。本文描述的是已经落地并通过 RK3588/OpenCCA ImageCache smoke 验证的最新版机制，不是旧 V2 copy-mode，也不是 2026-06-10 的 V3 草案。

## 一句话结论

最终版路径把“镜像共享”拆成控制面和数据面：

- 控制面只通过 vsock 从 Image CVM 返回一个 rootfs share descriptor，不传输 rootfs 数据。
- 数据面由 Image CVM 生成只读 EROFS rootfs image，注册成 RMM-backed Image Share Object。
- Runtime CVM 通过自己的 `/dev/coco-image-share` 把该 share attach 成只读 block device `/dev/cocoimg0`。
- Runtime CVM 直接挂载 `/dev/cocoimg0` 为只读 lowerdir，再叠加 overlay upper/work，kata-agent 用这个 rootfs 启动容器。

这条路径的核心改动是：Runtime CVM 不再拉镜像、不再通过 vsock 拷贝 rootfs、不再依赖完整 rootfs 的连续目标内存；Image CVM 也不再把完整镜像塞进旧的 CMA/reserved buffer。RMM 只按需把 Image CVM 已 pin 的 rootfs image 页只读映射到 Runtime CVM 的小窗口。

## 版本基线

本文对应 2026-06-11 工作区状态，核心子模块版本如下：

| 组件 | 版本 |
| --- | --- |
| `Firecracker-CCA` | `9280d33` |
| `guest-components` | `bacb5da` |
| `kata-containers-cca` | `3e883fb` |
| `linux-image-share` | `8829021` |
| `opencca` | `bf11d7` |
| `opencca/tf-rmm` | `8b186b8` |

已验证 smoke 基线：

- 平台：RK3588 / ROCK5B / OpenCCA Realm VM
- 镜像：`docker.m.daocloud.io/library/busybox:latest`
- 网络：`coco-bridge`
- DNS：`192.168.31.1`
- Image CVM 等待：`15s`
- 成功标志：`coco-runtime-cvm-ok`

## 目标和非目标

目标：

- Image CVM 负责一次性拉取镜像、展开 rootfs、构建只读 rootfs image。
- Runtime CVM 不再访问 registry，也不重复展开镜像层。
- Runtime CVM 通过 RMM share descriptor 直接挂载共享 rootfs。
- 数据面由 RMM 控制只读页映射，不让 Image CVM 直接修改 Runtime CVM 的 stage-2。
- 避免旧设计对大块连续 CMA/reserved memory 的依赖。
- 缓存未命中时，昂贵工作尽量发生在 Image CVM 并被 pending/bundle-index 协调，避免 Runtime 再触发重复 pull/build。

非目标：

- 本阶段不启用 Trustee。
- 本阶段不做镜像加密、远程策略认证、远程 attestation policy。
- 本阶段 `rootfs_digest` 默认不是强制安全校验字段；完整 rootfs SHA256 可通过环境变量打开，但 Runtime/RMM 当前不强制验证该字段。
- 本阶段只验证本机 Image CVM 到 Runtime CVM 共享，不做跨节点缓存。

## 总体架构

```text
Host / containerd / guest-pull-snapshotter
    |
    | nerdctl annotations:
    |   io.kata-containers.is-image-cvm=true/false
    |   io.kubernetes.cri.image-name=<image>
    |   io.kata-containers.disable-image-cvm-prefetch=<bool>
    v
Kata runtime
    |
    | kernel params:
    |   agent.image_cvm_role=image/runtime
    |   agent.image_cvm_ref=<image>     # prefetch enabled only
    v
+-----------------------------+       fast vsock 54322       +------------------------------+
| Image CVM                   | <---------------------------> | Runtime CVM                  |
|                             |     PrepareRootfsRequest      |                              |
| kata-agent                  |                               | kata-agent                   |
| image-rs                    |                               | image-rs fast client         |
| cdh / vsock-ttrpc-server    |                               | /dev/coco-image-share        |
|                             |                               | /dev/cocoimg0                |
| pull + stream unpack        |                               | erofs readonly mount         |
| mkfs.erofs rootfs image     |                               | overlay upper/work/rootfs    |
| /dev/coco-image-share       |                               | container process            |
+-------------+---------------+                               +---------------+--------------+
              |                                                       ^
              | RSI IMG_SHARE_CREATE / ADD_PAGES / SEAL               |
              v                                                       |
       RMM Image Share Object -----------------------------------------+
             readonly page-list backed attach windows
```

控制面和数据面分离：

- 控制面：Runtime CVM 问 Image CVM “这个 image_ref 的 rootfs share descriptor 是什么”。
- 数据面：Runtime CVM 的 block read 触发 guest kernel 按 offset attach 一个小窗口，RMM 把 Image CVM source 页只读映射到 Runtime window，再由 block driver 把窗口内容复制到 bio 页。

## Host 和 Kata 侧入口

Image CVM 和 Runtime CVM 都由普通 `nerdctl run` 启动，区别只在 annotations。

Image CVM：

```bash
nerdctl run -d \
  --net coco-bridge \
  --dns 192.168.31.1 \
  --annotation "io.kubernetes.cri.image-name=docker.m.daocloud.io/library/busybox:latest" \
  --annotation "io.kata-containers.is-image-cvm=true" \
  --snapshotter guest-pull \
  --runtime io.containerd.kata.v2 \
  docker.m.daocloud.io/library/busybox:latest sh -c "sleep 600"
```

Runtime CVM：

```bash
nerdctl run --rm \
  --net coco-bridge \
  --dns 192.168.31.1 \
  --annotation "io.kubernetes.cri.image-name=docker.m.daocloud.io/library/busybox:latest" \
  --annotation "io.kata-containers.is-image-cvm=false" \
  --annotation "io.kata-containers.disable-image-cvm-prefetch=false" \
  --snapshotter guest-pull \
  --runtime io.containerd.kata.v2 \
  docker.m.daocloud.io/library/busybox:latest sh -c "echo coco-runtime-cvm-ok"
```

实际测试优先使用脚本：

```bash
COCO_REMOTE_PASSWORD=root ./scripts/run/run-image-cache-smoke-remote.sh
```

不做 Runtime startup prefetch 的验证：

```bash
COCO_DISABLE_IMAGE_CVM_PREFETCH=true \
COCO_REMOTE_PASSWORD=root \
./scripts/run/run-image-cache-smoke-remote.sh
```

Kata runtime 根据第一个容器 annotation 设置 agent kernel params：

| annotation | 值 | 行为 |
| --- | --- | --- |
| `io.kata-containers.is-image-cvm` | `true` | `agent.image_cvm_role=image` |
| `io.kata-containers.is-image-cvm` | `false` | `agent.image_cvm_role=runtime` |
| `io.kata-containers.disable-image-cvm-prefetch` | truthy | 不写 `agent.image_cvm_ref`，Runtime 只 preconnect |
| `io.kata-containers.disable-image-cvm-prefetch` | falsey | 写 `agent.image_cvm_ref=<image>`，Runtime 启动时预取 descriptor |

truthy 兼容 `1/true/yes/on` 以及大小写变体。

## Image CVM 侧流程

Image CVM 里 kata-agent 的 `ImageService::pull_image()` 判断当前容器带有：

```text
io.kata-containers.is-image-cvm=true
```

后走 Image CVM 准备路径：

1. 调用 image-rs/CDH 拉取 OCI manifest。
2. 以流式方式拉取 layer blob。
3. 非加密 layer 直接从 registry stream 进入 decompress/unpack，不再落 `.compress` 临时文件。
4. 生成 OCI bundle，rootfs 位于 bundle 的 `rootfs/`。
5. 写入 bundle-index，记录 `image_ref`、`image_id`、`bundle_path`。
6. 异步 warm shared-rootfs cache。
7. warmup 负责从 bundle rootfs 构建 rootfs image，并注册 RMM share。

### 流式 layer unpack

最新版 image-rs 对非加密 layer 采用：

```text
registry blob stream -> CountingReader -> decompress -> unpack -> layer store
```

收益：

- 不再先写 `<layer>.compress`，再读回解压。
- 减少 Image CVM 内 I/O 和临时空间压力。
- 保留 compressed byte count 校验，发现 registry stream 长度异常会失败。

加密 layer 仍需要 decryptor 输出 plaintext stream，然后再 decompress/unpack；这个路径不是当前 busybox smoke 的主要对象。

### shared-rootfs 工作目录

默认根目录：

```text
/tmp/run/image-rs/shared-rootfs
```

子目录：

| 路径 | 用途 |
| --- | --- |
| `cache/` | share descriptor cache，按 `image_ref` 和 `image_id` 建索引 |
| `images/` | EROFS/SquashFS/Ext4 rootfs image 文件 |
| `bundles/` | Image CVM pull 后生成的 bundle |
| `bundle-index/` | `image_ref`/`image_id` 到 bundle path 的索引 |

可以用环境变量覆盖根目录：

```bash
COCO_SHARED_ROOTFS_DIR=/tmp/run/image-rs/shared-rootfs
```

### pending 和 bundle-index

旧慢路径的问题是 Runtime cache miss 时可能自己触发 Image CVM 再 pull/build 一遍，导致 23s 级 `guest_pull`。最新版加入两个协调点：

- pending marker：Image CVM 在开始 pull 前就标记该 `image_ref` 正在准备。
- bundle-index：Image CVM pull 成功后，立即写出 `image_ref/image_id -> bundle_path`。

Runtime 请求到达 Image CVM 后的判断顺序：

1. 如果 `cache/` 已有有效 share descriptor，直接返回。
2. 如果 pending 存在，则等待 Image CVM 正在进行的 warmup，轮询 cache。
3. 如果没有 cache 但 bundle-index 已有 bundle，则从已有 bundle 构建 rootfs image/share，不再重复网络 pull。
4. 最后才退回 CDH pull path。

这就是 cache miss 不再离谱的关键：Runtime 不再在 Image CVM 已经 pull 过时重复走网络和 layer unpack。

## rootfs image 格式和构建

格式候选顺序：

1. EROFS：默认首选，只读、挂载快、适合容器 rootfs。
2. SquashFS：工具存在时可用作 fallback。
3. Ext4：最后 fallback，仅用于兼容，不作为推荐路径。

Image CVM 对 busybox 的当前验证路径使用 EROFS：

```text
mkfs.erofs -x-1 <rootfs-image> <bundle-rootfs>
```

默认优化：

- `-x-1`：跳过 xattr 扫描，降低 demo 路径 rootfs prepare 时间。
- 默认不计算完整 rootfs image SHA256，`rootfs_digest` 使用 `image-id:<OCI image_id>`。

可选环境变量：

| 变量 | 默认 | 作用 |
| --- | --- | --- |
| `COCO_SHARED_ROOTFS_EROFS_PRESERVE_XATTRS=1` | 关闭 | 保留 xattr，不传 `-x-1` |
| `COCO_SHARED_ROOTFS_HASH_IMAGE=1` | 关闭 | 计算完整 rootfs image SHA256，并写 digest sidecar |

注意：当前安全边界不是靠 `rootfs_digest` enforce。重新打开 SHA256 会增加 Image CVM rootfs prepare 时间，但 Runtime/RMM 仍不会因为 digest 不匹配而拒绝挂载。后续若要做强完整性，应把校验放到 RMM metadata、dm-verity、EROFS verity 或 fs-verity 类机制里。

## RMM share 创建

Image CVM 调用 image-rs 的 `/dev/coco-image-share` 封装：

```text
COCO_IMAGE_SHARE_IOC_CREATE_FROM_FILE(path, RO)
```

guest kernel driver 执行：

1. 以只读方式打开 EROFS rootfs image。
2. 读取文件大小，计算 page_count。
3. 限制当前最大页数为 32768 页，即 128 MiB。
4. 用 `read_mapping_page()` pin 住 rootfs image 的 page cache 页。
5. 构建 page list，每项包含：
   - `source_ipa`
   - `file_offset`
6. 构建 desc page 和 meta page。
7. 调 `RSI_GET_RD_ADDR` 获取 Image CVM 自己的 RD 地址。
8. 调 `RSI_IMG_SHARE_CREATE(desc_ipa)` 创建 RMM object。
9. 调 `RSI_IMG_SHARE_ADD_PAGES(share_id, page_list_ipa, 0, page_count)` 注册页表。
10. 调 `RSI_IMG_SHARE_SEAL(share_id, meta_ipa, 0, 0)` 封存对象。
11. 返回 share descriptor：
    - `share_id`
    - `source_rd_addr`
    - `image_size`
    - `page_count`

Image CVM 写入的 cache entry 包含：

| 字段 | 含义 |
| --- | --- |
| `image_ref` | 原始镜像引用 |
| `image_id` | OCI image config digest |
| `fs_type` | `erofs` / `squashfs` / `ext4` |
| `image_size` | rootfs image 大小 |
| `block_size` | 当前固定 4096 |
| `rootfs_digest` | 默认 `image-id:<image_id>`，可选完整 SHA256 |
| `oci_config_json` | Runtime 需要写入 bundle 的 OCI config |
| `source_rd_addr` | Image CVM RD PA |
| `share_id` | RMM image share object id |
| `page_count` | rootfs image 页数 |
| `rootfs_image_path` | Image CVM 内 rootfs image 路径 |

## 控制面协议

### protobuf

请求：

```text
PrepareRootfsRequest {
  image_ref: string
}
```

响应：

```text
PrepareRootfsResponse {
  image_id: string
  fs_type: string
  image_size: uint64
  block_size: uint64
  rootfs_digest: string
  oci_config_json: bytes
  source_rd_addr: uint64
  share_id: uint64
  page_count: uint64
}
```

### fast vsock

默认控制面端口：

| 端口 | 协议 | 用途 |
| --- | --- | --- |
| `54322` | length-prefixed protobuf | 主路径 |
| `54321` | tonic/HTTP2 over vsock | fallback |

fast vsock 帧格式：

```text
request:
  u32_be length
  PrepareRootfsRequest bytes

response:
  u8 status
  u32_be length
  PrepareRootfsResponse bytes or error text
```

限制：

- 单消息最大 1 MiB。
- Runtime 侧对同一时间的 prepare 请求加全局 lock，避免重复并发 prepare。
- Runtime startup prefetch 超时为 3s，超时不阻止后续正式 `guest_pull`。

### preconnect 和 prefetch

Runtime agent 初始化时：

- 如果 `agent.image_cvm_role=runtime` 且没有 `agent.image_cvm_ref`，只预连接 fast vsock。
- 如果 `agent.image_cvm_role=runtime` 且有 `agent.image_cvm_ref`，启动时直接 `prepare_rootfs_fast(image_ref)`，把响应缓存到 Runtime 内存。
- 正式 `guest_pull_image()` 时，如果 prefetched image_ref 匹配，直接使用 descriptor，不再等 Image CVM。

这使 Runtime `guest_pull` 从秒级控制面等待降到百毫秒级。

## Runtime CVM 挂载流程

Runtime kata-agent 的 `guest_pull_image()` 不再执行传统 pull，而是：

1. 调 `prepare_rootfs_fast(image_ref)`。
2. 如果 fast vsock 失败，则 fallback 到 tonic `prepare_rootfs`。
3. 把 Image CVM 返回的 `oci_config_json` 写到 Runtime bundle 的 `config.json`。
4. 校验 `share_id` 和 `source_rd_addr` 非 0。
5. 调 `/dev/coco-image-share` 销毁旧 `/dev/cocoimg0`。
6. 调 `/dev/coco-image-share` 创建新的 block device。
7. 对 `/dev/cocoimg0` 做 EROFS/SquashFS/Ext4 preflight。
8. 直接用 `/dev/cocoimg0` 挂载只读 lowerdir。
9. 挂 overlay：

```text
lowerdir=<bundle>/lower
upperdir=<bundle>/upper
workdir=<bundle>/work
rootfs=<bundle>/rootfs
```

10. 返回 `image_id` 给 kata-agent，后续 create container 使用 `<bundle>/rootfs`。

挂载结果：

```text
/dev/cocoimg0 --ro--> lowerdir
lowerdir + upperdir + workdir --overlay--> rootfs
container root = rootfs
```

## Runtime guest kernel lazy block device

Runtime CVM 中 `/dev/coco-image-share` 支持：

| ioctl | 作用 |
| --- | --- |
| `GET_RD_ADDR` | 获取当前 Realm RD |
| `GET_WINDOW` | 获取 image-share reserved window |
| `CREATE_FROM_FILE` | Image CVM 创建 share |
| `ATTACH_WINDOW` | Runtime 映射某个文件 offset 到 reserved window |
| `DETACH_WINDOW` | Runtime 解除窗口映射 |
| `DESTROY` | Image CVM 销毁 RMM share object |
| `CREATE_DEVICE` | Runtime 创建 `/dev/cocoimg0` |
| `DESTROY_DEVICE` | Runtime 删除 `/dev/cocoimg0` |

Runtime block device 不是一次性映射完整 rootfs image。它是 lazy window 设计：

- Firecracker 在 FDT 中暴露 `compatible = "coco,imgshare-window", "shared-dma-pool"`。
- guest kernel 发现该窗口后，调用 `rsi_set_reserved_memory()` 把窗口标记为保留。
- 当前窗口来自 Firecracker `RESERVERD_MEM_SIZE = 0x1400000`，约 20 MiB。
- block device 每次最多 attach 256 KiB。
- read bio 到来时，driver 根据 sector 找到 file_offset。
- 如果当前窗口没有覆盖该 offset，先 detach 旧窗口，再 attach 新窗口。
- attach 成功后，从 ioremap 的窗口复制数据到 bio page。
- block device 只接受 read，拒绝 write。

因此 Runtime 侧连续 IPA 需求固定在小窗口，不随 rootfs image 大小线性增长。

## RMM Image Share Object

RMM 当前实现位于 `opencca/tf-rmm/runtime/rsi/rsi_image.c`，核心对象：

- share object 表：最多 32 个对象。
- attachment 表：最多 64 个活跃 attach。
- 单个 rootfs image 最大 32768 页，即 128 MiB。
- 单个 attach 最大 64 页，即 256 KiB。
- object 状态：
  - `FREE`
  - `CREATING`
  - `SEALED`
- attachment 状态：
  - `FREE`
  - `PENDING`
  - `ACTIVE`

RSI ABI：

| RSI call | 调用方 | 作用 |
| --- | --- | --- |
| `RSI_GET_RD_ADDR` | 任意 Realm | 返回自己的 RD PA |
| `RSI_IMG_SHARE_CREATE` | Image CVM | 读取 desc，创建 object |
| `RSI_IMG_SHARE_ADD_PAGES` | Image CVM | 记录 source page list IPA |
| `RSI_IMG_SHARE_SEAL` | Image CVM | 校验 meta，转入 sealed |
| `RSI_IMG_SHARE_ATTACH` | Runtime CVM | 把 source 页只读映射到 Runtime target IPA |
| `RSI_IMG_SHARE_DETACH` | Runtime CVM | 恢复 target IPA 原 S2TTE |
| `RSI_IMG_SHARE_DESTROY` | Image CVM | 无引用时销毁 object |

attach 细节：

1. Runtime 提供 `share_id`、`source_rd_addr`、`target_ipa`、`file_offset`、`size`。
2. RMM 校验 share 已 sealed，source RD 匹配，offset/size 对齐。
3. RMM 读取 Image CVM source page list。
4. 对每页通过 Image CVM 的 stage-2 walk 得到 source PA。
5. 在 Runtime CVM target IPA 写入 `assigned_ram_ro` S2TTE。
6. 保存 Runtime 原 S2TTE，用于 detach/cleanup。
7. 返回 mapped page count。

detach 细节：

1. Runtime 调 `RSI_IMG_SHARE_DETACH(target_ipa, size)`。
2. RMM 找到 attachment。
3. 恢复之前保存的 S2TTE。
4. 递减 share ref。

cleanup：

- Realm 销毁时，RMM 会尝试恢复相关 attachment。
- source Realm 销毁时，RMM 会清理其 share object。
- 当前仍是原型表实现，如果异常路径导致 table 状态不可恢复，优先通过 Pi 重启 RK。

## 为什么旧 cache miss 会很慢

早期 23s 级 Runtime `guest_pull` 不是因为 RMM attach 或 EROFS mount 慢。日志显示慢点主要来自：

- Runtime cache miss 时进入 Image CVM prepare。
- Image CVM 还没暴露 pending/cache 结果。
- Runtime 触发了重复 `pull_image`、rootfs image 构建和 RMM share 创建。
- full rootfs image SHA256 也额外增加了 Image CVM rootfs prepare 时间。

最新版修复点：

- Image CVM pull 前先写 pending marker。
- Image CVM pull 后写 bundle-index。
- Runtime 请求先等 pending/cache，再用 bundle-index，从已有 bundle 构建 share。
- Image CVM warmup 异步提前构建 EROFS + RMM share。
- Runtime startup prefetch 提前拿 descriptor。
- EROFS 默认跳过 xattr 扫描。
- 默认不计算未被 enforce 的 rootfs image SHA256。
- fast vsock 替代 tonic/HTTP2 主路径。

## 最新性能记录

详细记录见：

```text
docs/log/imagecache-debug/perf/imagecache-perf-20260611.md
```

关键结果：

| 阶段 | 旧慢路径 | 最新路径 |
| --- | ---: | ---: |
| Runtime `guest_pull took` | 23.764 s | 0.165-0.258 s 常见 |
| Runtime `createContainers TIME` | 26.264 s | 3.42-3.91 s |
| Image CVM rootfs image build | 1.26 s 级 | 0.30-0.43 s |
| Image CVM warmup total | 1.28 s 级 | 0.36-0.46 s |
| Runtime create device | n/a | 0-5 ms |
| Runtime EROFS mount fast path | n/a | 0.11-0.12 s |

最新 no-prefetch/nohash 记录：

```text
Shared rootfs image build selected: elapsed_ms=304, mkfs_ms=299, sha256_ms=0
shared rootfs cache warmup completed: elapsed_ms=367, fs_type=erofs, image_size=4194304, pages=1024
Runtime fast image share preconnect completed: elapsed_ms=48
Fast image share stage prepare_response completed: share_id=6, elapsed_ms=0
Runtime shared rootfs stage prepare_rootfs_fast completed: share_id=6, elapsed_ms=92
Runtime shared rootfs stage create_device completed: elapsed_ms=5
Runtime shared rootfs stage mount_fast_path completed: elapsed_ms=123
guest_pull took: 258 ms
coco-runtime-cvm-ok
```

最新 stream unpack/no-prefetch 记录显示：

| 阶段 | 时间 |
| --- | ---: |
| Image CVM startVM | 22.255 s |
| Image CVM pull | 6.020 s |
| Image CVM EROFS build | 0.483 s |
| Image CVM warmup | 0.563 s |
| Runtime startVM | 39.811 s |
| Runtime `prepare_rootfs_fast` | 0.092 s |
| Runtime `guest_pull took` | 0.265 s |
| Runtime createContainers | 2.778 s |

结论：

- 当前 rootfs/share 数据面不是主要瓶颈。
- Image CVM 网络 pull 仍然由 registry/network 决定，busybox 约 5-6s。
- Runtime VM 启动本身仍占 39s 左右，是后续优化的最大块。
- Runtime rootfs attach/mount 已经降到百毫秒量级。

## 构建和部署

修改 `guest-components/image-rs` 后，通常必须同时重编 guest-components 和 kata-agent，并重新注入 guest image：

```bash
./scripts/build/build-guest-components.sh
./scripts/build/build-kata-agent.sh
./scripts/image/install-guest-components-into-kata-image.sh
./scripts/image/install-kata-agent-into-kata-image.sh
./scripts/image/install-rootfs-tools-into-kata-image.sh --verify-only
./scripts/image/install-guest-components-into-kata-image.sh --verify-only
./scripts/image/install-kata-agent-into-kata-image.sh --verify-only
COCO_REMOTE_PASSWORD=root ./scripts/deploy/sync-coco-sftp.sh
```

修改 `kata-containers-cca` agent/runtime 后：

```bash
./scripts/build/build-kata-agent.sh
./scripts/image/install-kata-agent-into-kata-image.sh
COCO_REMOTE_PASSWORD=root ./scripts/deploy/sync-coco-sftp.sh
```

修改 `linux-image-share` guest kernel 后：

```bash
JOBS=8 ./scripts/build/build-linux-image-share.sh
COCO_REMOTE_PASSWORD=root ./scripts/deploy/sync-coco-sftp.sh
```

修改 `opencca/tf-rmm` 后：

```bash
./scripts/firmware/build-rmm-uboot.sh
COCO_RPI_PASSWORD=root COCO_REMOTE_PASSWORD=root \
  ./scripts/firmware/flash-rk3588-firmware-via-pi.sh --flash-mmc --wait-rk
```

如果是 RMM + U-Boot + 测试一条龙：

```bash
COCO_RPI_PASSWORD=root COCO_REMOTE_PASSWORD=root \
  ./scripts/firmware/rmm-uboot-flash-flow.sh --flash-mmc --wait-rk --test-imagecache
```

## 测试和成功判据

连续测试默认轻量检查，不重启 containerd：

```bash
COCO_REMOTE_PASSWORD=root ./scripts/run/run-image-cache-smoke-remote.sh
```

刚刷机、网络/CNI 状态不确定时：

```bash
COCO_REMOTE_PASSWORD=root ./scripts/run/run-image-cache-smoke-remote.sh --prepare
```

成功输出：

```text
coco-runtime-cvm-ok
```

关键日志：

```text
Image manifest
shared rootfs cache warmup completed
Created RMM rootfs share
Prepared RMM shared rootfs
Runtime shared rootfs stage prepare_rootfs_fast completed
Runtime shared rootfs stage create_device completed
Runtime shared rootfs stage mount_fast_path completed
guest_pull took
```

抓日志：

```bash
sshpass -p root ssh root@192.168.31.18 \
  'journalctl -u containerd --since "10 minutes ago" --no-pager |
   egrep -i "Image manifest|Created RMM rootfs share|Prepared RMM shared rootfs|shared rootfs cache warmup|prepare_rootfs_fast|guest_pull took|coco-runtime-cvm-ok|cocoimg|coco-image-share" |
   tail -n 200'
```

涉及 RMM attach/detach、蓝灯常亮、Realm destroy、guest kernel bio 错误时，先开串口日志：

```bash
COCO_RPI_PASSWORD=root ./scripts/debug/rk3588-serial-log.sh start --tag imagecache
```

测试失败后拉回：

```bash
COCO_RPI_PASSWORD=root ./scripts/debug/rk3588-serial-log.sh fetch
```

## 故障定位

### Runtime `guest_pull` 又变成 20s 级

优先看是否回到了旧慢路径：

- Image CVM 是否写了 pending marker。
- Image CVM 是否有 `shared rootfs cache warmup completed`。
- Image CVM 是否有 bundle-index hit。
- Runtime 是否使用了 `prepare_rootfs_fast`。
- Runtime agent 是否是最新 kata-agent。

如果日志仍出现旧控制流，优先怀疑只重编了 guest-components，没重编/注入 kata-agent。

### Image CVM pull 慢

如果慢点在：

```text
Image share stage pull_manifest
Image share stage pull_layers
Image CVM pull took
```

这属于 Image CVM 访问 registry/network 的成本。优先确认：

- 使用 `docker.m.daocloud.io/library/busybox:latest`。
- 使用 `--net coco-bridge`。
- 使用 `--dns 192.168.31.1`。
- 不要默认切到 `--net=host` 或 `8.8.8.8`。

### Image CVM rootfs build 慢

看：

```text
Shared rootfs image build selected
mkfs_ms
sha256_ms
```

如果 `sha256_ms` 不为 0，说明打开了：

```bash
COCO_SHARED_ROOTFS_HASH_IMAGE=1
```

当前默认应关闭。如果 `mkfs_ms` 明显变大，确认没有设置：

```bash
COCO_SHARED_ROOTFS_EROFS_PRESERVE_XATTRS=1
```

### Runtime attach/mount 慢或失败

看：

```text
Runtime shared rootfs stage create_device
Runtime shared rootfs stage preflight_device
Runtime shared rootfs stage mount_fast_path
coco-image-share: mapped share
coco-image-share: read failed
IMG_SHARE_ATTACH
IMG_SHARE_DETACH
```

常见原因：

- guest kernel 不是最新 `linux-image-share`。
- RMM 不是最新 `tf-rmm` 或 U-Boot 未重新打包/刷写。
- Firecracker 没有给 FDT 注入 `coco,imgshare-window`。
- RMM share table/attachment table 被异常测试消耗，需要重启 RK。

### `forward signal child exited` 是否代表容器失败

单看：

```text
ERRO[...] forward signal child exited error="Sandbox not running: unknown"
```

不能直接判断 ImageCache 失败。短命令容器正常退出、脚本 cleanup `nerdctl rm -f`、Kata/containerd teardown 时都可能出现类似日志。判断成功必须看：

```text
coco-runtime-cvm-ok
guest_pull took
process command: ["sh", "-c", "echo coco-runtime-cvm-ok"]
```

如果没有成功标志，再结合 containerd/kata/RMM 日志判断。

## 安全模型

当前机制比旧 prototype 更接近安全边界：

- Image CVM 不能直接指定 Runtime 的任意 stage-2 映射。
- Runtime CVM 主动 attach，RMM 校验 `share_id`、`source_rd_addr`、offset、size 和状态。
- RMM 只写入 readonly S2TTE。
- Runtime block device 只读，拒绝 write bio。
- RMM 保存 Runtime 原 S2TTE，detach 时恢复。
- Image CVM share object seal 后不能继续 add pages。

仍然存在的原型限制：

- RSI image share FID 当前仍是实验 ABI。
- RMM share object 表是静态数组，默认最多 32 个 object、64 个 attachment。
- 当前 rootfs image 最大 128 MiB，单 attach 最大 256 KiB。
- `rootfs_digest` 默认不参与强制验证。
- 没有 Trustee、镜像加密、远程策略认证。
- Image CVM 内部 rootfs image 文件页由 guest kernel pin，Image CVM 仍是该 image 内容的来源；更强完整性需要后续 verity/measurement 设计。

## 黑名单和删除方向

不要把以下旧方案重新设为主路径：

- V2 loop/overlay copy-mode。
- ext4 copy-mode。
- 逐文件 `/dev/image-server` + `GetFile` 路径。
- 通过扩大 CMA/reserved memory 承载完整 rootfs。
- `SMC_RSI_MAP_MEM_LIST` 过渡接口作为最终安全接口。
- Image CVM 主动直接改 Runtime RTT。
- Runtime CVM 通过 vsock 接收完整 rootfs image。
- 默认 `--net=host`。
- 默认 public DNS `8.8.8.8`。
- 用 `nerdctl --add-host` 作为 guest-pull DNS 修复主方案。

失败的实验代码不应保留为默认或隐藏 fallback；如果测试失败且对后续没有价值，应删除，避免污染后续排障。

## 源码索引

核心实现文件：

| 组件 | 文件 | 作用 |
| --- | --- | --- |
| guest-components | `image-rs/src/image.rs` | Runtime `guest_pull_image()`、mount fast path |
| guest-components | `image-rs/src/shared_rootfs.rs` | rootfs image 构建、cache、bundle-index、overlay mount |
| guest-components | `image-rs/src/coco_image_share.rs` | `/dev/coco-image-share` ioctl 封装 |
| guest-components | `image-rs/src/vsock_ttrpc_client/mod.rs` | fast vsock client、prefetch、tonic fallback |
| guest-components | `image-rs/src/pull.rs` | stream pull/unpack 优化 |
| guest-components | `confidential-data-hub/hub/src/bin/vsock-ttrpc-server.rs` | Image CVM prepare_rootfs server |
| kata | `src/agent/src/image.rs` | Image CVM warmup、Runtime prefetch 初始化 |
| kata | `src/agent/src/config.rs` | `agent.image_cvm_role/ref` |
| kata | `src/runtime/virtcontainers/sandbox.go` | annotations 到 kernel params |
| kata | `src/runtime/virtcontainers/kata_agent.go` | guest-pull image_ref 传递 |
| guest kernel | `drivers/coco-image-share/coco-image-share.c` | share 创建、lazy block device、window attach |
| guest kernel | `include/uapi/linux/coco-image-share.h` | ioctl ABI |
| guest kernel | `arch/arm64/include/asm/rsi_cmds.h` | RSI helper |
| guest kernel | `arch/arm64/include/asm/rsi_smc.h` | RSI FID |
| RMM | `runtime/rsi/rsi_image.c` | RMM image share object |
| RMM | `runtime/include/rsi-image.h` | RMM image share cleanup declarations |
| Firecracker | `src/vmm/src/arch/aarch64/fdt.rs` | `coco,imgshare-window` FDT reserved-memory |
| Firecracker | `src/vmm/src/builder.rs` | image-share aperture L3 RTT split |
| scripts | `COCO-SFTP/scripts/remote/run/run-image-cache-smoke.sh` | smoke entry |

配置要求：

```text
CONFIG_COCO_IMAGE_SHARE=y
CONFIG_VSOCKETS=y
CONFIG_OVERLAY_FS=y
CONFIG_BLK_DEV_LOOP=y
CONFIG_SQUASHFS=y
CONFIG_EROFS_FS=y
```

这些配置由 `linux-image-share/rk3588_fragment.config` 参与合并。

## 后续优化方向

优先级从高到低：

1. Runtime CVM startVM 优化。当前 39s 级启动时间已经远大于 rootfs attach/mount 成本。
2. RMM image share ABI 正式化，移出实验 FID。
3. rootfs 完整性 enforcement：dm-verity、EROFS verity、fs-verity 或 RMM metadata measurement。
4. share object 动态分配和更完整的生命周期回收。
5. 大镜像支持：超过 128 MiB rootfs image 的 page table 扩展和压力测试。
6. 多 Runtime 并发 attach/read 压测。
7. 将 Image CVM descriptor 通过 host/shim metadata 提前传给 Runtime，进一步降低首个 `prepare_rootfs_fast` 的 vsock 延迟。

当前结论很明确：不要再围绕旧 copy-mode 或 CMA 大小反复实验。最新版主线应继续沿 RMM-backed share object、lazy window block device、Image CVM warmup/cache/prefetch 这条路径推进。
