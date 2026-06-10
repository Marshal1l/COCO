# Image CVM 到 Runtime CVM 的 RMM 镜像共享 V3 设计

日期：2026-06-10

状态：设计草案，作为后续内核、RMM、Firecracker、guest-components 修改记录的主文档。

## 资料来源和方法

本设计优先参考已有文档，而不是对大源码树做无目标全文搜索：

- `docs/design/image-cache-design/基于GPC的容器镜像缓存机制 253659a3b8cc80e58532d5c93abe5f2f.md`
  - 旧版 imagecache 的总体控制流。
  - `/dev/image-server`、`GetImageID/GetFile`、`RD_ADDR`、reserved IPA、RMM stage-2 映射的设计意图。
  - 旧实验中逐文件映射的性能收益和实现边界。
- `docs/design/image-cache-v2/IMAGE-CVM-SHARED-ROOTFS-DESIGN.md`
  - 当前 V2 copy-mode 的失败归因。
  - 旧 `/dev/image-server` ioctl adapter 被移出主路径的原因。
  - `image-rs` 同时被 Image CVM 侧服务和 Runtime CVM 侧 kata-agent 链接这一构建事实。
- 关键实现只做定点核对：
  - `linux-image-share/drivers/image-server/image-server.c`
  - `opencca/tf-rmm/runtime/rsi/rsi_image.c`
  - `Firecracker-CCA/src/vmm/src/arch/aarch64/fdt.rs`

本文中标为“建议”或“设计决策”的内容，是基于上述文档和定点实现核对后的新方案推导；在后续落地时需要继续用实验记录更新本文件。

## 目标

V3 的目标是推翻旧的逐文件映射和当前临时 copy-mode，把 Image CVM 中已经拉取并展开好的容器 rootfs，以安全、低拷贝、低内存占用的方式提供给 Runtime CVM 使用。

核心目标：

- Runtime CVM 不再通过 vsock 复制完整 rootfs image。
- Image CVM 不再把完整镜像塞进固定 CMA/reserved buffer。
- RMM 管理共享对象生命周期、只读权限、引用计数和 detach。
- Runtime CVM 能把共享 rootfs 当作只读 block/rootfs 直接挂载，然后由 kata-agent 启动容器。
- 旧方案保留为调试 fallback，但不再作为主路径。

非目标：

- 本阶段不要求 trustee、镜像加密、远程策略认证。
- 本阶段先服务单 Image CVM + 多 Runtime CVM 的本机共享，后续再做跨节点缓存。

## 旧方案复盘

旧版 imagecache 的控制流是：

1. Runtime CVM 通过 vsock RPC 向 Image CVM 请求镜像或文件。
2. Runtime CVM 调 `/dev/image-server` 获取自己的 `RD_ADDR` 和一段 reserved IPA。
3. Image CVM 收到 `GetFile` 后，通过 `IMG_IOCTL_LOAD_FILE` 把单个文件完整读入自己的 `shared-dma-pool` reserved memory。
4. Image CVM 再调用 `IMG_IOCTL_MAP_IPA`，底层执行：

```c
rsi_map_mem(guest_rd, guest_ipa, image_reserved_ipa, size)
```

5. RMM 的 `handle_rsi_map_mem` 逐页将 Image CVM source IPA 对应的 PA 写入 Runtime CVM 的 RTT。
6. Runtime CVM 再把映射窗口里的内容写回自己的文件系统。

这个方案的主要问题：

- 数据单位太小：以文件为单位反复 map/load/write，控制流重。
- 数据面仍然有大量复制：file -> reserved buffer -> Runtime writable layer。
- CMA/reserved memory 太小：当前 Firecracker reserved 区只有 `0x1400000`，约 20 MiB。
- Runtime 端复用同一段 IPA 反复 remap，但 RMM 没有 unmap/remap/refcount 状态机。
- Image CVM 可以主动修改目标 Runtime RTT，安全边界不清晰。
- ext4 rootfs image 会生成大量空洞/元数据，临时 copy-mode 容易把 Runtime CVM 的 tmpfs 撑满。

关键观察：

- 当前 RMM `handle_rsi_map_mem` 已经是按页 walk `image_ipa`，它理论上不需要 source PA 物理连续。
- 旧方案真正把 source 限制成连续 CMA 的，是 guest kernel `image-server` 驱动的 `reserved_mem` 设计。
- Runtime 端真正难受的是“必须一次拥有完整 rootfs image 的连续目标 IPA/可写存储”。

因此 V3 不再扩容 CMA 来硬撑，而是重构数据面。

## CMA 和连续内存限制拆解

这里需要把“连续性”拆成三层，否则容易误判为只要把 CMA 加大就能解决：

1. Image CVM source 存储连续性
   - 旧 `image-server` 只有一个 `reserved_mem`，启动时从 FDT 的 `shared-dma-pool` 节点取 `reg`，然后 `memremap()`。
   - `IMG_IOCTL_LOAD_FILE` 会把单个文件完整 `kernel_read()` 到这段 `reserved_mem`。
   - 因此旧方案要求“被共享的一个文件 <= reserved memory 大小”，而且 source IPA 必须是一段连续窗口。
   - 这是 CMA/reserved-memory 限制的主要来源。

2. RMM 映射接口连续性
   - 旧 `SMC_RSI_MAP_MEM(guest_rd, guest_ipa, image_ipa, map_size)` 只接受一个 source 起点和一个 target 起点。
   - `handle_rsi_map_mem()` 内部虽然逐页调用 `realm_ipa_to_pa(rec, image_ipa, ...)`，但每轮都会 `image_ipa += 4 KiB`、`guest_ipa += 4 KiB`。
   - 这意味着 RMM 当前接口要求 source IPA 和 target IPA 都是连续区间。
   - 它不严格要求 source PA 物理连续，因为每页都会重新 walk；但旧 driver 把 source 固定在连续 reserved IPA 上，所以实际效果仍像“必须连续物理内存”。

3. Runtime CVM target 窗口连续性
   - Runtime 必须提供一段连续 IPA 作为目标映射区。
   - 如果目标区要容纳完整 rootfs image，就会把连续性问题从 Image CVM 转移到 Runtime CVM。
   - V3 因此只让 Runtime 预留小窗口，例如 16 MiB，并通过 block driver 按需 remap。

结论：

- 单纯把 CMA 从 20 MiB 增大到几百 MiB，最多能缓解小镜像，不能解决大镜像和多 Runtime 复用。
- 第一刀应该切掉 Image CVM 的 source CMA 依赖：rootfs image 保存在 tmpfs/memfd/page cache 中，driver pin 页后提交 page list。
- 第二刀再切掉 Runtime 的完整连续目标区：只保留固定小窗口，block read 时按 offset attach。
- 第三刀补 RMM 生命周期：share object、seal、readonly、refcount、detach。

### P2a 过渡接口：page-list map

完整 share object 需要 RMM 内部维护对象表和引用计数，改动较大。为了先验证“source 不必来自连续 CMA”，可以增加一个过渡 RSI 接口：

```text
SMC_RSI_MAP_MEM_LIST(guest_rd, guest_ipa, page_list_ipa, nr_pages, flags)
```

其中 `page_list_ipa` 指向 Image CVM 内存中的页表数组：

```c
struct rsi_img_page_desc {
	u64 source_ipa;
	u64 file_offset;
};
```

语义：

- 调用方仍是 Image CVM，因此它只是 bring-up 过渡接口，不是最终安全模型。
- RMM 对每个 `source_ipa` 调 `realm_ipa_to_pa()`，然后映射到 Runtime 的 `guest_ipa + i * 4 KiB`。
- source IPA 可以不连续，绕过 Image CVM CMA/reserved buffer。
- target IPA 仍连续，但只用于 16 MiB/32 MiB 小窗口。
- flags 在 P2a 原型中必须为 0；read-only flag 只属于后续正式 share-object API。
- P2a 增量已经补了 Runtime window 的 read-only assigned_ram helper；但因为仍缺 source seal、detach 和 refcount，仍标记为“不满足最终安全模型”。

P2a 成功后，再升级为正式接口：

```text
SMC_RSI_IMG_SHARE_CREATE
SMC_RSI_IMG_SHARE_ADD_PAGES
SMC_RSI_IMG_SHARE_SEAL
SMC_RSI_IMG_SHARE_ATTACH
SMC_RSI_IMG_SHARE_DETACH
SMC_RSI_IMG_SHARE_DESTROY
```

这样可以把工程风险拆开：先证明 page-list 能绕开 CMA，再补对象生命周期和 Runtime 主动 attach。

## V3 总体方案：RMM-backed Image Share Object

V3 引入 RMM 管理的 Image Share Object。Image CVM 只负责生成只读 rootfs block image，并把这个 image 的页列表注册给 RMM；Runtime CVM 只拿一个 share descriptor，然后通过自己的内核 block driver 按需读取。

推荐数据格式：

- 首选 EROFS：只读、适合容器 rootfs、随机读友好、元数据开销小。
- 备选 SquashFS：压缩率高，但需要确认 guest kernel 和工具链支持。
- 不推荐 ext4：可写文件系统语义多、空洞大、镜像体积和挂载复杂度不合适。

推荐运行时形态：

```text
Image CVM
  pull image -> unpack rootfs -> mkfs.erofs in memfd/tmpfs
  -> pin image pages -> register pages to RMM -> seal share
  -> return share descriptor over vsock

Runtime CVM
  receive share descriptor over vsock
  -> /dev/coco-image-share attach share
  -> kernel exposes /dev/cocoimg0
  -> mount -t erofs -o ro /dev/cocoimg0 <bundle>/rootfs
  -> kata-agent starts container
```

vsock/ttrpc 只传控制面元数据，不传 rootfs 数据。

## 为什么不是“直接把整个内存文件系统映射过去”

用户提出的方向是正确的：Image CVM 解压到内存文件系统，Runtime CVM 直接挂载共享对象。但直接映射完整 tmpfs/rootfs 会遇到两个问题：

- Runtime Linux 不能直接 mount “一片裸内存中的目录树”。它需要 block image、filesystem image，或者一个内核文件系统/virtiofs 协议端。
- 如果把完整 rootfs image 映射到 Runtime 的连续 IPA，会要求 Runtime 端预留一个和镜像一样大的 IPA aperture。大镜像会浪费 Realm 内存布局，也继续受连续目标 IPA 影响。

因此 V3 采用“内存中的只读 block image + Runtime block driver”的形式。Runtime 挂载的是 `/dev/cocoimg0`，而不是把 Image CVM 的 tmpfs 目录直接 graft 过来。

这仍然满足原始思路的核心收益：镜像内容在 Image CVM 内存中，Runtime CVM 不再通过网络/磁盘复制完整镜像。

## 数据面模式

### 模式 A：完整只读映射

适合小镜像或调试：

1. Image CVM 注册 rootfs image 的所有页。
2. Runtime CVM 预留一个足够大的 no-map IPA aperture。
3. Runtime CVM 调 RMM attach，把 share 全量映射到 aperture。
4. Runtime 内核把 aperture 暴露为只读 block device 或 loop-like device。

优点：

- 实现简单。
- Runtime 读路径几乎零拷贝。

缺点：

- Runtime 端需要和镜像大小匹配的连续 IPA aperture。
- 大镜像会压缩 VM 可用内存布局。

### 模式 B：窗口化按需映射

这是 V3 主路径：

1. Runtime CVM 只预留小窗口，例如 8 MiB、16 MiB 或 32 MiB。
2. `/dev/cocoimg0` 收到 block read 请求。
3. Runtime driver 计算文件 offset，向 RMM 请求把 share 对应页映射到本地窗口。
4. Runtime driver 从窗口复制到 block layer bio/page cache。
5. driver detach 或缓存窗口，完成 read。

优点：

- 不要求完整镜像大小的连续 Runtime IPA。
- 不要求 Image CVM source pages 物理连续。
- 数据面不走 vsock；只在 Runtime 内核发生标准 block read copy。
- 可以做窗口缓存，提高重复读性能。

缺点：

- 需要 RMM 支持 attach/detach 或 remap window 状态机。
- 比完整映射多一次 kernel copy，但远少于旧方案的文件级复制和 RPC 循环。

默认建议：

- RK3588/OpenCCA 上先用 16 MiB window。
- 如果内存充裕，提升到 32 MiB。
- full-map 只作为小镜像优化路径。

## RMM 接口设计

旧接口：

```text
SMC_RSI_GET_RD_ADDR()
SMC_RSI_MAP_MEM(guest_rd, guest_ipa, image_ipa, map_size)
```

问题是 Image CVM 主动改 Runtime CVM RTT，没有共享对象、权限、detach。

V3 新接口建议：

```text
SMC_RSI_IMG_SHARE_CREATE(desc_ipa) -> share_id
SMC_RSI_IMG_SHARE_ADD_PAGES(share_id, page_list_ipa, nr_pages, file_offset)
SMC_RSI_IMG_SHARE_SEAL(share_id, meta_ipa)
SMC_RSI_IMG_SHARE_ATTACH(share_id, source_rd, target_ipa, file_offset, size, flags)
SMC_RSI_IMG_SHARE_DETACH(target_ipa, size)
SMC_RSI_IMG_SHARE_DESTROY(share_id)
```

安全原则：

- Image CVM 只能 create/add/seal 自己的 share。
- Runtime CVM 必须由自己调用 attach；Image CVM 不能直接写 Runtime CVM RTT。
- `source_rd` 和 `share_id` 必须匹配 RMM 中已 seal 的对象。
- attach 默认只读。
- RMM 检查目标 IPA 当前状态必须是可用于共享窗口的 no-map/DEV/empty 状态。
- detach 必须恢复目标 IPA 状态并做必要 TLB/cache 维护。
- share 对象维护引用计数，Runtime detach 后才允许 Image CVM destroy/unpin。

RMM 内部对象草图：

```c
enum img_share_state {
	IMG_SHARE_CREATING,
	IMG_SHARE_SEALED,
	IMG_SHARE_DESTROYING,
};

struct img_share_page {
	unsigned long source_ipa;
	unsigned long source_pa;
	unsigned long file_offset;
};

struct img_share {
	u64 share_id;
	struct granule *source_rd;
	u64 size;
	u32 block_size;
	u32 flags;
	u8 digest[32];
	enum img_share_state state;
	atomic_t refs;
	struct img_share_page *pages;
};
```

实现时可以先把 page list 保存在 Image CVM driver 中，RMM 只保存 seal 后的最小元数据；但更安全的方向是 RMM 保存 source PA 列表和引用状态。

### RMM 无通用堆约束下的正式对象模型

定点核对 `tf-rmm` 后，需要修正“RMM 保存完整页列表”的早期想法：

- RMM runtime 基本没有可随意使用的通用动态堆。
- 大镜像的 page list 可能达到数万页，不适合复制进 RMM 静态内存。
- 更稳妥的模型是“RMM 小对象表 + Image CVM sealed metadata pages”。

推荐 P3 对象模型：

```c
#define IMG_SHARE_MAX_OBJECTS 32

struct img_share_obj {
	u64 id;
	unsigned long source_rd_pa;
	unsigned long meta_ipa;
	unsigned long meta_pa;
	u64 image_size;
	u32 page_count;
	u32 page_shift;
	u32 flags;
	u32 refs;
	u8 state;
};
```

metadata page 仍在 Image CVM 内存中，由 Image CVM driver 生成：

```c
struct img_share_meta {
	u32 magic;
	u16 version;
	u16 page_shift;
	u64 image_size;
	u32 page_count;
	u32 extent_count;
	u8 digest[32];
	struct img_share_extent extents[];
};

struct img_share_extent {
	u64 file_offset;
	u64 source_ipa;
	u32 page_count;
	u32 flags;
};
```

RMM 在 `SEAL` 时做三件事：

- walk 并校验 metadata pages 和 source pages 都属于 Image CVM。
- 把 metadata pages 和 source image pages 在 Image CVM 自己的 S2 中改成 read-only，防止 seal 后被源端修改。
- 在固定对象表中保存 `id/source_rd/meta_pa/image_size/page_count/digest/state` 这类小元数据。

Runtime 在 `ATTACH` 时：

- 自己调用 RMM，不接受 Image CVM 直接改 RTT。
- RMM 根据 `share_id + file_offset` 查 sealed metadata，找到 source IPA，再 walk 到 source PA。
- RMM 把 source PA 以 read-only 方式映射进 Runtime 的小 window。
- Runtime block driver 从 window copy 到 bio/page cache，然后 `DETACH` 或缓存该 window。

这个模型避免了三件事：

- 避免 Image CVM source 必须来自连续 CMA。
- 避免 Runtime 必须拥有完整 rootfs image 大小的连续 IPA。
- 避免 RMM 为大镜像维护不可控长度的动态页表。

## Guest Kernel Driver 设计

旧驱动路径：`linux-image-share/drivers/image-server`

V3 建议重命名或新增：

```text
linux-image-share/drivers/coco-image-share/
```

设备：

```text
/dev/coco-image-share
/dev/cocoimg0
/dev/cocoimg1
```

Image CVM ioctl：

```c
COCO_IMG_IOC_CREATE_FROM_FILE
COCO_IMG_IOC_ADD_FILE_RANGE
COCO_IMG_IOC_SEAL
COCO_IMG_IOC_DESTROY
```

Runtime CVM ioctl：

```c
COCO_IMG_IOC_ATTACH
COCO_IMG_IOC_DETACH
COCO_IMG_IOC_QUERY
```

关键实现：

- Image CVM 使用 `memfd_create` 或 tmpfs 文件保存 EROFS/SquashFS image。
- driver pin 文件页并用 `page_to_phys()` 得到 source IPA。
- driver 分批把 page list 传给 RMM，不需要 CMA。
- seal 后禁止文件增长、收缩和写入。memfd 可使用 `F_SEAL_WRITE | F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL`。
- Runtime CVM attach 后注册一个只读 block device。
- block device `submit_bio` 中使用固定窗口映射 share extents。

窗口化 read 伪代码：

```c
static void cocoimg_submit_bio(struct bio *bio)
{
	u64 off = bio->bi_iter.bi_sector << 9;
	u64 len = bio->bi_iter.bi_size;

	while (len > 0) {
		u64 chunk = min_t(u64, len, window_size);

		rsi_img_share_attach(share_id, source_rd, window_ipa, off, chunk, RO);
		memcpy_from_window_to_bio(window_va, bio, chunk);
		rsi_img_share_detach(window_ipa, chunk);

		off += chunk;
		len -= chunk;
	}

	bio_endio(bio);
}
```

后续优化：

- 多窗口缓存，避免重复 attach/detach。
- 以 2 MiB 为窗口粒度，减少 SMC 次数。
- 顺序预读，适配 EROFS/SquashFS mount 阶段。

## Firecracker/Kata 内存布局

当前 Firecracker-CCA 在 FDT 中生成：

```text
/reserved-memory/reserved_region@...
compatible = "shared-dma-pool"
no-map
reg = <reserved_start reserved_size>
```

V3 仍然需要 no-map aperture，但语义从“装完整镜像的 CMA”改为“Runtime 共享窗口”。

建议：

- 默认 `imgshare_window_size = 16 MiB`。
- 可通过 Kata hypervisor annotation/config 调整到 32 MiB 或 64 MiB。
- 不再要求 `linux,cma-default`。
- FDT compatible 建议改成明确名字：

```text
compatible = "coco,imgshare-window"
```

兼容期可同时保留 `shared-dma-pool`，让旧驱动还能发现节点。

长期优化：

- Runtime 的 window aperture 可以不占用普通 Linux memory。
- 如果 KVM/RMM 允许对目标 Realm 创建未 backed 的 IPA hole，则 Firecracker 不必为 window 分配真实 host backing。
- 如果当前实现仍要求 memslot，window 也固定很小，内存成本可接受。

## guest-components / Kata 控制面

V3 fast path 的 RPC 不再包含 `read_rootfs_chunk`。

建议 proto：

```proto
service ImageShareService {
  rpc prepare_rootfs(PrepareRootfsRequest) returns (PrepareRootfsResponse);
  rpc destroy_share(DestroyShareRequest) returns (DestroyShareResponse);
}

message PrepareRootfsResponse {
  string image_id = 1;
  string fs_type = 2;          // erofs or squashfs
  uint64 image_size = 3;
  uint64 block_size = 4;
  string rootfs_digest = 5;
  bytes oci_config_json = 7;
  uint64 source_rd_addr = 8;
  uint64 share_id = 9;
  uint64 page_count = 10;
}
```

Image CVM side：

1. `vsock-ttrpc-server` 收到 `prepare_rootfs(image_ref)`。
2. 调 CDH pull image，生成 bundle/rootfs。
3. 使用 `mkfs.erofs` 或 `mksquashfs` 生成只读 rootfs image。
4. 调 `/dev/coco-image-share` create/seal。
5. 返回 share descriptor。

Runtime CVM side：

1. kata-agent 的 `guest_pull_image()` 调 `prepare_rootfs`。
2. 写 OCI config 到 bundle。
3. 调 `/dev/coco-image-share` attach。
4. 等待 `/dev/cocoimgN` 出现。
5. `mount -t erofs -o ro /dev/cocoimgN <bundle>/rootfs`。

当前决策：

- Runtime CVM 主路径必须使用 RMM share descriptor 和 `/dev/cocoimg0`。
- `read_rootfs_chunk` copy-mode 已从主代码删除；fast path 失败时直接失败并暴露根因。
- 调试阶段如果需要复活 copy-mode，必须在新分支或单独实验脚本中完成，不能重新进入默认路径。

## 安全模型

最小 TCB：

- RMM：共享对象和页表权限的强制执行者。
- Image CVM：受信任镜像服务，负责拉取、校验、生成 rootfs image。
- Runtime CVM：消费方，自己发起 attach。

关键安全属性：

- Runtime attach 必须由 Runtime 自己调用 RMM。
- Image CVM 不能主动修改 Runtime CVM RTT。
- share seal 后内容不可变。
- Runtime 只读映射，不允许写回 Image CVM 页。
- RMM 维护 refs，避免 Image CVM 提前释放页导致 Runtime 读悬挂数据。
- digest 由 Image CVM 返回，后续可升级为 RMM 记录 digest 或 dm-verity/FS-verity。

可选增强：

- RMM 在 `SEAL` 时把 Image CVM source pages 改成只读，防止 seal 后被源端修改。
- Runtime driver 用 dm-verity 挂载 rootfs image。
- share descriptor 加入 nonce/epoch，防止复用陈旧 share_id。

## 性能预期

旧 V2 copy-mode：

- vsock 复制完整 rootfs image。
- Runtime tmpfs/可写层需要容纳完整 image。
- ext4 image 小镜像也可能膨胀到十几 MiB 以上。

V3 window block mode：

- vsock 只传 metadata。
- 镜像内容不进入 Runtime tmpfs。
- Runtime 只读取 mount 和容器启动实际访问的 blocks。
- 多 Runtime CVM 可以共享同一个 Image CVM source pages。

预期收益：

- warm cache 场景启动时间主要由 attach、mount、kata-agent 流程决定。
- 内存峰值约为 `Image rootfs image pages + Runtime window + Runtime page cache`。
- Runtime window 固定 16/32 MiB，不随镜像总大小线性增长。

## 分阶段落地计划

### P0：文档和接口冻结

- 建立本文档。
- 冻结 V3 fast path 的 RPC 元数据。
- 明确 V2 copy-mode 只作为 fallback。

### P1：只读 rootfs image 生成

- 在 Image CVM guest image 中加入 `mkfs.erofs` 或 `mksquashfs`。
- `prepare_rootfs` 默认生成 EROFS/SquashFS，而不是 ext4。
- 本地验证生成的 rootfs image 可 loop mount。

### P2：kernel driver page-list share prototype

- 新增 `/dev/coco-image-share`。
- Image CVM 支持从 memfd/tmpfs 文件创建 share。
- Runtime CVM 先支持 full-map 小镜像 attach，暴露 `/dev/cocoimg0`。
- 用 busybox rootfs 做 sha256 和 mount 验证。

### P3：RMM share object

- 新增 `SMC_RSI_IMG_SHARE_*`。
- Runtime-initiated attach。
- detach/refcount/只读权限。
- 保留旧 `SMC_RSI_MAP_MEM` 只作为兼容测试接口。

### P4：窗口化 block driver

- Runtime block driver 支持 16 MiB window。
- block read 时 attach/detach share extents。
- 加入简单 LRU window cache。

### P5：Kata fast path 接入

- kata-agent `guest_pull_image()` 优先走 V3 attach。
- fallback 到 V2 copy-mode。
- nerdctl/kata smoke 验证 busybox/nginx。

### P6：安全和性能增强

- dm-verity 或 fs-verity。
- RMM seal 后 source readonly。
- 多 Runtime CVM 引用计数压力测试。
- benchmark：启动耗时、SMC 次数、RSS、网络流量。

## 测试计划

### 单元测试

- image-rs：
  - `prepare_rootfs` 返回 share descriptor。
  - fallback 和 fast path 选择逻辑。
- kernel driver：
  - ioctl ABI size/layout。
  - page list 分块。
  - window offset 对齐。
- RMM：
  - attach 非 sealed share 必须失败。
  - attach 非 owner/source mismatch 必须失败。
  - attach 到已占用 target IPA 必须失败。
  - detach 后再次 attach 必须成功。

### 集成测试

1. Image CVM 创建 4 KiB share，Runtime 读取 sha256。
2. Image CVM 创建 64 MiB sparse/random share，Runtime 随机读校验。
3. Image CVM 生成 busybox EROFS，Runtime mount 并执行 `/bin/sh -c true`。
4. Kata 启动 busybox confidential container。
5. 两个 Runtime CVM 同时 attach 同一个 share。

### RK3588 smoke

推荐命令形态：

```bash
sudo nerdctl run \
  --cgroup-manager=cgroupfs \
  --snapshotter guest-pull \
  --annotation "io.kubernetes.cri.image-name=docker.m.daocloud.io/library/busybox:latest" \
  --annotation "io.kata-containers.is-image-cvm=true" \
  --runtime io.containerd.kata.v2 \
  -it docker.m.daocloud.io/library/busybox:latest sh
```

成功判据：

- containerd 日志出现 `image-share fast path attached`。
- Runtime CVM 内出现 `/dev/cocoimg0`。
- rootfs mount 类型为 `erofs` 或 `squashfs`。
- 容器内能执行 `cat /etc/os-release` 或 busybox `true`。
- 日志中没有 `read_rootfs_chunk` fast path 数据传输。

## 风险和待验证点

- 当前 Firecracker/RMM 是否允许 target window aperture 不 backing host memory；如果不允许，先使用小 memslot。
- RMM 中 source page seal 后 readonly 的具体 S2TTE helper 需要确认。
- Runtime block driver attach/detach 每个 bio 都 SMC，可能需要窗口缓存和 readahead。
- EROFS 工具链需要放入 Kata guest image；如果太麻烦，短期用 SquashFS 或 ext4 readonly 小镜像验证接口。
- 当前 `rsi_reserved_mem_phys` hook 仍以 reserved-memory 为入口，V3 需要逐步去掉对 CMA 默认区域的依赖。

## 失败方案黑名单

以下方案已经被当前文档和测试过程淘汰，不再作为主路径推进：

- 继续使用 `read_rootfs_chunk` / ext4 copy-mode 作为镜像共享机制。
  - 原因：Runtime CVM 需要通过 vsock 接收完整 rootfs image，tmpfs/可写层容易被撑满；它还会掩盖 RMM fast path 的真实错误。
  - 结论：已从默认控制面删除，不能作为 fallback 重新进入主路径。
- 继续让 Image CVM 通过旧 `SMC_RSI_MAP_MEM` 主动覆盖 Runtime CVM 的同一段 IPA。
  - 原因：缺少 Runtime-initiated attach、detach、readonly、refcount 和 remap 生命周期。
  - 结论：只能保留为兼容/诊断接口，新方案必须引入 RMM share object。
- 用 `debugfs -R "stat <path>"` 的退出码判断 guest image 内文件是否存在。
  - 原因：本轮检查发现文件不存在时 debugfs 仍可能返回 0，容易产生假阳性。
  - 结论：必须解析 `debugfs` 输出，或用 `dump` 后检查宿主机文件是否真实生成。
- 在未配置 arm64 foreign architecture/source 的宿主机上直接执行 `apt-get download <pkg>:arm64`。
  - 原因：宿主机 apt 默认只有 amd64 包索引，直接下载会报 `Unable to locate package ...:arm64`。
  - 结论：使用隔离的临时 apt root 和 Ubuntu ports arm64 sources，不污染宿主机 apt 配置。
- 只通过扩大 CMA/reserved-memory 来解决大镜像共享。
  - 原因：这只能缓解 Image CVM source buffer 的容量问题，不能解决 Runtime 完整连续目标 IPA、无 detach/refcount、以及多 Runtime 复用问题。
  - 结论：CMA 可以临时调大用于诊断，但不能作为 V3 主路径。
- 把 `SMC_RSI_MAP_MEM_LIST` 当作最终安全接口。
  - 原因：P2a 仍是 Image CVM 主动改 Runtime RTT；虽然 Runtime window 已改为 readonly S2 映射，但仍缺少 source seal、detach 和引用计数。
  - 结论：它只用于验证“source pages 不必来自连续 CMA”；正式路径必须升级为 Runtime 主动 attach 的 `SMC_RSI_IMG_SHARE_*`。
- 把当前 `0x1B0+` 自定义 RSI FID 当作长期 ABI。
  - 原因：本地旧接口已使用 `GET_RD_ADDR/MAP_MEM` 的 `0x1B0/0x1B1`，P2a 延续到 `0x1B2`；这与标准范围边界有重叠风险。
  - 结论：过渡原型可以沿用本地约定，正式 share-object API 需要重新整理 FID 分配和 logger 范围。
- 让 Realm destroy/data destroy 路径直接遇到 active image-share S2TTE。
  - 原因：`docs/log/3.log` 显示 Runtime CVM 超时销毁时，RMM `DATA_DESTROY` 看到了仍指向 Image CVM PA 的共享映射，随后 `find_lock_granule(..., GRANULE_STATE_DATA)` 返回空并触发 assert。
  - 结论：RMM 必须在 `REALM_DESTROY`/`DATA_DESTROY` 前清理该 Realm 作为 target 或 source 的 image-share attachment；清理后仍不匹配时也只能返回错误并打日志，不能 assert 杀死整板。

## 第一批代码锚点

P1/P2 建议先做最小可验证原型，不急着一次性完成 windowed block driver。

第一批建议修改：

- `guest-components/image-rs/src/shared_rootfs.rs`
  - 新增 `RootfsImageFormat::Erofs`。
  - 支持调用 `mkfs.erofs` 生成只读 rootfs image。
  - 保留 ext4 作为 fallback，但 fast path 默认优先 EROFS。
- `guest-components/confidential-data-hub/hub/src/bin/vsock-ttrpc-server.rs`
  - `prepare_rootfs` 生成 EROFS/SquashFS。
  - 调用 `/dev/coco-image-share` create/seal。
  - 创建 RMM share 失败时直接返回错误，不返回 copy-mode 元数据。
- `guest-components/image-rs/protos/image.proto`
  - 在 `PrepareRootfsResponse` 中保留 `source_rd_addr/share_id/page_count`。
  - 不再定义 `rootfs_image_path` 和 `read_rootfs_chunk`。
- `linux-image-share/drivers/coco-image-share/`
  - 新建驱动目录。
  - 第一版只支持 Image CVM create/seal 和 Runtime full-map attach。
  - 第二版再支持 windowed block device。
- `opencca/tf-rmm/runtime/rsi/rsi_image.c`
  - 新增 `SMC_RSI_IMG_SHARE_*` handler。
  - 初期可复用当前逐页 `realm_ipa_to_pa` 和 RTT 写入逻辑，但必须把 attach 改为 Runtime initiated。
- `Firecracker-CCA/src/vmm/src/arch/aarch64/fdt.rs`
  - reserved-memory compatible 增加 `coco,imgshare-window`。
  - 将 reserved 区语义改为 window aperture，而不是大 CMA buffer。
- `scripts/image/install-guest-components-into-kata-image.sh`
  - 注入 `mkfs.erofs` 或 `mksquashfs` 所需工具。
  - 验证 guest image 中存在 EROFS/SquashFS mount 能力。

第一批验收目标：

1. Image CVM 能生成 busybox 的 EROFS rootfs image。
2. Image CVM 能 create/seal 一个 share descriptor。
3. Runtime CVM 能 attach 小镜像并在 guest 中看到 `/dev/cocoimg0`。
4. Runtime CVM 能 mount `/dev/cocoimg0` 到 bundle rootfs。
5. kata-agent 能从该 rootfs 启动 busybox。

## 2026-06-10 设计记录 1

本轮只做设计文档，不修改代码。

已确认的旧实现事实：

- `linux-image-share/drivers/image-server/image-server.c` 只有一个 `reserved_mem`。
- `IMG_IOCTL_LOAD_FILE` 会把完整文件读入该 buffer。
- `IMG_IOCTL_MAP_IPA` 调 `rsi_map_mem(guest_rd, guest_ipa, reserved_mem_phys, size)`。
- `opencca/tf-rmm/runtime/rsi/rsi_image.c` 的 `handle_rsi_map_mem` 已经逐页 walk `image_ipa`，不是只能处理连续 source PA。
- 当前接口缺少 share object、detach、readonly、refcount 和 Runtime-initiated attach。

设计决策：

- 不继续扩容 CMA 作为主方案。
- 不把完整 rootfs image 复制到 Runtime tmpfs。
- 主方案采用 RMM-backed Image Share Object + Runtime windowed block driver。
- Image CVM 使用 memfd/tmpfs rootfs image + page list 注册，绕开 source 连续内存限制。
- Runtime CVM 使用小 no-map window + block driver，绕开完整镜像连续目标 IPA 限制。

测试记录：

- 本轮未运行构建或远端 smoke。
- 下一轮从 P1/P2 开始修改代码时，必须在本文件继续追加“代码修改”和“测试结果”。

## 2026-06-10 P1 实现记录 1：只读 rootfs image 优先

本轮目标：

- 让 Image CVM 的 rootfs image 构建逻辑优先选择只读文件系统格式。
- 继续保留 ext4 fallback，避免 guest image 暂时缺少 `mkfs.erofs`/`mksquashfs` 时阻断现有 bring-up。
- 本轮不接入 RMM share object，不宣称 fast path 已完成。

代码修改：

- `guest-components/image-rs/src/shared_rootfs.rs`
  - 新增 `RootfsImageFormat::Erofs`，`as_fs_type()` 返回 `erofs`。
  - 新增 `BuildRootfsImageOptions::erofs()`。
  - 新增 `rootfs_image_format_candidates()`：
    - 若 `mkfs.erofs` 存在，优先返回 EROFS。
    - 若 `mksquashfs` 存在，其次返回 SquashFS。
    - 始终追加 Ext4 fallback。
  - 新增 `build_erofs_image()`，调用 `mkfs.erofs <output> <rootfs_dir>`。
  - 新增测试 `build_squashfs_image_when_tool_is_available`，在本机存在 `mksquashfs` 时真实生成 squashfs rootfs image。
- `guest-components/confidential-data-hub/hub/src/bin/vsock-ttrpc-server.rs`
  - `prepare_rootfs` 不再硬编码 `RootfsImageFormat::Ext4`。
  - 新增 `prepare_shared_rootfs_image()`，按候选格式依次查找缓存或构建 rootfs image。
  - 新增 `build_options_for_format()`，将 EROFS/SquashFS/Ext4 分发到对应 builder。
  - 如果某个格式构建失败，会记录失败并尝试下一个格式。

测试命令：

```bash
cd guest-components
cargo fmt -p image-rs -p confidential-data-hub
cargo test -p image-rs shared_rootfs --lib
cargo check -p confidential-data-hub --bin vsock-ttrpc-server --features bin,ttrpc
```

测试结果：

```text
cargo test -p image-rs shared_rootfs --lib
running 7 tests
test shared_rootfs::tests::build_squashfs_image_when_tool_is_available ... ok
test shared_rootfs::tests::rootfs_image_format_candidates_keep_ext4_fallback ... ok
test result: ok. 7 passed; 0 failed

cargo check -p confidential-data-hub --bin vsock-ttrpc-server --features bin,ttrpc
Finished dev profile
```

当前环境观察：

```text
mkfs.erofs: not installed
mksquashfs: /usr/bin/mksquashfs
mkfs.ext4: /usr/sbin/mkfs.ext4
```

结论：

- P1 的“只读格式优先”代码路径已通过本地测试。
- 当前构建机上会优先生成 SquashFS，然后 fallback 到 Ext4。
- EROFS 逻辑已接入，但因本机缺少 `mkfs.erofs`，尚未做真实 EROFS image 构建测试。
- 下一步应把 EROFS/SquashFS 工具注入 Kata guest image，或先以 SquashFS 作为只读 rootfs image 验证 Image CVM -> Runtime CVM 挂载流程。

## 2026-06-10 环境检查记录 1：guest image 只读工具

本轮只做离线检查，不修改 guest image。

检查对象：

- `COCO-SFTP/images/kata-containers-cca.img`

有效检查方法：

- 从镜像第一分区导出 ext4。
- 使用 `debugfs -R "stat <path>"` 查看输出是否包含 `File not found`。
- 使用 `debugfs -R "dump <path> <host_path>"` 后检查宿主机文件是否生成。

结果：

```text
/usr/bin/mkfs.erofs: File not found
/usr/bin/mksquashfs: File not found
dump /usr/bin/mkfs.erofs: no host file generated
dump /usr/bin/mksquashfs: no host file generated
```

结论：

- 当前 Kata guest image 尚不能在 Image CVM 内生成 EROFS/SquashFS。
- P1 代码已具备只读格式优先能力，但远端运行仍会 fallback 到 ext4，直到注入 `mkfs.erofs` 或 `mksquashfs`。
- 下一步优先做工具注入和 verify 检查；若工具注入成本过高，再进入 `/dev/coco-image-share` 原型时先用宿主机预生成的小只读镜像验证 RMM/Runtime 挂载链路。

## 2026-06-10 P1 实现记录 2：只读 rootfs 工具注入

本轮目标：

- 让 Kata guest image 里的 Image CVM 能实际执行 `mkfs.erofs` 和 `mksquashfs`。
- 不在 guest 内运行 apt；改为宿主机下载 arm64 deb、离线解包、debugfs 注入。
- 避免污染宿主机 apt architecture/source 配置。

代码修改：

- 新增 `scripts/image/install-rootfs-tools-into-kata-image.sh`
  - 默认目标镜像：`COCO-SFTP/images/kata-containers-cca.img`。
  - 默认 arm64 源：Ubuntu ports focal `main universe`、`focal-updates`、`focal-security`。
  - 下载包：
    - `erofs-utils:arm64`
    - `squashfs-tools:arm64`
    - `liblz4-1:arm64`
    - `libzstd1:arm64`
    - `liblzo2-2:arm64`
  - 注入文件：
    - `/usr/bin/mkfs.erofs`
    - `/usr/bin/mksquashfs`
    - `/usr/lib/aarch64-linux-gnu/liblz4.so.1`
    - `/usr/lib/aarch64-linux-gnu/libzstd.so.1`
    - `/lib/aarch64-linux-gnu/liblzo2.so.2`
  - 支持参数：
    - `--dry-run`
    - `--verify-only`
    - `--skip-download`

实现注意：

- Ubuntu focal 的 `liblz4` 和 `libzstd` 位于 `/usr/lib/aarch64-linux-gnu`。
- `liblzo2` 位于 `/lib/aarch64-linux-gnu`。
- deb payload 中这些 soname 通常是 symlink；脚本注入时用 `readlink -f` 解析真实文件，把真实 `.so` 内容写到 soname 路径，避免 debugfs symlink 处理复杂化。
- verify 复用 `coco_file_exists_in_ext4`，通过 `debugfs` 输出中的 `Inode:` 判断文件存在，避免退出码假阳性。

测试命令：

```bash
bash -n scripts/image/install-rootfs-tools-into-kata-image.sh
scripts/image/install-rootfs-tools-into-kata-image.sh --dry-run
scripts/image/install-rootfs-tools-into-kata-image.sh --verify-only
scripts/image/install-rootfs-tools-into-kata-image.sh --skip-download
scripts/image/install-rootfs-tools-into-kata-image.sh --verify-only
```

测试结果：

初始 verify 确认工具缺失：

```text
[missing:image] /usr/bin/mkfs.erofs
[missing:image] /usr/bin/mksquashfs
[missing:image] /lib/aarch64-linux-gnu/liblz4.so.1
[missing:image] /lib/aarch64-linux-gnu/libzstd.so.1
[missing:image] /lib/aarch64-linux-gnu/liblzo2.so.2
```

第一次真实执行在写入 guest image 之前失败：

```text
[coco] error: extracted package payload is missing /lib/aarch64-linux-gnu/liblz4.so.1
```

失败原因：

- `liblz4-1:arm64` 和 `libzstd1:arm64` 的 payload 路径是 `/usr/lib/aarch64-linux-gnu/...`。
- 已修正脚本路径，并将失败原因加入黑名单/注意事项。

修正后执行：

```text
[coco] installed guest image file /usr/bin/mkfs.erofs
[coco] installed guest image file /usr/bin/mksquashfs
[coco] installed guest image file /usr/lib/aarch64-linux-gnu/liblz4.so.1
[coco] installed guest image file /usr/lib/aarch64-linux-gnu/libzstd.so.1
[coco] installed guest image file /lib/aarch64-linux-gnu/liblzo2.so.2
[coco] updated Kata image with read-only rootfs tools
[ok:image] /usr/bin/mkfs.erofs
[ok:image] /usr/bin/mksquashfs
[ok:image] /usr/lib/aarch64-linux-gnu/liblz4.so.1
[ok:image] /usr/lib/aarch64-linux-gnu/libzstd.so.1
[ok:image] /lib/aarch64-linux-gnu/liblzo2.so.2
[coco] Kata guest image contains read-only rootfs tools
```

额外验证：

- 从 guest image dump 出注入文件后执行 `file`：

```text
mkfs.erofs: ELF 64-bit LSB pie executable, ARM aarch64
mksquashfs: ELF 64-bit LSB pie executable, ARM aarch64
liblz4.so.1: ELF 64-bit LSB shared object, ARM aarch64
libzstd.so.1: ELF 64-bit LSB shared object, ARM aarch64
liblzo2.so.2: ELF 64-bit LSB shared object, ARM aarch64
```

- `readelf -d` 依赖覆盖：

```text
mkfs.erofs needs: liblz4.so.1, libc.so.6, ld-linux-aarch64.so.1
mksquashfs needs: libpthread.so.0, libm.so.6, libz.so.1, liblzma.so.5,
                  liblzo2.so.2, liblz4.so.1, libzstd.so.1, libc.so.6,
                  ld-linux-aarch64.so.1
```

其中 `libpthread/libm/libz/liblzma/libc/ld-linux-aarch64` 已存在于原 guest image。

结论：

- Kata guest image 已具备 Image CVM 侧生成 EROFS/SquashFS rootfs image 的用户态工具。
- P1 “只读 rootfs image 优先”的代码路径已经不再因为 guest image 缺工具而必然 fallback 到 ext4。
- 下一步应重新构建/注入 `vsock-ttrpc-server` 后做 Image CVM 侧 `prepare_rootfs` 真实运行验证，确认远端会选择 `erofs` 或 `squashfs`。

## 2026-06-10 RMM 稳定性记录：share attach 后销毁卡死

输入日志：

- `docs/log/3.log`

关键现象：

```text
IMG_SHARE_ADD_PAGES share=2 pages=1024
IMG_SHARE_SEAL share=2
IMG_SHARE_ATTACH ... > RSI_SUCCESS
IMG_SHARE_DETACH ... > RSI_SUCCESS
IMG_SHARE_ATTACH ... > RSI_SUCCESS
SMC_RMI_DATA_DESTROY ... > RMI_ERROR_RTT
Assertion "g_data != NULL" failed ... runtime/rmi/rtt.c:1113
```

判断：

- share attach 本身能成功。
- 后续 Runtime CVM 超时或容器启动失败触发 Realm teardown。
- teardown 期间 `DATA_DESTROY` 遇到 active image-share 映射，target IPA 的 S2TTE 指向 Image CVM source PA，而不是 Runtime Realm 自己的 DATA granule。
- 原实现按普通 DATA 页销毁，`find_lock_granule(data_addr, GRANULE_STATE_DATA)` 返回空后 assert，导致 RMM/板子异常。

已落地修复方向：

- `rsi_image.c` 增加 `rsi_img_share_cleanup_realm(rd_pa)`。
- cleanup 同时处理两类关系：
  - 当前 Realm 是 Runtime target：恢复所有映射到该 Realm 的 attachment。
  - 当前 Realm 是 Image source：恢复借用该 source share 的所有 attachment，并丢弃 source share object。
- `smc_realm_destroy()` 开始时调用 image-share cleanup。
- `smc_data_destroy()` 在发现 DATA granule 不匹配时，先尝试 cleanup 再重试一次。
- cleanup 后仍不匹配时返回 `RMI_ERROR_RTT` 并记录 `DATA_DESTROY_BAD_DATA_GRANULE`，不再 assert。

构建和刷写结果：

```text
tf-rmm.elf sha256: 7b1272bda21d45559b6159f67dbc8d15f463f515527baee951a0bab113966fa1
idbloader.img sha256: 91e413683313810e51595f2a2872d718c1f1fde4942df6e92fb9873f74ef042f
u-boot.itb sha256: 0edfee249974d9c15b23c7715913a3d2ddccc395eec4aaf756e79e367f6b7c65
u-boot-rockchip-spi.bin sha256: 8d22dd2a425fbabe1c41f1a17a5d13e59dac50bcbe638d471c947b5eb552500f
```

已通过 Pi 刷写 RK3588 MMC 并恢复 SSH：

```text
Linux opencca-rock5b-rk3588 6.12.0-opencca-wip #1 SMP PREEMPT Wed Jun 10 11:09:56 CST 2026
```

后续测试要求：

- 重复触发 Runtime CVM 启动失败和正常退出，确认 RMM log 不再出现 `g_data != NULL` assert。
- 如果仍看到 `DATA_DESTROY_BAD_DATA_GRANULE`，优先收集对应 `IMG_SHARE_ATTACH/DETACH/CLEANUP` 前后日志，而不是先扩大 CMA 或重刷旧固件。

## 2026-06-10 Host CNI 模块记录：xt_comment

问题：

- RK host kernel 缺 `xt_comment.ko`。
- CNI/iptables comment match 会失败，影响容器网络初始化。

修复：

- 使用 `scripts/deploy/install-host-kernel-modules.sh`。
- 构建基线来自 RK `/boot/config-6.12.0-opencca-wip`。
- 只启用 `CONFIG_NETFILTER_XT_MATCH_COMMENT=m`。
- 全部构建命令使用 `LOCALVERSION=`，避免 dirty tree 生成 `6.12.0-opencca-wip+`。

验证结果：

```text
xt_comment vermagic=6.12.0-opencca-wip
iptables comment match test passed
runc CNI smoke reached runc-cni-ok
```

当前剩余问题：

- Kata overlay smoke 已越过 CNI/iptables comment 问题，但失败在 rootfs mount：

```text
failed to mount /run/kata-containers/shared/containers/<cid>/rootfs
to /run/kata-containers/<cid>/rootfs: ENOENT
```

这属于 Kata/shared-rootfs 路径问题，不再归因于 `xt_comment` 缺失。

## 2026-06-10 P1 实现记录 3：Image CVM 组件重建和注入

本轮目标：

- 将 P1 中修改过的 `vsock-ttrpc-server` 和 `image-rs` 重新编译进 Image CVM 侧 guest-components。
- 确认重新注入 guest-components 后，只读 rootfs 工具仍保留在 Kata guest image 中。

执行命令：

```bash
./scripts/build/build-guest-components.sh
./scripts/image/install-guest-components-into-kata-image.sh
./scripts/image/install-guest-components-into-kata-image.sh --verify-only
./scripts/image/install-rootfs-tools-into-kata-image.sh --verify-only
```

结果：

```text
[coco] guest-components artifacts are ready under /home/mzh/RK3588/COCO/artifacts/guest-components
[coco] Kata guest image contains guest-components
[ok:image] /usr/bin/mkfs.erofs
[ok:image] /usr/bin/mksquashfs
[ok:image] /usr/lib/aarch64-linux-gnu/liblz4.so.1
[ok:image] /usr/lib/aarch64-linux-gnu/libzstd.so.1
[ok:image] /lib/aarch64-linux-gnu/liblzo2.so.2
[coco] Kata guest image contains read-only rootfs tools
```

注意：

- 构建过程中 make 内部尝试使用 `sudo` 安装 Rust target，因无交互密码打印了 warning，但实际 cargo build 继续完成，最终脚本退出码为 0。
- 本轮只重建并注入 Image CVM 侧 guest-components。
- Runtime CVM 侧 kata-agent 也链接 `guest-components/image-rs`，后续修改 Runtime 挂载/fast path 逻辑时仍必须执行：

```bash
./scripts/build/build-kata-agent.sh
./scripts/image/install-kata-agent-into-kata-image.sh
```

结论：

- Image CVM 侧已具备新 `prepare_rootfs` 只读格式候选逻辑。
- Kata guest image 同时具备新 guest-components 和 `mkfs.erofs`/`mksquashfs` 工具。
- 下一步可以同步到 RK3588 后运行 Image CVM `prepare_rootfs` 真实验证，观察返回 `fs_type=erofs` 或 `squashfs`，再进入 RMM share object/`/dev/coco-image-share` 原型。

## 2026-06-10 P2a 实现记录：page-list 过渡映射接口

本轮目标：

- 先验证“Image CVM source pages 不需要来自连续 CMA/reserved buffer”这个关键判断。
- 不直接进入完整 share object，避免一次性同时引入对象生命周期、只读权限、detach、refcount 和 block driver。
- 保留旧 `/dev/image-server` 兼容路径，但把 reserved-memory 节点语义逐步迁移为 Runtime 小窗口。

代码修改：

- `opencca/tf-rmm/lib/smc/include/smc-rsi.h`
  - 新增过渡 FID `SMC_RSI_MAP_MEM_LIST`，当前值为 `0xC40001B2`。
- `opencca/tf-rmm/runtime/core/exit.c`
  - 在 Realm RSI handler 中分发 `SMC_RSI_MAP_MEM_LIST`。
- `opencca/tf-rmm/runtime/include/rsi-handler.h`
  - 声明 `handle_rsi_map_mem_list()`。
- `opencca/tf-rmm/runtime/rsi/logger.c`
  - 增加 `SMC_RSI_MAP_MEM_LIST` 日志项，参数数为 5，返回值数为 2。
- `opencca/tf-rmm/runtime/rsi/rsi_image.c`
  - 新增 `struct rsi_img_page_desc { source_ipa, file_offset }`。
  - 新增 `handle_rsi_map_mem_list()`：
    - 参数为 `guest_rd_pa, guest_ipa, page_list_ipa, nr_pages, flags`。
    - `flags` 当前必须为 0。
    - `nr_pages` 当前限制为单个 RMM granule 内能容纳的 descriptor 数量，即 256 个 4 KiB 页。
    - RMM 对每个 `source_ipa` 单独 walk，再映射到 Runtime 连续 window。
    - 返回 `x1=mapped_pages`，便于诊断部分失败。
  - 新增内部 helper `map_pa_to_guest_ipa()`，复用旧 `assigned_ram` 映射方式。
- `linux-image-share/arch/arm64/include/asm/rsi_smc.h`
  - 新增 Linux 侧 `SMC_RSI_MAP_MEM_LIST` ABI 定义。
- `linux-image-share/arch/arm64/include/asm/rsi_cmds.h`
  - 新增 `rsi_map_mem_list()` wrapper。
- `linux-image-share/drivers/image-server/image-server.c`
  - 优先查找 FDT compatible `coco,imgshare-window`。
  - 兼容期 fallback 到旧 `shared-dma-pool`。
- `Firecracker-CCA/src/vmm/src/arch/aarch64/fdt.rs`
  - reserved-memory compatible 改为 string-list：

```text
"coco,imgshare-window", "shared-dma-pool"
```

ABI 说明：

```text
SMC_RSI_MAP_MEM_LIST(guest_rd_pa, guest_ipa, page_list_ipa, nr_pages, flags)

struct rsi_img_page_desc {
	u64 source_ipa;
	u64 file_offset;
};
```

当前 P2a 语义：

- 调用方仍是 Image CVM。
- source IPA 可以不连续，目标是绕过旧 driver 的单块 CMA source buffer。
- target IPA 仍是一段连续 Runtime window，因此 P2a 只能验证 source 侧优化。
- `file_offset` 已进入 descriptor，但当前 RMM 原型只用 `source_ipa`；`file_offset` 留给后续 share object/block driver 维护映射关系。
- 只要任意页 walk 或 map 失败，接口返回 `RSI_ERROR_INPUT`，同时 `x1` 返回已映射页数。

重要限制：

- P2a 仍然是 Image CVM 主动修改 Runtime CVM RTT，不满足最终安全模型。
- Runtime window 当前使用 read-only assigned_ram S2TTE；但 Image CVM source pages 尚未 seal 成只读。
- 当前没有 detach，也没有引用计数；重复映射/覆盖目标 window 的状态机还没有收敛。
- 当前 page list 一次最多描述 256 页，即 1 MiB；后续可以循环调用或升级为 share object 批量注册。
- 当前 `0xC40001B2` 是沿用本地旧 `GET_RD_ADDR/MAP_MEM` 的过渡 FID 约定，不应冻结为长期 ABI。

测试命令：

```bash
git -C opencca/tf-rmm diff --check \
  lib/smc/include/smc-rsi.h \
  runtime/include/rsi-handler.h \
  runtime/core/exit.c \
  runtime/rsi/logger.c \
  runtime/rsi/rsi_image.c

cd opencca/tf-rmm
cmake --build build -j"$(nproc)"

git -C linux-image-share diff --check \
  arch/arm64/include/asm/rsi_smc.h \
  arch/arm64/include/asm/rsi_cmds.h \
  drivers/image-server/image-server.c \
  rk3588_fragment.config

JOBS=8 ./scripts/build/build-linux-image-share.sh

git -C Firecracker-CCA diff --check src/vmm/src/arch/aarch64/fdt.rs
```

测试结果：

```text
opencca/tf-rmm: [100%] Built target rmm
linux-image-share: installed /home/mzh/RK3588/COCO/COCO-SFTP/firecracker-bins/Image
linux-image-share: guest kernel Image is ready at /home/mzh/RK3588/COCO/COCO-SFTP/firecracker-bins/Image
diff --check: opencca/tf-rmm、linux-image-share、Firecracker-CCA 均无输出
```

额外验证限制：

- `Firecracker-CCA` 未完成本机 `cargo fmt --check -p vmm`，原因是当前 1.83 toolchain 缺少 `cargo-fmt`。
- `Firecracker-CCA` 未完成本机 `cargo check -p vmm`，原因是 x86 构建环境会触发既有 aarch64/RME/kvm-bindings/vm-memory 版本问题；这不能证明 FDT 修改有问题，也不能证明 Firecracker 整体可用。
- 本轮没有把新 RMM/guest kernel 刷入 RK3588，也没有做 `nerdctl/kata` 远端 smoke。P2a 只算“本地可编译原型”。

结论：

- “source 不必来自连续 CMA”这条优化路径已经有 RMM 和 guest kernel 的可编译过渡接口。
- P2a 可以作为下一步 `/dev/coco-image-share` 原型或旧 `image-server` adapter 的底层 SMC，但不能作为最终安全设计。
- 下一阶段应该实现 Image CVM 侧 page-list 生成和 Runtime 小 window 验证；验证通过后，尽快转入 `SMC_RSI_IMG_SHARE_*`，补 Runtime 主动 attach、readonly、detach 和 refcount。

### P2a 增量：Runtime window 改为只读映射

追加修改：

- `opencca/tf-rmm/lib/s2tt/src/s2tt_pvt_defs.h`
  - 将 S2AP 拆成 `S2TTE_AP_R`、`S2TTE_AP_W`、`S2TTE_AP_RW`。
- `opencca/tf-rmm/lib/s2tt/include/s2tt.h`
  - 新增 `s2tte_create_assigned_ram_ro()` 声明。
- `opencca/tf-rmm/lib/s2tt/src/s2tt.c`
  - 新增 `s2tte_create_assigned_ram_ro()`，生成保留读权限、清除写权限的 assigned_ram S2TTE。
- `opencca/tf-rmm/runtime/rsi/rsi_image.c`
  - P2a `MAP_MEM_LIST` 写 Runtime window 时改用 `s2tte_create_assigned_ram_ro()`。

验证命令：

```bash
git -C opencca/tf-rmm diff --check \
  lib/s2tt/include/s2tt.h \
  lib/s2tt/src/s2tt.c \
  lib/s2tt/src/s2tt_pvt_defs.h \
  runtime/rsi/rsi_image.c

cd opencca/tf-rmm
cmake --build build -j"$(nproc)"
```

验证结果：

```text
diff --check: 无输出
opencca/tf-rmm: [100%] Built target rmm
```

更新后的 P2a 限制：

- Runtime window 已经是 RMM S2 read-only 映射，Runtime 不能通过该窗口写回 Image CVM 页。
- Image CVM source pages 和 metadata pages 尚未在 source Realm 内被 seal 成 read-only。
- P2a 仍然是 Image CVM 主动修改 Runtime RTT，仍然不能作为最终安全模型。
- detach/refcount/Runtime initiated attach 仍然要在 `SMC_RSI_IMG_SHARE_*` 中完成。

远端状态检查：

```text
RK3588: root@192.168.31.18
hostname: opencca-rock5b-rk3588
kernel: 6.12.0-opencca-wip #1 SMP PREEMPT Wed Jun 10 11:09:56 CST 2026
/: 30G total, 5.5G used, 23G available
/run: 331M total, 330M available
/tmp: 1.7G available
containerd: active
guest-pull-snapshotter: active
/dev/image-server: not present
```

结论：

- 远端板子健康，但本轮没有刷入新 RMM/guest kernel。
- `/dev/image-server` 缺失说明当前运行内核还不是本轮本地构建出的 `linux-image-share` Image，不能用于判断 P2a 是否可运行。

## 2026-06-10 P3 实现记录：RMM share-object 原型

本轮目标：

- 从 P2a `MAP_MEM_LIST` 过渡到 Runtime 主动 attach 的正式对象生命周期。
- 继续保留“source pages 不必来自连续 CMA/reserved buffer”的方向。
- 先做 RMM 和 Linux RSI wrapper 的可编译骨架，为后续 `/dev/coco-image-share` 和 windowed block driver 铺路。

核心判断：

- 当前映射失败不应该简单归因成“RMM 只能处理连续物理内存”。
- 旧 `handle_rsi_map_mem` 在 RMM 内部已经逐页 walk `image_ipa`，所以它不严格要求 source PA 物理连续。
- 真正把旧方案卡到 CMA/reserved buffer 的，是 Image CVM kernel `image-server` 驱动把待共享文件复制进一段固定 reserved-memory，然后用连续 `image_ipa` 调用旧接口。
- Runtime 端如果一次映射完整 rootfs image，仍然要求一段完整连续 target IPA，所以 V3 必须改成小窗口按 offset attach，而不是把整镜像一次挂进去。

代码修改：

- `opencca/tf-rmm/lib/smc/include/smc-rsi.h`
  - 新增正式原型 FID，放回 RSI range 内：

```text
SMC_RSI_IMG_SHARE_CREATE     0xC40001A0
SMC_RSI_IMG_SHARE_ADD_PAGES  0xC40001A1
SMC_RSI_IMG_SHARE_SEAL       0xC40001A2
SMC_RSI_IMG_SHARE_ATTACH     0xC40001A3
SMC_RSI_IMG_SHARE_DETACH     0xC40001A4
SMC_RSI_IMG_SHARE_DESTROY    0xC40001A5
```

- `opencca/tf-rmm/runtime/core/exit.c`
  - 新增 `SMC_RSI_IMG_SHARE_*` dispatch。
- `opencca/tf-rmm/runtime/include/rsi-handler.h`
  - 声明 create/add_pages/seal/attach/detach/destroy handler。
- `opencca/tf-rmm/runtime/rsi/logger.c`
  - 新增 `SMC_RSI_IMG_SHARE_*` logger 条目。
  - 将正式 `0x1A0..0x1A5` 与 legacy `0x1B0..0x1B2` 分段处理，避免把中间空洞误记为合法 RSI 调用。
- `opencca/tf-rmm/runtime/rsi/rsi_image.c`
  - 新增 RMM 内部固定对象表，当前最多 32 个 share object。
  - 新增固定 attachment 表，当前最多 64 个 Runtime attach window。
  - 新增全局 spinlock 保护对象表和 attachment 表。
  - `CREATE`：Image CVM 提交 descriptor，RMM 分配 share id 并记录 source RD。
  - `ADD_PAGES`：登记 source page-list IPA；当前只接受一次性完整列表。
  - `SEAL`：校验 metadata 与 page-list IPA，并将对象状态推进到 sealed。
  - `ATTACH`：Runtime CVM 主动传入 `share_id/source_rd/target_ipa/file_offset/size/flags`，RMM 从 source RD walk page-list，再把对应 source PA readonly 映射到 Runtime window。
  - `DETACH`：Runtime CVM 按 `target_ipa/size` 解除 attachment 并递减引用计数。
  - `DESTROY`：Image CVM owner 在引用计数为 0 时销毁 share object。
  - `ATTACH` 过程使用 pending/active attachment 状态，避免并发 attach/detach 把半映射 window 当成完整共享。
  - `ATTACH` 按 page index 重新 walk 对应 page-list granule，不再把 page-list 当成单个 4 KiB granule。
  - 当前原型限制 `page_count <= 32768`，即 128 MiB 镜像；page-list 元数据约为镜像大小的 1/256，128 MiB 镜像对应 512 KiB page-list。
- `linux-image-share/arch/arm64/include/asm/rsi_smc.h`
  - 新增 Linux 侧正式 FID 定义。
- `linux-image-share/arch/arm64/include/asm/rsi_cmds.h`
  - 新增 `rsi_img_share_create()`。
  - 新增 `rsi_img_share_add_pages()`。
  - 新增 `rsi_img_share_seal()`。
  - 新增 `rsi_img_share_attach()`。
  - 新增 `rsi_img_share_detach()`。
  - 新增 `rsi_img_share_destroy()`。

当前 ABI 形态：

```text
CREATE(desc_ipa) -> share_id
ADD_PAGES(share_id, page_list_ipa, start_page, nr_pages) -> added_pages
SEAL(share_id, meta_ipa, flags, reserved)
ATTACH(share_id, source_rd_addr, target_ipa, file_offset, size, flags) -> mapped_pages
DETACH(target_ipa, size)
DESTROY(share_id)

struct rsi_img_share_desc {
	u32 magic;      // "CIMG"
	u32 version;    // 1
	u64 image_size;
	u64 page_count;
	u64 flags;      // RO only
};

struct rsi_img_share_meta {
	u32 magic;
	u32 version;
	u64 image_size;
	u64 page_count;
	u64 source_page_list_ipa;
	u64 flags;
};

struct rsi_img_page_desc {
	u64 source_ipa;
	u64 file_offset;
};
```

验证命令：

```bash
git -C opencca/tf-rmm diff --check \
  lib/smc/include/smc-rsi.h \
  runtime/include/rsi-handler.h \
  runtime/core/exit.c \
  runtime/rsi/logger.c \
  runtime/rsi/rsi_image.c \
  lib/s2tt/include/s2tt.h \
  lib/s2tt/src/s2tt.c \
  lib/s2tt/src/s2tt_pvt_defs.h

cd opencca/tf-rmm
cmake --build build -j"$(nproc)"

git -C linux-image-share diff --check \
  arch/arm64/include/asm/rsi_smc.h \
  arch/arm64/include/asm/rsi_cmds.h \
  drivers/image-server/image-server.c \
  rk3588_fragment.config

cd /home/mzh/RK3588/COCO
JOBS=8 ./scripts/build/build-linux-image-share.sh
```

验证结果：

```text
opencca/tf-rmm diff --check: 无输出
opencca/tf-rmm: [100%] Built target rmm
linux-image-share diff --check: 无输出
linux-image-share: installed /home/mzh/RK3588/COCO/COCO-SFTP/firecracker-bins/Image
linux-image-share: guest kernel Image is ready at /home/mzh/RK3588/COCO/COCO-SFTP/firecracker-bins/Image
```

重要限制：

- 本轮没有刷入 RK3588，也没有远端 `nerdctl/kata` smoke；只能说明 RMM 和 guest kernel 本地可编译。
- Source Realm 内的 metadata/page-list/source pages 还没有真正 seal 成 readonly。Runtime window 已 readonly，但 Image CVM owner 仍可能修改 source 内容，因此还不是最终安全模型。
- 当前 RMM 要求 page-list 元数据 IPA 连续，且最大 32768 页/128 MiB。它已经去掉“整镜像数据必须连续”的要求，但还没有完全去掉 page-list 元数据连续性。
- `ADD_PAGES` 当前只接受 `start_page == 0 && nr_pages == page_count`，还不支持多批次注册。
- `DETACH` 当前要求 exact `target_ipa/size` 命中 attachment，不支持局部 detach。
- RMM 内部对象表和 attachment 表都是静态固定大小，没有动态扩展。
- 已进入 `/dev/coco-image-share` bring-up；Runtime 端已有 `/dev/cocoimg0` block driver 原型，但还没有窗口缓存，也没有远端 smoke。
- 尚未把 image-rs/CDH 的 `prepare_rootfs` 返回值接到 `share_id/source_rd`，也未更新 kata-agent 的 Runtime 挂载路径。

下一步：

- 在 Runtime CVM 中用用户态 ioctl 创建 `/dev/cocoimg0`，验证 EROFS/SquashFS 可以通过 4 KiB attach window mount。
- 后续把 `prepare_rootfs` 的 share metadata 传给 kata-agent/Runtime mount 路径。
- 验证通过后，把 RMM page-list 从 single granule 扩展成 metadata extents 或多页 sealed list。
- 最后再把 source-side seal/readonly、digest/measurement 和窗口缓存补齐。

## 2026-06-10 P4 实现记录：`/dev/coco-image-share` 与 `/dev/cocoimg0`

本轮目标：

- 在 guest kernel 里补一个最小入口，让 Image CVM 可以把文件注册成 RMM share object。
- 在 Runtime CVM 里补一个只读 block device 原型，让 Runtime 能把 share object 暴露成 `/dev/cocoimg0`。
- 先验证控制流和 RMM 映射，不做窗口缓存、digest 和 source-side seal。

代码修改：

- `linux-image-share/include/uapi/linux/coco-image-share.h`
  - 新增 UAPI ioctl 结构：
    - `GET_RD_ADDR`
    - `GET_WINDOW`
    - `CREATE_FROM_FILE`
    - `ATTACH_WINDOW`
    - `DETACH_WINDOW`
    - `DESTROY`
    - `CREATE_DEVICE`
    - `DESTROY_DEVICE`
- `linux-image-share/drivers/coco-image-share/`
  - 新增 `Kconfig`、`Makefile`、`coco-image-share.c`。
- `linux-image-share/drivers/Kconfig`
  - 引入 `drivers/coco-image-share/Kconfig`。
- `linux-image-share/drivers/Makefile`
  - 增加 `obj-$(CONFIG_COCO_IMAGE_SHARE) += coco-image-share/`。
- `linux-image-share/rk3588_fragment.config`
  - 增加 `CONFIG_COCO_IMAGE_SHARE=y`。

Image CVM 路径：

- `CREATE_FROM_FILE` 打开用户传入文件。
- 按页分配普通 kernel pages 并读取文件内容，不再把整镜像复制进 reserved CMA。
- 为每页生成 `struct rsi_img_page_desc { source_ipa, file_offset }`。
- 使用 `rsi_img_share_create()`、`rsi_img_share_add_pages()`、`rsi_img_share_seal()` 注册 RMM share object。
- 返回 `share_id/source_rd_addr/image_size/page_count` 给用户态。

Runtime CVM 路径：

- `CREATE_DEVICE` 接收 Image CVM 返回的 `share_id/source_rd_addr/image_size`。
- 创建 read-only block device `/dev/cocoimg0`。
- bio read 路径串行使用全局 RMM window：
  - `ATTACH_WINDOW` 将 `file_offset` 对应的 4 KiB source page readonly 映射到 Runtime window。
  - driver 从 window 拷贝到 bio page。
  - `DETACH_WINDOW` 解除 window。
- 当前窗口读路径故意用全局 mutex 串行化，避免多个 bio 并发覆盖同一窗口。性能不是本轮目标。

验证命令：

```bash
make -C linux-image-share \
  O=out/coco-arm64 \
  ARCH=arm64 \
  CROSS_COMPILE=aarch64-linux-gnu- \
  drivers/coco-image-share/coco-image-share.o -j8

git -C linux-image-share diff --check \
  include/uapi/linux/coco-image-share.h \
  drivers/coco-image-share \
  drivers/Kconfig \
  drivers/Makefile \
  rk3588_fragment.config \
  arch/arm64/include/asm/rsi_smc.h \
  arch/arm64/include/asm/rsi_cmds.h \
  drivers/image-server/image-server.c

JOBS=8 ./scripts/build/build-linux-image-share.sh

rg -n "CONFIG_COCO_IMAGE_SHARE|CONFIG_IMAGE_SERVER" \
  linux-image-share/out/coco-arm64/.config

aarch64-linux-gnu-nm -n linux-image-share/out/coco-arm64/vmlinux | \
  rg "coco_img_submit_bio|create_block_device|destroy_block_device|coco_img_blk_fops"

strings -a COCO-SFTP/firecracker-bins/Image | \
  rg "coco-image-share|cocoimg0|image-share window"
```

验证结果：

```text
coco-image-share.o: 编译通过
linux-image-share diff --check: 无输出
linux-image-share: installed /home/mzh/RK3588/COCO/COCO-SFTP/firecracker-bins/Image
linux-image-share .config: CONFIG_COCO_IMAGE_SHARE=y
vmlinux symbols: coco_img_submit_bio / coco_img_blk_fops / destroy_block_device present
Image strings: coco-image-share / cocoimg0 / image-share window present
```

重要限制：

- 还没有把新 guest kernel 和新 RMM 刷入 RK3588。
- 还没有在 Image CVM 内执行 `CREATE_FROM_FILE`，也没有在 Runtime CVM 内创建并 mount `/dev/cocoimg0`。
- 当前 block read 每 4 KiB 都 attach/detach，一定很慢；它只用于证明机密 VM 内的只读 rootfs 可以从 Image CVM share object 挂载。
- `CREATE_FROM_FILE` 当前仍然把文件内容读入 kernel pages，后续应该改为 pin tmpfs/memfd/page-cache pages，减少复制。
- Source-side seal/readonly 仍未实现，Image CVM owner 仍可能修改 source pages。
- 还没有把 CDH/image-rs/kata-agent 的控制流改成传递 `share_id/source_rd_addr/image_size` 并调用 `CREATE_DEVICE`。

## 2026-06-10 P5 实现记录：CDH/image-rs/kata-agent 快路径控制流

本轮目标：

- 把 P4 的 `/dev/coco-image-share` 接进现有 Image CVM 和 Runtime CVM 控制流。
- 保留 V2 copy-mode fallback，避免 fast path 失败时直接破坏现有调试路径。
- 明确改动 `image-rs` 后必须重建 `kata-agent`，不能只编译 `image-rs`。

代码修改：

- `guest-components/confidential-data-hub/hub/protos/image.proto`
  - `PrepareRootfsResponse` 新增：
    - `uint64 source_rd_addr = 8`
    - `uint64 share_id = 9`
- `guest-components/image-rs/protos/image.proto`
  - 同步新增 `source_rd_addr/share_id`。
- `guest-components/image-rs/src/coco_image_share.rs`
  - 新增 Rust UAPI 封装，直接调用 `/dev/coco-image-share` ioctl。
  - 支持 `CREATE_FROM_FILE`、`CREATE_DEVICE`、`DESTROY_DEVICE`。
- `guest-components/image-rs/src/lib.rs`
  - 导出 `coco_image_share` 模块。
- `guest-components/confidential-data-hub/hub/src/bin/vsock-ttrpc-server.rs`
  - Image CVM 在生成 EROFS/SquashFS/ext4 rootfs image 后调用 `create_from_file()`。
  - 成功则在 `PrepareRootfsResponse` 返回 `share_id/source_rd_addr`。
  - 失败则记录错误并保持 `share_id/source_rd_addr=0`，Runtime 继续使用 copy-mode fallback。
- `guest-components/image-rs/src/image.rs`
  - Runtime CVM 的 `guest_mount_shared_rootfs_copy_mode()` 保留原名和 fallback。
  - 如果 `prepare_rootfs` 响应包含 `share_id/source_rd_addr`，优先调用 `CREATE_DEVICE` 创建 `/dev/cocoimg0`。
  - 然后用 direct block device 模式挂载 `/dev/cocoimg0`，成功后直接返回。
  - fast path 失败时自动回退到原 `read_rootfs_chunk` copy-mode。
- `guest-components/image-rs/src/shared_rootfs.rs`
  - `MountSharedRootfsOptions` 新增 `direct_block_device`。
  - direct 模式下不再执行 `losetup`，直接把 block device 挂载为 lower rootfs。
  - 非 direct 模式保留原 loop/copy-mode 行为。

验证命令：

```bash
cd guest-components
cargo fmt -p image-rs -p confidential-data-hub
cargo check -p image-rs --features keywrap-ttrpc
cargo check -p confidential-data-hub --bin vsock-ttrpc-server --features bin,ttrpc

cd /home/mzh/RK3588/COCO
./scripts/build/build-guest-components.sh
./scripts/build/build-kata-agent.sh
./scripts/image/install-guest-components-into-kata-image.sh
./scripts/image/install-kata-agent-into-kata-image.sh
./scripts/image/install-guest-components-into-kata-image.sh --verify-only
./scripts/image/install-kata-agent-into-kata-image.sh --verify-only
./scripts/image/install-rootfs-tools-into-kata-image.sh --verify-only

git -C guest-components diff --check \
  image-rs/protos/image.proto \
  confidential-data-hub/hub/protos/image.proto \
  image-rs/src/coco_image_share.rs \
  image-rs/src/lib.rs \
  image-rs/src/image.rs \
  image-rs/src/shared_rootfs.rs \
  confidential-data-hub/hub/src/bin/vsock-ttrpc-server.rs
```

验证结果：

```text
cargo fmt: 通过
image-rs cargo check: 通过
confidential-data-hub vsock-ttrpc-server cargo check: 通过
guest-components aarch64 musl build: 通过
kata-agent aarch64 musl release build: 通过
Kata guest image verify: guest-components / kata-agent / mkfs.erofs / mksquashfs 均存在
guest-components diff --check: 无输出
```

已有 warning：

- `confidential-data-hub/hub/src/config.rs` 有既有 `unused_mut` 和 `dead_code` warning，本轮未处理。
- kata-agent 构建有既有 dependency/lint warning，本轮未处理。
- `build-guest-components.sh` 中 Makefile 会触发 sudo 密码提示用于环境探测，但本轮构建未因此失败。

重要限制：

- 本轮仍未刷入 RK3588，也未远端启动 Image CVM/Runtime CVM 进行 `nerdctl` smoke。
- Runtime fast path 依赖 guest kernel 内置 `CONFIG_COCO_IMAGE_SHARE=y` 和 FDT `coco,imgshare-window`。
- `/dev/cocoimg0` 当前只有一个全局设备，不能并发服务多个 rootfs share。
- block read 每 4 KiB attach/detach，没有窗口缓存，性能预期很差但可用于证明链路。
- fast path 不做 digest 校验；copy-mode fallback 仍保留 digest 校验。
- Source-side seal/readonly 还没完成，因此仍不是最终安全模型。

## 2026-06-10 P6 实现记录：删除 Runtime copy-mode，Image source 改为 page-cache pinned pages

本轮目标：

- 不再让 Runtime CVM 在 fast path 失败时回退到 `read_rootfs_chunk`。
- 不再让 Image CVM driver 把 rootfs image 完整读入另一批新分配 pages。
- 让已生成的 rootfs image 文件页直接成为 RMM share source pages，贴近“Image CVM 内存文件系统共享给 Runtime CVM”的设计。

代码修改：

- `guest-components/image-rs/protos/image.proto`
  - 删除 `read_rootfs_chunk` RPC。
  - 删除 `rootfs_image_path` 字段。
  - `PrepareRootfsResponse` 新增 `page_count = 10`。
- `guest-components/confidential-data-hub/hub/protos/image.proto`
  - 同步删除 chunk RPC 和 `rootfs_image_path`。
  - 同步新增 `page_count`。
- `guest-components/confidential-data-hub/hub/src/bin/vsock-ttrpc-server.rs`
  - 删除 `read_rootfs_chunk()` 服务端实现。
  - 删除 shared-rootfs path 校验函数。
  - `create_from_file()` 失败时直接返回 `Status::internal`，不再返回 `share_id=0` 给 Runtime 走 copy-mode。
  - `PrepareRootfsResponse` 返回 `share_id/source_rd_addr/page_count`。
- `guest-components/image-rs/src/vsock_ttrpc_client/mod.rs`
  - 删除 `read_rootfs_chunk()` client。
- `guest-components/image-rs/src/image.rs`
  - `guest_pull_image()` 调用 `guest_mount_shared_rootfs()`。
  - 删除 Runtime 本地 rootfs image 临时目录、chunk copy、sparse writer、digest 校验、loop/copy-mode mount helper。
  - 如果 `prepare_rootfs` 没有返回 `share_id/source_rd_addr`，直接失败。
  - fast path mount `/dev/cocoimg0` 失败时直接失败，不再 fallback。
- `linux-image-share/drivers/coco-image-share/coco-image-share.c`
  - `CREATE_FROM_FILE` 从 `kernel_read()` + `alloc_page()` 改为 `read_mapping_page()`。
  - driver 持有 rootfs image 文件的 page-cache/tmpfs pages 引用，并用 `page_to_phys()` 写入 RMM page list。
  - `free_share()` 用 `put_page()` 释放页引用，并持有 `source_file` 直到 share 销毁，避免 page cache 被回收。
- `linux-image-share/rk3588_fragment.config`
  - 清理重复配置项，减少每次 guest kernel 构建 warning。

当前数据面：

```text
Image CVM
  rootfs image file on tmpfs/page cache
  -> read_mapping_page() pin page-cache pages
  -> RMM IMG_SHARE_CREATE/ADD_PAGES/SEAL

Runtime CVM
  prepare_rootfs() receives share descriptor
  -> /dev/coco-image-share CREATE_DEVICE
  -> /dev/cocoimg0
  -> mount read-only rootfs
```

相比 P5 的改进：

- Runtime 不再通过 vsock 复制完整 rootfs image。
- Image CVM 不再复制 rootfs image 到另一批 kernel pages。
- 失败不会被 copy-mode fallback 掩盖。

验证命令：

```bash
cd guest-components
cargo fmt -p image-rs -p confidential-data-hub
cargo check -p image-rs --lib
cargo check -p image-rs --features kata-cc-rustls-tls --lib
cargo check -p confidential-data-hub --bin vsock-ttrpc-server --features bin,ttrpc

cd /home/mzh/RK3588/COCO
JOBS=16 ./scripts/build/build-linux-image-share.sh
./scripts/build/build-guest-components.sh
./scripts/build/build-kata-agent.sh
./scripts/image/install-guest-components-into-kata-image.sh
./scripts/image/install-kata-agent-into-kata-image.sh
./scripts/image/install-guest-components-into-kata-image.sh --verify-only
./scripts/image/install-kata-agent-into-kata-image.sh --verify-only
./scripts/image/install-rootfs-tools-into-kata-image.sh --verify-only
```

验证结果：

```text
image-rs cargo check --lib: 通过
image-rs cargo check --features kata-cc-rustls-tls --lib: 通过
confidential-data-hub vsock-ttrpc-server cargo check: 通过
linux-image-share guest kernel build: 通过
COCO-SFTP/firecracker-bins/Image 已更新
guest-components aarch64 build: 通过
kata-agent aarch64 release build: 通过
Kata guest image verify: guest-components / kata-agent / mkfs.erofs / mksquashfs 均存在
```

当前产物 hash：

```text
COCO-SFTP/firecracker-bins/Image:
  e4eaab76a6cd5716fadde87a86d341f03e9b53e438a974312837f69ee2dcb3b6
COCO-SFTP/images/kata-containers-cca.img:
  8ff63bee494988275e4831bd9586210d220214417a5fc5e835abb9ee087d33fe
artifacts/guest-components/bin/vsock-ttrpc-server:
  b3f2f36ae4e9d5b5fa29b5f712d1c143c91220ca6e7ff6b6f21418831d8a9002
artifacts/kata-agent/bin/kata-agent:
  ae44666f7d0d2f4442ecd88b51dd21a8c66be827fdcd429650a266a7ed7da29e
```

已知 warning：

- Cargo 输出 `/home/mzh/.cargo/config` deprecated，属于本机 Cargo 配置。
- `confidential-data-hub` 仍有既有 `unused_mut` / `dead_code` warning。
- `image-rs --features kata-cc-rustls-tls` 仍有既有 `Grpc is never constructed` warning。
- guest kernel fragment 仍会提示 `MODULE_SIG/LOCALVERSION_AUTO/CPU_IDLE` 覆盖基线配置，这是有意覆盖；重复赋值 warning 已清理。

当前限制：

- 尚未同步到 RK 并跑 Image CVM/Runtime CVM smoke。
- RMM source-side readonly/seal 仍未实现；Image CVM 用户态理论上仍可能改 rootfs image 文件内容。
- `/dev/cocoimg0` 仍是单全局设备，尚不支持并发多个 Runtime rootfs。
- Runtime block driver 仍使用 256 KiB cache window 串行 attach/detach，性能比最终多窗口/LRU 方案低。

黑名单更新：

- `read_rootfs_chunk` copy-mode 已不再允许作为默认 fallback。
- `kernel_read()` 到新分配 pages 的 Image CVM share 创建方式已被 page-cache pinned source pages 取代，除非 page-cache 方案被实测证明不可用，否则不要回滚。

## 2026-06-10 P7 远端通过记录：RMM page-cache EROFS share

本轮结论：

- Image CVM 到 Runtime CVM 的 RMM-backed rootfs share 主链路已经通过 RK3588 远端 smoke。
- Runtime CVM 不再通过 vsock copy rootfs image，也不再使用 V2 loop/overlay copy-mode fallback。
- Image CVM 生成 EROFS rootfs image 后，通过 `/dev/coco-image-share` pin page-cache/tmpfs pages 并创建 RMM share object。
- Runtime CVM 通过 `/dev/cocoimg0` 直接挂载 RMM share 出来的只读 EROFS rootfs，并成功执行容器命令。

本轮真正跑通的数据面：

```text
Image CVM
  pull busybox
  -> unpack bundle rootfs
  -> mkfs.erofs
  -> read_mapping_page() pin rootfs image page-cache pages
  -> RSI IMG_SHARE_CREATE / ADD_PAGES / SEAL
  -> return share_id/source_rd/image_size/page_count/fs_type

Runtime CVM
  prepare_rootfs() receives RMM descriptor
  -> /dev/coco-image-share CREATE_DEVICE
  -> /dev/cocoimg0 block read
  -> RSI IMG_SHARE_ATTACH read-only source PA into Runtime aperture
  -> mount -t erofs -o ro /dev/cocoimg0 lower
  -> overlay upper/work/rootfs
  -> kata-agent CreateContainer
```

关键修复：

- Firecracker 在 Realm 激活前预拆 image-share aperture 的 L3 RTT。
  - 位置：`Firecracker-CCA/src/vmm/src/builder.rs`
  - 做法：常规 `INIT_IPA_REALM` 初始化 guest memory 后，对 `layout::RESERVERD_MEM_START..RESERVERD_MEM_START+RESERVERD_MEM_SIZE` 每个 2 MiB block 再做一次 4 KiB `INIT_IPA_REALM`。
  - 目的：让 RMM attach 看到 target window 是 page-level RTT，而不是 coarse 2 MiB block。RMM 继续严格要求 page-level，避免把共享页错误写进 block-level RTT 后在 teardown 触发异常。
- RMM share attach/teardown 生命周期修复。
  - 位置：`opencca/tf-rmm/runtime/rsi/rsi_image.c`、`runtime/rmi/rtt.c`、`runtime/include/rsi-image.h`
  - attach 失败时恢复已经替换的 target S2TTE，不发布半成品 attachment。
  - `DATA_DESTROY` 前通过 `rsi_img_share_cleanup_target_ipa(rd_pa, ipa)` 清理覆盖目标 IPA 的 active attachment。
  - `REALM_DESTROY`/异常 fallback 继续通过 `rsi_img_share_cleanup_realm(rd_pa)` 清理该 Realm 作为 source 或 target 的 attachment。
  - cleanup 后仍不能匹配普通 DATA granule 时返回错误并打日志，不再 assert 杀死整板。
- Runtime preflight 修正。
  - 位置：`guest-components/image-rs/src/image.rs`
  - 失败现象：attach/read 已成功，但 preflight 把 EROFS magic 错误判断成 ASCII `"Erofs"`，导致误报 `/dev/cocoimg0 does not expose an EROFS superblock magic`。
  - 修复：按 `fs_type` 校验 superblock。EROFS 使用 offset 1024 的 little-endian `0xE0F5E1E2`，SquashFS 使用 offset 0 的 `hsqs`。

构建、部署和验证命令：

```bash
cd /home/mzh/RK3588/COCO/guest-components
cargo check -p image-rs

cd /home/mzh/RK3588/COCO
./scripts/build/build-guest-components.sh
./scripts/build/build-kata-agent.sh
./scripts/image/install-guest-components-into-kata-image.sh
./scripts/image/install-kata-agent-into-kata-image.sh
./scripts/image/install-rootfs-tools-into-kata-image.sh --verify-only
./scripts/image/install-guest-components-into-kata-image.sh --verify-only
./scripts/image/install-kata-agent-into-kata-image.sh --verify-only

./scripts/build/build-firecracker.sh
JOBS=8 ./scripts/build/build-linux-image-share.sh
./scripts/firmware/build-rmm-uboot.sh
COCO_RPI_PASSWORD=root COCO_REMOTE_PASSWORD=root \
  ./scripts/firmware/flash-rk3588-firmware-via-pi.sh --flash-mmc --wait-rk

COCO_REMOTE_PASSWORD=root ./scripts/deploy/sync-coco-sftp.sh
COCO_REMOTE_PASSWORD=root ./scripts/run/run-image-cache-smoke-remote.sh
```

远端测试环境：

```text
RK: root@192.168.31.18
Image: docker.m.daocloud.io/library/busybox:latest
Network: coco-bridge
DNS: 192.168.31.1
Image CVM wait: 15s
Runtime memory: 512 MiB
```

通过证据：

```text
coco-runtime-cvm-ok
Image manifest: OciImageManifest ...
Created RMM rootfs share: path=/tmp/run/image-rs/shared-rootfs/images/sha256_e0e8b3cbfed68a90084781e2962f9c0deead51c5a3f11a488eef0283a4284bc2.erofs, share_id=2, source_rd=0x17233000, size=4194304, pages=1024
guest_pull took: 23586 ms
```

完整 containerd 日志：

```text
docs/log/imagecache-debug/containerd-imagecache-rmm-share-pass-20260610.log
```

产物 hash：

```text
opencca/snapshot/tf-rmm.elf:
  516939ab9d8f7282678c9078e8f5cc4e03fbeba10bf0ed156f19abe88c997882
opencca/snapshot/idbloader.img:
  d40522b75342526333366d11e99e04bda0bbe38c48524af9d7b1e576f338beef
opencca/snapshot/u-boot.itb:
  731d4985abadca9dc18b5e938f7bb350e960cd139dfcf9bea2a1792bae15ac1c
opencca/snapshot/u-boot-rockchip-spi.bin:
  17eecb632cacc479a9aec4bc2f435ad898c2b0862ec4809381dc42d6b77f5743
COCO-SFTP/firecracker-bins/firecracker:
  ca13f4d80225d62f6eab5d4e6bf85a30004f5b302427e06b624b055ee2ce346c
COCO-SFTP/firecracker-bins/Image:
  5353427bc94934bdefd853b7b17315b9ba092c6a4dcfd3a70734e5854e317cfe
COCO-SFTP/images/kata-containers-cca.img:
  83dece9b2529eff68d1cf3705e1a4207a424a20752eb5aa7927ec3226d627216
artifacts/guest-components/bin/vsock-ttrpc-server:
  e35a016870dc5950ee92566134c755d7aa5e12834dd5b0004c4d1ac77042c006
artifacts/kata-agent/bin/kata-agent:
  eeca5a8291144e3cd9ccc109e5727f27e9f88dd11fa1da63642ef1ab9cf833d7
```

验证结果：

```text
cargo check -p image-rs: 通过
guest-components aarch64 musl build: 通过
kata-agent aarch64 musl release build: 通过
Kata guest image verify: rootfs tools / guest-components / kata-agent 均存在
Firecracker build: 通过
linux-image-share guest kernel build: 通过
RMM + U-Boot build: 通过
Pi flash RK3588 MMC + wait SSH: 通过
ImageCache smoke: 通过，脚本退出码 0
```

已确认不再出现：

- `attach failed`
- `map window failed`
- `/dev/cocoimg0` `read failed`
- `Buffer I/O error on dev cocoimg0`
- `failed to preflight /dev/cocoimg0`
- `does not expose an EROFS superblock magic`
- RMM `g_data != NULL` assert 导致 RK SSH 失联

当前仍然保留的限制：

- `/dev/cocoimg0` 仍是单全局设备，尚不支持多个 Runtime rootfs 并发。
- Runtime driver 当前仍是单窗口串行 attach/read，已经能工作，但还不是最终性能形态。
- RMM share object 表和 attachment 表仍是静态大小。
- Source-side seal/readonly 仍需继续完善；当前主验证点是快速共享和只读 Runtime 映射。
- 串口 logger 在本轮环境里 `stty /dev/ttyUSB0` 返回 I/O error，RMM 证据主要来自 containerd/guest console 和 RK 可达性。

黑名单补充：

- 不要回到“RMM attach 允许写入 coarse/block-level RTT”的旧思路。
  - 它能让 attach 短暂成功，但 teardown 会把 source PA 当成 target DATA granule 处理，风险比 attach 失败更高。
  - 正确做法是 Firecracker/host 在 Realm 激活前准备 page-level target RTT，RMM attach 保持严格检查。
- 不要只在 RMM 里放宽 target S2TTE replaceable 判断来绕过 attach 失败。
  - 如果 target walk 没有到 page level，RMM 没有通用分配器来安全拆 RTT；应该由 VMM/KVM 初始化阶段提供 delegated page 并拆分。
- 不要使用 ASCII `"Erofs"` 判断 EROFS superblock。
  - EROFS magic 是 little-endian `0xE0F5E1E2`，位置在 offset 1024。错误检查会把已经可读的 `/dev/cocoimg0` 误判成失败。
