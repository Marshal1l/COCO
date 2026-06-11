# Trustee / Keyprovider Encrypted Image Demo

日期：2026-06-11

状态：已在 RK3588/OpenCCA 上验证通过。Image CVM 可以通过 CCA 远程证明向本地 Trustee/KBS 获取加密镜像 KEK，解密 encrypted OCI layer，随后继续走 Image CVM -> Runtime CVM 的 RMM/EROFS image share 路径，Runtime CVM 输出 `coco-runtime-cvm-ok`。

本文记录当前可复现 demo 路径。它不是完整生产级 CCA 供应链：平台 token 和 RAK 使用 OpenCCA/Trustee sample key，KBS 使用 `insecure_http` 和 `insecure_key`，OPA policy 仍是 demo policy。

## 已验证结论

成功命令：

```bash
COCO_REMOTE_PASSWORD=root COCO_IMAGE_CACHE_SMOKE_TIMEOUT=420 \
  ./scripts/run/run-image-cache-smoke-remote.sh \
  --image 10.88.0.1:19000/coco/busybox:encrypted \
  --annotation 10.88.0.1:19000/coco/busybox:encrypted \
  --wait 35 \
  --insecure-registry
```

成功输出：

```text
coco-runtime-cvm-ok
[coco-remote] image-cache smoke run completed with 10.88.0.1:19000/coco/busybox:encrypted
```

KBS 成功证据：

```text
POST /kbs/v0/attest HTTP/1.1" 200
GET /kbs/v0/resource/default/key/key_id1 HTTP/1.1" 200
```

最终 evidence：

```text
artifacts/trustee/cca-evidence-success-final.cbor
sha256 b7e9b8bb1664b1bc38d41a2bff95c2be6919c7d5b6a7b439539af27fabf9e665
```

离线验证：

```bash
./rust-ccatoken-trustee-cca/target/release/ccatoken verify \
  -e artifacts/trustee/cca-evidence-success-final.cbor \
  -t /opt/confidential-containers/attestation-service/cca/tastore.json
```

输出：

```text
verification completed
platform trust vector: { "instance-identity": 2 }
realm trust vector: { "instance-identity": 2 }
```

注意：`ccatoken appraise` 和 EAR 里仍可能出现 `warning`。当前 KBS policy 允许 non-sample CCA evidence 且 AS crypto verify/RAK binding 成功后发 key。完整 production policy 还需要进一步收紧平台和 Realm 参考值评价。

## 关键修复：RMM Raw RAK 兼容路径

最初失败不是镜像源或网络问题，而是 CCA evidence 的 RAK binding 不通过：

```text
Attestation: Verifier evaluate failed: RAK signature or RAK attestation could not be verified
```

根因：

- RK3588 TF-A 的 `rk3588_plat_attest_token.c` 返回静态 sample platform token。
- 该 platform token 的 challenge 是 `sha256(0x04 || RAK.x || RAK.y)`，也就是 SEC1 uncompressed raw P-384 public key hash。
- RMM 原先在 Realm token 中写入 `tag:arm.com,2023:realm#1.0.0` profile，并把 RAK claim 写成 COSE_Key。
- Trustee 的 `ccatoken` verifier 看到该 profile 后会计算 `sha256(COSE_Key)`，因此和静态 platform token challenge 不一致。

已落地修复：

- `opencca/tf-rmm/lib/attestation/src/attestation_key.c`
  - 导入 RAK 私钥后调用 `psa_export_public_key()`。
  - 保存 PSA/SEC1 raw public key，格式为 `0x04 || x || y`，长度 97 字节。
  - platform token challenge hash 也基于这 97 字节计算。
- `opencca/tf-rmm/lib/attestation/src/attestation_token.c`
  - 不再写 Realm profile claim。
  - Trustee verifier 走 backward-compatible raw RAK 路径，Realm token RAK 和 platform token challenge 对齐。

构建和刷写：

```bash
./scripts/firmware/build-rmm-uboot.sh --rmm-only
./scripts/firmware/build-rmm-uboot.sh --uboot-only

COCO_RPI_PASSWORD=root COCO_REMOTE_PASSWORD=root \
  ./scripts/firmware/flash-rk3588-firmware-via-pi.sh --flash-mmc --wait-rk
```

本次固件产物：

```text
d09be70795bb3dd4ee928b5b1e2267f7c04f7275a2a834006e8f67e3ea796d68  opencca/snapshot/tf-rmm.elf
d50f7f49617675183054bf0bee4b5cd8471606ab70c4967fdd73bdba4aa604f6  opencca/snapshot/u-boot.itb
8c8420417c8d9027a8f5ab1b9f27709c79b160b81ee5797839c43830f36458f7  opencca/snapshot/idbloader.img
```

## Guest 配置

AA 和 CDH 配置安装到 Kata guest image：

```text
/etc/attestation-agent.toml
/etc/confidential-data-hub.toml
/etc/image-rs-config.json
```

当前配置使用 RK `coco-bridge` 网关地址作为 Image CVM 内的 Trustee/registry 入口：

```toml
# configs/guest-components/attestation-agent.toml
[token_configs]
[token_configs.coco_as]
url = "http://10.88.0.1:15004"
[token_configs.kbs]
url = "http://10.88.0.1:18080"
```

```toml
# configs/guest-components/cdh.toml
socket = "unix:///run/confidential-containers/cdh.sock"
[kbc]
name = "cc_kbc"
url = "http://10.88.0.1:18080"
[image]
max_concurrent_layer_downloads_per_image = 3
insecure_registry_hosts = ["10.88.0.1:19000"]
```

相关构建和注入：

```bash
./scripts/build/build-guest-components.sh
./scripts/build/build-kata-agent.sh
./scripts/image/install-guest-components-into-kata-image.sh
./scripts/image/install-kata-agent-into-kata-image.sh
COCO_REMOTE_PASSWORD=root ./scripts/deploy/sync-coco-sftp.sh
```

必须同时更新 guest-components 和 kata-agent。只更新 guest-components 会留下 Runtime/Image CVM 中的旧 kata-agent 启动参数和旧配置路径。

## Trustee 服务

当前本地部署目录：

```text
/opt/confidential-containers
```

关键配置：

```text
/opt/confidential-containers/trustee-config/kbs-config-grpc.toml
/opt/confidential-containers/trustee-config/as-config.json
/opt/confidential-containers/trustee-config/cca-config-local.json
/opt/confidential-containers/trustee-config/rvps.json
/opt/confidential-containers/attestation-service/cca/tastore.json
/opt/confidential-containers/attestation-service/cca/rvstore.json
/opt/confidential-containers/attestation-service/cca/opa/default.rego
/opt/confidential-containers/kbs/repository/default/key/key_id1
```

`/etc/hosts` 需要包含：

```text
127.0.0.1 rvps grpc-as as
```

启动顺序：

```bash
RUST_LOG=debug \
  /opt/confidential-containers/trustee-bin/rvps \
  -c /opt/confidential-containers/trustee-config/rvps.json

CCA_CONFIG_FILE=/opt/confidential-containers/trustee-config/cca-config-local.json \
RUST_LOG=debug \
  /opt/confidential-containers/trustee-bin/grpc-as \
  -c /opt/confidential-containers/trustee-config/as-config.json \
  -s 0.0.0.0:50004

RUST_LOG=debug \
  /opt/confidential-containers/trustee-bin/kbs \
  -c /opt/confidential-containers/trustee-config/kbs-config-grpc.toml

RUST_LOG=coco_keyprovider \
  /opt/confidential-containers/trustee-bin/coco_keyprovider \
  --socket 127.0.0.1:50000
```

本次运行中的进程：

```text
rvps
grpc-as
kbs
coco_keyprovider
```

KBS key：

```text
/opt/confidential-containers/kbs/repository/default/key/key_id1
```

该文件必须是 32 字节 KEK。加密镜像 layer annotation 中的 `kid` 为：

```text
kbs:///default/key/key_id1
```

## 加密镜像制备

当前已验证 encrypted OCI layout：

```text
artifacts/encrypted-images/immzh-busybox/oci
```

tag：

```text
encrypted
```

manifest digest：

```text
sha256:2814dd87c174edeb4e3b42e33d74e23b14dfce74c9b54d29ba44e5070615f43e
```

encrypted layer digest：

```text
sha256:9b06bdfb4f66211e45653b3c6b0976fda0ab7d62b78e1b7f2fc8834b3ac0a684
```

如果要从其他镜像源重新制作加密镜像，可以优先使用镜像源加速拉取，例如：

```bash
mkdir -p artifacts/encrypted-images/new-image
head -c 32 /dev/urandom > artifacts/encrypted-images/new-image/key1

sudo install -D -m0600 \
  artifacts/encrypted-images/new-image/key1 \
  /opt/confidential-containers/kbs/repository/default/key/key_id1

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

skopeo copy --insecure-policy \
  --encryption-key "provider:attestation-agent:keypath=$PWD/artifacts/encrypted-images/new-image/key1::keyid=kbs:///default/key/key_id1::algorithm=A256GCM" \
  docker://docker.m.daocloud.io/library/busybox:latest \
  oci:artifacts/encrypted-images/new-image/oci:encrypted
```

本次没有继续换源重新制作镜像，因为成功和失败都已经证明网络镜像源不是主要阻塞点。失败点在 RAK binding，修复 RMM 后现有 encrypted OCI layout 已能完成远程证明和解密。

## 本地 OCI Layout Registry

当前使用一个最小 pull-only registry 暴露 OCI layout：

```bash
python3 scripts/run/serve-oci-layout-registry.py \
  --layout artifacts/encrypted-images/immzh-busybox/oci \
  --host 127.0.0.1 \
  --port 19000
```

Image CVM 看到的镜像名：

```text
10.88.0.1:19000/coco/busybox:encrypted
```

`coco` 和 `busybox` 只是 registry API path 的 repository name；本地 server 只根据 tag/digest 从单个 OCI layout 返回 manifest/blob。

## RK 到本地服务的端口链路

当前本地 x86/WSL 环境不能让 RK 或 Image CVM 直接访问本机监听端口，所以使用两段链路：

1. 本机到 RK 的 SSH reverse tunnel：

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

2. RK 上把 `10.88.0.1` 转发到 `127.0.0.1`：

```bash
ip link add name coco0 type bridge 2>/dev/null || true
ip addr show dev coco0 | grep -q '10.88.0.1/16' || ip addr add 10.88.0.1/16 dev coco0
ip link set coco0 up
sysctl -w net.ipv4.ip_forward=1
iptables -t nat -C POSTROUTING -s 10.88.0.0/16 ! -o coco0 -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s 10.88.0.0/16 ! -o coco0 -j MASQUERADE

nohup /tmp/coco_trustee_forward.py 10.88.0.1 18080 127.0.0.1 18080 >/tmp/coco-forward-18080.log 2>&1 &
nohup /tmp/coco_trustee_forward.py 10.88.0.1 15004 127.0.0.1 15004 >/tmp/coco-forward-15004.log 2>&1 &
nohup /tmp/coco_trustee_forward.py 10.88.0.1 19000 127.0.0.1 19000 >/tmp/coco-forward-19000.log 2>&1 &
```

`/tmp/coco_trustee_forward.py` 是一个简单 TCP forwarder。本次为临时 demo 使用；后续可以沉淀成正式远端脚本。

验证监听：

```bash
ss -ltnp | grep -E '(10.88.0.1|127.0.0.1):(18080|15004|19000)'
```

## 成功路径时序

```text
Image CVM
  -> image-rs 拉取 10.88.0.1:19000/coco/busybox:encrypted
  -> ocicrypt-rs 发现 encrypted layer annotation
  -> AA 通过 /sys/kernel/config/tsm/report 取 CCA token
  -> KBS /kbs/v0/auth
  -> AS/grpc-as 校验 CCA evidence
  -> KBS /kbs/v0/attest 返回 EAR/JWT
  -> KBS /kbs/v0/resource/default/key/key_id1 返回 KEK
  -> AA unwrap PLBCO
  -> image-rs 解密 layer、展开 rootfs、生成 EROFS
  -> /dev/coco-image-share 创建 RMM share
Runtime CVM
  -> 向 Image CVM 获取 rootfs share descriptor
  -> /dev/coco-image-share attach
  -> /dev/cocoimg0 mount readonly
  -> overlay upper/work
  -> container 输出 coco-runtime-cvm-ok
```

## 已知现象

成功后仍可能看到：

```text
ERRO[0048] forward signal child exited error="Sandbox not running: unknown"
```

如果它出现在 `coco-runtime-cvm-ok` 之后，本次判断为 `nerdctl run --rm` 清理/信号转发阶段噪声，不表示容器未运行。

AS/KBS token 中可能仍显示：

```text
ear.status = warning
executables = 33
```

这是 demo OPA policy 和 reference evaluation 的保守评分，不影响当前 KBS 发 key策略。生产化前应把 policy、rvstore、REM/RIM 评价逻辑统一收紧。

## 黑名单

不要用这些方案作为默认路径：

- 只更新 `rvstore.json/tastore.json` 而不修 RAK binding。结果是 AS 仍 401，KBS 不发 key。
- 修改 Trustee verifier 放松 `check_binding()`。这会绕过 CCA RAK 绑定，不是可信远程证明。
- 把换镜像源当成当前失败根因。换源可以改善拉取速度，但不能解决 AS 拒绝 evidence。
- 依赖 `check-image-cache-network.sh` 自动创建 `coco0`。它只检查 CNI 配置和 NAT 规则，刷机后可能没有真实 bridge interface。
- 在远端 SSH 命令里使用 `pkill -f coco_trustee_forward.py`。命令行本身可能匹配该 pattern，导致 SSH 会话被自己杀掉。
