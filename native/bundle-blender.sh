#!/usr/bin/env bash
# DEV TOOL: copy locally built libktx shared libraries into a Blender addon
# that loads them via ctypes (the gltf-exporter addon's ktx_lib.py checks
# <addon>/bin/<triple>/ktx.{so,dylib,dll} before its downloaded copy). End
# users don't need this — the addon downloads the lib for their platform from
# this repo's GitHub releases (see .github/workflows/release.yml).
#
# Usage:  native/bundle-blender.sh <addon-dir> [triple ...]
#   With no triples given, every <triple>/ dir in the repo that contains a
#   built ktx.* is bundled. Build them first with native/build-shared.sh
#   (locally) or download the libktx-* CI artifacts into the <triple>/ dirs.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ $# -lt 1 ]; then
  echo "usage: $0 <addon-dir> [triple ...]" >&2
  exit 1
fi
ADDON="$1"
shift

if [ ! -f "$ADDON/ktx_lib.py" ]; then
  echo "$ADDON does not look like the gltf-exporter addon (no ktx_lib.py)" >&2
  exit 1
fi

triples=("$@")
if [ ${#triples[@]} -eq 0 ]; then
  for d in "$REPO_ROOT"/*/; do
    t="$(basename "$d")"
    case "$t" in
      linux-*|macos-*|windows-*) triples+=("$t") ;;
    esac
  done
fi

bundled=0
for t in ${triples[@]+"${triples[@]}"}; do
  found=""
  for lib in "$REPO_ROOT/$t"/ktx.so "$REPO_ROOT/$t"/ktx.dylib "$REPO_ROOT/$t"/ktx.dll; do
    [ -f "$lib" ] || continue
    mkdir -p "$ADDON/bin/$t"
    cp "$lib" "$ADDON/bin/$t/"
    echo "bundled $t/$(basename "$lib")"
    found=1
    bundled=$((bundled + 1))
  done
  [ -n "$found" ] || echo "skipped $t (no built ktx.* — run native/build-shared.sh $t)"
done

if [ "$bundled" -eq 0 ]; then
  echo "nothing bundled" >&2
  exit 1
fi
