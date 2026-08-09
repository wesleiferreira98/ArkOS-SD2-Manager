#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$BASE_DIR/VERSION")"
DIST_DIR="$BASE_DIR/dist"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rom-splitter-release.XXXXXX")"
trap 'rm -rf -- "$STAGE_DIR"' EXIT

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)?$ ]] || {
  printf 'Invalid VERSION: %s\n' "$VERSION" >&2
  exit 1
}
command -v zip >/dev/null 2>&1 || { printf 'zip is required to build a release.\n' >&2; exit 1; }

mkdir -p "$DIST_DIR" "$STAGE_DIR/config" "$STAGE_DIR/boot" "$STAGE_DIR/lib"
rm -f -- "$DIST_DIR/ROM-Splitter-$VERSION.zip" "$DIST_DIR/Install ROM Splitter.sh"
cp "$BASE_DIR/VERSION" "$BASE_DIR/README.md" "$BASE_DIR/LICENSE" \
  "$BASE_DIR/install.sh" "$BASE_DIR/uninstall.sh" "$BASE_DIR/roms2-manager.sh" "$STAGE_DIR/"
cp "$BASE_DIR/config/roms2.conf" "$BASE_DIR/config/oga_controls_settings.txt" "$STAGE_DIR/config/"
cp "$BASE_DIR/boot/roms2-mount.sh" "$STAGE_DIR/boot/"
cp "$BASE_DIR"/lib/*.sh "$STAGE_DIR/lib/"
chmod +x "$STAGE_DIR"/*.sh "$STAGE_DIR/boot"/*.sh "$STAGE_DIR/lib"/*.sh

(
  cd "$STAGE_DIR"
  zip -q -r "$DIST_DIR/ROM-Splitter-$VERSION.zip" .
)
cp "$BASE_DIR/packaging/Install ROM Splitter.sh" "$DIST_DIR/Install ROM Splitter.sh"
PACKAGE_SHA256="$(sha256sum -- "$DIST_DIR/ROM-Splitter-$VERSION.zip" | awk '{print $1}')"
sed -i "s/^EXPECTED_SHA256=.*/EXPECTED_SHA256=\"$PACKAGE_SHA256\"/" "$DIST_DIR/Install ROM Splitter.sh"
chmod +x "$DIST_DIR/Install ROM Splitter.sh"

printf 'Release created:\n'
printf '  %s\n' "$DIST_DIR/ROM-Splitter-$VERSION.zip"
printf '  %s\n' "$DIST_DIR/Install ROM Splitter.sh"
