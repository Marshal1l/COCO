# Trustee / Keyprovider Build Deploy Runbook

日期：2026-06-11

本文记录当前 COCO 工作区内 Trustee、Keyprovider、CCA token 验证工具、加密镜像和 RK3588 Image CVM 联调的完整构建、部署、运行流程。它对应已经验证通过的 demo：Image CVM 通过 CCA 远程证明向 KBS 获取 KEK，解密 encrypted OCI layer，然后继续通过 RMM/EROFS image share 让 Runtime CVM 启动容器。

更偏设计和根因分析的记录见：

```text
docs/TRUSTEE_KEYPROVIDER_ENCRYPTED_IMAGE_DEMO.md
```

## 1. 代码位置和远程仓库

相关代码已经整理进 COCO 工作区：

| 路径 | 远程仓库 | 作用 |
| --- | --- | --- |
| `trustee-cca/` | `https://github.com/Marshal1l/COCO-trustee-cca.git` | KBS、AS/grpc-as、RVPS 源码，分支 `cca`。 |
| `rust-ccatoken-trustee-cca/` | `https://github.com/Marshal1l/COCO-rust-ccatoken-trustee-cca.git` | CCA evidence 离线 verify/appraise 工具，分支 `trustee-cca`。 |
| `guest-components/attestation-agent/coco_keyprovider/` | `https://github.com/Marshal1l/COCO-guest-components.git` | 本地制作 encrypted image 使用的 CoCo keyprovider。 |
| `configs/trustee/` | 顶层 `COCO` | 已验证的 demo 部署配置模板。 |
| `configs/guest-components/` | 顶层 `COCO` | Image CVM 内 AA/CDH/image-rs 使用的 KBS/AS/registry 配置。 |
| `scripts/run/serve-oci-layout-registry.py` | 顶层 `COCO` | 把一个本地 OCI layout 暴露成最小 pull-only registry。 |

新机器 clone 后需要初始化这些子模块：

```bash
cd /home/mzh/RK3588/COCO
git submodule update --init --recursive \
  trustee-cca \
  rust-ccatoken-trustee-cca \
  guest-components
```

keyprovider 没有单独拆成新仓库，因为它是 guest-components 的正式 workspace member，路径为 `guest-components/attestation-agent/coco_keyprovider`。

## 2. 端口和机器角色

本 demo 使用 x86 控制机运行 Trustee 和 registry，RK3588 运行 containerd/Kata/Firecracker/Image CVM。

| 服务 | 控制机监听 | RK/Image CVM 访问地址 | 说明 |
| --- | --- | --- | --- |
| KBS | `127.0.0.1:8080` / `0.0.0.0:8080` | `http://10.88.0.1:18080` | Image CVM AA/CDH 从这里取 token 和 KEK。 |
| AS/grpc-as | `0.0.0.0:50004` | `http://10.88.0.1:15004` | KBS 通过 gRPC 调 AS，AA 配置中也保留该地址。 |
| RVPS | `0.0.0.0:50003` | 本机内部使用 | AS 通过 `rvps:50003` 读取 reference values。 |
| CoCo keyprovider | `127.0.0.1:50000` | 本机制作镜像时使用 | `skopeo` 加密镜像时调用。 |
| OCI layout registry | `127.0.0.1:19000` | `http://10.88.0.1:19000` | 给 Image CVM 拉 encrypted image。 |

当前 Image CVM 内固定访问 RK 网关地址：

```text
10.88.0.1:18080 -> KBS
10.88.0.1:15004 -> AS
10.88.0.1:19000 -> OCI registry
```

如果新环境的 COCO bridge 网段不同，需要同步修改：

```text
configs/guest-components/attestation-agent.toml
configs/guest-components/cdh.toml
```

然后重新构建和注入 guest-components/kata-agent。

## 3. 控制机依赖

基础依赖：

```bash
sudo apt update
sudo apt install -y \
  build-essential git curl ca-certificates pkg-config libssl-dev \
  protobuf-compiler clang cmake make jq skopeo openssl \
  python3 python3-venv sshpass
```

Rust：

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
. "$HOME/.cargo/env"
rustup component add rustfmt
```

为了复用缓存，不要在常规迭代中执行 `cargo clean` 或删除 `target/`。Trustee、ccatoken、guest-components 都会复用各自源码目录下的 `target/`。

## 4. 编译 Trustee 核心服务

Trustee 核心服务来自 `trustee-cca/`：

```bash
cd /home/mzh/RK3588/COCO/trustee-cca

make -C attestation-service build VERIFIER=cca-verifier
make -C rvps build
make -C kbs build AS_TYPE=coco-as-grpc
```

成功后应该存在：

```text
trustee-cca/target/release/grpc-as
trustee-cca/target/release/rvps
trustee-cca/target/release/kbs
```

检查：

```bash
file target/release/grpc-as target/release/rvps target/release/kbs
```

当前 x86 控制机上它们应为 x86-64 ELF。

## 5. 编译 ccatoken 验证工具

`ccatoken` 用于离线验证 Image CVM 生成的 CCA evidence，排查 AS/KBS 拒绝原因非常有用。

```bash
cd /home/mzh/RK3588/COCO/rust-ccatoken-trustee-cca
cargo build --release
```

成功产物：

```text
rust-ccatoken-trustee-cca/target/release/ccatoken
```

验证当前成功 evidence：

```bash
./rust-ccatoken-trustee-cca/target/release/ccatoken verify \
  -e artifacts/trustee/cca-evidence-success-final.cbor \
  -t /opt/confidential-containers/attestation-service/cca/tastore.json
```

已验证成功输出包含：

```text
verification completed
platform trust vector: { "instance-identity": 2 }
realm trust vector: { "instance-identity": 2 }
```

## 6. 编译 CoCo keyprovider

CoCo keyprovider 来自 guest-components workspace，用于本机制作 encrypted OCI image：

```bash
cd /home/mzh/RK3588/COCO/guest-components
cargo build --release --package coco_keyprovider
```

成功产物：

```text
guest-components/target/release/coco_keyprovider
```

新环境优先从 COCO 的 `guest-components` 子模块重新编译，不再依赖旧的本机临时目录。

## 7. 安装到 /opt/confidential-containers

创建目录：

```bash
sudo mkdir -p \
  /opt/confidential-containers/trustee-bin \
  /opt/confidential-containers/trustee-config \
  /opt/confidential-containers/attestation-service/cca \
  /opt/confidential-containers/attestation-service/reference_values \
  /opt/confidential-containers/kbs/repository/default/key \
  /opt/confidential-containers/logs
```

安装二进制：

```bash
cd /home/mzh/RK3588/COCO

sudo install -m0755 trustee-cca/target/release/kbs \
  /opt/confidential-containers/trustee-bin/kbs
sudo install -m0755 trustee-cca/target/release/rvps \
  /opt/confidential-containers/trustee-bin/rvps
sudo install -m0755 trustee-cca/target/release/grpc-as \
  /opt/confidential-containers/trustee-bin/grpc-as
sudo install -m0755 guest-components/target/release/coco_keyprovider \
  /opt/confidential-containers/trustee-bin/coco_keyprovider
```

安装配置：

```bash
sudo install -m0644 configs/trustee/trustee-config/kbs-config-grpc.toml \
  /opt/confidential-containers/trustee-config/kbs-config-grpc.toml
sudo install -m0644 configs/trustee/trustee-config/as-config.json \
  /opt/confidential-containers/trustee-config/as-config.json
sudo install -m0644 configs/trustee/trustee-config/cca-config-local.json \
  /opt/confidential-containers/trustee-config/cca-config-local.json
sudo install -m0644 configs/trustee/trustee-config/rvps.json \
  /opt/confidential-containers/trustee-config/rvps.json

sudo install -m0644 configs/trustee/attestation-service/cca/tastore.json \
  /opt/confidential-containers/attestation-service/cca/tastore.json
sudo install -m0644 configs/trustee/attestation-service/cca/rvstore.json \
  /opt/confidential-containers/attestation-service/cca/rvstore.json
sudo install -m0644 configs/trustee/kbs/policy.rego \
  /opt/confidential-containers/kbs/policy.rego
```

配置本机 hosts。KBS 和 AS 配置里使用 `as`、`rvps` 主机名：

```bash
grep -q 'rvps grpc-as as' /etc/hosts || \
  sudo sh -c 'printf "\n# confidential containers\n127.0.0.1 rvps grpc-as as\n" >> /etc/hosts'
```

## 8. 准备 KBS KEK

KBS 资源路径：

```text
/opt/confidential-containers/kbs/repository/default/key/key_id1
```

encrypted image layer annotation 中的 `kid` 必须匹配：

```text
kbs:///default/key/key_id1
```

注意：已经制作好的 encrypted image 必须使用同一个 KEK。如果删除旧 KEK 并重新生成，旧 encrypted image 会无法解密。

新制作镜像时生成 32 字节 KEK：

```bash
mkdir -p artifacts/encrypted-images/new-image
head -c 32 /dev/urandom > artifacts/encrypted-images/new-image/key1

sudo install -D -m0600 \
  artifacts/encrypted-images/new-image/key1 \
  /opt/confidential-containers/kbs/repository/default/key/key_id1
```

已验证的本地 encrypted OCI layout 是：

```text
artifacts/encrypted-images/immzh-busybox/oci
```

该 layout 对应的 KEK 没有提交进 git，必须从安全备份或当前 `/opt/confidential-containers/kbs/repository/default/key/key_id1` 保留。

## 9. 启动 Trustee 服务

建议按 RVPS、AS、KBS、keyprovider 的顺序启动。

先停止旧进程：

```bash
pkill -f '/opt/confidential-containers/trustee-bin/rvps' || true
pkill -f '/opt/confidential-containers/trustee-bin/grpc-as' || true
pkill -f '/opt/confidential-containers/trustee-bin/kbs' || true
pkill -f '/opt/confidential-containers/trustee-bin/coco_keyprovider' || true
```

启动 RVPS：

```bash
nohup env RUST_LOG=debug \
  /opt/confidential-containers/trustee-bin/rvps \
  -c /opt/confidential-containers/trustee-config/rvps.json \
  > /opt/confidential-containers/logs/rvps.log 2>&1 &
echo $! | sudo tee /opt/confidential-containers/logs/rvps.pid
```

启动 AS：

```bash
nohup env \
  CCA_CONFIG_FILE=/opt/confidential-containers/trustee-config/cca-config-local.json \
  RUST_LOG=debug \
  /opt/confidential-containers/trustee-bin/grpc-as \
  -c /opt/confidential-containers/trustee-config/as-config.json \
  -s 0.0.0.0:50004 \
  > /opt/confidential-containers/logs/grpc-as.log 2>&1 &
echo $! | sudo tee /opt/confidential-containers/logs/grpc-as.pid
```

启动 KBS：

```bash
nohup env RUST_LOG=debug \
  /opt/confidential-containers/trustee-bin/kbs \
  -c /opt/confidential-containers/trustee-config/kbs-config-grpc.toml \
  > /opt/confidential-containers/logs/kbs.log 2>&1 &
echo $! | sudo tee /opt/confidential-containers/logs/kbs.pid
```

启动 keyprovider：

```bash
nohup env RUST_LOG=coco_keyprovider \
  /opt/confidential-containers/trustee-bin/coco_keyprovider \
  --socket 127.0.0.1:50000 \
  > /opt/confidential-containers/logs/coco_keyprovider.log 2>&1 &
echo $! | sudo tee /opt/confidential-containers/logs/coco_keyprovider.pid
```

检查监听：

```bash
ss -ltnp | grep -E ':(8080|50003|50004|50000)\b'
ps -ef | grep -E 'trustee-bin/(rvps|grpc-as|kbs|coco_keyprovider)' | grep -v grep
```

看日志：

```bash
tail -n 80 /opt/confidential-containers/logs/rvps.log
tail -n 80 /opt/confidential-containers/logs/grpc-as.log
tail -n 80 /opt/confidential-containers/logs/kbs.log
tail -n 80 /opt/confidential-containers/logs/coco_keyprovider.log
```

## 10. 制作 encrypted OCI image

先准备 ocicrypt keyprovider 配置：

```bash
cd /home/mzh/RK3588/COCO

mkdir -p artifacts/encrypted-images
cat > artifacts/encrypted-images/ocicrypt-keyprovider.json <<'EOF'
{
  "key-providers": {
    "attestation-agent": {
      "grpc": "127.0.0.1:50000"
    }
  }
}
EOF

export OCICRYPT_KEYPROVIDER_CONFIG="$PWD/artifacts/encrypted-images/ocicrypt-keyprovider.json"
```

从镜像源拉取并制作 encrypted OCI layout。可以使用更快的镜像源，例如 DaoCloud mirror：

```bash
mkdir -p artifacts/encrypted-images/new-image

skopeo copy --insecure-policy \
  --override-os linux \
  --override-arch arm64 \
  --encryption-key "provider:attestation-agent:keypath=$PWD/artifacts/encrypted-images/new-image/key1::keyid=kbs:///default/key/key_id1::algorithm=A256GCM" \
  docker://docker.m.daocloud.io/library/busybox:latest \
  oci:artifacts/encrypted-images/new-image/oci:encrypted
```

确认 layer 已加密：

```bash
skopeo inspect --raw oci:artifacts/encrypted-images/new-image/oci:encrypted | jq .

skopeo inspect oci:artifacts/encrypted-images/new-image/oci:encrypted | \
  jq -r '.LayersData[].MIMEType'
```

期望看到：

```text
application/vnd.oci.image.layer.v1.tar+gzip+encrypted
```

查看 `kid`：

```bash
skopeo inspect oci:artifacts/encrypted-images/new-image/oci:encrypted | \
  jq -r '.LayersData[].Annotations."org.opencontainers.image.enc.keys.provider.attestation-agent"' | \
  base64 -d
```

期望包含：

```text
"kid":"kbs:///default/key/key_id1"
```

## 11. 启动本地 OCI layout registry

对于已验证的 busybox encrypted layout：

```bash
cd /home/mzh/RK3588/COCO

nohup python3 scripts/run/serve-oci-layout-registry.py \
  --layout artifacts/encrypted-images/immzh-busybox/oci \
  --host 127.0.0.1 \
  --port 19000 \
  > artifacts/encrypted-images/immzh-busybox/registry.log 2>&1 &
echo $! > artifacts/encrypted-images/immzh-busybox/registry.pid
```

对于新制作的 layout，把 `--layout` 换成：

```text
artifacts/encrypted-images/new-image/oci
```

本地检查：

```bash
curl -i http://127.0.0.1:19000/v2/
curl -s http://127.0.0.1:19000/v2/coco/busybox/tags/list | jq .
```

Image CVM 使用的镜像名：

```text
10.88.0.1:19000/coco/busybox:encrypted
```

其中 `coco/busybox` 只是 registry API path；这个最小 registry 只从单个 OCI layout 读取 manifest/blob。

## 12. 打通 RK 到本机服务

如果 RK 可以直接访问控制机 IP，可以把 guest 配置改成控制机 IP，不需要 SSH reverse tunnel。当前已验证环境中使用两段链路：控制机到 RK 的 SSH reverse tunnel，再由 RK 把 `10.88.0.1` 转发到 `127.0.0.1`。

控制机启动 reverse tunnel：

```bash
sshpass -p root ssh -f -N \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=2 \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile=/tmp/coco_known_hosts \
  -R 127.0.0.1:18080:127.0.0.1:8080 \
  -R 127.0.0.1:15004:127.0.0.1:50004 \
  -R 127.0.0.1:19000:127.0.0.1:19000 \
  root@192.168.31.18
```

RK 上准备 `10.88.0.1`：

```bash
sshpass -p root ssh root@192.168.31.18 '
set -e
ip link add name coco0 type bridge 2>/dev/null || true
ip addr show dev coco0 | grep -q "10.88.0.1/16" || ip addr add 10.88.0.1/16 dev coco0
ip link set coco0 up
sysctl -w net.ipv4.ip_forward=1
iptables -t nat -C POSTROUTING -s 10.88.0.0/16 ! -o coco0 -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s 10.88.0.0/16 ! -o coco0 -j MASQUERADE
'
```

RK 上放置临时 TCP forwarder：

```bash
sshpass -p root ssh root@192.168.31.18 'cat > /tmp/coco_trustee_forward.py <<'"'"'PY'"'"'
#!/usr/bin/env python3
import selectors
import socket
import sys

listen_host, listen_port, target_host, target_port = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
sel = selectors.DefaultSelector()

def accept(sock):
    client, _ = sock.accept()
    upstream = socket.create_connection((target_host, target_port))
    client.setblocking(False)
    upstream.setblocking(False)
    sel.register(client, selectors.EVENT_READ, upstream)
    sel.register(upstream, selectors.EVENT_READ, client)

def relay(src, dst):
    try:
        data = src.recv(65536)
        if data:
            dst.sendall(data)
            return
    except OSError:
        pass
    for s in (src, dst):
        try:
            sel.unregister(s)
        except Exception:
            pass
        try:
            s.close()
        except OSError:
            pass

server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind((listen_host, listen_port))
server.listen()
server.setblocking(False)
sel.register(server, selectors.EVENT_READ, None)

while True:
    for key, _ in sel.select():
        if key.data is None:
            accept(key.fileobj)
        else:
            relay(key.fileobj, key.data)
PY
chmod +x /tmp/coco_trustee_forward.py'
```

启动 RK 端转发：

```bash
sshpass -p root ssh root@192.168.31.18 '
nohup /tmp/coco_trustee_forward.py 10.88.0.1 18080 127.0.0.1 18080 >/tmp/coco-forward-18080.log 2>&1 &
nohup /tmp/coco_trustee_forward.py 10.88.0.1 15004 127.0.0.1 15004 >/tmp/coco-forward-15004.log 2>&1 &
nohup /tmp/coco_trustee_forward.py 10.88.0.1 19000 127.0.0.1 19000 >/tmp/coco-forward-19000.log 2>&1 &
ss -ltnp | grep -E "(10.88.0.1|127.0.0.1):(18080|15004|19000)"
'
```

不要在远端 SSH 命令里直接执行 `pkill -f coco_trustee_forward.py`；命令行自身可能匹配 pattern，导致 SSH 会话被自己杀掉。需要清理时先 `pgrep -af coco_trustee_forward.py`，确认 PID 后按 PID kill。

## 13. 更新 Image CVM Guest 配置

当前 guest 配置：

```text
configs/guest-components/attestation-agent.toml
configs/guest-components/cdh.toml
```

内容应指向：

```text
KBS: http://10.88.0.1:18080
AS:  http://10.88.0.1:15004
Registry insecure host: 10.88.0.1:19000
```

构建并注入 guest image：

```bash
cd /home/mzh/RK3588/COCO

./scripts/build/build-guest-components.sh
./scripts/build/build-kata-agent.sh
./scripts/image/install-guest-components-into-kata-image.sh
./scripts/image/install-kata-agent-into-kata-image.sh

./scripts/image/install-guest-components-into-kata-image.sh --verify-only
./scripts/image/install-kata-agent-into-kata-image.sh --verify-only
```

同步到 RK：

```bash
COCO_REMOTE_PASSWORD=root ./scripts/deploy/sync-coco-sftp.sh
```

注意：修改 `image-rs`、AA/CDH 配置或 kata-agent 启动参数后，必须同时构建 guest-components 和 kata-agent，并重新注入 `kata-containers-cca.img`。只更新其中一个很容易在 Runtime/Image CVM 中留下旧路径。

## 14. RMM/Guest Kernel 前置条件

Trustee 成功前还需要这些已经验证过的 COCO 改动：

| 组件 | 必要改动 |
| --- | --- |
| `opencca/tf-rmm` | RMM 导出 raw SEC1 RAK public key，并去掉 Realm profile claim，让 Trustee verifier 使用 raw RAK binding。 |
| `linux-image-share` | guest kernel 启用 `CONFIG_VIRT_DRIVERS=y`、`CONFIG_TSM_REPORTS=y`、`CONFIG_ARM_CCA_GUEST=y`，AA 才能通过 configfs 取 TSM report。 |
| `kata-containers-cca` | kata-agent 挂载 configfs，按 TOML 配置启动 AA/CDH，并把 `/etc/image-rs-config.json` seed 到 image-rs 工作目录。 |
| `guest-components/image-rs` | 支持 `insecure_registry_hosts`，允许 Image CVM 从 `10.88.0.1:19000` 这个 HTTP registry 拉取镜像。 |

如果重新构建固件：

```bash
./scripts/firmware/build-rmm-uboot.sh --rmm-only
./scripts/firmware/build-rmm-uboot.sh --uboot-only

COCO_RPI_PASSWORD=root COCO_REMOTE_PASSWORD=root \
  ./scripts/firmware/flash-rk3588-firmware-via-pi.sh --flash-mmc --wait-rk
```

如果重新构建 guest kernel：

```bash
JOBS=8 ./scripts/build/build-linux-image-share.sh
COCO_REMOTE_PASSWORD=root ./scripts/deploy/sync-coco-sftp.sh
```

## 15. 跑 encrypted image smoke

确认 Trustee、registry、tunnel、RK forwarder 都在运行后：

```bash
COCO_REMOTE_PASSWORD=root COCO_IMAGE_CACHE_SMOKE_TIMEOUT=420 \
  ./scripts/run/run-image-cache-smoke-remote.sh \
  --image 10.88.0.1:19000/coco/busybox:encrypted \
  --annotation 10.88.0.1:19000/coco/busybox:encrypted \
  --wait 35 \
  --insecure-registry
```

成功标志：

```text
coco-runtime-cvm-ok
POST /kbs/v0/attest HTTP/1.1" 200
GET /kbs/v0/resource/default/key/key_id1 HTTP/1.1" 200
```

抓 KBS/AS 日志：

```bash
tail -n 200 /opt/confidential-containers/logs/kbs.log
tail -n 200 /opt/confidential-containers/logs/grpc-as.log
```

抓 RK containerd 关键日志：

```bash
sshpass -p root ssh root@192.168.31.18 \
  'journalctl -u containerd --since "10 minutes ago" --no-pager | egrep -i "Image manifest|Created RMM rootfs share|guest_pull took|coco-runtime-cvm-ok|attestation|kbs|decrypt|failed" | tail -n 200'
```

成功后仍可能看到：

```text
ERRO[0048] forward signal child exited error="Sandbox not running: unknown"
```

如果它出现在 `coco-runtime-cvm-ok` 之后，这是 `nerdctl run --rm` 清理/信号转发阶段噪声，不表示容器没运行。

## 16. Evidence 采集和离线验证

KBS/AS 调试时，优先保存 evidence，再用 `ccatoken` 离线看失败点。当前已验证 evidence：

```text
artifacts/trustee/cca-evidence-success-final.cbor
```

验证：

```bash
rust-ccatoken-trustee-cca/target/release/ccatoken verify \
  -e artifacts/trustee/cca-evidence-success-final.cbor \
  -t /opt/confidential-containers/attestation-service/cca/tastore.json
```

如果 AS 日志出现：

```text
RAK signature or RAK attestation could not be verified
```

优先检查：

- RK 是否刷入包含 raw RAK 修复的 `tf-rmm.elf`。
- `opencca/tf-rmm/lib/attestation/src/attestation_key.c` 是否使用 `psa_export_public_key()` 输出 raw SEC1 public key。
- `opencca/tf-rmm/lib/attestation/src/attestation_token.c` 是否未写入 `CCA_REALM_PROFILE`。
- `/opt/confidential-containers/attestation-service/cca/tastore.json` 是否匹配当前 sample platform token。

## 17. 常见失败和处理

KBS 401 或不发 key：

- 看 `/opt/confidential-containers/logs/kbs.log` 和 `grpc-as.log`。
- 确认 AS 返回 200，KBS 日志中有 `/kbs/v0/attest`。
- 确认 policy 没有误拒绝 `input["submods"]["cpu"]`。

Image CVM 拉不到 registry：

- 在 RK 上检查 `ss -ltnp | grep 19000`。
- 在控制机检查 `curl http://127.0.0.1:19000/v2/`。
- 确认 smoke 命令带 `--insecure-registry`。
- 确认 `configs/guest-components/cdh.toml` 里有 `insecure_registry_hosts = ["10.88.0.1:19000"]`，并已重新注入 guest image。

AA 取不到 CCA report：

- 确认 guest kernel 启用了 TSM/CCA guest。
- 确认 kata-agent 已挂载 `/sys/kernel/config`。
- containerd guest console 中应能看到 AA 启动日志。

旧 encrypted image 无法解密：

- 不要随意重新生成 `/opt/confidential-containers/kbs/repository/default/key/key_id1`。
- `key_id1` 必须是制作该 encrypted image 时使用的同一个 32 字节 KEK。
- 如果换了 KEK，必须重新执行 `skopeo copy --encryption-key ...` 制作新 encrypted OCI layout。

## 18. 当前已验证版本

已验证 smoke 命令：

```bash
COCO_REMOTE_PASSWORD=root COCO_IMAGE_CACHE_SMOKE_TIMEOUT=420 \
  ./scripts/run/run-image-cache-smoke-remote.sh \
  --image 10.88.0.1:19000/coco/busybox:encrypted \
  --annotation 10.88.0.1:19000/coco/busybox:encrypted \
  --wait 35 \
  --insecure-registry
```

已验证输出：

```text
coco-runtime-cvm-ok
```

已验证 KBS 访问：

```text
POST /kbs/v0/attest HTTP/1.1" 200
GET /kbs/v0/resource/default/key/key_id1 HTTP/1.1" 200
```

已验证 evidence：

```text
artifacts/trustee/cca-evidence-success-final.cbor
sha256 b7e9b8bb1664b1bc38d41a2bff95c2be6919c7d5b6a7b439539af27fabf9e665
```
