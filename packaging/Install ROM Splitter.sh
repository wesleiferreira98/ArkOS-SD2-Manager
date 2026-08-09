#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROMS_DIR="${ROMS_ROOT:-/roms}"
INSTALL_DIR="$ROMS_DIR/tools/.rom-splitter"
EXPECTED_SHA256=""

archive=""
for candidate in "$SCRIPT_DIR"/ROM-Splitter-*.zip "$SCRIPT_DIR"/ROM\ Splitter*.zip; do
  [[ -f "$candidate" ]] && { archive="$candidate"; break; }
done

if [[ -z "$archive" ]]; then
  printf 'ROM Splitter package was not found next to this installer.\n' >&2
  printf 'Copy ROM-Splitter-<version>.zip and this .sh into the same folder.\n' >&2
  exit 1
fi

command -v unzip >/dev/null 2>&1 || { printf 'The unzip command is required.\n' >&2; exit 1; }
if [[ -n "$EXPECTED_SHA256" ]]; then
  command -v sha256sum >/dev/null 2>&1 || { printf 'sha256sum is required.\n' >&2; exit 1; }
  actual_sha256="$(sha256sum -- "$archive" | awk '{print $1}')"
  [[ "$actual_sha256" == "$EXPECTED_SHA256" ]] || {
    printf 'Package checksum verification failed. Installation was cancelled.\n' >&2
    exit 1
  }
fi
mkdir -p "$INSTALL_DIR" 2>/dev/null || sudo mkdir -p "$INSTALL_DIR"
if [[ ! -w "$INSTALL_DIR" ]]; then
  sudo chown "$(id -u):$(id -g)" "$INSTALL_DIR"
fi

unzip -q -o "$archive" -d "$INSTALL_DIR"
[[ -f "$INSTALL_DIR/install.sh" && -f "$INSTALL_DIR/roms2-manager.sh" ]] || {
  printf 'Invalid or incomplete ROM Splitter package.\n' >&2
  exit 1
}

chmod +x "$INSTALL_DIR/install.sh" "$INSTALL_DIR/uninstall.sh" \
  "$INSTALL_DIR/roms2-manager.sh" "$INSTALL_DIR/boot/roms2-mount.sh"
find "$INSTALL_DIR/lib" -type f -name '*.sh' -exec chmod +x {} +
"$INSTALL_DIR/install.sh"

printf '\nROM Splitter installed successfully.\n'
printf 'Restart or refresh EmulationStation and open Tools > ROM Splitter.\n'
