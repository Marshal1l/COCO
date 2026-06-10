# README
# 工作区清单

| 路径 | 描述 |
| --- | --- |
| `COCO-SFTP/` | 同步到远程 `/root/COCO-SFTP` 的运行目录，包含主机侧运行产物、固定下载资产和 guest 镜像。 |
| `artifacts/` | 本地源码构建产物，不直接作为 SFTP 根目录同步；guest-components 的可部署二进制和配置存放在这里。 |
| `scripts/` | 统一的构建、镜像注入、SFTP 准备、校验、同步脚本。 |
| `docs/` | 设计、环境和语义化管理说明。 |

本工作区现在使用语义化运行目录 `COCO-SFTP/` 管理远程开发板上的容器运行栈。
本地目录 `COCO-SFTP/` 应同步到远程 `/root/COCO-SFTP`，不要再使用旧的
`sftp_folder` 作为默认项目名。源码和运行产物的关系见
`docs/COCO_WORKSPACE_LAYOUT.md`。


# 一.系统环境概述

由于Linaro FVP模拟平台存在指令转译等性能瓶颈，难以支撑多机密容器的并发测试（实测单容器启动耗时逾200秒且无法满足镜像共享功能所需的至少双容器并发验证条件）。为此，本研究改用基于ROCK5B（RK3588）ArmV8开发板的硬件环境，依托OpenCCA模拟CCA平台进行机密容器镜像共享功能的部署与测试。OpenCCA方案则采用基于真实Arm硬件（RK3588）的原生执行模式，充分利用硬件内置的虚拟化扩展（Virtualization Extensions）构建隔离执行环境，消除了指令转译等带来的性能损耗，整体性能能够支持镜像共享功能的验证。

OpenCCA是一个开源的、软件定义的CCA参考实现，在没有专用物理安全芯片的情况下模拟Arm CCA的核心特性。OpenCCA通过软件层面的虚拟化技术，在标准的Arm处理器上构建出隔离的执行环境，操作系统和应用程序可以像在真正的机密硬件上一样运行，代码和数据在内存中受到保护，即便是拥有最高权限的Host OS或Hypervisor也无法窥探其内部状态。OpenCCA通过模拟Realm Management Monitor（RMM）、Granule Page Table（GPT）等关键组件，复现了Arm CCA标准中定义的启动、生命周期管理和内存隔离机制，从而在通用硬件上创造出了一个符合机密计算规范的逻辑安全区，使得开发者能够在硬件尚未普及或成本受限的情况下，提前进行机密容器、可信执行环境等前沿技术的开发与验证。

# 二.系统环境配置

## 1.ROCK5B（RK3588）固件编译

为ROCK5B（RK3588）编译OpenCCA提供的固件，确保OpenCCA平台能够正常运行。编译获得的固件idbloader.img、u-boot.itb以及刷入之后的系统镜像opencca-image-rockchip-rock5b-rk3588.img均在附件Firmware.tar.gz中。用工具比如balenaEtcher直接将提供的opencca-image-rockchip-rock5b-rk3588.img镜像刷入到ROCK5B（RK3588）的Micro SD卡中即可正常启动。

```flow
git clone [https://github.com/opencca/opencca-build](https://github.com/opencca/opencca-build)

//修改SPL Loader为1.16版本，官方文档给的1.08版本无法正常初始化内存
//修改opencca-build/buildconf/firmware_opencca.mk：
- UBOOT_ROCKCHIP_TPL := $(ASSETS_DIR)/rk3588/rk3588_ddr_lp4_2112MHz_lp5_2736MHz_v1.08.bin
+ UBOOT_ROCKCHIP_TPL := $(ASSETS_DIR)/rk3588/rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v1.16.bin

//修改OpenCCA提供的RMM，添加镜像共享相关的RSI调用
opencca/tf-rmm

//进入docker编译
cd opencca-build/scripts&&./build_all.sh

//编译后获得snapshot/idbloader.img与snapshot/u-boot.itb
//使用dd将两个文件刷入至opencca给的系统镜像中
dd if=~/opencca-work/opencca/snapshot/idbloader.img of=~/opencca-work/rootfs/opencca-image-rockchip-rock5b-rk3588.img seek=64 conv=notrunc
dd if=~/opencca-work/opencca/snapshot/u-boot.itb of=~/opencca-work/rootfs/opencca-image-rockchip-rock5b-rk3588.img seek=16384 conv=notrunc

//opencca-image-rockchip-rock5b-rk3588.img可以使用opencca发布的二进制文件版本
https://github.com/opencca/opencca-releases/releases/download/opencca/systex25/opencca.tar.gz
```

## 2.容器软件栈配置

容器启动相关内容现在按语义整理在 `COCO-SFTP/` 中：Firecracker、guest kernel、Kata runtime、guest-pull-snapshotter 和 OpenCCA 产物由源码脚本构建或收集；CNI、nerdctl、QEMU/kvmtool 辅助程序、guest 镜像等固定下载资产只整理位置，不由无关源码脚本重建。guest-components 是 guest 侧组件，先构建为本地 `artifacts/guest-components/` 中的 stripped 可部署产物，再离线注入 `COCO-SFTP/images/kata-containers-cca.img`，不再作为远程主机上的散落二进制安装。

本地准备与校验：

```bash
./scripts/run/coco-local-flow.sh --check-prereqs
./scripts/run/coco-local-flow.sh --build
./scripts/package/check-coco-sftp.sh
./scripts/package/check-remote-install-flow.sh
```

远程开发板当前尚未连通时，不需要执行同步；连接恢复后再显式同步：

```bash
./scripts/run/coco-local-flow.sh --sync
```

```bash
mkdir -p /root/COCO-SFTP
# 通过 sftp/rsync 将本地 COCO-SFTP/ 同步到远程 /root/COCO-SFTP
cd /root/COCO-SFTP && ./scripts/remote/install/all.sh
./scripts/remote/run/start-container-runtime.sh
# host kernel 和固件刷入由后续单独脚本处理，不属于默认 COCO-SFTP runtime 安装流程。
```

# 三.镜像共享机制验证

启动运行机密容器所需的containerd和guest-pull-snapshotter组件。

```flow
sudo systemctl restart containerd 
sudo systemctl start guest-pull-snapshotter
```

也可以使用已经整理好的远程入口按正确顺序启动：

```bash
cd /root/COCO-SFTP
./scripts/remote/run/start-container-runtime.sh
```

启动用于共享镜像的Image Manager CVM。

```flow
sudo nerdctl run --net=host --annotation "io.kubernetes.cri.image-name=docker.io/library/busybox:latest" --annotation "io.kata-containers.is-image-cvm=true" --snapshotter guest-pull --runtime io.containerd.kata.v2 -it docker.io/library/busybox:latest sh
```

启动通过Image Manager CVM启动的Runtime CVM。

```flow
sudo nerdctl run --net=host --annotation "io.kubernetes.cri.image-name=docker.io/library/busybox:latest" --annotation "io.kata-containers.is-image-cvm=false" --snapshotter guest-pull --runtime io.containerd.kata.v2 -it docker.io/library/busybox:latest sh
```

远程 smoke 入口：

```bash
cd /root/COCO-SFTP
./scripts/remote/run/run-image-cache-smoke.sh
```

当前已验证的 ImageCache 测试固定使用：

```bash
COCO_REMOTE_PASSWORD=root ./scripts/run/run-image-cache-smoke-remote.sh
```

默认镜像和网络为 `docker.m.daocloud.io/library/busybox:latest`、
`coco-bridge`、DNS `192.168.31.1`。连续测试时脚本只做轻量检查，不会每次
重装 CNI 或重启 `guest-pull-snapshotter/containerd`；需要重置运行环境时再加
`--prepare`。

RMM 修改后的固定固件流程：

```bash
./scripts/firmware/build-rmm-uboot.sh
COCO_RPI_PASSWORD=root ./scripts/firmware/flash-rk3588-firmware-via-pi.sh --flash-mmc --wait-rk
```
