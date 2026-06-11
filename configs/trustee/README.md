# Trustee Demo Configs

These files are the verified local RK3588/OpenCCA demo configs for Trustee,
KBS, AS, RVPS, and CCA appraisal.

They intentionally use demo settings:

- KBS listens on plain HTTP.
- KBS uses an insecure demo token key.
- CCA trust stores match the current OpenCCA sample platform token path.
- Policy only checks that AS marks the evidence as non-sample.

Do not commit KEK material under this directory. Runtime keys belong under:

```text
/opt/confidential-containers/kbs/repository/default/key/key_id1
```
