#!/usr/bin/env bash
# Native GTK action/dialog regression; does not require Swift or OCCT.
set -euo pipefail
cd "$(dirname "$0")/.."
forge_test_dir=$(mktemp -d)
trap 'rm -rf "$forge_test_dir"' EXIT
read -r -a forge_gtk_flags <<< "$(pkg-config --cflags --libs gtk4 epoxy)"
"${CC:-cc}" -std=c11 -D_GNU_SOURCE \
    -ISources/CForgeWin/gtk -ISources/CForgeWin/include \
    Tests/NativeGTKTests/MenuActionTests.c \
    Sources/CForgeWin/gtk/gtk_shell.c Sources/CForgeWin/gtk/gtk_icons.c Sources/CForgeWin/gtk/gtk_render.c \
    "${forge_gtk_flags[@]}" -lm -o "$forge_test_dir/menu-actions"
if command -v xvfb-run >/dev/null 2>&1; then
    timeout 30s xvfb-run -a env GDK_BACKEND=x11 "$forge_test_dir/menu-actions"
else
    echo "GTK tests require xvfb-run; refusing to open test dialogs on the desktop." >&2
    exit 1
fi
