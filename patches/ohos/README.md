# OpenHarmony registry patches

These patches are applied to crate sources in `$CARGO_HOME/registry/src` by
`scripts/ohos-build.sh patches` (idempotent). They are only needed until the
corresponding upstream fixes are released.

| Patch | Crate | Upstream | Drop when |
|---|---|---|---|
| `aws-lc-sys-0.43.0-ohos.patch` | `aws-lc-sys 0.43.0` | [aws-lc-rs#1280](https://github.com/aws/aws-lc-rs/issues/1280), [PR #1293](https://github.com/aws/aws-lc-rs/pull/1293) | an `aws-lc-sys` release contains the native OpenHarmony CMake fallback (Linux-compatible platform + processor from the Cargo target) |
| `zstd-sys-2.0.16-qsort_r.patch` | `zstd-sys 2.0.16+zstd.1.5.7` | [meta/zstd#4872](https://github.com/meta/zstd/issues/4872), [PR #4886](https://github.com/meta/zstd/pull/4886) | a zstd release includes the `#if defined(__OHOS__)` `qsort_r` declaration, or `zstd-sys` bumps to it |

## Other OpenHarmony workarounds (not in this directory)

- `packages/lightningcss-openharmony-arm64/` — JS fallback for the
  lightningcss native binding; drop after
  [tailwindcss#20629](https://github.com/tailwindlabs/tailwindcss/pull/20629)
  is released.
