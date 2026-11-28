#!/usr/bin/env bash
# Runs the Foundation-only part of ReviveKit's tests on Linux (cloud containers have no macOS).
# Covers CardProtocol, CardLink (without CoreBluetooth), CardService, DeviceSource, Library,
# SyncEngine, LinkImport, Account and LibraryTools, and builds the `revive` tool without audio: about 250
# tests. Everything that needs AVFoundation, Speech, CoreBluetooth, Security or SwiftUI is still
# tested only by app-ci on macOS, which stays the gate for merging.
#
#   app/ReviveKit/scripts/linux-test.sh             # all of the above
#   app/ReviveKit/scripts/linux-test.sh --filter X  # extra arguments go to `swift test`
#   app/ReviveKit/scripts/linux-test.sh --install   # first download the pinned toolchain (~1 GB)
#
# Swift comes from $SWIFT_LINUX (a toolchain's usr/bin), else the cached toolchain, else PATH.
# The sources are copied into app/ReviveKit/.build-linux/ (ignored by git), patched by
# linux/patch.py, and built there with linux/Package.swift.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
kit="$(cd "$here/.." && pwd)"
work="$kit/.build-linux/pkg"
toolchain_version="6.2"
toolchain_dir="${XDG_CACHE_HOME:-$HOME/.cache}/swift-$toolchain_version-linux"

if [[ "${1:-}" == "--install" ]]; then
  shift
  if [[ ! -x "$toolchain_dir/usr/bin/swift" ]]; then
    . /etc/os-release
    platform="ubuntu${VERSION_ID//./}"
    name="swift-$toolchain_version-RELEASE-ubuntu$VERSION_ID"
    url="https://download.swift.org/swift-$toolchain_version-release/$platform/swift-$toolchain_version-RELEASE/$name.tar.gz"
    echo "linux-test: downloading $url"
    mkdir -p "$toolchain_dir"
    curl -sSfL "$url" | tar xz -C "$toolchain_dir" --strip-components=1
  fi
fi

if [[ -n "${SWIFT_LINUX:-}" ]]; then
  export PATH="$SWIFT_LINUX:$PATH"
elif [[ -x "$toolchain_dir/usr/bin/swift" ]]; then
  export PATH="$toolchain_dir/usr/bin:$PATH"
fi
if ! command -v swift >/dev/null; then
  echo "linux-test: no swift found. Run with --install, or set SWIFT_LINUX to a toolchain's usr/bin." >&2
  exit 2
fi

mkdir -p "$work"
rm -rf "$work/Sources" "$work/Tests" "$work/Shim"
cp -r "$kit/Sources" "$kit/Tests" "$work/"
cp -r "$here/linux/shim" "$work/Shim"
cp "$here/linux/Package.swift" "$work/Package.swift"
python3 "$here/linux/patch.py" "$work"
cd "$work"
exec swift test --disable-xctest "$@"
