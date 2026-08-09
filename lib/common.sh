#!/usr/bin/env bash
set -Eeuo pipefail

ROMS_ROOT="${ROMS_ROOT:-/roms}"
ROMS2_ROOT="${ROMS2_ROOT:-/roms2}"
CONFIG_DIR="${ROMS2_BASE_DIR}/config"
LOG_DIR="${ROMS2_BASE_DIR}/logs"
STATE_DIR="${ROMS2_BASE_DIR}/state"
CONFIG_FILE="$CONFIG_DIR/roms2.conf"
LOG_FILE="$LOG_DIR/roms2-manager.log"

log() {
  mkdir -p "$LOG_DIR"
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

fail() {
  log "ERROR: $*"
  printf '%s\n' "$*" >&2
  return 1
}

ensure_runtime_dirs() {
  mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$STATE_DIR" "$ROMS2_ROOT"
}

require_root_or_sudo() {
  command -v sudo >/dev/null 2>&1 || true
}

run_root() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

human_size() {
  numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || printf '%s B' "$1"
}

file_size_bytes() {
  local p="$1"
  if [[ -d "$p" ]]; then
    du -sb -- "$p" | awk '{print $1}'
  else
    stat -c '%s' -- "$p"
  fi
}

safe_realpath() {
  realpath -m -- "$1"
}

is_under() {
  local child parent
  child="$(safe_realpath "$1")"
  parent="$(safe_realpath "$2")"
  [[ "$child" == "$parent" || "$child" == "$parent"/* ]]
}

load_config() {
  [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
}

save_config_value() {
  local key="$1" value="$2"
  touch "$CONFIG_FILE"
  if grep -q "^${key}=" "$CONFIG_FILE"; then
    sed -i "s|^${key}=.*|${key}=$(printf '%q' "$value")|" "$CONFIG_FILE"
  else
    printf '%s=%q\n' "$key" "$value" >> "$CONFIG_FILE"
  fi
}
