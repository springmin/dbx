#!/bin/sh
# OpenHarmony native build helper for DBX.
#
# Subcommands:
#   patches   apply the registry patches (aws-lc-sys, zstd-sys), idempotent
#   frontend  sign native npm bindings, fix the oxide platform link, build dist/
#   backend   build target/release/dbx-web with the OHOS SDK linker paths
#   deploy    install the binary, static assets and dialect plugins to ~/dbx-ohos
#   release   build a versioned tar.gz release package under ~/dbx-ohos/releases
#   publish   create a GitHub release for a tag and upload the packaged asset
#   all       patches + frontend + backend + deploy
#
# Environment overrides:
#   OHOS_SDK_NATIVE  OHOS SDK "native" directory (llvm/, sysroot/)
#   OHOS_SIGN_TOOL   binary-sign-tool path
#   DBX_DEPLOY_DIR   deployment directory (default: $HOME/dbx-ohos)
#   CARGO_HOME       cargo home (default: $HOME/.cargo)
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CARGO_HOME=${CARGO_HOME:-$HOME/.cargo}
DBX_DEPLOY_DIR=${DBX_DEPLOY_DIR:-$HOME/dbx-ohos}

if [ -z "${OHOS_SDK_NATIVE:-}" ]; then
  # SDK 26.0.0.38+ uses Cellar/ohos-sdk-native/<ver>; older layouts used
  # Cellar/ohos-sdk/<ver>/native. Prefer whichever has an llvm/ directory.
  for candidate in "$HOME"/.harmonybrew/Cellar/ohos-sdk-native/* "$HOME"/.harmonybrew/Cellar/ohos-sdk/*/native; do
    [ -d "$candidate/llvm" ] && OHOS_SDK_NATIVE="$candidate"
  done
fi
OHOS_SIGN_TOOL=${OHOS_SIGN_TOOL:-$HOME/.harmonybrew/bin/binary-sign-tool}
OHOS_LLVM_LIB=${OHOS_SDK_NATIVE:+$OHOS_SDK_NATIVE/llvm/lib}

die() { echo "error: $*" >&2; exit 1; }

registry_src() {
  ls -d "$CARGO_HOME"/registry/src/* 2>/dev/null | head -1
}

PATCH_APPLIED=0

apply_patch_idempotent() {
  dir=$1
  patch_file=$2
  marker=$3
  target=$4
  [ -d "$dir" ] || return 0
  if grep -q "$marker" "$dir/$target" 2>/dev/null; then
    echo "already patched: $(basename "$dir")"
    return 0
  fi
  echo "patching: $(basename "$dir")"
  patch -p1 -d "$dir" < "$patch_file"
  PATCH_APPLIED=1
}

cmd_patches() {
  src=$(registry_src) || true
  [ -n "$src" ] || die "cargo registry sources not found under $CARGO_HOME (run: cargo fetch)"
  apply_patch_idempotent "$src/aws-lc-sys-0.43.0" \
      "$ROOT/patches/ohos/aws-lc-sys-0.43.0-ohos.patch" \
      "OHOS_ARCH" "aws-lc/crypto/fipsmodule/CMakeLists.txt"
  apply_patch_idempotent "$src/zstd-sys-2.0.16+zstd.1.5.7" \
      "$ROOT/patches/ohos/zstd-sys-2.0.16-qsort_r.patch" \
      "OpenHarmony (musl) exports qsort_r" "zstd/lib/dictBuilder/cover.c"
  if [ "$PATCH_APPLIED" = 1 ]; then
    echo "clearing aws-lc build cache (CMake caches the processor detection)"
    rm -rf "$ROOT"/target/release/build/aws-lc-sys-* \
           "$ROOT"/target/release/deps/libaws_lc_sys-* \
           "$ROOT"/target/release/deps/aws_lc_sys-*
  fi
}

sign_node_bindings() {
  [ -x "$OHOS_SIGN_TOOL" ] || die "binary-sign-tool not found: $OHOS_SIGN_TOOL"
  count=0
  for f in $(find "$ROOT/node_modules" -name "*.node" -type f 2>/dev/null); do
    case "$f" in *.darwin-*.node) continue ;; esac
    if readelf -S "$f" 2>/dev/null | grep -q codesign; then
      continue
    fi
    tmp="$f.sigtmp"
    "$OHOS_SIGN_TOOL" sign -selfSign 1 -inFile "$f" -outFile "$tmp" >/dev/null 2>&1 \
      || { rm -f "$tmp"; die "signing failed: $f"; }
    mv -f "$tmp" "$f"
    count=$((count + 1))
  done
  echo "signed $count native binding(s)"
}

fix_oxide_link() {
  oxide=$(ls -d "$ROOT"/node_modules/.pnpm/@tailwindcss+oxide@*/node_modules/@tailwindcss/oxide 2>/dev/null | head -1)
  [ -n "$oxide" ] || { echo "oxide package not installed, skipping"; return; }
  version=$(basename "$(dirname "$oxide")")
  version=${version##*@}
  target="../../../@tailwindcss+oxide-linux-arm64-musl@$version/node_modules/@tailwindcss/oxide-linux-arm64-musl"
  link="$(dirname "$oxide")/oxide-openharmony-arm64"
  if [ -e "$ROOT/node_modules/.pnpm/@tailwindcss+oxide-linux-arm64-musl@$version" ]; then
    ln -sfn "$target" "$link"
    echo "oxide-openharmony-arm64 -> $version"
  else
    echo "warning: @tailwindcss/oxide-linux-arm64-musl@$version not installed; oxide will fail on OHOS" >&2
  fi
}

cmd_frontend() {
  if [ ! -d "$ROOT/node_modules" ]; then
    echo "installing pnpm dependencies"
    CI=true pnpm install --frozen-lockfile
  fi
  sign_node_bindings
  fix_oxide_link
  echo "building frontend"
  LD_LIBRARY_PATH="${OHOS_LLVM_LIB:-}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" pnpm build
}

cmd_backend() {
  [ -n "$OHOS_LLVM_LIB" ] || die "OHOS SDK not found; set OHOS_SDK_NATIVE"
  # The SDK lld needs the SDK's own libxml2; an incompatible copy in
  # ~/.harmonybrew/lib would otherwise shadow it and break every link.
  LD_LIBRARY_PATH="$OHOS_LLVM_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    cargo build --offline --release -p dbx-web \
      --config 'profile.release.lto=false' \
      --config 'profile.release.codegen-units=16'
}

cmd_deploy() {
  [ -f "$ROOT/target/release/dbx-web" ] || die "dbx-web not built"
  [ -d "$ROOT/dist" ] || die "dist/ not built"
  mkdir -p "$DBX_DEPLOY_DIR/data/plugins"
  if [ -f "$DBX_DEPLOY_DIR/dbx-web" ]; then
    cp -a "$DBX_DEPLOY_DIR/dbx-web" "$DBX_DEPLOY_DIR/dbx-web.prev"
  fi
  rm -f "$DBX_DEPLOY_DIR/dbx-web"
  cp "$ROOT/target/release/dbx-web" "$DBX_DEPLOY_DIR/dbx-web"
  rm -rf "$DBX_DEPLOY_DIR/static"
  cp -r "$ROOT/dist" "$DBX_DEPLOY_DIR/static"
  rm -rf "$DBX_DEPLOY_DIR/data/plugins/dialects"
  cp -r "$ROOT/plugins/dialects" "$DBX_DEPLOY_DIR/data/plugins/dialects"
  echo "deployed to $DBX_DEPLOY_DIR"
  echo "restart with: sh $DBX_DEPLOY_DIR/start.sh"
}

cmd_release() {
  [ -f "$ROOT/target/release/dbx-web" ] || die "dbx-web not built (run: $0 backend)"
  [ -d "$ROOT/dist" ] || die "dist/ not built (run: $0 frontend)"
  version=$(sed -n 's/^  "version": "\([^"]*\)",$/\1/p' "$ROOT/package.json" | head -1)
  [ -n "$version" ] || die "cannot read version from package.json"
  pkg="dbx-web-$version-ohos-aarch64"
  out=${DBX_RELEASE_DIR:-$DBX_DEPLOY_DIR/releases}
  mkdir -p "$out"
  stage=$(mktemp -d 2>/dev/null || true)
  if [ -z "$stage" ]; then
    stage=${TMPDIR:-$HOME/.cache}/dbx-release.$$
    mkdir -p "$stage"
  fi
  pkgdir="$stage/$pkg"
  mkdir -p "$pkgdir/data/plugins"
  cp "$ROOT/target/release/dbx-web" "$pkgdir/dbx-web"
  cp -r "$ROOT/dist" "$pkgdir/static"
  cp -r "$ROOT/plugins/dialects" "$pkgdir/data/plugins/dialects"
  cp "$ROOT/scripts/ohos-start.sh" "$pkgdir/start.sh"
  chmod +x "$pkgdir/start.sh"
  printf '%s\n' "$version" > "$pkgdir/VERSION"
  cat > "$pkgdir/README.txt" <<EOF
DBX Web $version for OpenHarmony (aarch64)

Layout:
  dbx-web                 release binary (aarch64-unknown-linux-ohos, self-signed)
  static/                 Vue frontend build
  data/plugins/dialects   SQL dialect plugins
  start.sh                launcher

Run:
  sh start.sh             # http://<device-ip>:4224
  sh start.sh 8080        # custom port

The data directory is \$DIR/data by default (dbx.db, plugins, local SQLite
files). Password login is disabled by start.sh; set DBX_PASSWORD and
DBX_DISABLE_PASSWORD=false to enable it.

Known limitations (v$version):
  - DuckDB needs the driver agent; no OHOS agent is bundled. Install it from
    the Driver Manager or set DBX_DUCKDB_DRIVER_PATH (the binary must be
    signed for OpenHarmony).
  - The Transwarp/Inceptor dialect is not registered in this build (36/37).
  - CSS optimization is disabled (Vite/esbuild still minifies the bundle).
EOF
  tar -czf "$out/$pkg.tar.gz" -C "$stage" "$pkg"
  (cd "$out" && sha256sum "$pkg.tar.gz" > "$pkg.tar.gz.sha256")
  rm -rf "$stage"
  echo "release package: $out/$pkg.tar.gz"
  echo "sha256: $(cut -d' ' -f1 "$out/$pkg.tar.gz.sha256")"
}

cmd_publish() {
  tag=${1:-}
  asset=${2:-}
  [ -n "$tag" ] || die "usage: $0 publish <tag> [asset]"
  if [ -z "$asset" ]; then
    asset=$(ls -t "${DBX_RELEASE_DIR:-$DBX_DEPLOY_DIR/releases}"/*.tar.gz 2>/dev/null | head -1 || true)
  fi
  [ -f "$asset" ] || die "release asset not found"
  repo=${DBX_REPO:-springmin/dbx}
  gh release create "$tag" --repo "$repo" \
    --title "DBX Web for OpenHarmony ($tag)" \
    --generate-notes "$asset"
}

case "${1:-all}" in
  patches) cmd_patches ;;
  frontend) cmd_frontend ;;
  backend) cmd_backend ;;
  deploy) cmd_deploy ;;
  release) cmd_release ;;
  publish) cmd_publish "${2:-}" "${3:-}" ;;
  all) cmd_patches; cmd_frontend; cmd_backend; cmd_deploy ;;
  -h|--help|help)
    sed -n '2,24p' "$0"
    ;;
  *) die "unknown subcommand: $1 (use patches|frontend|backend|deploy|release|publish|all)" ;;
esac
