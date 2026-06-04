# CNI Plugin Source

The files in `bin/` are fixed runtime artifacts restored from the official
Containernetworking plugins release:

```text
version: v1.9.1
asset: cni-plugins-linux-arm64-v1.9.1.tgz
url: https://github.com/containernetworking/plugins/releases/download/v1.9.1/cni-plugins-linux-arm64-v1.9.1.tgz
sha256: 56171987d3947707c3563db2f4001bccaf50fd63468611b9f3cbecb1375ee7ec
```

These binaries are intentionally kept as organized fixed artifacts in
`COCO-SFTP`; no source tree in this workspace rebuilds them.
