# RK3588 Host Kernel Compile And Replace

本文记录 RK3588 host kernel 和 host kernel modules 的当前固定流程。

当前板子运行版本：

```text
6.12.0-opencca-wip
```

重要规则：

- 只补一个缺失模块时，不要重新替换整套 host kernel。
- 构建运行中内核的外部/增量模块时，所有 `make` 命令都必须显式带 `LOCALVERSION=`。
- `modinfo -F vermagic <module.ko>` 第一列必须等于远端 `uname -r`。
- 如果 `vermagic` 是 `6.12.0-opencca-wip+`，说明源码树 dirty release 后缀没有固定住，禁止安装这个模块。

## 单模块快速修复

缺少 `xt_comment` 或类似单个 host kernel module 时，优先使用脚本：

```bash
cd /home/mzh/RK3588/COCO
COCO_REMOTE_PASSWORD=root ./scripts/deploy/install-host-kernel-modules.sh
```

默认行为：

- 从 `root@192.168.31.18:/boot/config-$(uname -r)` 拉取正在运行内核的配置。
- 只启用目标 symbol，默认是 `CONFIG_NETFILTER_XT_MATCH_COMMENT=m`。
- 使用 `LOCALVERSION=` 运行 `olddefconfig`、`kernelrelease`、`modules`。
- `olddefconfig` 后立刻检查 `kernelrelease` 是否等于远端 `uname -r`。
- 重编前删除旧目标 `.ko`，避免复用上一次带 `+` 的错误 vermagic 产物。
- 默认只构建必要 `.ko` 目标，不扫完整模块树：
  - `net/netfilter/x_tables.ko` 参与 `xt_comment` 的 modpost 依赖。
  - `net/netfilter/xt_comment.ko` 是安装目标。
- 检查构建出的 `xt_comment.ko` 的 `vermagic` 是否等于远端 `uname -r`。
- 安装到 `/lib/modules/$(uname -r)/kernel/net/netfilter/xt_comment.ko`。
- 执行 `depmod -a` 和 `modprobe xt_comment`。

只构建不安装：

```bash
COCO_REMOTE_PASSWORD=root ./scripts/deploy/install-host-kernel-modules.sh --build-only
```

离线复用已有 `.config`：

```bash
./scripts/deploy/install-host-kernel-modules.sh --build-only --no-remote-config
```

检查结果：

```bash
sshpass -p root ssh root@192.168.31.18 \
  'uname -r; modprobe xt_comment; modinfo -F vermagic xt_comment'
```

期望第一列一致：

```text
6.12.0-opencca-wip
6.12.0-opencca-wip SMP preempt mod_unload aarch64
```

## 为什么必须固定 `LOCALVERSION=`

Linux 内核在源码树 dirty 时可能自动把 release 变成：

```text
6.12.0-opencca-wip+
```

但 RK3588 当前启动的是：

```text
6.12.0-opencca-wip
```

这两个字符串对 `modprobe` 来说不是同一个内核版本。即使代码和配置正确，`vermagic` 不一致也会被拒绝加载。

手动构建时必须这样写：

```bash
make -C linux-host-kernel O=linux-host-kernel/out/rk3588-host \
  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= olddefconfig

make -C linux-host-kernel O=linux-host-kernel/out/rk3588-host \
  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= -j"$(nproc)" modules
```

然后检查：

```bash
modinfo -F vermagic linux-host-kernel/out/rk3588-host/net/netfilter/xt_comment.ko
```

如果第一列带 `+`，不要安装，删除该 `.ko` 后重新构建。release 没固定前不要继续跑运行时测试，否则后续日志会混入模块加载失败的噪音。

固定 release 的完整检查顺序：

```bash
sshpass -p root ssh root@192.168.31.18 'uname -r'
make -C linux-host-kernel O=linux-host-kernel/out/rk3588-host \
  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= olddefconfig
make -s -C linux-host-kernel O=linux-host-kernel/out/rk3588-host \
  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= kernelrelease
rm -f linux-host-kernel/out/rk3588-host/net/netfilter/xt_comment.ko
make -C linux-host-kernel O=linux-host-kernel/out/rk3588-host \
  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= -j"$(nproc)" \
  net/netfilter/x_tables.ko net/netfilter/xt_comment.ko
modinfo -F vermagic linux-host-kernel/out/rk3588-host/net/netfilter/xt_comment.ko
```

`kernelrelease` 和 `modinfo -F vermagic` 第一列都必须是远端 `uname -r`。

## 不要默认合并完整 fragment 修单模块

`linux-host-kernel/coco_host_fragment.config` 用于完整 host kernel/module set，不是单模块修复的默认入口。

单独补 `xt_comment.ko` 时，合并完整 fragment 可能打开大量 netfilter、xfrm、tunnel 相关模块，导致无关的 `modpost` unresolved symbol，例如：

```text
ERROR: modpost: "xfrm_lookup" [net/netfilter/nf_nat.ko] undefined!
ERROR: modpost: "__xfrm_decode_session" [net/netfilter/nf_nat.ko] undefined!
```

正确做法是用远端正在运行的 `/boot/config-$(uname -r)` 作为基线，只打开目标模块 symbol。

只有确实准备完整替换 host kernel 或完整模块集合时，才使用：

```bash
COCO_REMOTE_PASSWORD=root ./scripts/deploy/install-host-kernel-modules.sh --merge-fragment --full-modules
```

## 完整替换 Host Kernel

完整替换 host kernel 时使用 `linux-host-kernel` 源码树。

示例：

```bash
cd /home/mzh/RK3588/COCO/linux-host-kernel
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export OUT=out/rk3588-host

mkdir -p "$OUT"
cp /tmp/rk-config-6.12.0-opencca-wip "$OUT/.config"
./scripts/config --file "$OUT/.config" -m NETFILTER_XT_MATCH_COMMENT
make O="$OUT" LOCALVERSION= olddefconfig
make O="$OUT" LOCALVERSION= -j"$(nproc)" Image modules
```

如果没有远端配置缓存，先从 RK 拉取：

```bash
cd /home/mzh/RK3588/COCO
sshpass -p root scp \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile=/tmp/coco_known_hosts \
  root@192.168.31.18:/boot/config-6.12.0-opencca-wip \
  /tmp/rk-config-6.12.0-opencca-wip
```

安装到 staging：

```bash
cd /home/mzh/RK3588/COCO/linux-host-kernel
export OUT=out/rk3588-host
export STAGING=/home/mzh/RK3588/COCO/COCO-SFTP/linux-host-kernel

rm -rf "$STAGING"
mkdir -p "$STAGING"
cp "$OUT/arch/arm64/boot/Image" "$STAGING/Image"
make O="$OUT" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  LOCALVERSION= modules_install INSTALL_MOD_PATH="$STAGING"
```

同步到 RK：

```bash
cd /home/mzh/RK3588/COCO
COCO_REMOTE_PASSWORD=root COCO_SYNC_BOARD_ASSETS=1 ./scripts/deploy/sync-coco-sftp.sh
```

在 RK 上替换：

```bash
cp -v /root/COCO-SFTP/linux-host-kernel/Image /boot/vmlinuz-6.12.0-opencca-wip
rsync -a /root/COCO-SFTP/linux-host-kernel/lib/modules/6.12.0-opencca-wip/ \
  /lib/modules/6.12.0-opencca-wip/
depmod 6.12.0-opencca-wip
sync
reboot
```

重启后确认：

```bash
uname -r
modprobe overlay
modprobe vsock
modprobe vhost-vsock
modprobe loop
modprobe xt_comment
```

## Guest Kernel 另走 `linux-image-share`

不要混淆 host kernel 和 guest kernel。

修改 CVM guest kernel 时使用：

```bash
cd /home/mzh/RK3588/COCO
JOBS=8 ./scripts/build/build-linux-image-share.sh
COCO_REMOTE_PASSWORD=root ./scripts/deploy/sync-coco-sftp.sh
```

注意：

- guest kernel 必须合并 `linux-image-share/rk3588_fragment.config`。
- 产物是 `COCO-SFTP/firecracker-bins/Image`。
- 运行中的 CVM 不会自动切换到新 guest kernel，必须重新启动容器/VM。
