# Release process

Releases are **tag-driven**. Pushing an annotated tag matching `v<MAJOR>.<MINOR>.<PATCH>`
triggers `.github/workflows/release.yml`, which:

1. Verifies the tag base matches `[package].version` in `Cargo.toml` and fails
   fast otherwise (single source of truth).
2. Cross-builds the matrix (5 variants: `arm_cortex-a7_neon-vfpv4`,
   `aarch64_cortex-a53`, `aarch64_generic`, `x86_64`, `entware-aarch64`) using
   `cross` 0.2.5.
3. Packages each variant via `scripts/build-ipk.sh` with `PKG_VERSION` derived
   from `scripts/pkg-version.sh`.
4. Generates `SHA256SUMS` and creates a GitHub Release attaching every `.ipk`
   plus the manifest.

## Versioning conventions (OpenWrt-style)

The `.ipk` filename is `<name>_<PKG_VERSION>-<PKG_RELEASE>_<arch>.ipk`.

- **`PKG_VERSION`** — upstream Rust crate version. Bump when source changes.
  Read from `Cargo.toml`'s `[package].version`.
- **`PKG_RELEASE`** — packaging revision. Defaults to `1`. Bump when only the
  packaging metadata (postinst, conffiles, file paths) changes; reset to `1`
  every time `PKG_VERSION` moves.

This mirrors the OpenWrt source-package `Makefile` convention (`PKG_VERSION` /
`PKG_RELEASE`).

## Cutting a release

```sh
# 1. Bump version in Cargo.toml.
$EDITOR Cargo.toml                       # version = "0.2.0"
cargo update --workspace                 # refresh Cargo.lock
git commit -am "chore: bump to 0.2.0"
git push

# 2. Tag and push.
git tag v0.2.0
git push origin v0.2.0
```

The release workflow runs automatically on the tag push. Watch it under
[Actions → Release](https://github.com/naoNao89/openwrt-hotspot-banner/actions/workflows/release.yml).

## Re-cutting a packaging-only revision

If a release ships and you spot a packaging bug (e.g. a wrong conffile entry)
without changing the Rust source, re-cut with `PKG_RELEASE=2`:

```sh
# CI builds 0.2.0-2 instead of 0.2.0-1.
PKG_RELEASE=2 git tag -f v0.2.0
git push -f origin v0.2.0
```

Or, more cleanly, use a `-p2` tag suffix and let the workflow infer:

```sh
git tag v0.2.0-p2     # workflow extracts base 0.2.0 from tag, PKG_RELEASE=2 from suffix... TODO
```

Currently the simpler `-f` re-tag approach is the supported one; richer
suffix parsing is a future enhancement.

## Manual one-off (not via tag)

For ad-hoc local builds you don't intend to release:

```sh
make ipk        # one arch (the default armv7)
make ipk-all    # full matrix locally
```

These do not touch GitHub Releases.

## Verifying a release artifact

```sh
sha256sum -c SHA256SUMS
opkg install openwrt-hotspot-banner_0.2.0-1_arm_cortex-a7_neon-vfpv4.ipk
```
