#!/bin/bash
# Build the bundled NTFS engine from PINNED source and stage it into Resources/.
#
# What this does:
#   1. Builds ntfs-3g from the pinned source tree given by $NTFS3G_SRC
#      (a local checkout at the pinned version — never an opaque binary).
#   2. Verifies the built binary links FUSE-T's libfuse and NOT macFUSE
#      (otool check: the Homebrew build drags the kext back in).
#   3. Installs it to Resources/bin/ntfs-3g, copies its COPYING (GPLv2)
#      to Resources/licenses/, and stamps Resources/engine-info.json
#      with the exact version + source revision for THIRD_PARTY_LICENSES.
#
# Usage:
#   NTFS3G_SRC=/path/to/ntfs-3g-source ./scripts/bundle-engine.sh
#
# Obtaining the pinned source (maintainer step, needs network + Xcode CLT):
#   git clone https://github.com/macos-fuse-t/ntfs-3g   # FUSE-T-compatible fork
#   cd ntfs-3g && git checkout <pinned tag matching NTFS3G_VERSION>
# ...or use an official tarball from https://github.com/tuxera/ntfs-3g
# releases, provided it is built against FUSE-T's libfuse headers
# (FUSE-T must be installed: `brew install --cask fuse-t`).
#
# Fails closed: missing source, unmet prereqs, wrong linkage, or a
# version mismatch all abort with a non-zero exit — never a silent bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

# ---- Pinned versions (bump deliberately; record in THIRD_PARTY_LICENSES.md) ----
# Default source is upstream tuxera/ntfs-3g at the pinned tag below, built
# with NTFS3G_CONFIGURE_EXTRA="--with-fuse=external" (the script supplies
# the fuse.pc alias + large-file flags upstream needs on macOS).
# Fallback: macos-fuse-t/ntfs-3g fork (branch `edge`) also builds, but it
# tracks 2022.10.3 and predates the 2026.7.7 CVE fixes — use only if
# upstream regresses on a future SDK (see THIRD_PARTY_LICENSES.md).
NTFS3G_VERSION="2026.9.28"

RES="Resources"
BIN_DIR="$RES/bin"
LIC_DIR="$RES/licenses"
INFO="$RES/engine-info.json"

: "${NTFS3G_SRC:?Set NTFS3G_SRC to the pinned ntfs-3g source tree (see header).}"
[ -d "$NTFS3G_SRC" ] || { echo "NTFS3G_SRC is not a directory: $NTFS3G_SRC"; exit 1; }

for tool in clang make pkg-config otool codesign git; do
    command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool (install Xcode CLT + pkg-config)"; exit 1; }
done
[ -f /usr/local/lib/libfuse-t.dylib ] || [ -f /opt/homebrew/lib/libfuse-t.dylib ] \
    || { echo "FUSE-T libfuse not found — install it (brew install --cask fuse-t) so ntfs-3g builds kext-free."; exit 1; }

# (pkg-config fuse alias is set up after BUILD_DIR exists, below.)

echo "==> Building ntfs-3g $NTFS3G_VERSION from $NTFS3G_SRC"
BUILD_DIR="$(mktemp -d /tmp/ntfsbridge-engine-XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT

# Upstream configure wants pkg-config module `fuse >= 2.6.0`; FUSE-T ships
# the SAME fuse-2.9 API as module `fuse-t` (fuse_common.h declares 2.9).
# Alias it so the version check links FUSE-T's library — no stub, the
# headers and binary really are the 2.9 interface ntfs-3g programs against.
if ! pkg-config --exists "fuse >= 2.6.0" 2>/dev/null; then
    if pkg-config --exists fuse-t 2>/dev/null; then
        mkdir -p "$BUILD_DIR/pkgconfig"
        {
            echo "# Alias for FUSE-T's fuse-t module (fuse-2.9 API, FUSE-T runtime)."
            sed -e 's/^Name:.*/Name: fuse/' -e 's/^Version:.*/Version: 2.9/' \
                "$(pkg-config --variable=pcfiledir fuse-t)/fuse-t.pc"
        } > "$BUILD_DIR/pkgconfig/fuse.pc"
        export PKG_CONFIG_PATH="$BUILD_DIR/pkgconfig:${PKG_CONFIG_PATH:-}"
        echo "Aliased pkg-config fuse-t -> fuse (FUSE 2.9 API)."
    else
        echo "Neither pkg-config fuse nor fuse-t found — install FUSE-T."; exit 1
    fi
fi

cp -R "$NTFS3G_SRC/." "$BUILD_DIR/src/"
cd "$BUILD_DIR/src"

SRC_REV="$(git rev-parse --short HEAD 2>/dev/null || echo "non-git-source")"
if [ -f configure ]; then :; elif [ -f autogen.sh ]; then ./autogen.sh; else
    echo "No configure/autogen.sh in source tree — aborting."; exit 1
fi
# --disable-library links libntfs-3g into the binary instead of installing
# a .so (whose Linux-only relocation hook would fail on macOS anyway):
# the result is one self-contained binary, which is all we bundle.
# NTFS3G_CONFIGURE_EXTRA passes through, e.g. "--with-fuse=external" so
# upstream builds link FUSE-T's libfuse instead of the bundled internal one.
# External FUSE on macOS requires large-file flags the .pc file omits.
export CPPFLAGS="${CPPFLAGS:-} -D_FILE_OFFSET_BITS=64"
./configure --prefix="$BUILD_DIR/install" --disable-library --disable-dependency-tracking ${NTFS3G_CONFIGURE_EXTRA:-} >/dev/null
mkdir -p "$BUILD_DIR/destroot/sbin"
make -j"$(sysctl -n hw.ncpu)" >/dev/null
# Linux-distro defaults (rootlibdir=/lib, rootbindir=/bin + hardcoded
# /sbin mount-helper symlinks) would write outside the staging area.
# DESTDIR contains everything; the libdir/bindir overrides neuter the
# relocation hooks — we bundle the binary, not the .so or symlinks.
make install DESTDIR="$BUILD_DIR/destroot" \
    "rootlibdir=\$(libdir)" "rootbindir=\$(bindir)" "rootsbindir=\$(sbindir)" >/dev/null
cd - >/dev/null

BUILT_BIN="$BUILD_DIR/destroot$BUILD_DIR/install/bin/ntfs-3g"
[ -x "$BUILT_BIN" ] || { echo "Build produced no ntfs-3g binary — aborting."; exit 1; }

echo "==> Verifying linkage (must use libfuse-t, never macfuse)"
LINKAGE="$(otool -L "$BUILT_BIN")"
echo "$LINKAGE" | grep -qi "libfuse-t" \
    || { echo "LINKAGE CHECK FAILED: binary does not link libfuse-t:"; echo "$LINKAGE"; exit 1; }
if echo "$LINKAGE" | grep -qi "macfuse\|osxfuse"; then
    echo "LINKAGE CHECK FAILED: binary links macFUSE (kext path) — rebuild against FUSE-T headers."
    echo "$LINKAGE"; exit 1
fi
# Distributability gate: every non-system dependency must be accounted for.
# Allowed: /usr/lib + /System (present on every Mac) and libfuse-t.*
# (the documented FUSE-T companion runtime — see THIRD_PARTY_LICENSES).
# Anything else (Homebrew libs, /tmp build paths) means the binary will
# not run on a user's Mac: bundle the dylib or link statically instead.
UNACCOUNTED="$(echo "$LINKAGE" | grep -E "^\s+/" | grep -v -E "^\s+/(usr/lib|System/)|libfuse-t" || true)"
if [ -n "$UNACCOUNTED" ]; then
    echo "LINKAGE CHECK FAILED: unaccounted non-system dependencies:"
    echo "$UNACCOUNTED"
    exit 1
fi
echo "Linkage OK (libfuse-t, no macfuse, no stray deps)."
echo "$LINKAGE" > "$RES/engine-linkage.txt"

echo "==> Staging into $BIN_DIR"
mkdir -p "$BIN_DIR" "$LIC_DIR"
cp "$BUILT_BIN" "$BIN_DIR/ntfs-3g"
chmod +x "$BIN_DIR/ntfs-3g"

# The build may link @rpath/libfuse-t.dylib with no RPATH, leaving the
# loader unable to find FUSE-T's library at runtime (fuse-t.pc nowadays
# adds the RPATH at link time, the fork-era build did not). Ensure an
# RPATH to FUSE-T's install location exists — /usr/local/lib on both
# architectures (observed) — then re-sign (distribution signing replaces
# ad-hoc later).
if ! otool -l "$BIN_DIR/ntfs-3g" 2>/dev/null | grep -A2 LC_RPATH | grep -q "/usr/local/lib"; then
    install_name_tool -add_rpath /usr/local/lib "$BIN_DIR/ntfs-3g"
fi
codesign --force --sign - "$BIN_DIR/ntfs-3g"
"$BIN_DIR/ntfs-3g" --version >/dev/null \
    || { echo "STAGED BINARY CHECK FAILED: ntfs-3g --version does not run."; exit 1; }
echo "Staged binary runs: $("$BIN_DIR/ntfs-3g" --version 2>&1 | head -1)"

if [ -f "$NTFS3G_SRC/COPYING" ]; then
    cp "$NTFS3G_SRC/COPYING" "$LIC_DIR/ntfs-3g-COPYING"
else
    echo "WARNING: no COPYING in source tree — GPLv2 text must be added to $LIC_DIR before distribution."
fi

cat > "$INFO" <<EOF
{
  "engine": "ntfs-3g",
  "version": "$NTFS3G_VERSION",
  "source_revision": "$SRC_REV",
  "source": "built from pinned source (NTFS3G_SRC), linked against FUSE-T libfuse",
  "license": "GPLv2 (see Resources/licenses/ntfs-3g-COPYING)",
  "bundled_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

codesign --verify --strict "$BIN_DIR/ntfs-3g" 2>/dev/null || true
echo "==> Done. Engine staged:"
ls -la "$BIN_DIR" "$LIC_DIR"
cat "$INFO"
echo "Next: ./scripts/build-app.sh (bundles Resources/ into NTFSBridge.app)"
