# COCO From Zero Build And Setup

本文是给一台全新的控制机使用的主线文档，目标是从零拉取仓库、恢复大文件、编译 COCO/OpenCCA 组件、部署到 RK3588，并跑通 Image CVM 到 Runtime CVM 的 ImageCache smoke。

当前主线只覆盖 RK3588/ROCK5B + OpenCCA + Firecracker + Kata + guest-pull + RMM/EROFS image share。Trustee、镜像加密和远程策略认证不属于本阶段必需项。

## 0. 机器角色

一套完整环境通常有三类机器：

| 角色 | 说明 |
| --- | --- |
| 控制机 | x86_64/amd64 Linux，负责 clone、交叉编译、同步、远程测试。 |
| RK3588 | ROCK5B/OpenCCA 运行板，运行 containerd/Kata/Firecracker/Realm VM。 |
| Raspberry Pi | 可选但推荐，用于 RK3588 串口日志、电源/刷机控制。 |

不要把 IP 写死进新环境。本文使用变量：

```bash
export COCO_ROOT="$HOME/RK3588/COCO"
export COCO_REMOTE_HOST="root@<RK3588_IP>"
export COCO_REMOTE_PASSWORD="<RK3588_ROOT_PASSWORD>"
export COCO_RPI_HOST="<PI_USER>@<PI_IP>"
export COCO_RPI_PASSWORD="<PI_PASSWORD>"
```

如果没有 Raspberry Pi，可以先只设置 `COCO_REMOTE_HOST` 和 `COCO_REMOTE_PASSWORD`，runtime 构建、同步、远程安装和 smoke 不依赖 Pi；固件刷写和串口日志才依赖 Pi。

## 1. 控制机基础依赖

推荐使用 Ubuntu/Debian 控制机。先装通用工具：

```bash
sudo apt update
sudo apt install -y \
  build-essential git git-lfs curl wget ca-certificates pkg-config \
  make cmake ninja-build meson python3 python3-pip perl \
  rsync openssh-client sshpass file bc bison flex \
  device-tree-compiler libssl-dev libelf-dev dwarves \
  ccache \
  gcc-aarch64-linux-gnu g++-aarch64-linux-gnu binutils-aarch64-linux-gnu \
  musl-tools qemu-utils e2fsprogs util-linux erofs-utils squashfs-tools \
  jq xz-utils unzip zstd lz4 dpkg-dev
```

安装 GitHub CLI，用于下载 release 大文件：

```bash
sudo apt install -y gh
gh auth login
```

安装 Rust：

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
. "$HOME/.cargo/env"
rustup target add aarch64-unknown-linux-musl
```

Firecracker 仓库带 `rust-toolchain.toml`，会自动使用它需要的 toolchain。若缺少 `rustfmt`：

```bash
rustup component add rustfmt
```

安装 Go。`guest-pull-snapshotter` 使用 Go 1.23.x，Kata runtime 至少需要 Go 1.21。推荐直接安装 Go 1.23.x：

```bash
curl -fsSL https://go.dev/dl/go1.23.4.linux-amd64.tar.gz -o /tmp/go.tar.gz
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf /tmp/go.tar.gz
echo 'export PATH=/usr/local/go/bin:$PATH' >> "$HOME/.bashrc"
export PATH=/usr/local/go/bin:$PATH
go version
```

安装 AArch64 musl 交叉工具链。很多发行版没有 `aarch64-linux-musl-gcc` 包，建议使用 musl.cc 预编译工具链：

```bash
sudo mkdir -p /opt
curl -fsSL https://musl.cc/aarch64-linux-musl-cross.tgz -o /tmp/aarch64-linux-musl-cross.tgz
sudo tar -C /opt -xzf /tmp/aarch64-linux-musl-cross.tgz
echo 'export PATH=/opt/aarch64-linux-musl-cross/bin:$PATH' >> "$HOME/.bashrc"
export PATH=/opt/aarch64-linux-musl-cross/bin:$PATH
aarch64-linux-musl-gcc --version
```

OpenCCA RMM/U-Boot 固件构建还需要 `aarch64-none-linux-gnu-gcc`。如果控制机没有这个命令，先 clone 仓库，之后运行 OpenCCA 自带下载脚本：

```bash
cd "$COCO_ROOT"
./opencca/opencca-build/buildconf/download-arm-toolchain.sh linux
export PATH="$COCO_ROOT/opencca/opencca-build/buildconf/aarch64-none-linux-gnu/bin:$PATH"
aarch64-none-linux-gnu-gcc --version
```

最终必须满足这些命令存在：

```bash
command -v git gh make cargo rustup go \
  aarch64-linux-gnu-gcc aarch64-linux-musl-gcc \
  aarch64-none-linux-gnu-gcc ccache \
  rsync ssh sshpass debugfs sfdisk
```

## 2. 获取源码和大文件

克隆顶层仓库和全部子模块：

```bash
mkdir -p "$(dirname "$COCO_ROOT")"
git clone https://github.com/Marshal1l/COCO.git "$COCO_ROOT"
cd "$COCO_ROOT"
git submodule update --init --recursive
```

确认关键子模块存在：

```bash
git submodule status --recursive | sed -n '1,120p'
test -d Firecracker-CCA
test -d firecracker-deps/kvm-bindings
test -d guest-components
test -d kata-containers-cca
test -d linux-image-share
test -d linux-host-kernel
test -d opencca/tf-rmm
```

恢复不进 git 的固定大文件。它们位于 `Marshal1l/COCO` 的 `coco-runtime-artifacts` release：

```bash
./scripts/package/download-release-assets.sh
```

该脚本会恢复：

```text
COCO-SFTP/images/kata-containers-cca.img
COCO-SFTP/images/rootfs.ext4
COCO-SFTP/qemu-bins/qemu-special
opencca/rootfs/opencca-image-rockchip-rock5b-rk3588.img
```

如果下载失败，先确认：

```bash
gh release view coco-runtime-artifacts --repo Marshal1l/COCO
```

## 3. 发现 RK3588 和 Pi 地址

优先让新机器自己发现网段，而不是复用旧 IP。

查看控制机出口网卡和网段：

```bash
ip -br addr
ip route
```

扫描本地网段。将网段替换成控制机所在 LAN，例如 `192.168.31.0/24`：

```bash
sudo apt install -y nmap
nmap -sn <LAN_CIDR>
```

也可以通过 ARP/SSH 快速筛选：

```bash
ip neigh
for ip in $(seq 1 254); do
  host="<LAN_PREFIX>.$ip"
  timeout 1 bash -c "cat < /dev/null > /dev/tcp/$host/22" 2>/dev/null && echo "$host ssh"
done
```

如果让另一台新机器或自动化 Agent 接手环境发现，可以直接使用这段提示词：

```text
请不要复用旧机器的固定 IP。先在控制机执行 ip -br addr 和 ip route 判断当前 LAN 网段，
用 nmap -sn <LAN_CIDR>、ip neigh 和 22 端口探测找出可能的 RK3588 与 Raspberry Pi。
对候选机器分别尝试 SSH，RK3588 预期能执行 hostname/uname/containerd/ip route，
Pi 预期能看到 /dev/ttyUSB0 或 /home/mzh/opencca-flash/flash.sh。
确认后导出 COCO_REMOTE_HOST、COCO_REMOTE_PASSWORD、COCO_RPI_HOST、COCO_RPI_PASSWORD。
ImageCache DNS 不要写死，优先取 RK 的默认网关或 /etc/resolv.conf 中的局域网 DNS。
```

确认 RK3588：

```bash
export COCO_REMOTE_HOST="root@<RK3588_IP>"
export COCO_REMOTE_PASSWORD="root"

sshpass -p "$COCO_REMOTE_PASSWORD" ssh \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile=/tmp/coco_known_hosts \
  "$COCO_REMOTE_HOST" 'hostname; uname -a; ip -br addr'
```

确认 Raspberry Pi：

```bash
export COCO_RPI_HOST="<PI_USER>@<PI_IP>"
export COCO_RPI_PASSWORD="root"

sshpass -p "$COCO_RPI_PASSWORD" ssh \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile=/tmp/coco_known_hosts \
  "$COCO_RPI_HOST" 'hostname; ls -l /dev/ttyUSB0 || true'
```

如果 RK 地址还没有固定，可在 RK 上根据实际网卡写 systemd-networkd 配置。先找网卡名：

```bash
ip -br link
```

示例配置，不要照抄 IP，按实际网段替换：

```bash
cat >/etc/systemd/network/10-opencca-lan.network <<'EOF'
[Match]
Name=<RK_ETH_IFACE>

[Network]
DHCP=no
Address=<RK3588_IP>/<PREFIX_BITS>
Gateway=<LAN_GATEWAY>
DNS=<LAN_DNS>

[Link]
RequiredForOnline=yes
EOF

systemctl restart systemd-networkd
```

## 4. RK3588 基础系统准备

RK3588 需要能 SSH 登录 root、能访问互联网或镜像源、已安装 containerd。远端基础检查：

```bash
sshpass -p "$COCO_REMOTE_PASSWORD" ssh \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile=/tmp/coco_known_hosts \
  "$COCO_REMOTE_HOST" '
set -e
hostname
uname -a
command -v containerd || true
systemctl status containerd --no-pager || true
ip route
cat /etc/resolv.conf || true
'
```

如果 RK 是新刷系统，先装基础包：

```bash
sshpass -p "$COCO_REMOTE_PASSWORD" ssh "$COCO_REMOTE_HOST" '
set -e
apt update
apt install -y openssh-server containerd iptables iproute2 systemd \
  ca-certificates curl rsync kmod e2fsprogs
systemctl enable ssh containerd
'
```

允许 root SSH 登录，按需在 RK 上配置：

```bash
cat >/etc/ssh/sshd_config.d/99-coco-root-login.conf <<'EOF'
PasswordAuthentication yes
PermitRootLogin yes
PubkeyAuthentication yes
EOF
systemctl restart ssh
```

## 5. 本地构建前检查

回到控制机：

```bash
cd "$COCO_ROOT"
export COCO_REMOTE_HOST COCO_REMOTE_PASSWORD COCO_RPI_HOST COCO_RPI_PASSWORD
./scripts/run/coco-local-flow.sh --check-prereqs
```

如果缺 `aarch64-linux-musl-gcc`，修正 PATH：

```bash
export PATH=/opt/aarch64-linux-musl-cross/bin:$PATH
```

如果 Firecracker 构建提示缺 `firecracker-deps`，重新拉完整子模块：

```bash
git submodule update --init --recursive firecracker-deps
```

## 6. 构建 runtime 栈

完整 runtime 构建：

```bash
cd "$COCO_ROOT"
JOBS="$(nproc)" ./scripts/build/build-all.sh
```

等价的可组合入口：

```bash
./scripts/run/coco-local-flow.sh --build
```

构建完成后必须检查：

```bash
./scripts/package/check-coco-sftp.sh
./scripts/package/check-remote-install-flow.sh
```

构建产物位置：

| 组件 | 输出 |
| --- | --- |
| Firecracker | `COCO-SFTP/firecracker-bins/firecracker` |
| guest kernel | `COCO-SFTP/firecracker-bins/Image` |
| Kata runtime/shim | `COCO-SFTP/kata-bins/` |
| guest-pull snapshotter | `COCO-SFTP/guest-pull/` |
| guest-components | `artifacts/guest-components/bin/`，并注入 Kata guest image |

如果改了 `guest-components/image-rs`，必须同时重建 guest-components 和 kata-agent，并重新注入 guest image：

```bash
./scripts/build/build-guest-components.sh
./scripts/build/build-kata-agent.sh
./scripts/image/install-guest-components-into-kata-image.sh
./scripts/image/install-kata-agent-into-kata-image.sh
./scripts/image/install-rootfs-tools-into-kata-image.sh --verify-only
./scripts/image/install-guest-components-into-kata-image.sh --verify-only
./scripts/image/install-kata-agent-into-kata-image.sh --verify-only
```

Image CVM 需要 guest image 内有 rootfs image 工具。首次恢复 guest image 后建议验证：

```bash
./scripts/image/install-rootfs-tools-into-kata-image.sh --verify-only
```

如果缺失，安装进去：

```bash
./scripts/image/install-rootfs-tools-into-kata-image.sh
```

## 7. 构建 OpenCCA RMM/U-Boot 固件

如果只部署 runtime，不改 RMM/固件，可以跳过本节。若要从零构建并刷入当前 RMM image share 实现，执行：

```bash
cd "$COCO_ROOT"
./scripts/firmware/build-rmm-uboot.sh
```

该脚本使用：

```text
opencca/opencca-build/buildconf/firmware_opencca.mk
opencca/tf-rmm
opencca/u-boot
opencca/snapshot/
```

预期产物：

```bash
ls -lh opencca/snapshot/tf-rmm.elf \
       opencca/snapshot/idbloader.img \
       opencca/snapshot/u-boot.itb \
       opencca/snapshot/u-boot-rockchip-spi.bin
```

只构建 RMM：

```bash
./scripts/firmware/build-rmm-uboot.sh --rmm-only
```

只用当前 `tf-rmm.elf` 重新打包 U-Boot：

```bash
./scripts/firmware/build-rmm-uboot.sh --uboot-only
```

## 8. 通过 Pi 刷写固件

确认 Pi 可以访问，且刷机目录存在。默认刷机目录是 `/home/mzh/opencca-flash`，新环境不同路径时用 `COCO_RPI_FLASH_ROOT` 覆盖：

```bash
export COCO_RPI_FLASH_ROOT="${COCO_RPI_FLASH_ROOT:-/home/mzh/opencca-flash}"
sshpass -p "$COCO_RPI_PASSWORD" ssh "$COCO_RPI_HOST" '
hostname
ls -ld '"$COCO_RPI_FLASH_ROOT"'
ls -l '"$COCO_RPI_FLASH_ROOT"'/flash.sh
'
```

只同步固件到 Pi：

```bash
COCO_RPI_PASSWORD="$COCO_RPI_PASSWORD" COCO_RPI_FLASH_ROOT="$COCO_RPI_FLASH_ROOT" \
./scripts/firmware/flash-rk3588-firmware-via-pi.sh --sync-only
```

刷写 MMC 并等待 RK SSH 恢复：

```bash
COCO_RPI_PASSWORD="$COCO_RPI_PASSWORD" COCO_RPI_FLASH_ROOT="$COCO_RPI_FLASH_ROOT" \
COCO_REMOTE_PASSWORD="$COCO_REMOTE_PASSWORD" \
./scripts/firmware/flash-rk3588-firmware-via-pi.sh --flash-mmc --wait-rk
```

构建、刷写、等待一条龙：

```bash
COCO_RPI_PASSWORD="$COCO_RPI_PASSWORD" COCO_REMOTE_PASSWORD="$COCO_REMOTE_PASSWORD" \
./scripts/firmware/rmm-uboot-flash-flow.sh --flash-mmc --wait-rk
```

需要捕获串口日志时：

```bash
COCO_RPI_PASSWORD="$COCO_RPI_PASSWORD" ./scripts/debug/rk3588-serial-log.sh start --tag from-zero
# 跑测试或刷机
COCO_RPI_PASSWORD="$COCO_RPI_PASSWORD" ./scripts/debug/rk3588-serial-log.sh fetch
```

串口固定参数是 `1500000` baud，默认 Pi 设备是 `/dev/ttyUSB0`。

## 9. 同步 runtime 到 RK3588

同步本地 `COCO-SFTP/` 到 RK 的 `/root/COCO-SFTP`：

```bash
cd "$COCO_ROOT"
COCO_REMOTE_HOST="$COCO_REMOTE_HOST" COCO_REMOTE_PASSWORD="$COCO_REMOTE_PASSWORD" \
./scripts/deploy/sync-coco-sftp.sh
```

默认不会同步 host kernel 和 OpenCCA 大资产。只有做完整 host kernel/board asset 实验时才加：

```bash
COCO_SYNC_BOARD_ASSETS=1 ./scripts/deploy/sync-coco-sftp.sh
```

## 10. 远端安装 runtime 栈

在 RK 上运行：

```bash
sshpass -p "$COCO_REMOTE_PASSWORD" ssh "$COCO_REMOTE_HOST" '
set -e
cd /root/COCO-SFTP
./scripts/remote/check/preflight.sh
./scripts/remote/install/all.sh
./scripts/remote/run/start-container-runtime.sh
'
```

`install/all.sh` 会安装：

```text
CNI plugins and config
containerd config
Kata config
Kata runtime/shim/monitor
guest-pull snapshotter service
nerdctl
```

`start-container-runtime.sh` 会：

```text
准备 coco-bridge/CNI/NAT
加载 overlay/vsock/vhost-vsock/loop
重启 guest-pull-snapshotter
重启 containerd
```

连续测试时不要每次都重启服务。轻量检查：

```bash
sshpass -p "$COCO_REMOTE_PASSWORD" ssh "$COCO_REMOTE_HOST" '
cd /root/COCO-SFTP
./scripts/remote/run/check-image-cache-network.sh
'
```

## 11. Host kernel 模块

如果 CNI/NAT 报缺 `xt_comment`，或者 `check-image-cache-network.sh` 失败，先用脚本补模块，不要直接替换整套 host kernel：

```bash
cd "$COCO_ROOT"
COCO_REMOTE_HOST="$COCO_REMOTE_HOST" COCO_REMOTE_PASSWORD="$COCO_REMOTE_PASSWORD" \
./scripts/deploy/install-host-kernel-modules.sh
```

验证：

```bash
sshpass -p "$COCO_REMOTE_PASSWORD" ssh "$COCO_REMOTE_HOST" '
uname -r
modprobe xt_comment
modinfo -F vermagic xt_comment
'
```

`modinfo` 第一列必须等于 `uname -r`。如果出现 `6.12.0-opencca-wip+`，不要安装该模块；固定 `LOCALVERSION=` 后重编。

完整 host kernel 构建和替换参考：

```text
docs/env/opencca-rk3588-env/KernelCompile.md
docs/env/opencca-rk3588-env/HostKernelModules.md
```

## 12. ImageCache smoke

推荐默认镜像和网络：

```text
image: docker.m.daocloud.io/library/busybox:latest
net: coco-bridge
dns: 使用当前 LAN 网关/DNS，例如 192.168.31.1
wait: 15s
```

不要固定旧 DNS。先从控制机或 RK 上确认网关：

```bash
sshpass -p "$COCO_REMOTE_PASSWORD" ssh "$COCO_REMOTE_HOST" '
ip route | awk "/default/ {print \$3; exit}"
cat /etc/resolv.conf
'
```

如果 LAN 网关是 `<LAN_GATEWAY>`，测试：

```bash
COCO_REMOTE_HOST="$COCO_REMOTE_HOST" COCO_REMOTE_PASSWORD="$COCO_REMOTE_PASSWORD" \
./scripts/run/run-image-cache-smoke-remote.sh \
  --image docker.m.daocloud.io/library/busybox:latest \
  --net coco-bridge \
  --dns <LAN_GATEWAY> \
  --wait 15 \
  --timeout 300
```

首次启动或刚重启 RK 后，可以加 `--prepare`：

```bash
./scripts/run/run-image-cache-smoke-remote.sh --prepare --dns <LAN_GATEWAY>
```

成功标志：

```text
coco-runtime-cvm-ok
Image manifest
Created RMM rootfs share
guest_pull took
```

抓关键日志：

```bash
sshpass -p "$COCO_REMOTE_PASSWORD" ssh "$COCO_REMOTE_HOST" '
journalctl -u containerd --since "10 minutes ago" --no-pager |
egrep -i "Image manifest|Created RMM rootfs share|Prepared shared rootfs|guest_pull took|coco-runtime-cvm-ok|failed to pull|dns error|cocoimg|coco-image-share" |
tail -n 200
'
```

## 13. 从零构建的推荐顺序

新机器建议按这个顺序执行：

```bash
# 1. 控制机依赖和工具链
command -v gh go cargo aarch64-linux-gnu-gcc aarch64-linux-musl-gcc

# 2. clone + submodule
git clone https://github.com/Marshal1l/COCO.git "$COCO_ROOT"
cd "$COCO_ROOT"
git submodule update --init --recursive

# 3. 恢复固定大文件
./scripts/package/download-release-assets.sh

# 4. 设置环境变量
export COCO_REMOTE_HOST="root@<RK3588_IP>"
export COCO_REMOTE_PASSWORD="<RK3588_ROOT_PASSWORD>"
export COCO_RPI_HOST="<PI_USER>@<PI_IP>"
export COCO_RPI_PASSWORD="<PI_PASSWORD>"

# 5. 本地构建和检查
./scripts/run/coco-local-flow.sh --check-prereqs
./scripts/run/coco-local-flow.sh --build
./scripts/image/install-rootfs-tools-into-kata-image.sh --verify-only

# 6. 可选：构建并刷 RMM/U-Boot
./scripts/firmware/build-rmm-uboot.sh
./scripts/firmware/flash-rk3588-firmware-via-pi.sh --flash-mmc --wait-rk

# 7. 同步 runtime 到 RK
./scripts/deploy/sync-coco-sftp.sh

# 8. 远端安装和启动服务
sshpass -p "$COCO_REMOTE_PASSWORD" ssh "$COCO_REMOTE_HOST" '
cd /root/COCO-SFTP
./scripts/remote/check/preflight.sh
./scripts/remote/install/all.sh
./scripts/remote/run/start-container-runtime.sh
'

# 9. smoke
./scripts/run/run-image-cache-smoke-remote.sh --dns <LAN_GATEWAY> --timeout 300
```

## 14. 常见失败分流

### SSH 不通

确认网段、root 登录、端口：

```bash
ping <RK3588_IP>
sshpass -p "$COCO_REMOTE_PASSWORD" ssh -vv "$COCO_REMOTE_HOST" 'hostname'
```

如果 RK 蓝灯常亮或系统无响应，用 Pi 重启：

```bash
COCO_RPI_PASSWORD="$COCO_RPI_PASSWORD" COCO_REMOTE_PASSWORD="$COCO_REMOTE_PASSWORD" \
./scripts/firmware/flash-rk3588-firmware-via-pi.sh --reboot --wait-rk
```

### 本地构建缺工具

先跑：

```bash
./scripts/build/check-build-prereqs.sh
```

缺 `aarch64-linux-musl-gcc` 时安装 musl.cc 交叉工具链；缺 `aarch64-linux-gnu-gcc` 时安装 `gcc-aarch64-linux-gnu`。

### Release 大文件缺失

症状是 `check-coco-sftp.sh` 报缺 `kata-containers-cca.img`、`rootfs.ext4` 或 `qemu-special`。

修复：

```bash
gh auth status
./scripts/package/download-release-assets.sh
./scripts/package/check-coco-sftp.sh
```

### Image CVM DNS 失败

日志类似：

```text
failed to pull manifest ... dns error
```

不要默认用 `8.8.8.8`。先查 RK 默认网关/DNS：

```bash
sshpass -p "$COCO_REMOTE_PASSWORD" ssh "$COCO_REMOTE_HOST" '
ip route
cat /etc/resolv.conf
'
```

然后使用同网段网关：

```bash
./scripts/run/run-image-cache-smoke-remote.sh --dns <LAN_GATEWAY> --prepare
```

### CNI/NAT 失败

先检查：

```bash
sshpass -p "$COCO_REMOTE_PASSWORD" ssh "$COCO_REMOTE_HOST" '
cd /root/COCO-SFTP
./scripts/remote/run/check-image-cache-network.sh
'
```

缺模块时：

```bash
COCO_REMOTE_PASSWORD="$COCO_REMOTE_PASSWORD" ./scripts/deploy/install-host-kernel-modules.sh
```

### 修改 image-rs 后行为没变

通常是没有重新构建并注入 kata-agent：

```bash
./scripts/build/build-guest-components.sh
./scripts/build/build-kata-agent.sh
./scripts/image/install-guest-components-into-kata-image.sh
./scripts/image/install-kata-agent-into-kata-image.sh
./scripts/deploy/sync-coco-sftp.sh
```

### RMM 更新没生效

必须完成：

```text
build-rmm-uboot.sh
flash-rk3588-firmware-via-pi.sh --flash-mmc --wait-rk
重新启动新的容器/VM
```

只同步 `COCO-SFTP` 不会更新 RMM/U-Boot。

## 15. 参考文档

更细的局部说明：

```text
docs/COCO_RUNTIME_BUILD_AND_DEPLOY.md
docs/COCO_WORKSPACE_LAYOUT.md
docs/COCO_REPOSITORY_TOPOLOGY.md
docs/env/opencca-rk3588-env/OPENCCA-RK3588-ENV.md
docs/env/opencca-rk3588-env/KernelCompile.md
docs/env/opencca-rk3588-env/HostKernelModules.md
docs/design/image-cache-v3/RMM-IMAGE-SHARE-V3-DESIGN.md
```

当前 verified smoke 基线：

```text
image: docker.m.daocloud.io/library/busybox:latest
net: coco-bridge
dns: 按当前 LAN 网关设置
wait: 15s
success: coco-runtime-cvm-ok
```
