# Image CVM Shared Rootfs Design

## 1. 背景和结论

当前 image-cache 方案把镜像共享拆成了很多次文件级操作：

1. Runtime CVM 向 Image CVM 请求 image id。
2. Runtime CVM 再请求 `image_file_list.json`。
3. Runtime CVM 逐个请求 layer、meta 文件。
4. 每个文件都需要 Image CVM `load_file`，再通过 RMM 将同一段 reserved memory 反复映射到 Runtime CVM。
5. Runtime CVM 再把共享内存中的内容写回自己的本地文件系统，然后重新走 snapshot mount 和 layer 解压流程。

这个方案的主要问题不是单点 bug，而是机制本身过重：

- 控制面太碎。每个文件一次 RPC，一次 ioctl，一次 RMM 映射，一次 guest 内复制。
- 数据面不稳定。当前 Runtime CVM 每次请求都会上报同一个 `ipa_start`，Image CVM 也复用同一个 shared range，RMM 实现中没有清晰的 unmap/remap 状态机。
- 启动路径重复。Image CVM 已经拉取和处理了镜像，Runtime CVM 仍然要把 layer 文件复制到本地并重新组织 rootfs。
- reserved memory 太小。当前 20 MiB 只适合小镜像，稍大镜像会立刻碰到容量和映射管理问题。

新的方向是：Image CVM 不再共享一组 layer 文件，而是共享一个已经可挂载的只读 rootfs。Runtime CVM 不再逐文件复制镜像内容，而是直接把共享 rootfs 作为容器的 lowerdir 或只读根文件系统挂载。

## 2. 目标

- Image CVM 只拉取、验证、解密和组装镜像一次。
- Runtime CVM 启动容器时不再重复下载、解密和逐层解包。
- Runtime CVM 能以 mount 的方式使用 Image CVM 准备好的 rootfs。
- 数据面尽量减少复制。短期允许一次性复制验证原型，长期目标是共享内存块设备或 lazy block。
- RMM 接口必须有明确的映射生命周期，不能依赖反复覆盖同一 IPA。
- 保持现有 `io.kata-containers.is-image-cvm=true/false` 语义：
  - Image CVM 负责缓存和发布 rootfs。
  - Runtime CVM 负责挂载共享 rootfs 并启动容器。

## 3. 方案总览

### V2.0: Shared Rootfs Image

这是优先落地的方案。

Image CVM 将目标 OCI 镜像处理成一个只读 filesystem image，例如 EROFS、SquashFS 或 ext4 ro image。Runtime CVM 通过一次 RPC 获取元数据。

当前 V2.0 过渡实现使用 `read_rootfs_chunk` 把 rootfs image 一次性复制到 Runtime CVM 本地，再用 loop 设备挂载。这一步是为了先验证 Kata agent、Image CVM 服务和 rootfs mount 控制流。

最终 V2.1 会把这一步替换为 RMM 管理的共享内存块设备，Runtime CVM 不再落盘复制。

推荐默认格式：

- 首选 EROFS：只读、挂载快、适合容器镜像 rootfs，可以选择压缩或不压缩。
- 备选 SquashFS：成熟但随机读和 CPU 解压成本可能更高。
- 原型备选 ext4 ro：工具普遍，方便快速验证，但镜像体积更大。

Runtime CVM 挂载方式：

1. 将共享内存区域暴露为只读块设备，例如 `/dev/coco-imgblk0`。
2. 挂载只读 rootfs image 到 `${bundle}/rootfs.lower`。
3. 创建 `${bundle}/rootfs.upper` 和 `${bundle}/rootfs.work`。
4. 用 overlayfs 挂载：

```bash
mount -t overlay overlay \
  -o lowerdir=${bundle}/rootfs.lower,upperdir=${bundle}/rootfs.upper,workdir=${bundle}/rootfs.work \
  ${bundle}/rootfs
```

这样 OCI runtime 仍然看到普通的 `${bundle}/rootfs` 目录，Kata agent 对上层容器启动路径的改动很小。

### V2.1: Page-list Shared Rootfs

V2.0 如果要求 rootfs image 物理连续，会受到 reserved memory 大小限制。V2.1 改为 page-list 映射：

- Image CVM 将 rootfs image 放在 page cache、tmpfs 或 memfd 中。
- Image CVM 内核驱动 pin 住这些 page，生成 page descriptor list。
- RMM 新增或扩展 map API，将一组 source IPA/HPA page 映射到 Runtime CVM 的连续 IPA。
- Runtime CVM 仍然看到一个连续的只读块设备。

这能避免超大连续内存，同时保留直接挂载的使用体验。

### V2.2: Lazy Chunk Block

V2.2 面向大镜像和多个 Runtime CVM：

- Image CVM 维护 content-addressed chunk store。
- Runtime CVM 中的只读块设备只在读 miss 时请求对应 chunk。
- 传输通过固定共享窗口或 shared ring 完成。
- Runtime CVM 可缓存热 chunk。

这个方案比整镜像映射更节省内存，但实现复杂度更高。它适合后续优化，不适合作为第一版。

## 4. V2.0 控制流

### 4.1 Image CVM

Image CVM 启动时运行 image share service，监听 `cid=4:54321` 或新的服务端口。

收到 Runtime CVM 的 `PrepareRootfs(image_ref)` 后：

1. 解析 image reference，得到 immutable image digest。
2. 如果缓存命中，直接返回已有 rootfs image 元数据。
3. 如果缓存未命中，调用现有 image-rs/CDH 流程拉取、验证、解密镜像。
4. 使用现有 snapshotter 将 layer 合成 merged rootfs。
5. 将 merged rootfs 打包成只读 filesystem image。
6. 计算 rootfs image digest。
7. 返回 rootfs 元数据和 OCI runtime config。

### 4.2 Runtime CVM

Runtime CVM 的 Kata agent 处理普通 workload 镜像时：

1. 读取 annotation `io.kata-containers.is-image-cvm=false`。
2. 调用 image-rs 的新接口 `guest_mount_shared_rootfs_copy_mode(image, bundle_path)`。
3. 通过 Vsock 调用 Image CVM `prepare_rootfs`。
4. V2.0 copy-mode 通过 `read_rootfs_chunk` 顺序复制 rootfs image。
5. Runtime CVM 校验 rootfs image sha256。
6. Runtime CVM 用 loop 设备只读挂载 image 到 `${bundle}/lower`。
7. agent 创建 overlay upper/work，并挂载 `${bundle}/rootfs`。
8. agent 写入 `${bundle}/config.json`。
9. 返回 `${bundle}/rootfs` 给现有容器启动流程。

V2.1 shared-memory block mode 会把第 4-6 步替换为：

1. Runtime CVM 通过 Vsock/RPC 获取 RMM share metadata。
2. Runtime CVM 的 `coco-imgblk` driver 调用 RSI attach share。
3. Runtime CVM 得到 `/dev/coco-imgblk0`。
4. Runtime CVM 将 `/dev/coco-imgblk0` 只读挂载到 `${bundle}/lower`。

## 5. RPC 草案

### 5.1 当前 V2.0 RPC

```protobuf
service Greeter {
  rpc prepare_rootfs(PrepareRootfsRequest) returns (PrepareRootfsResponse);
  rpc read_rootfs_chunk(ReadRootfsChunkRequest) returns (ReadRootfsChunkResponse);
}

message PrepareRootfsRequest {
  string image_ref = 1;
}

message PrepareRootfsResponse {
  string image_id = 1;
  string fs_type = 2;
  uint64 image_size = 3;
  uint64 block_size = 4;
  string rootfs_digest = 5;
  string rootfs_image_path = 6;
  bytes oci_config_json = 7;
}

message ReadRootfsChunkRequest {
  string rootfs_image_path = 1;
  uint64 offset = 2;
  uint32 size = 3;
}

message ReadRootfsChunkResponse {
  bytes data = 1;
}
```

### 5.2 V2.1 目标 RPC/RSI 语义

V2.1 不应回到旧的 `guest_rd + guest_ipa` 直接覆盖模式。推荐把对象抽象为 share：

```protobuf
service ImageShareService {
  rpc PrepareRootfs(PrepareRootfsRequest) returns (PrepareRootfsResponse);
  rpc AttachRootfsShare(AttachRootfsShareRequest) returns (AttachRootfsShareResponse);
  rpc ReleaseRootfsShare(ReleaseRootfsShareRequest) returns (ReleaseRootfsShareResponse);
}

message AttachRootfsShareRequest {
  string share_id = 1;
}

message AttachRootfsShareResponse {
  string device_hint = 1;
  uint64 image_size = 2;
  uint64 block_size = 3;
}

message ReleaseRootfsShareRequest {
  string share_id = 1;
}

message ReleaseRootfsShareResponse {}
```

## 6. Kernel 和 RMM 设计

### 6.1 Runtime CVM block driver

新增只读块设备驱动 `coco-imgblk`：

- 输入：share id、size、block size、fs type、digest。
- 输出：`/dev/coco-imgblkN`。
- 行为：bio read 从 RMM attach 后的只读共享页拷贝到目标 page。
- 写请求直接返回 `-EROFS`。
- 支持 `ioctl(COCO_IMGBLK_ATTACH)` 和 `ioctl(COCO_IMGBLK_DETACH)`。

短期 V2.0 通过 `read_rootfs_chunk` 把 image 复制成本地文件再 loop mount。这不是最终方案，但能快速验证 agent 和 rootfs-image 控制流。

### 6.2 Image CVM share driver

Image CVM 侧驱动负责：

- 将 rootfs image 加载到共享内存，或 pin 住 rootfs image page。
- 调用 RMM share lifecycle API 创建 share object。
- 记录 share id 和引用计数。
- Release 时解除映射并释放引用。

### 6.3 RMM API 要求

当前 `SMC_RSI_MAP_MEM` 直接覆盖目标 Realm 的 RTT 条目，不适合长期使用。新设计需要一个有生命周期的 API：

- `RSI_COCO_SHARE_CREATE(page_list, size, flags, digest) -> share_id`
- `RSI_COCO_SHARE_ATTACH(share_id, flags) -> attach_handle`
- `RSI_COCO_SHARE_DETACH(attach_handle) -> status`
- `RSI_COCO_SHARE_RELEASE(share_id) -> status`

最低要求：

- 所有地址和大小按 granule 对齐。
- attach 前由 Runtime CVM driver 申请本地设备映射，RMM 只接受 share object 级 attach。
- 不允许静默覆盖有效映射。
- 映射必须是 read-only，除非显式授权。
- detach 时执行正确的 TLBI。
- 共享页需要引用计数，避免 Image CVM 释放后 Runtime CVM 仍访问。

## 7. 安全性

V2.0 信任 Image CVM 完成镜像拉取、验证和解密。Runtime CVM 至少应验证：

- `image_ref` 对应的 immutable digest。
- rootfs image digest。
- `oci_config_json` digest 或签名。

如果后续需要降低对 Image CVM 的信任，可以加入 Merkle tree：

- Image CVM 返回 rootfs image 的 Merkle root。
- Runtime CVM 的 block driver 或用户态 verifier 在读块时验证 chunk。
- 这更接近 dm-verity/EROFS fs-verity 的模型。

## 8. 为什么不继续修当前逐文件方案

当前 bug 可以继续定位，但即便修好，也只能得到一个慢路径：

- 每个 layer 都要一次加载、映射、复制。
- Runtime CVM 仍然要保存 layer 文件并再次 mount。
- 多容器复用效果差。
- RMM 需要支持反复重映射同一 IPA，复杂且容易破坏隔离状态。

新方案把问题从“传文件”改成“发布只读 rootfs”，更贴近容器启动的真实需求。

## 9. 分阶段实现计划

### 阶段 A: 文档和本地原型

- 创建本设计文档。
- 在 Image CVM 内确认工具可用性：`mkfs.erofs`、`mksquashfs`、`mkfs.ext4`、`losetup`、`mount`。
- 用现有 image-rs 在 Image CVM 生成 merged rootfs。
- 手工打包 busybox rootfs 为 ext4/EROFS image。
- 在 Runtime CVM 上通过临时复制或 loop mount 验证 rootfs image 能启动容器。

### 阶段 B: 一次性 rootfs image 共享

- 扩展 RPC：`prepare_rootfs` 和 `read_rootfs_chunk`。
- Runtime CVM 先把 rootfs image copy 成本地 image file，再 loop mount。
- 这一步仍有一次复制，但不再逐文件传输，不再重复 layer 控制流。

### 阶段 C: 只读共享块设备

- 新增 Runtime CVM `coco-imgblk` block driver。
- Runtime CVM 直接 mount 共享内存块设备。
- 不再 dump image file。

### 阶段 D: RMM share lifecycle

- 用 `RSI_COCO_SHARE_CREATE/ATTACH/DETACH/RELEASE` 替换临时 `SMC_RSI_MAP_MEM`。
- 加入 attach/detach、readonly、引用计数和目标 IPA 状态检查。

### 阶段 E: Lazy chunk

- 如果整镜像映射内存压力过大，再实现 lazy chunk block。

## 10. 设计和测试日志

### 2026-06-10 设计记录 1

触发原因：

- 当前逐文件 `GetFile` 方案在 `image_file_list.json` 后请求 layer 时卡住。
- 观察到 Runtime CVM 每次都使用同一个 reserved IPA。
- RMM 当前 `handle_rsi_map_mem` 直接写目标 Realm RTT，没有完整 remap 生命周期。

设计结论：

- 放弃逐文件共享作为主路径。
- 新主路径改为 Image CVM 发布可挂载 rootfs image。
- Runtime CVM 通过只读块设备或临时 loop mount 使用 rootfs image。

当前状态：

- 已完成方案草案。
- 尚未修改代码。
- 尚未测试新方案。

下一步：

- 调查 RK3588 guest 环境是否已有 EROFS/SquashFS/ext4 loop 支持。
- 实现阶段 A 的手工 rootfs image 原型。

### 2026-06-10 配置修改 1

修改文件：

- `linux-image-share/rk3588_fragment.config`

修改内容：

- 加入 `CONFIG_BLK_DEV_LOOP=y`，确保 Runtime CVM 可以用 loop 设备验证 rootfs image 挂载路径。
- 加入 SquashFS 支持，包括 `CONFIG_SQUASHFS_XZ=y` 和 `CONFIG_SQUASHFS_ZSTD=y`。
- 加入 EROFS 支持，包括 xattr 和压缩格式支持。
- 加入 `CONFIG_BLK_DEV_DM=y`、`CONFIG_DM_VERITY=y` 和 `CONFIG_FS_VERITY=y`，为后续只读 rootfs 完整性校验做准备。

当前环境观察：

- RK3588 当前运行环境已有 `/dev/loop-control`。
- RK3588 当前内核已支持 `squashfs` 和 `overlay`。
- RK3588 当前 rootfs 里没有 `mkfs.erofs` 和 `mksquashfs`，但本地构建机有 `mksquashfs` 和 `mkfs.ext4`。
- 因此 V2.0 原型优先使用本地构建 rootfs image，远程 Runtime CVM 只负责 loop mount 和 overlay mount。

设计影响：

- 原型阶段可以用 ext4 ro 或 squashfs image 验证 agent/rootfs mount 控制流。
- 正式阶段推荐 EROFS + verity，减少挂载成本并提供更强完整性边界。

### 2026-06-10 原型脚本 1

新增文件：

- `scripts/image/build-shared-rootfs-image.sh`
- `COCO-SFTP/scripts/remote/run/mount-shared-rootfs-image-prototype.sh`

用途：

- `build-shared-rootfs-image.sh` 从一个 rootfs 目录生成可挂载的只读 rootfs image。当前支持 `squashfs` 和 `ext4`。
- `mount-shared-rootfs-image-prototype.sh` 在目标系统上将 rootfs image 通过 loop 设备只读挂载到 `lower`，再叠加 overlayfs 到 `rootfs`。

注意：

- 这两个脚本是 V2.0 控制流原型，不是最终零拷贝实现。
- 它们用于验证 Runtime CVM 是否能直接使用一个只读 rootfs image 启动进程。
- 最终数据路径会把 loop image file 替换成 RMM 共享内存块设备。

### 2026-06-10 Runtime 挂载测试 1

测试目标：

- 验证 RK3588 当前系统支持 V2.0 的基础挂载模型：
  - squashfs 只读 lower。
  - overlayfs writable rootfs。
  - 从 overlay rootfs 中执行 aarch64 程序。

测试 rootfs：

- 本地使用 `aarch64-linux-musl-gcc` 编译静态 `hello`。
- 构造最小 rootfs：
  - `/bin/hello`
  - `/etc/hostname`
  - `/tmp`
  - `/proc`
  - `/sys`
  - `/dev`
- 使用 `scripts/image/build-shared-rootfs-image.sh` 生成 `artifacts/shared-rootfs-v2/prototype-aarch64.squashfs`。
- 镜像大小：20480 bytes。
- sha256：`a4b8d6912173eaf52e08ea1d1a3c80b34ad42b2a8ad4f80a9df836b5588fcb84`。

远端测试命令：

```bash
/root/mount-shared-rootfs-image-prototype.sh \
  --image /root/prototype-aarch64.squashfs \
  --work-dir /run/coco-shared-rootfs-test \
  --fs-type squashfs \
  -- chroot /run/coco-shared-rootfs-test/rootfs /bin/hello from-shared-rootfs

echo test_file > /run/coco-shared-rootfs-test/rootfs/tmp/overlay-write-test
cat /run/coco-shared-rootfs-test/rootfs/tmp/overlay-write-test
findmnt /run/coco-shared-rootfs-test/rootfs
findmnt /run/coco-shared-rootfs-test/lower
```

测试结果：

```text
lower=/run/coco-shared-rootfs-test/lower
rootfs=/run/coco-shared-rootfs-test/rootfs
loopdev=/dev/loop0
coco-shared-rootfs-ok argc=2 pid=805
argv[0]=/bin/hello
argv[1]=from-shared-rootfs
test_file
```

挂载状态：

```text
/run/coco-shared-rootfs-test/lower  /dev/loop0  squashfs  ro
/run/coco-shared-rootfs-test/rootfs overlay     overlay   rw,lowerdir=...,upperdir=...,workdir=...
```

结论：

- Runtime 侧“只读 rootfs image + overlayfs writable rootfs”模型成立。
- 这条路径可以替代当前逐文件 layer 传输后再创建 bundle 的笨重流程。
- 下一步要做的是把 rootfs image 的来源从本地文件/loop 替换成 Image CVM 发布的共享内存块设备。

脚本修正：

- 第一版脚本中 `findmnt "$LOWER" "$ROOTFS"` 用法错误，导致挂载成功后脚本仍返回失败。
- 已修正为分别执行 `findmnt "$LOWER" || true` 和 `findmnt "$ROOTFS" || true`。

## 11. 工程落地路线

### 11.1 复用现有 image-rs 的位置

现有 image-rs 已经有一条可用路径：

- `pull_image_content()` 拉取、验证、解密 layer。
- `create_bundle()` 通过 snapshotter 把 layer 合成 `${bundle}/rootfs`。
- Kata agent 当前只需要拿到 `${bundle}/rootfs`。

V2 不应该重写这条镜像处理链路。更合理的位置是在 Image CVM 侧：

1. 使用现有 image-rs 拉取镜像。
2. 在 Image CVM 本地生成一个临时 bundle。
3. 取 `${bundle}/rootfs` 作为输入，生成只读 rootfs image。
4. 发布 rootfs image 给 Runtime CVM。

也就是说，V2 是替换“Runtime CVM 逐文件拉 layer 并重新组 bundle”这一段，而不是替换 OCI 拉取和 layer 验证逻辑。

### 11.2 阶段 B: Copy-mode rootfs image

目的：

- 先验证 Kata agent 使用 shared-rootfs bundle 的控制流。
- 不依赖 RMM 新接口。
- 不依赖新的 block driver。

实现：

- Image CVM 新增 `PrepareRootfs` RPC。
- Image CVM 生成 rootfs image 后，通过临时传输路径交给 Runtime CVM。
- Runtime CVM 将 image 落盘到 `/run/coco-shared-rootfs/images/<digest>.squashfs`。
- Runtime CVM 调用 loop+overlay 挂载逻辑。

这一步仍有一次复制，但已经去掉逐文件 layer RPC、反复 RMM map、Runtime 重新处理 layer 的开销。

### 11.3 阶段 C: Shared-memory block device

目的：

- 去掉 copy-mode 的落盘复制。
- Runtime CVM 直接把 Image CVM 发布的 rootfs image 当只读块设备 mount。

新增 Runtime CVM driver：

- 名称：`coco-imgblk`。
- 设备：`/dev/coco-imgblk0`。
- 输入：
  - shared IPA base。
  - image size。
  - block size。
  - digest。
  - readonly flag。
- 行为：
  - `submit_bio` 对 read 请求从共享 IPA 区域拷贝到 bio page。
  - write 请求返回 `BLK_STS_IOERR` 或 `-EROFS`。
  - detach 时拒绝新 bio，等待 inflight bio 结束，再释放映射。

Runtime 挂载：

```bash
mount -t squashfs -o ro /dev/coco-imgblk0 ${bundle}/rootfs.lower
mount -t overlay overlay \
  -o lowerdir=${bundle}/rootfs.lower,upperdir=${bundle}/rootfs.upper,workdir=${bundle}/rootfs.work \
  ${bundle}/rootfs
```

### 11.4 阶段 D: RMM share lifecycle

当前 RMM 的 `SMC_RSI_MAP_MEM` 只适合实验，不适合作为最终安全接口。正式接口至少要表达：

- share 创建。
- attach 到目标 Realm。
- detach。
- share 销毁。
- readonly 权限。
- 引用计数。
- 目标 IPA 状态检查。

最小安全规则：

1. 所有 mapping granule 对齐。
2. attach 前目标 IPA 必须处于 empty/unassigned 或由同一个 share handle 持有。
3. 不允许覆盖 Runtime CVM 的普通 RAM 映射。
4. Image CVM 释放 rootfs image 前，RMM 必须确认没有 Runtime CVM attachment。
5. Runtime CVM 只能获得 readonly 映射。
6. RMM 在 attach/detach 时执行 TLBI。

### 11.5 完整性方案

V2.0/V2.1 最低完整性：

- Image CVM 返回 rootfs image sha256。
- Runtime CVM 在 copy-mode 下校验 sha256 后 mount。
- Shared-memory block mode 下，Runtime CVM 在 attach 后可做一次全量 sha256 校验，适合小镜像和验证阶段。

V2.2 推荐完整性：

- 使用 dm-verity 或 EROFS fs-verity。
- Image CVM 返回 roothash。
- Runtime CVM mount 前建立 verity 设备或启用 fs-verity 校验。
- 这样 Runtime CVM 不需要信任 Image CVM 后续不会修改共享内存。

### 11.6 组件改造清单

`guest-components/image-rs`：

- 新增 rootfs image builder 模块。
- 新增 `guest_mount_shared_rootfs_copy_mode()` 作为 Runtime CVM 过渡路径。
- `guest_pull_image()` 直接进入 shared-rootfs 路径，不再回退到旧逐文件映射。
- `pull_content()` 保留为 CDH 兼容 API，但语义调整为创建标准 OCI bundle，不再生成 `image_file_list.json`。

`guest-components/confidential-data-hub`：

- Image CVM 侧 vsock server 实现 `prepare_rootfs` 和 `read_rootfs_chunk`。
- 删除旧 `say_hello/get_file` RPC。
- 删除旧 Runtime/Image CVM `/dev/image-server` ioctl adapter。

`kata-containers-cca/src/agent`：

- 对 `is-image-cvm=false` 的普通 workload，调用 shared-rootfs V2 copy-mode。
- 返回路径仍是 `${bundle}/rootfs`，减少 OCI runtime 侧改动。

`linux-image-share`：

- 短期保留 `image-server`。
- 新增或扩展 Runtime CVM block driver `coco-imgblk`。
- 后续移除逐文件 `LOAD_FILE/WRITE_FILE` 主路径。

`opencca/tf-rmm`：

- 新增 share lifecycle RSI。
- 逐步淘汰实验性的 `SMC_RSI_MAP_MEM` 直接 RTT 覆盖接口。

### 2026-06-10 配置验证 1

验证命令：

```bash
LINUX_DIR=linux-image-share
LINUX_OUT_DIR=$LINUX_DIR/out/coco-arm64-v2config
make -C "$LINUX_DIR" O="$PWD/$LINUX_OUT_DIR" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
"$LINUX_DIR/scripts/kconfig/merge_config.sh" -m -O "$PWD/$LINUX_OUT_DIR" \
  "$PWD/$LINUX_OUT_DIR/.config" "$PWD/$LINUX_DIR/rk3588_fragment.config"
make -C "$LINUX_DIR" O="$PWD/$LINUX_OUT_DIR" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
```

验证结果：

```text
CONFIG_BLK_DEV_LOOP=y
CONFIG_BLK_DEV_DM=y
CONFIG_DM_VERITY=y
CONFIG_FS_VERITY=y
CONFIG_OVERLAY_FS=y
CONFIG_SQUASHFS=y
CONFIG_SQUASHFS_XZ=y
CONFIG_SQUASHFS_ZSTD=y
CONFIG_EROFS_FS=y
CONFIG_EROFS_FS_ZIP=y
CONFIG_EROFS_FS_ZIP_ZSTD=y
```

结论：

- `rk3588_fragment.config` 可以成功 merge。
- V2 所需的只读 rootfs、loop、overlay、verity 相关内核配置可以进入 guest kernel `.config`。
- 当前 RK 上已运行的内核已经支持 squashfs、loop 和 overlay，因此 V2.0 squashfs 原型不需要先刷 guest kernel。

### 2026-06-10 image-rs 修改 1

新增文件：

- `guest-components/image-rs/src/shared_rootfs.rs`

修改文件：

- `guest-components/image-rs/src/lib.rs`
- `guest-components/image-rs/src/image.rs`

新增能力：

- `build_rootfs_image()`：将一个 rootfs 目录打包成只读 rootfs image。
  - 当前支持 `squashfs` 和 `ext4`。
  - squashfs 路径调用 `mksquashfs`。
  - ext4 路径调用 `truncate` 和 `mkfs.ext4 -d`。
  - 返回 `RootfsImageInfo { path, format, size, sha256 }`。
- `mount_shared_rootfs_image()`：Runtime CVM copy-mode 原型挂载逻辑。
  - 调用 `losetup --read-only`。
  - 将 image mount 到 `work_dir/lower`。
  - 用 overlayfs 挂载到 `work_dir/rootfs`。
- `cleanup_shared_rootfs_mount()`：清理 overlay、lower 和 loop 设备。
- `ImageClient::prepare_shared_rootfs_image()`：
  - 复用现有 `pull_image()` 生成 bundle/rootfs。
  - 将 `${bundle}/rootfs` 打包成 squashfs rootfs image。
  - 这是后续 Image CVM `PrepareRootfs` RPC 的核心调用点。

设计取舍：

- 当前模块先使用外部工具，避免引入复杂 Rust filesystem image builder。
- 当前 `prepare_shared_rootfs_image()` 默认生成 squashfs；正式路径可以在配置中切换 EROFS/SquashFS/ext4。
- `mount_shared_rootfs_image()` 是 copy-mode 原型，后续 `coco-imgblk` 块设备完成后，可以把 loop image file 替换为 `/dev/coco-imgblkN`。

验证命令：

```bash
cd guest-components
cargo test -p image-rs shared_rootfs --lib
cargo check -p image-rs --lib
```

验证结果：

```text
test shared_rootfs::tests::rootfs_image_format_reports_fs_type ... ok
test shared_rootfs::tests::sha256_file_returns_expected_digest ... ok
test result: ok. 2 passed
```

`cargo check -p image-rs --lib` 通过。

已知情况：

- 后续需要把 Image CVM vsock server 接入 systemd/agent 启动流程，并在真实 Runtime CVM 中验证 `guest_pull_image()`。

### 2026-06-10 映射失败归因 1

结合应用层、kernel 和 RMM 代码，旧路径失败更像是方案语义不匹配，而不是单纯镜像源或网络问题。

应用层旧控制流：

- Runtime CVM 调 `say_hello(image)` 让 Image CVM 拉镜像。
- Runtime CVM 先 `get_file(image_file_list.json)`。
- Runtime CVM 再按 `image_file_list.json` 对每个 layer、meta 文件重复 `get_file()`。
- 每次 `get_file()` 都复用 Runtime CVM 中同一段 reserved IPA。

kernel 旧控制流：

- Image CVM 的 `image-server` 先通过 `IMG_IOCTL_LOAD_FILE` 把一个文件读入同一段 `shared-dma-pool` reserved memory。
- 再通过 `IMG_IOCTL_MAP_IPA` 调 `rsi_map_mem(guest_rd, guest_ipa, reserved_mem_phys, size)`。
- 也就是说，它把“文件复制”和“跨 Realm 映射”绑在一起，每个文件都要覆盖一次同一目标 IPA。

RMM 旧控制流：

- `handle_rsi_map_mem` 直接拿 Image CVM IPA 翻译到 PA。
- 找到目标 guest RD 后，直接改目标 Realm 对应 IPA 的 RTT entry。
- 没有 share object、attach/detach、引用计数、occupied check、readonly policy 和回收状态机。

结论：

- 旧方案要求 RMM 支持“同一 Runtime CVM IPA 被多次覆盖成不同文件内容”。
- 当前 RMM 实验接口更像一次性 RTT 写入接口，不适合作为多次 remap 的文件传输协议。
- 因此即使修通网络，也会继续遇到 remap/lifecycle/一致性问题。
- 新方案必须把共享对象提升为 rootfs image 或 block image，并让 RMM 管理共享对象生命周期。

### 2026-06-10 image-cache V2 修改 2

本轮代码清理目标：

- 保留 RMM/shared-memory 作为最终底层方向。
- 删除旧逐文件映射主路径，避免继续影响新方案调试。
- 用 V2.0 copy-mode 先验证 Kata agent、Image CVM vsock server、rootfs mount 和容器启动控制流。

已修改：

- `guest-components/image-rs/protos/image.proto`
- `guest-components/confidential-data-hub/hub/protos/image.proto`
  - RPC 收敛为 `prepare_rootfs` 和 `read_rootfs_chunk`。
  - 删除 `say_hello`、`get_file`、`RpcRequest/RpcResponse`、`GetFileRpcRequest/GetFileResponse`。
- `guest-components/confidential-data-hub/hub/src/bin/vsock-ttrpc-server.rs`
  - Image CVM 收到 `prepare_rootfs(image_ref)` 后调用 CDH `PullImage` 生成 bundle/rootfs。
  - 将 bundle/rootfs 打成 squashfs rootfs image。
  - 返回 `image_id/fs_type/image_size/rootfs_digest/rootfs_image_path/config_json`。
  - `read_rootfs_chunk` 限制 chunk 最大 1 MiB，并校验路径必须位于 Image CVM 的 shared-rootfs image 目录下。
  - 删除旧 `/dev/image-server` ioctl adapter。
- `guest-components/image-rs/src/vsock_ttrpc_client/mod.rs`
  - Runtime CVM client 只保留 `prepare_rootfs` 和 `read_rootfs_chunk`。
  - 删除旧 `image_ioctl` client 和 `get_file/say_hello`。
- `guest-components/image-rs/src/image.rs`
  - 删除 `ImageFileList`、`guest_pull_content`、`guest_uncompress`、`create_map_bundle`、`create_dest_meta` 等逐文件映射相关代码。
  - `guest_pull_image()` 改为直接调用 `guest_mount_shared_rootfs_copy_mode()`。
  - copy-mode 拆分为写 config、复制 rootfs image、校验 digest、挂载 rootfs 的小函数。
  - `pull_content()` 保留为 CDH 兼容包装，内部改为调用 `pull_image()` 创建标准 bundle。
- `guest-components/image-rs/src/decoder/mod.rs`
- `guest-components/image-rs/src/pull.rs`
- `guest-components/image-rs/src/stream.rs`
  - 清理低风险 Rust 风格 warning。

验证命令：

```bash
cd guest-components
cargo fmt -p image-rs -p confidential-data-hub
cargo check -p image-rs --lib
cargo test -p image-rs shared_rootfs --lib
cargo check -p confidential-data-hub --bin vsock-ttrpc-server --features bin,ttrpc
```

验证结果：

```text
cargo check -p image-rs --lib
Finished dev profile

cargo test -p image-rs shared_rootfs --lib
test shared_rootfs::tests::rootfs_image_format_reports_fs_type ... ok
test shared_rootfs::tests::sha256_file_returns_expected_digest ... ok
test result: ok. 2 passed

cargo check -p confidential-data-hub --bin vsock-ttrpc-server --features bin,ttrpc
Finished dev profile
```

残留 warning：

- CDH lib 中 `config.rs` 仍有既有 `unused_mut` 和 `dead_code` warning。
- 这两个 warning 与 image-cache V2 路径无关，本轮未改。

### 2026-06-10 最终底层方向确认

copy-mode 不是最终实现，只是为了快速验证上层控制流。最终仍以 RMM 管理的共享内存作为安全边界：

1. Image CVM 拉取、验证、解密 OCI 镜像，并生成不可变 rootfs image。
2. Image CVM 通过新 RSI 调用向 RMM 创建 share object。
3. share object 至少包含 `share_id`、owner RD、rootfs image page list、size、digest、readonly policy、attachment list 和 refcount。
4. Runtime CVM 通过 Kata/agent 获取 `share_id` 和元数据。
5. Runtime CVM 内核 `coco-imgblk` 通过 RSI attach share object，得到只读块设备。
6. Runtime CVM 将 `/dev/coco-imgblkN` 作为 lowerdir/rootfs mount。
7. Runtime CVM detach 后 RMM 才允许 Image CVM release。

这比旧 `SMC_RSI_MAP_MEM` 安全：

- 不再让应用层传 `guest_rd + guest_ipa` 并反复覆盖目标 RTT。
- RMM 持有 share 生命周期和只读权限。
- 一个 rootfs image 只需要 attach 一次，不需要按文件重复映射。
- 可以自然接入 dm-verity/fs-verity，防止 Image CVM 在 Runtime CVM 使用期间修改共享内容。

建议的 RMM/Kernel 新接口命名：

- `RSI_COCO_SHARE_CREATE`
- `RSI_COCO_SHARE_ATTACH`
- `RSI_COCO_SHARE_DETACH`
- `RSI_COCO_SHARE_RELEASE`
- Runtime CVM Linux driver: `drivers/block/coco-imgblk`

V2.0 到 V2.1 的迁移方式：

- 保持 `prepare_rootfs` 元数据 RPC 不变。
- 将 `read_rootfs_chunk` copy-mode 替换为 `attach_rootfs_share(share_id)`。
- `image-rs` 的 mount 入口不再接收本地 image file，而是接收 `/dev/coco-imgblkN`。
- `mount_shared_rootfs_image()` 可复用，只需要把 loop setup 替换为 shared block device。

### 2026-06-10 kata-agent 集成修改 1

本轮补齐 Image CVM 服务启动链：

- `kata-containers-cca/src/agent/src/image.rs`
  - 确认 `io.kata-containers.is-image-cvm=false` 仍进入 `ImageClient::guest_pull_image()`。
  - 当前 `ImageClient::guest_pull_image()` 已切到 shared-rootfs copy-mode，因此 agent 上层调用不需要再改 storage handler。
  - 清理 `ImageClient::new()` 的多余 `mut`。
- `kata-containers-cca/src/agent/src/main.rs`
  - 原逻辑只在 `agent.guest_components_procs=api-server-rest` 时顺带启动 `vsock-ttrpc-server`。
  - 修改为 CDH 启动成功后即尝试启动 `/usr/local/bin/vsock-ttrpc-server`。
  - 如果该二进制不存在，只记录 warning，不阻断普通 CDH/attestation 场景。
  - 这让 Image CVM 在只启用 `confidential-data-hub` 时也能提供 `cid=4:54321` image-share 服务。

验证命令：

```bash
cd kata-containers-cca/src/agent
cargo check --features guest-pull --bin kata-agent
```

验证结果：

```text
Finished dev profile
```

残留 warning：

- `kata-types` lifetime 风格 warning。
- `protocols` 中已移除 lint `box_pointers` 的 warning。
- `image-rs` 中既有 `Grpc` dead code warning。
- `kata-agent` 中既有 `supports_seccomp` 和 `VirtioBlkCcwHandler` dead code warning。

这些 warning 与本轮 image-cache V2 启动链无关。

### 2026-06-10 构建和镜像安装 1

已构建 aarch64 guest 产物：

```bash
scripts/build/build-kata-agent.sh
guest-components/vsock-server-build.sh
```

构建结果：

```text
[coco] Kata guest agent artifact is ready at artifacts/kata-agent/bin/kata-agent
[coco] installed artifacts/guest-components/bin/vsock-ttrpc-server
```

已写入本地 Kata guest image：

```bash
scripts/image/install-kata-agent-into-kata-image.sh
scripts/image/install-guest-components-into-kata-image.sh
```

验证结果：

```text
[ok:image] /usr/bin/kata-agent
[ok:image] /usr/local/bin/api-server-rest
[ok:image] /usr/local/bin/attestation-agent
[ok:image] /usr/local/bin/confidential-data-hub
[ok:image] /usr/local/bin/ttrpc-cdh-tool
[ok:image] /usr/local/bin/vsock-ttrpc-server
[ok:image] /root/guest-components/aa.toml
[ok:image] /root/guest-components/cdh.toml
[ok:image] /etc/attestation-agent.conf
[ok:image] /etc/confidential-data-hub.conf
```

说明：

- 本地 `COCO-SFTP/images/kata-containers-cca.img` 已包含新 agent 和新 `vsock-ttrpc-server`。
- 下一步需要将该 image 同步到 RK3588，并用 `is-image-cvm=true/false` 两类 workload 验证 Image CVM 服务和 Runtime CVM copy-mode 挂载链路。

### 2026-06-10 远端配置清理和同步 1

当前实验环境统一为：

- RK3588：`root@192.168.31.18`
- Raspberry Pi 控制机：`mzh@192.168.31.52`
- 本地工作区：`/home/mzh/RK3588/COCO`
- RK3588 运行目录：`/root/COCO-SFTP`

清理内容：

- `scripts/lib/coco_paths.sh`
  - 默认 `COCO_REMOTE_HOST` 改为 `root@192.168.31.18`。
  - 新增 `COCO_REMOTE_PASSWORD` 和 `COCO_RPI_PASSWORD` 可选变量。
- `scripts/deploy/sync-coco-sftp.sh`
  - 当 `COCO_REMOTE_PASSWORD` 非空时通过 `sshpass` 执行 rsync。
  - 保持默认不在仓库中固化密码。
- `scripts/deploy/update-remote-component.sh`
  - 当 `COCO_REMOTE_PASSWORD` 非空时通过 `sshpass` 执行远端安装/重启命令。
  - `guest-components` 更新改为强制重新注入 Kata guest image，避免旧二进制残留。
- `scripts/run/coco-local-flow.sh`
  - 同步帮助信息中的当前 RK 地址。
  - `guest-components` 构建后也改为强制注入 guest image。
- `docs/env/opencca-rk3588-env/OPENCCA-RK3588-ENV.md`
  - 静态 IP、默认网关、SSH known-host 清理示例更新到 `192.168.31.*` 当前网段。
- `docs/env/opencca-rk3588-env/KernelCompile.md`
  - Host kernel staging 路径更新为 `COCO-SFTP/linux-host-kernel`。
  - RK3588 替换 kernel/module 的远端路径更新为 `/root/COCO-SFTP/linux-host-kernel`。
- `docs/COCO_RUNTIME_BUILD_AND_DEPLOY.md`
  - 增加 `COCO_REMOTE_PASSWORD=root` 的无 SSH key 同步示例。

验证命令：

```bash
bash -n scripts/lib/coco_paths.sh \
  scripts/deploy/sync-coco-sftp.sh \
  scripts/deploy/update-remote-component.sh \
  scripts/run/coco-local-flow.sh

rg -n "192\\.168\\.137|root@192\\.168\\.137|/home/mzh/cca|/home/mzh/gpu|GPU-SFTP|GPU_SFTP" \
  scripts COCO-SFTP/configs COCO-SFTP/scripts README.md \
  docs/env/opencca-rk3588-env docs/COCO_RUNTIME_BUILD_AND_DEPLOY.md \
  docs/COCO_WORKSPACE_LAYOUT.md \
  -g '!**/MANIFEST.generated.txt'

sshpass -p root ssh root@192.168.31.18 'hostname; uname -r'
COCO_REMOTE_PASSWORD=root ./scripts/deploy/sync-coco-sftp.sh
```

验证结果：

```text
bash -n: passed
stale COCO script/env scan: no matches
RK3588 ssh: opencca-rock5b-rk3588, 6.12.0-opencca-wip
rsync total size: 951,543,509 bytes
rsync literal data: 20,973,773 bytes
rsync speedup: 44.98
```

远端安装和状态检查：

```bash
sshpass -p root ssh root@192.168.31.18 \
  'cd /root/COCO-SFTP && \
   ./scripts/remote/install/install-configs.sh && \
   ./scripts/remote/run/start-container-runtime.sh && \
   systemctl is-active guest-pull-snapshotter containerd'
```

结果：

```text
[coco-remote] installed containerd and Kata configs
[coco-remote] guest-pull-snapshotter and containerd are active
active
active
```

本地和远端 payload 检查：

```text
./scripts/package/check-coco-sftp.sh: passed
/root/COCO-SFTP/scripts/remote/check/preflight.sh: passed
remote stale config scan under scripts/configs/README.md: no matches
```

### 2026-06-10 Image CVM ext4 兼容修正 1

离线检查 Kata guest image 后发现：

```text
[missing] /usr/bin/mksquashfs
[missing] /bin/mksquashfs
[ok] /sbin/mkfs.ext4
[ok] /bin/mount
[ok] /sbin/losetup
[ok] /bin/mountpoint
[ok] /bin/umount
[ok] /usr/bin/truncate
[ok] /usr/bin/sha256sum
```

因此 V2.0 copy-mode 不能默认依赖 squashfs，否则 Image CVM 会在
`prepare_rootfs` 内生成 shared rootfs image 时失败。临时修正为：

- `guest-components/confidential-data-hub/hub/src/bin/vsock-ttrpc-server.rs`
  - `prepare_rootfs` 默认生成 `*.ext4`。
  - `PrepareRootfsResponse.fs_type` 返回 `ext4`。
  - RPC 协议和 Runtime CVM 端复制/挂载流程保持不变。
- `guest-components/image-rs/src/shared_rootfs.rs`
  - ext4 image size 不再固定 64 MiB。
  - 根据 rootfs 内容估算容量，并保留至少 32 MiB headroom。
  - 保留 64 MiB 默认下限，避免 busybox/alpine 这类小镜像生成过小文件系统。

验证命令：

```bash
cd guest-components
cargo fmt -p image-rs -p confidential-data-hub
cargo test -p image-rs shared_rootfs --lib
cargo check -p confidential-data-hub --bin vsock-ttrpc-server --features bin,ttrpc

cd /home/mzh/RK3588/COCO
./scripts/build/build-guest-components.sh
./scripts/image/install-guest-components-into-kata-image.sh
COCO_REMOTE_PASSWORD=root ./scripts/deploy/sync-coco-sftp.sh
```

验证结果：

```text
cargo test -p image-rs shared_rootfs --lib: 3 passed
cargo check -p confidential-data-hub --bin vsock-ttrpc-server --features bin,ttrpc: passed
guest-components rebuild: passed
Kata guest image contains updated guest-components
rsync literal data: 36,831,232 bytes
remote guest-pull-snapshotter/containerd: active
```

### 2026-06-10 image-rs/kata-agent 构建注意事项 1

本轮远端 smoke 暴露了一个容易误判的构建问题：`guest-components/image-rs`
不是独立部署物，它至少被两个方向使用。

- Image CVM 侧：
  - `confidential-data-hub` / `vsock-ttrpc-server` 使用 `image-rs` 拉取镜像、生成 rootfs image，并服务 `prepare_rootfs`、`read_rootfs_chunk`。
- Runtime CVM 侧：
  - `/usr/bin/kata-agent` 通过 `kata-containers-cca/src/agent/Cargo.toml` 的本地 `image-rs = { path = "../../../guest-components/image-rs" }` 依赖，把 `guest_mount_shared_rootfs_copy_mode()` 链接进 agent。

因此修改 `guest-components/image-rs/src/image.rs`、`shared_rootfs.rs`、RPC
协议、copy-mode 路径、chunk 传输或 mount 逻辑时，不能只执行：

```bash
./scripts/build/build-guest-components.sh
./scripts/image/install-guest-components-into-kata-image.sh
```

上面的命令只会更新 Image CVM 侧服务二进制。Runtime CVM 仍会运行旧的
`kata-agent`，继续使用旧的 `image-rs` 代码。

正确的最小构建/注入顺序是：

```bash
./scripts/build/build-guest-components.sh
./scripts/build/build-kata-agent.sh
./scripts/image/install-guest-components-into-kata-image.sh
./scripts/image/install-kata-agent-into-kata-image.sh
COCO_REMOTE_PASSWORD=root ./scripts/deploy/sync-coco-sftp.sh
```

这次的具体现象：

- 已将 Runtime CVM 本地 rootfs image 路径从
  `/run/kata-containers/<cid>/shared-rootfs-image/...` 改为 copy-mode 临时路径。
  第一次尝试使用 `/var/lib/image-rs/runtime-shared-rootfs/<cid>/...`，但 Kata guest rootfs 以只读方式挂载，远端 smoke 报 `Read-only file system (os error 30)`。
  当前 V2.0 过渡路径改为 `/tmp/run/image-rs/runtime-shared-rootfs/<cid>/...`。
- 只重建并注入 guest-components 后，远端 Runtime CVM 日志仍显示旧路径：
  `/run/kata-containers/<cid>/shared-rootfs-image/sha256_....ext4`。
- 失败原因仍是 `/run` tmpfs 空间不足：
  `No space left on device (os error 28)`。
- 结论：Runtime CVM 侧运行的 `kata-agent` 仍是旧二进制，必须重建并注入
  `kata-agent` 后再重新 smoke。

这个注意事项也适用于后续 V2.1 RMM share object 方案：凡是 Runtime CVM 侧
挂载、校验、attach/detach 控制流变化，都需要重新构建 `kata-agent`。
