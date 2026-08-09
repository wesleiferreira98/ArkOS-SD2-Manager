#!/usr/bin/env bash
set -Eeuo pipefail

CONTROLS_BACKEND="keyboard"
CONTROLS_PID=""

find_oga_controls() {
  local candidate
  for candidate in \
    "${OGA_CONTROLS_BIN:-}" \
    /opt/quitter/oga_controls \
    /opt/inttools/oga_controls \
    /opt/system/Tools/PortMaster/oga_controls \
    /roms/ports/PortMaster/oga_controls \
    /roms2/ports/PortMaster/oga_controls; do
    [[ -n "$candidate" && -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done
  command -v oga_controls 2>/dev/null || return 1
}

find_gptokeyb() {
  local candidate
  for candidate in \
    "${GPTOKEYB_BIN:-}" \
    /opt/inttools/gptokeyb \
    /opt/system/Tools/PortMaster/gptokeyb; do
    [[ -n "$candidate" && -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done
  command -v gptokeyb 2>/dev/null || return 1
}

handheld_device_name() {
  local value=""
  for source in /home/ark/.config/.DEVICE /opt/system/.DEVICE /etc/device; do
    if [[ -r "$source" ]]; then
      value="$(tr -d '\r\n' < "$source")"
      [[ -n "$value" ]] && break
    fi
  done
  [[ -n "$value" ]] || value="$(tr '[:upper:]' '[:lower:]' < /proc/device-tree/model 2>/dev/null || true)"
  printf '%s\n' "${value,,}"
}

oga_device_profile() {
  local device
  if [[ -n "${ROMS2_OGA_PROFILE:-}" ]]; then
    printf '%s\n' "$ROMS2_OGA_PROFILE"
    return 0
  fi
  device="${1:-$(handheld_device_name)}"
  device="${device,,}"
  case "$device" in
    *rg351*|*rg353*|*rg503*|*r35s*|*r36s*|*r36h*|*anbernic*) printf 'anbernic\n' ;;
    *gameforce*|*chi*) printf 'chi\n' ;;
    *odroid*super*|*ogs*) printf 'ogs\n' ;;
    *rk2020*) printf 'rk2020\n' ;;
    *rgb10*|*odroid*advance*|*oga*) printf 'oga\n' ;;
    *) return 1 ;;
  esac
}

start_controller_support() {
  [[ "${ROMS2_DEMO:-0}" != 1 ]] || { CONTROLS_BACKEND="demo/keyboard"; return 0; }
  [[ -t 0 && -t 1 ]] || return 0

  if pgrep -f 'gptokeyb|oga_controls' >/dev/null 2>&1; then
    CONTROLS_BACKEND="existing controller mapper"
    log "An existing controller mapper was detected; a second mapper was not started."
    return 0
  fi

  local gptokey keys controller_db
  gptokey="$(find_gptokeyb || true)"
  keys="$ROMS2_BASE_DIR/config/rom-splitter.gptk"
  controller_db="/opt/inttools/gamecontrollerdb.txt"
  if [[ -n "$gptokey" && -r "$keys" ]]; then
    run_root chmod 666 /dev/uinput
    [[ -r "$controller_db" ]] && export SDL_GAMECONTROLLERCONFIG_FILE="$controller_db"
    "$gptokey" -c "$keys" >> "$LOG_FILE" 2>&1 &
    CONTROLS_PID=$!
    sleep 0.2
    if kill -0 "$CONTROLS_PID" 2>/dev/null; then
      CONTROLS_BACKEND="gptokeyb (ROM Splitter profile)"
      log "Controller support started: $CONTROLS_BACKEND"
      return 0
    fi
    wait "$CONTROLS_PID" 2>/dev/null || true
    CONTROLS_PID=""
    log "gptokeyb failed to start; trying oga_controls fallback."
  fi

  local mapper profile settings runtime_dir
  mapper="$(find_oga_controls || true)"
  profile="$(oga_device_profile || true)"
  settings="$ROMS2_BASE_DIR/config/oga_controls_settings.txt"
  [[ -n "$mapper" && -n "$profile" && -r "$settings" ]] || {
    log "Controller mapper unavailable; keyboard controls remain active."
    return 0
  }

  # oga_controls reads oga_controls_settings.txt from its working directory.
  runtime_dir="$STATE_DIR/controller"
  mkdir -p "$runtime_dir"
  cp -f -- "$settings" "$runtime_dir/oga_controls_settings.txt"
  (
    cd "$runtime_dir"
    run_root "$mapper" roms2-manager.sh "$profile"
  ) >> "$LOG_FILE" 2>&1 &
  CONTROLS_PID=$!
  sleep 0.2
  if kill -0 "$CONTROLS_PID" 2>/dev/null; then
    CONTROLS_BACKEND="oga_controls ($profile)"
    log "Controller support started: $CONTROLS_BACKEND"
  else
    wait "$CONTROLS_PID" 2>/dev/null || true
    CONTROLS_PID=""
    log "Controller mapper failed to start; keyboard controls remain active."
  fi
}

stop_controller_support() {
  [[ -n "$CONTROLS_PID" ]] || return 0
  if kill -0 "$CONTROLS_PID" 2>/dev/null; then
    pkill -TERM -P "$CONTROLS_PID" 2>/dev/null || true
    kill "$CONTROLS_PID" 2>/dev/null || true
    wait "$CONTROLS_PID" 2>/dev/null || true
  fi
  CONTROLS_PID=""
  unset SDL_GAMECONTROLLERCONFIG_FILE
}

controller_help_text() {
  printf 'D-Pad: Navigate | A: Confirm | B: Previous screen | X: Select\nL1/R1: Navigate | Exit only from the main menu'
}
