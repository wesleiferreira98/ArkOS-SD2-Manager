#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ROMS2_BASE_DIR="$BASE_DIR"

if [[ "${1:-}" == "--demo" ]]; then
  export ROMS2_DEMO=1
  export ROMS_ROOT="${TMPDIR:-/tmp}/roms2-manager-demo/roms"
  export ROMS2_ROOT="${TMPDIR:-/tmp}/roms2-manager-demo/roms2"
  export ROMS2_BASE_DIR="${TMPDIR:-/tmp}/roms2-manager-demo/app"
fi

# shellcheck source=lib/common.sh
source "$BASE_DIR/lib/common.sh"
source "$BASE_DIR/lib/controls.sh"
source "$BASE_DIR/lib/devices.sh"
source "$BASE_DIR/lib/mount.sh"
source "$BASE_DIR/lib/games.sh"
source "$BASE_DIR/lib/groups.sh"
source "$BASE_DIR/lib/transfer.sh"
source "$BASE_DIR/lib/filesystem.sh"
source "$BASE_DIR/lib/ui.sh"

require_root_or_sudo
ensure_runtime_dirs
if [[ "${ROMS2_DEMO:-0}" == 1 ]]; then
  mkdir -p "$ROMS_ROOT/psx" "$ROMS_ROOT/dreamcast" "$ROMS_ROOT/atari2600"
  if [[ ! -e "$ROMS_ROOT/psx/Final Fantasy VII.m3u" ]]; then
    printf '%s\n' 'Final Fantasy VII (Disc 1).chd' 'Final Fantasy VII (Disc 2).chd' > "$ROMS_ROOT/psx/Final Fantasy VII.m3u"
    truncate -s 12M "$ROMS_ROOT/psx/Final Fantasy VII (Disc 1).chd"
    truncate -s 14M "$ROMS_ROOT/psx/Final Fantasy VII (Disc 2).chd"
    printf '%s\n' 'FILE "Crazy Taxi (Track 01).bin" BINARY' > "$ROMS_ROOT/dreamcast/Crazy Taxi.cue"
    truncate -s 8M "$ROMS_ROOT/dreamcast/Crazy Taxi (Track 01).bin"
    truncate -s 2M "$ROMS_ROOT/atari2600/Enduro.zip"
  fi
fi
start_controller_support
trap stop_controller_support EXIT
trap 'stop_controller_support; exit 130' INT TERM
main_menu
