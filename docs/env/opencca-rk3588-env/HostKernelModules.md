# RK3588 Host Kernel Modules

本文记录 RK3588 host kernel 当前需要的模块和快速修复方式。

当前 host kernel：

```text
6.12.0-opencca-wip
```

## 快速安装缺失模块

优先使用脚本：

```bash
cd /home/mzh/RK3588/COCO
COCO_REMOTE_PASSWORD=root ./scripts/deploy/install-host-kernel-modules.sh
```

默认安装：

```text
CONFIG_NETFILTER_XT_MATCH_COMMENT=m
net/netfilter/xt_comment.ko
```

默认构建还会带上：

```text
net/netfilter/x_tables.ko
```

原因是 `xt_comment.ko` 的 `modpost` 需要看到 `x_tables` 导出的 `xt_register_match` 和 `xt_unregister_match`。`x_tables.ko` 只作为构建依赖，默认不会覆盖安装到远端。

脚本会固定 `LOCALVERSION=`，先检查 `kernelrelease` 等于远端 `uname -r`，再清理旧目标 `.ko`，最后检查 `vermagic` 等于远端 `uname -r` 后才安装。

只构建：

```bash
COCO_REMOTE_PASSWORD=root ./scripts/deploy/install-host-kernel-modules.sh --build-only
```

## 必要模块

ImageCache/Kata/Firecracker 当前常用模块：

```bash
modprobe overlay
modprobe vsock
modprobe vhost-vsock
modprobe loop
modprobe br_netfilter
modprobe iptable_nat
modprobe nf_nat
modprobe nf_conntrack
modprobe xt_comment
modprobe xt_addrtype
modprobe xt_MASQUERADE
modprobe xt_nat
```

关键配置建议：

```text
CONFIG_VSOCKETS=y
CONFIG_VHOST=m
CONFIG_VHOST_VSOCK=m
CONFIG_OVERLAY_FS=y

CONFIG_BRIDGE_NETFILTER=m
CONFIG_IP_NF_NAT=m
CONFIG_NF_NAT=m
CONFIG_NF_CONNTRACK=m
CONFIG_NETFILTER_XTABLES=m
CONFIG_NETFILTER_XT_MATCH_COMMENT=m
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=m
CONFIG_NETFILTER_XT_TARGET_MASQUERADE=m
CONFIG_NETFILTER_XT_NAT=m
```

`xt_comment` 当前以模块方式安装即可，不要求重新编进 host kernel。

## `xt_comment` 缺失症状

CNI/NAT 初始化可能失败，日志类似：

```text
iptables: Couldn't load match `comment'
failed to setup CNI/NAT
```

修复：

```bash
COCO_REMOTE_PASSWORD=root ./scripts/deploy/install-host-kernel-modules.sh
```

验证 iptables comment match：

```bash
sshpass -p root ssh root@192.168.31.18 '
set -e
modprobe xt_comment
iptables -t nat -N COCO_XT_COMMENT_TEST 2>/dev/null || true
iptables -t nat -F COCO_XT_COMMENT_TEST
iptables -t nat -A COCO_XT_COMMENT_TEST -m comment --comment coco-test -j RETURN
iptables -t nat -S COCO_XT_COMMENT_TEST
iptables -t nat -F COCO_XT_COMMENT_TEST
iptables -t nat -X COCO_XT_COMMENT_TEST
'
```

期望输出包含：

```text
-A COCO_XT_COMMENT_TEST -m comment --comment coco-test -j RETURN
```

## release 固定规则

不要安装 `vermagic` 带 `+` 的模块。

错误：

```text
6.12.0-opencca-wip+
```

正确：

```text
6.12.0-opencca-wip
```

手动构建时所有 `make` 命令必须带：

```bash
LOCALVERSION=
```

例如：

```bash
make -C linux-host-kernel O=linux-host-kernel/out/rk3588-host \
  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= olddefconfig
make -C linux-host-kernel O=linux-host-kernel/out/rk3588-host \
  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= -j"$(nproc)" modules
```

固定 release 的收尾规则：

- 先确认远端 `uname -r`，当前应为 `6.12.0-opencca-wip`。
- 每次修正配置后都重新跑 `make ... LOCALVERSION= olddefconfig`。
- 立刻跑 `make ... LOCALVERSION= kernelrelease`，结果必须等于远端 `uname -r`。
- 如果曾经生成过 `6.12.0-opencca-wip+` 的 `.ko`，先删除对应旧 `.ko` 再重编。
- 安装前再次跑 `modinfo -F vermagic <module.ko>`，第一列必须等于远端 `uname -r`。
- release/vermagic 没固定前，不要继续重启服务、跑 smoke 或分析 ImageCache 日志；这些错误会污染后续判断。

## 不要滥用完整 fragment

单独补 `xt_comment.ko` 时，不要默认合并完整 `coco_host_fragment.config`。

完整 fragment 会打开很多额外 netfilter/xfrm/tunnel 模块，可能导致和 `xt_comment` 无关的 `modpost` 错误。只有完整替换 host kernel 或完整模块集合时，才显式使用：

```bash
COCO_REMOTE_PASSWORD=root ./scripts/deploy/install-host-kernel-modules.sh --merge-fragment --full-modules
```
