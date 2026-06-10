# AGENTS.md

本文件是本仓库给 Codex/自动化代理/开发者的根目录操作手册。进入本项目后优先阅读本文件，再查阅更细的设计和环境文档。

## 项目目标

本项目目标是在 RK3588/OpenCCA 硬件平台上运行 Confidential Containers/Kata Containers，并验证 Image CVM 到 Runtime CVM 的镜像共享路径。

当前主线目标：

- 使用 Firecracker 启动 OpenCCA Realm VM。
- Image CVM 负责拉取镜像、展开 rootfs、生成只读 EROFS rootfs image。
- Image CVM 通过 `/dev/coco-image-share` 注册 RMM-backed image share object。
- Runtime CVM 通过 RMM attach 共享对象，并通过 `/dev/cocoimg0` 挂载只读 rootfs。
- Runtime CVM 内的 kata-agent 能和 Kata runtime 通信并启动容器。
- 本阶段不要求 Trustee、镜像加密、远程策略认证。

已验证成功路径，日期为 2026-06-10：

- 镜像：`docker.m.daocloud.io/library/busybox:latest`
- 网络：`coco-bridge`
- DNS：`192.168.31.1`
- Image CVM 等待：`15s`
- 成功标志：`Image manifest`、`Created RMM rootfs share`、`guest_pull took`、`coco-runtime-cvm-ok`

## 硬件平台

默认硬件和网络：

- 本地工作目录：`/home/mzh/RK3588/COCO`
- RK3588/ROCK5B：`root@192.168.31.18`
- RK3588 密码：`root`
- Raspberry Pi 刷机/电源控制机：`mzh@192.168.31.52`
- Raspberry Pi 密码：`root`
- RK 运行目录：`/root/COCO-SFTP`
- Pi 刷机目录：`/home/mzh/opencca-flash`
- Pi 固件目录：`/home/mzh/opencca-flash/snapshot`



常用环境变量：

```bash
export COCO_REMOTE_HOST=root@192.168.31.18
export COCO_REMOTE_PASSWORD=root
export COCO_RPI_HOST=mzh@192.168.31.52
export COCO_RPI_PASSWORD=root
```

连接命令示例：

```bash
sshpass -p root ssh -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile=/tmp/coco_known_hosts \
  root@192.168.31.18 'hostname; uname -a'

sshpass -p root ssh -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile=/tmp/coco_known_hosts \
  mzh@192.168.31.52 'hostname; ls -l /home/mzh/opencca-flash/snapshot'
```

## 关键目录

仓库顶层：

- `COCO-SFTP/`：同步到 RK 的运行目录，远端路径为 `/root/COCO-SFTP`。
- `scripts/`：本地构建、镜像注入、同步、远程测试和固件流程脚本。
- `docs/`：环境、设计、测试记录。
- `docs/design/image-cache-v3/RMM-IMAGE-SHARE-V3-DESIGN.md`：RMM/EROFS image share 主设计和实现记录。
- `docs/COCO_RUNTIME_BUILD_AND_DEPLOY.md`：运行栈构建、同步、测试和固件脚本说明。

核心组件：

- `guest-components/`：CDH、image-rs、vsock-ttrpc-server 等 guest 侧组件。
- `kata-containers-cca/`：Kata runtime/shim/agent 源码。Runtime CVM 中的 `/usr/bin/kata-agent` 来自这里。
- `linux-image-share/`：Firecracker guest kernel 源码，包含 `/dev/coco-image-share`、`/dev/cocoimg0`。
- `Firecracker-CCA/`：OpenCCA/Firecracker VMM。
- `opencca/tf-rmm/`：RMM 源码，包含 image share RSI handlers。
- `opencca/opencca-build/`：OpenCCA 固件构建入口。
- `opencca/snapshot/`：本地固件产物，包含 `idbloader.img`、`u-boot.itb`、`u-boot-rockchip-spi.bin`、`tf-rmm.elf`。

远端脚本：

- `COCO-SFTP/scripts/remote/run/check-image-cache-network.sh`：轻量检查网络和服务，不修改状态。
- `COCO-SFTP/scripts/remote/run/prepare-image-cache-network.sh`：加载模块、修复 CNI/NAT，不重启 containerd。
- `COCO-SFTP/scripts/remote/run/start-container-runtime.sh`：完整准备并重启 `guest-pull-snapshotter`、`containerd`。
- `COCO-SFTP/scripts/remote/run/run-image-cache-smoke.sh`：远端 Image CVM + Runtime CVM smoke。

## 编译构建方式

优先使用脚本，不要手工拼命令。脚本已经记录了当前仓库的路径、目标架构、strip、镜像注入和远程默认地址。

本地基础检查：

```bash
./scripts/run/coco-local-flow.sh --check-prereqs
./scripts/package/check-coco-sftp.sh
./scripts/package/check-remote-install-flow.sh
```

构建 Firecracker：

```bash
./scripts/build/build-firecracker.sh
```

构建 guest kernel `linux-image-share`：

```bash
JOBS=8 ./scripts/build/build-linux-image-share.sh
```

注意：

- `linux-image-share/rk3588_fragment.config` 必须参与合并。
- 该内核需要包含 `CONFIG_COCO_IMAGE_SHARE=y`、`CONFIG_IMAGE_SERVER=y`、EROFS/SquashFS/loop/overlay/vsock/vhost-vsock 等配置。
- 构建产物会更新到 `COCO-SFTP/firecracker-bins/Image`。

构建 guest-components：

```bash
./scripts/build/build-guest-components.sh
./scripts/image/install-guest-components-into-kata-image.sh
```

构建并注入 kata-agent：

```bash
./scripts/build/build-kata-agent.sh
./scripts/image/install-kata-agent-into-kata-image.sh
```

注入 rootfs 工具：

```bash
./scripts/image/install-rootfs-tools-into-kata-image.sh
```

重要规则：

- 修改 `guest-components/image-rs` 后，通常必须同时重编 `guest-components` 和 `kata-agent`。
- 只编译 `image-rs` 或只注入 guest-components 不会更新 Runtime CVM 中的 kata-agent。
- 如果 Runtime 日志仍出现旧路径或旧控制流，优先怀疑 kata-agent 没有重新构建/注入。

推荐 image-rs 相关完整构建序列：

```bash
./scripts/build/build-guest-components.sh
./scripts/build/build-kata-agent.sh
./scripts/image/install-guest-components-into-kata-image.sh
./scripts/image/install-kata-agent-into-kata-image.sh
./scripts/image/install-rootfs-tools-into-kata-image.sh --verify-only
./scripts/image/install-guest-components-into-kata-image.sh --verify-only
./scripts/image/install-kata-agent-into-kata-image.sh --verify-only
```

构建 RMM 并重新打包 U-Boot：

```bash
./scripts/firmware/build-rmm-uboot.sh
```

只构建 RMM：

```bash
./scripts/firmware/build-rmm-uboot.sh --rmm-only
```

只用现有 `opencca/snapshot/tf-rmm.elf` 重新打包 U-Boot：

```bash
./scripts/firmware/build-rmm-uboot.sh --uboot-only
```

## 应用代码更改到远端

### 同步 COCO-SFTP 到 RK

```bash
COCO_REMOTE_PASSWORD=root ./scripts/deploy/sync-coco-sftp.sh
```

默认不包含 `linux-host-kernel/` 和 `opencca-assets/`。固件/host kernel 使用专门脚本，不要塞进普通 runtime 同步路径。

### 更新普通二进制和配置

构建、检查、同步并按组件远端安装：

```bash
COCO_REMOTE_PASSWORD=root \
  ./scripts/deploy/update-remote-component.sh \
  --component guest-pull-snapshotter \
  --remote-reinstall
```

可选组件：

- `firecracker`
- `linux-image-share`
- `kata`
- `guest-pull-snapshotter`
- `guest-components`

如需重启运行时服务，再加：

```bash
--remote-restart
```

不要每次测试都加 `--remote-restart`。连续 ImageCache 测试时，服务通常可以复用。

### 更新 Kata guest image

修改 guest-components、kata-agent、rootfs tools 后，相关脚本会更新：

```text
COCO-SFTP/images/kata-containers-cca.img
```

然后同步：

```bash
COCO_REMOTE_PASSWORD=root ./scripts/deploy/sync-coco-sftp.sh
```

### 更新 guest kernel

修改 `linux-image-share/` 后：

```bash
JOBS=8 ./scripts/build/build-linux-image-share.sh
COCO_REMOTE_PASSWORD=root ./scripts/deploy/sync-coco-sftp.sh
```

新 kernel 位于：

```text
COCO-SFTP/firecracker-bins/Image
```

运行中的 VM 不会自动使用新内核，必须新建容器/VM。

### 更新 RK Host kernel 模块

缺少单个 host kernel 模块时，优先使用专门脚本，不要重新走完整 host kernel 替换流程：

```bash
COCO_REMOTE_PASSWORD=root ./scripts/deploy/install-host-kernel-modules.sh
```

该脚本默认修复 `xt_comment.ko`，流程是：

- 从 RK 正在运行的 `/boot/config-$(uname -r)` 刷新本地 `.config`。
- 只打开目标模块配置，例如 `CONFIG_NETFILTER_XT_MATCH_COMMENT=m`。
- 所有 `make` 命令都显式传 `LOCALVERSION=`，避免 dirty tree 生成 `6.12.0-opencca-wip+`。
- `olddefconfig` 后立刻用 `kernelrelease` 对比远端 `uname -r`。
- 如果 release 或 `vermagic` 带 `+`，立即停止；删除错误 `.ko` 后固定 `LOCALVERSION=` 重新构建。
- 默认只构建必要 `.ko` 目标：`net/netfilter/x_tables.ko` 参与 modpost，`net/netfilter/xt_comment.ko` 作为安装目标。
- 构建后检查 `modinfo -F vermagic` 必须等于远端 `uname -r`。
- 安装到 `/lib/modules/$(uname -r)/kernel/...`，执行 `depmod` 和 `modprobe`。

只构建不安装：

```bash
COCO_REMOTE_PASSWORD=root ./scripts/deploy/install-host-kernel-modules.sh --build-only
```

离线复用已有 `.config`：

```bash
./scripts/deploy/install-host-kernel-modules.sh --build-only --no-remote-config
```

只有在准备完整 host module set 时才使用：

```bash
COCO_REMOTE_PASSWORD=root ./scripts/deploy/install-host-kernel-modules.sh --merge-fragment --full-modules
```

不要把 `--merge-fragment` 当成单模块修复的默认选项；它会打开大量额外模块，可能触发无关的 modpost 依赖错误。

### 更新 RMM/固件并通过 Pi 刷写

构建 RMM 并打包进 U-Boot：

```bash
./scripts/firmware/build-rmm-uboot.sh
```

同步固件到 Pi：

```bash
COCO_RPI_PASSWORD=root ./scripts/firmware/flash-rk3588-firmware-via-pi.sh --sync-only
```

刷写 MMC 并等待 RK SSH 恢复：

```bash
COCO_RPI_PASSWORD=root COCO_REMOTE_PASSWORD=root \
  ./scripts/firmware/flash-rk3588-firmware-via-pi.sh --flash-mmc --wait-rk
```

组合流程：

```bash
COCO_RPI_PASSWORD=root COCO_REMOTE_PASSWORD=root \
  ./scripts/firmware/rmm-uboot-flash-flow.sh --flash-mmc --wait-rk
```

构建、刷写、恢复后跑 ImageCache：

```bash
COCO_RPI_PASSWORD=root COCO_REMOTE_PASSWORD=root \
  ./scripts/firmware/rmm-uboot-flash-flow.sh --flash-mmc --wait-rk --test-imagecache
```

如果需要在测试前完整准备 RK runtime：

```bash
COCO_IMAGE_CACHE_PREPARE=1 COCO_RPI_PASSWORD=root COCO_REMOTE_PASSWORD=root \
  ./scripts/firmware/rmm-uboot-flash-flow.sh --flash-mmc --wait-rk --test-imagecache
```

## 测试方式

### 首选 ImageCache smoke

从本地直接跑，默认不重启远端服务：

```bash
COCO_REMOTE_PASSWORD=root ./scripts/run/run-image-cache-smoke-remote.sh
```

该脚本默认先调用远端轻量检查：

```text
/root/COCO-SFTP/scripts/remote/run/check-image-cache-network.sh
```

然后运行：

```text
/root/COCO-SFTP/scripts/remote/run/run-image-cache-smoke.sh
```

如需完整准备和重启服务：

```bash
COCO_REMOTE_PASSWORD=root ./scripts/run/run-image-cache-smoke-remote.sh --prepare
```

换镜像：

```bash
COCO_REMOTE_PASSWORD=root \
  ./scripts/run/run-image-cache-smoke-remote.sh \
  --image docker.m.daocloud.io/library/nginx:latest \
  --wait 20
```

远端直接跑：

```bash
sshpass -p root ssh root@192.168.31.18 \
  'cd /root/COCO-SFTP && ./scripts/remote/run/run-image-cache-smoke.sh'
```

成功标志：

- 命令输出 `coco-runtime-cvm-ok`
- containerd/kata 日志中出现 `Image manifest`
- Image CVM 日志中出现 `Created RMM rootfs share`
- Runtime CVM 日志中出现 `guest_pull took`

抓关键日志：

```bash
sshpass -p root ssh root@192.168.31.18 \
  'journalctl -u containerd --since "10 minutes ago" --no-pager | egrep -i "Image manifest|Created RMM rootfs share|Prepared shared rootfs|guest_pull took|coco-runtime-cvm-ok|failed to pull|dns error|cocoimg|coco-image-share" | tail -n 160'
```

### RK 串口/RMM 日志

树莓派可以通过 `ttyUSB0` 连接 RK3588 串口，波特率固定为 `1500000`。涉及 RMM、guest kernel、卡死、蓝灯常亮、`realm_destroy`、share/map/unmap 异常的测试，优先在测试前启动串口 logger：

```bash
COCO_RPI_PASSWORD=root ./scripts/debug/rk3588-serial-log.sh start --tag imagecache-test
```

测试失败后把日志拉回本地：

```bash
COCO_RPI_PASSWORD=root ./scripts/debug/rk3588-serial-log.sh fetch
```

日志默认保存到：

```text
docs/log/serial/
```

临时抓一小段现场：

```bash
COCO_RPI_PASSWORD=root ./scripts/debug/rk3588-serial-log.sh capture --seconds 30 --tag after-failure
```

状态和停止：

```bash
COCO_RPI_PASSWORD=root ./scripts/debug/rk3588-serial-log.sh status
COCO_RPI_PASSWORD=root ./scripts/debug/rk3588-serial-log.sh stop
```

不要同时运行后台 `start` 和临时 `capture` 读取同一个 `ttyUSB0`。如果要捕获 RMM 崩溃瞬间，必须在运行风险测试前先 `start`，失败后再 `fetch`；事后 `capture` 只能看到当时仍在输出的日志。

### 轻量网络检查

连续测试时只检查，不重启：

```bash
sshpass -p root ssh root@192.168.31.18 \
  'cd /root/COCO-SFTP && ./scripts/remote/run/check-image-cache-network.sh'
```

完整准备网络和服务：

```bash
sshpass -p root ssh root@192.168.31.18 \
  'cd /root/COCO-SFTP && ./scripts/remote/run/start-container-runtime.sh'
```

`start-container-runtime.sh` 会重启 `guest-pull-snapshotter` 和 `containerd`，不要在每次 smoke 前默认调用。

## 构建脚本的方式

新脚本的目的必须是减少重复工作，而不是增加一层难懂包装。

脚本化范围不要局限于本文已经列出的 RMM 编译、U-Boot 打包、树莓派刷写、ImageCache 测试、网络准备等流程。只要某个操作满足以下任一条件，就优先考虑沉淀为脚本：

- 高频重复执行，例如编译、同步、部署、清理、日志采集、远程健康检查。
- 参数经常变化但流程固定，例如镜像源、VM 内存、DNS、网络名、远程地址、固件路径、测试镜像。
- 手工执行容易漏步骤，例如修改 `image-rs` 后需要同时重编 guest-components 和 kata-agent，并重新注入镜像。
- 执行耗时较长，值得通过缓存、增量同步、快速检查、跳过已完成步骤来节省时间。
- 失败排查依赖固定证据，例如抓取 `containerd` 日志、RMM/guest kernel 关键字、服务状态、内核模块状态。
- 操作有风险，需要统一入口保护，例如刷写固件、重启 RK、重启服务、清理容器、替换内核或镜像。

换句话说，脚本的价值是把已经验证过的经验固化下来，减少每轮测试的重新思考和重新试错。不要只为用户明确点名的几个操作写脚本；任何能稳定缩短下一次构建、部署、测试、排障时间的重复动作，都应该进入脚本或现有脚本的参数化能力中。

脚本设计规则：

- 默认值必须来自已经实测成功的路径。
- 参数通过环境变量或明确选项覆盖。
- 默认动作要保守，避免误刷、误重启、误删数据。
- 对会刷写固件、重启服务、清理容器的动作，要在脚本名或参数中明显体现。
- 连续测试默认只做轻量检查，不做重复安装、重复 CNI 修复、重复重启。
- 输出实际执行命令，方便复制和复盘。
- 提供 `--dry-run`。
- 使用 `set -euo pipefail`。
- 公共路径和默认远程地址从 `scripts/lib/coco_paths.sh` 读取。
- 对远程 SSH 密码，支持 `COCO_REMOTE_PASSWORD`、`COCO_RPI_PASSWORD`。

已有脚本优先级：

1. 能用现有脚本组合完成的，不新增脚本。
2. 会重复使用三次以上，或单次成本高、容易出错、依赖固定顺序的手动命令，沉淀成脚本。
3. 成功验证之后再把默认值写进脚本。
4. 失败的旧方案不要伪装成可用入口，删除或在文档中标记为 blacklist。

## 现有脚本快速使用

检查本地包：

```bash
./scripts/package/check-coco-sftp.sh
./scripts/package/check-remote-install-flow.sh
```

同步运行目录：

```bash
COCO_REMOTE_PASSWORD=root ./scripts/deploy/sync-coco-sftp.sh
```

轻量 ImageCache 测试：

```bash
COCO_REMOTE_PASSWORD=root ./scripts/run/run-image-cache-smoke-remote.sh
```

完整准备后 ImageCache 测试：

```bash
COCO_REMOTE_PASSWORD=root ./scripts/run/run-image-cache-smoke-remote.sh --prepare
```

启动 RK 串口日志：

```bash
COCO_RPI_PASSWORD=root ./scripts/debug/rk3588-serial-log.sh start --tag imagecache
```

失败后抓取串口日志：

```bash
COCO_RPI_PASSWORD=root ./scripts/debug/rk3588-serial-log.sh fetch
```

构建 RMM + U-Boot：

```bash
./scripts/firmware/build-rmm-uboot.sh
```

刷写 RK MMC：

```bash
COCO_RPI_PASSWORD=root COCO_REMOTE_PASSWORD=root \
  ./scripts/firmware/flash-rk3588-firmware-via-pi.sh --flash-mmc --wait-rk
```

构建、刷写、测试一条龙：

```bash
COCO_RPI_PASSWORD=root COCO_REMOTE_PASSWORD=root \
  ./scripts/firmware/rmm-uboot-flash-flow.sh --flash-mmc --wait-rk --test-imagecache
```

## 已知错误和规避方式

### Image CVM DNS 失败

症状：

```text
failed to pull manifest ... dns error ... failed to lookup address information: Try again
```

优先使用已验证组合：

- `--net coco-bridge`
- `--dns 192.168.31.1`
- `docker.m.daocloud.io/library/busybox:latest`

不要默认使用：

- `--net=host`
- `8.8.8.8`
- 未验证镜像源

检查：

```bash
cd /root/COCO-SFTP
./scripts/remote/run/check-image-cache-network.sh
```

修复：

```bash
cd /root/COCO-SFTP
./scripts/remote/run/start-container-runtime.sh
```

注意：`nerdctl --add-host` 只影响最终容器的 `/etc/hosts`，guest-pull 拉镜像发生得更早，不能作为默认 DNS 修复方案。

### 重复测试后不想重启服务

使用：

```bash
COCO_REMOTE_PASSWORD=root ./scripts/run/run-image-cache-smoke-remote.sh
```

不要使用：

```bash
./scripts/remote/run/start-container-runtime.sh
```

除非 CNI/NAT/服务状态已经坏掉或刚刷机重启。

### 256 MiB 内存不稳定

当前 `COCO-SFTP/configs/kata-containers/configuration-fc.toml` 使用：

```toml
default_memory = 512
```

256 MiB 可能导致 guest 网络和 image pull 初始化不稳定。不要把默认值改回 256 MiB，除非明确在做内存压力实验。

### 修改 image-rs 后行为没变

原因通常是只重编了 guest-components，没有重编并注入 kata-agent。

修复：

```bash
./scripts/build/build-guest-components.sh
./scripts/build/build-kata-agent.sh
./scripts/image/install-guest-components-into-kata-image.sh
./scripts/image/install-kata-agent-into-kata-image.sh
COCO_REMOTE_PASSWORD=root ./scripts/deploy/sync-coco-sftp.sh
```

### RMM 更新后 RK 没有生效

必须完成三步：

1. 构建 RMM。
2. 把 `tf-rmm.elf` 打包进 `u-boot.itb`。
3. 通过 Pi 刷写 `idbloader.img` 和 `u-boot.itb`。

使用：

```bash
./scripts/firmware/build-rmm-uboot.sh
COCO_RPI_PASSWORD=root COCO_REMOTE_PASSWORD=root \
  ./scripts/firmware/flash-rk3588-firmware-via-pi.sh --flash-mmc --wait-rk
```

### RMM share 对象可能泄漏

当前 RMM image share object 是原型实现。重复创建/销毁 Image CVM 可能造成 RMM 内部静态 share table 被消耗。若出现异常且普通清理无效，优先通过 Pi 重启 RK。

```bash
COCO_RPI_PASSWORD=root COCO_REMOTE_PASSWORD=root \
  ./scripts/firmware/flash-rk3588-firmware-via-pi.sh --reboot --wait-rk
```

### Host kernel 缺 `xt_comment`

症状：

```text
iptables: Couldn't load match `comment'
failed to setup CNI/NAT
```

修复：

```bash
COCO_REMOTE_PASSWORD=root ./scripts/deploy/install-host-kernel-modules.sh
```

验证：

```bash
sshpass -p root ssh root@192.168.31.18 \
  'modprobe xt_comment && modinfo xt_comment | grep vermagic'
```

`vermagic` 的第一列必须是：

```text
6.12.0-opencca-wip
```

如果显示 `6.12.0-opencca-wip+`，说明构建时没有固定 release。不要安装这个模块，也不要尝试强制加载；删除错误 `.ko`，重新用 `LOCALVERSION=` 构建，直到 `kernelrelease` 和 `vermagic` 都等于远端 `uname -r`。

### Host module fragment 引入无关 modpost 错误

单独补模块时不要默认合并整份 `coco_host_fragment.config`。整份 fragment 会打开很多 netfilter/xfrm/tunnel 模块，可能出现和本次目标无关的 `modpost` unresolved symbol。

正确做法：

```bash
COCO_REMOTE_PASSWORD=root ./scripts/deploy/install-host-kernel-modules.sh --build-only
```

该脚本会使用远端运行内核配置作为基线，只补目标 symbol。只有完整替换 host kernel/module set 时，才显式使用 `--merge-fragment` 或 `KernelCompile.md` 中的完整流程。

### RK 蓝灯常亮或 SSH 不通

优先通过 Pi 控制重启：

```bash
COCO_RPI_PASSWORD=root COCO_REMOTE_PASSWORD=root \
  ./scripts/firmware/flash-rk3588-firmware-via-pi.sh --reboot --wait-rk
```

如果需要重新刷固件：

```bash
COCO_RPI_PASSWORD=root COCO_REMOTE_PASSWORD=root \
  ./scripts/firmware/flash-rk3588-firmware-via-pi.sh --flash-mmc --wait-rk
```

### `/run` 空间不足

旧调试中可能需要：

```bash
mount -o remount,size=8G /run
```

但这不是默认 ImageCache 路径。优先使用 EROFS/RMM share，避免 copy-mode 把 Runtime CVM tmpfs 撑满。

## 禁止事项

禁止把失败的旧方案重新设为默认：

- 不要默认使用 `--net=host` 跑 ImageCache。
- 不要默认使用 public DNS `8.8.8.8`。
- 不要默认使用 `docker.io` 直连作为 RK 测试镜像源。
- 不要把 `cid=4:54321` 当作 Image CVM 未启动前可用的链路。
- 不要用 `--add-host` 作为 guest-pull DNS 的主修复方案。
- 不要回到 V2 loop/overlay rootfs prototype 路径。
- 不要把 ext4 copy-mode 当主路径。
- 不要只靠增大 CMA/reserved memory 来解决 image share。
- 不要把 `SMC_RSI_MAP_MEM_LIST` 当最终安全接口。
- 不要把 0x1B0+ 自定义 FID 当长期 ABI。

禁止破坏工作区：

- 不要执行 `git reset --hard`、`git checkout -- .` 等会丢失用户改动的命令。
- 不要删除未确认来源的用户文件。
- 不要手动覆盖远端大镜像或固件，除非脚本和参数明确表示要这样做。
- 不要在每次 smoke 前重装 CNI、重启 containerd，除非检查失败或明确传 `--prepare`。
- 不要在未确认 RMM/U-Boot 构建成功时刷写固件。
- 不要绕过 `rk3588_fragment.config` 构建 guest kernel。
- 不要安装 `vermagic` 带 `+` 的 host kernel module。
- 不要在 release/vermagic 尚未固定时反复复用旧 `.ko`；先清理错误产物，再固定 `LOCALVERSION=` 重编。
- 不要为了单个缺失模块默认合并整份 host kernel fragment。

## 修改文件规则

- 优先使用 `rg` 查找。
- 手工编辑文件使用 `apply_patch`。
- 不要引入无关重构。
- 可能影响远端运行的改动必须给出构建、同步和测试命令。
- 脚本改动至少运行：

```bash
bash -n <script>
git diff --check
./scripts/package/check-remote-install-flow.sh
```

如果改动影响 COCO-SFTP：

```bash
./scripts/package/check-coco-sftp.sh
COCO_REMOTE_PASSWORD=root ./scripts/deploy/sync-coco-sftp.sh
```

## 参考文档

- `docs/COCO_RUNTIME_BUILD_AND_DEPLOY.md`
- `docs/design/image-cache-v3/RMM-IMAGE-SHARE-V3-DESIGN.md`
- `docs/env/opencca-rk3588-env/OPENCCA-RK3588-ENV.md`
- `docs/env/opencca-rk3588-env/KernelCompile.md`
- `docs/env/opencca-rk3588-env/HostKernelModules.md`
- `docs/log/EROFSshare.log`
