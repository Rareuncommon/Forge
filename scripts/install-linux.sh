#!/usr/bin/env bash
# Build and install Forge on Linux (docs/adr/0013-linux-app.md): the desktop app `forge`
# (GTK 4 + OpenGL) and the headless engine `forge-cli` (commands, scripts, MCP server).
#
#   scripts/install-linux.sh              install for this user into ~/.local
#   scripts/install-linux.sh --system     install into /usr/local (uses sudo)
#   scripts/install-linux.sh --no-deps    do not install distribution packages
#   scripts/install-linux.sh --uninstall  remove what an earlier run installed
#   FORGE_SWIFT_TARBALL=<file>             use a downloaded swift.org toolchain (+ <file>.sig)
#   FORGE_SWIFT=<swift>                    use this Swift 6.4 toolchain instead
#
# Tested on CachyOS / Arch Linux (pacman) and Ubuntu 24.04 (apt). It installs the build
# dependencies with the package manager, uses the official Swift toolchain from swift.org
# (downloaded once into ~/.local/share/forge, verified with swift.org's signing keys) rather
# than a distribution package, builds release binaries, and installs them with the Swift
# runtime libraries they use (in <prefix>/lib/forge), a desktop entry and an icon.
set -euo pipefail

SWIFT_VERSION="6.4.0"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="$HOME/.local"
SUDO=""
DEPS=1
UNINSTALL=0
TOOLCHAINS="${XDG_DATA_HOME:-$HOME/.local/share}/forge"

for arg in "$@"; do
  case "$arg" in
    --system) PREFIX="/usr/local"; SUDO="sudo" ;;
    --prefix=*) PREFIX="${arg#--prefix=}" ;;
    --no-deps) DEPS=0 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done
[[ $(id -u) -eq 0 ]] && SUDO=""

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
root() { if [[ $(id -u) -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

files=(
  "$PREFIX/bin/forge"
  "$PREFIX/bin/forge-cli"
  "$PREFIX/lib/forge"
  "$PREFIX/share/applications/forge.desktop"
  "$PREFIX/share/icons/hicolor/scalable/apps/forge.svg"
)

if [[ $UNINSTALL -eq 1 ]]; then
  for f in "${files[@]}"; do [[ -e "$f" ]] && { $SUDO rm -rf "$f"; echo "removed $f"; }; done
  echo "The Swift toolchain in $TOOLCHAINS is left in place; delete that folder to remove it too."
  exit 0
fi

# MARK: distribution packages

if [[ $DEPS -eq 1 ]]; then
  if command -v pacman >/dev/null; then
    say "Installing build dependencies (pacman)"
    # libxml2-legacy and ncurses: libraries the swift.org toolchain was linked against.
    root pacman -S --needed --noconfirm base-devel git python curl gnupg pkgconf \
      opencascade gtk4 libepoxy ncurses libxml2-legacy
  elif command -v apt-get >/dev/null; then
    say "Installing build dependencies (apt)"
    root apt-get update -q
    root apt-get install -y -q --no-install-recommends \
      libocct-foundation-dev libocct-modeling-data-dev libocct-modeling-algorithms-dev \
      libocct-data-exchange-dev libocct-ocaf-dev libgtk-4-dev libepoxy-dev \
      binutils git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev libpython3-dev \
      libsqlite3-0 libstdc++-13-dev libxml2-dev libncurses-dev libz3-dev pkg-config tzdata unzip zlib1g-dev \
      python3 curl ca-certificates
  else
    echo "No pacman or apt-get: install OpenCASCADE (7.6+), GTK 4, libepoxy, pkg-config, git, curl and gpg" \
         "with your package manager, then re-run with --no-deps."
    exit 1
  fi
fi

# MARK: Swift toolchain (swift.org)

SWIFT_DIR="$TOOLCHAINS/swift-$SWIFT_VERSION"
SWIFT="$SWIFT_DIR/usr/bin/swift"
if [[ -n "${FORGE_SWIFT:-}" ]]; then
  SWIFT="$FORGE_SWIFT"
elif [[ ! -x "$SWIFT" ]]; then
  arch_suffix=""
  [[ "$(uname -m)" == "aarch64" ]] && arch_suffix="-aarch64"
  name="swift-$SWIFT_VERSION-RELEASE-ubuntu24.04$arch_suffix"
  url="https://download.swift.org/swift-$SWIFT_VERSION-release/ubuntu2404$arch_suffix/swift-$SWIFT_VERSION-RELEASE/$name.tar.gz"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  if [[ -n "${FORGE_SWIFT_TARBALL:-}" ]]; then
    # An already downloaded toolchain (with its .sig next to it).
    cp "$FORGE_SWIFT_TARBALL" "$tmp/swift.tar.gz"
    cp "$FORGE_SWIFT_TARBALL.sig" "$tmp/swift.tar.gz.sig"
  else
    say "Downloading the Swift $SWIFT_VERSION toolchain from swift.org (about 1.1 GB)"
    curl -fL --progress-bar -o "$tmp/swift.tar.gz" "$url"
    curl -fsSL -o "$tmp/swift.tar.gz.sig" "$url.sig"
  fi
  say "Verifying its signature with swift.org's keys"
  export GNUPGHOME="$tmp/gnupg"
  mkdir -m 700 "$GNUPGHOME"
  # swift.org's public signing keys ship with Forge (packaging/linux, from
  # https://www.swift.org/keys/all-keys.asc); newer keys are fetched too when reachable.
  # gpg exits 2 when some keys of a bundle cannot be imported; the signature check decides.
  gpg --quiet --import "$ROOT/packaging/linux/swift-signing-keys.asc" 2>/dev/null || true
  if curl -fsSL -o "$tmp/swift-keys.asc" https://www.swift.org/keys/all-keys.asc 2>/dev/null; then
    gpg --quiet --import "$tmp/swift-keys.asc" 2>/dev/null || true
  fi
  if ! out="$(gpg --verify "$tmp/swift.tar.gz.sig" "$tmp/swift.tar.gz" 2>&1)"; then
    echo "$out" >&2
    die "the toolchain's signature does not verify"
  fi
  unset GNUPGHOME
  mkdir -p "$SWIFT_DIR"
  tar xzf "$tmp/swift.tar.gz" -C "$SWIFT_DIR" --strip-components=1
fi

# The swift.org build expects the narrow-character ncurses name; Arch ships only the wide one.
# A private link next to the toolchain's own libraries fixes that without touching the system.
compat="$SWIFT_DIR/usr/lib/swift/linux/libncurses.so.6"
if [[ -z "${FORGE_SWIFT:-}" && ! -e "$compat" ]] && ldd "$SWIFT_DIR/usr/bin/swift-driver" 2>/dev/null | grep -q "libncurses.so.6 => not found"; then
  for lib in /usr/lib/libncursesw.so.6 /usr/lib64/libncursesw.so.6 /usr/lib/x86_64-linux-gnu/libncursesw.so.6; do
    [[ -e "$lib" ]] && { ln -s "$lib" "$compat"; break; }
  done
fi

"$SWIFT" --version >/dev/null 2>&1 || {
  echo "The Swift toolchain in $SWIFT_DIR does not run:"
  "$SWIFT" --version || true
  echo "Missing libraries:"
  ldd "$SWIFT_DIR/usr/bin/swift-driver" "$SWIFT_DIR/usr/bin/swift-package" 2>/dev/null | grep "not found" | sort -u || true
  exit 1
}
say "$("$SWIFT" --version 2>/dev/null | head -1)"

# MARK: build

cd "$ROOT"
pkg-config --exists gtk4 epoxy || die "GTK 4 / libepoxy development files not found (pkg-config gtk4 epoxy)"
say "Building Forge (release; the first build takes a few minutes)"
# The Swift runtime is installed next to the binaries (lib/forge), found through $ORIGIN.
for product in forge forge-cli; do
  FORGE_LINUX_APP=1 "$SWIFT" build -c release --product "$product" -Xlinker -rpath -Xlinker '$ORIGIN/../lib/forge'
done
BIN="$(FORGE_LINUX_APP=1 "$SWIFT" build -c release --show-bin-path)"

# MARK: install

say "Installing into $PREFIX"
$SUDO install -Dm755 "$BIN/forge" "$PREFIX/bin/forge"
$SUDO install -Dm755 "$BIN/forge-cli" "$PREFIX/bin/forge-cli"
$SUDO rm -rf "$PREFIX/lib/forge"
$SUDO install -d "$PREFIX/lib/forge"
toolchain_lib="$(cd "$(dirname "$SWIFT")/../lib" && pwd)"
ldd "$BIN/forge" "$BIN/forge-cli" | awk -v dir="$toolchain_lib" 'index($3, dir) == 1 { print $3 }' | sort -u | while read -r lib; do
  $SUDO install -m644 "$lib" "$PREFIX/lib/forge/"
done
$SUDO install -Dm644 packaging/linux/forge.desktop "$PREFIX/share/applications/forge.desktop"
$SUDO install -Dm644 packaging/linux/forge.svg "$PREFIX/share/icons/hicolor/scalable/apps/forge.svg"
if [[ "$PREFIX" != "/usr/local" && "$PREFIX" != "/usr" ]]; then
  # The menu entry needs the full path when ~/.local/bin is not on the session's PATH.
  $SUDO sed -i "s|^Exec=forge |Exec=$PREFIX/bin/forge |" "$PREFIX/share/applications/forge.desktop"
fi
command -v update-desktop-database >/dev/null && $SUDO update-desktop-database -q "$PREFIX/share/applications" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null && $SUDO gtk-update-icon-cache -q -t "$PREFIX/share/icons/hicolor" 2>/dev/null || true

"$PREFIX/bin/forge-cli" version >/dev/null || die "forge-cli does not run"
say "Done. Start Forge from your application menu, or run: forge"
case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *) echo "    ($PREFIX/bin is not on your PATH; add it, e.g. in fish: fish_add_path $PREFIX/bin)" ;;
esac
echo "    Headless engine: forge-cli (forge-cli mcp serves MCP; forge-cli --help)"
