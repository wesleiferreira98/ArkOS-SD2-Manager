#!/usr/bin/env bash
set -Eeuo pipefail
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROMS2_BASE_DIR="$BASE_DIR"
source "$BASE_DIR/lib/common.sh"
source "$BASE_DIR/lib/devices.sh"
source "$BASE_DIR/lib/mount.sh"
source "$BASE_DIR/lib/games.sh"
source "$BASE_DIR/lib/groups.sh"
ensure_runtime_dirs
activate_inserted_sd2
