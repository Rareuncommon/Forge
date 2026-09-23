#!/usr/bin/env bash
# Set up a Linux (Ubuntu 24.04) machine to build and test the headless Forge engine:
# Swift 6.4.0 toolchain + the distribution's OCCT development packages (7.6.x).
# Used by CI and cloud dev sessions. The macOS app uses scripts/build-occt.sh instead.
set -euo pipefail

SWIFT_VERSION="${SWIFT_VERSION:-6.4.0}"
SWIFT_PREFIX="${SWIFT_PREFIX:-/opt/swift}"
SUDO=""
[[ $(id -u) -ne 0 ]] && SUDO="sudo"

$SUDO apt-get update -q
$SUDO apt-get install -y -q --no-install-recommends \
  libocct-foundation-dev libocct-modeling-data-dev libocct-modeling-algorithms-dev \
  libocct-data-exchange-dev libocct-ocaf-dev \
  binutils git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev libpython3-dev \
  libsqlite3-0 libstdc++-13-dev libxml2-dev libncurses-dev libz3-dev pkg-config tzdata unzip zlib1g-dev \
  python3 curl ca-certificates

if ! "$SWIFT_PREFIX/usr/bin/swift" --version 2>/dev/null | grep -q "Swift version ${SWIFT_VERSION%.0}"; then
  . /etc/os-release
  platform="ubuntu${VERSION_ID//./}"
  arch_suffix=""
  [[ "$(uname -m)" == "aarch64" ]] && arch_suffix="-aarch64"
  url="https://download.swift.org/swift-${SWIFT_VERSION}-release/${platform}${arch_suffix}/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE-ubuntu${VERSION_ID}${arch_suffix}.tar.gz"
  echo "Downloading $url"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/swift.tgz" "$url"
  $SUDO mkdir -p "$SWIFT_PREFIX"
  $SUDO tar xzf "$tmp/swift.tgz" -C "$SWIFT_PREFIX" --strip-components=1
  rm -rf "$tmp"
fi

"$SWIFT_PREFIX/usr/bin/swift" --version
echo "Add to PATH: export PATH=$SWIFT_PREFIX/usr/bin:\$PATH"
