#!/usr/bin/env bash
set -Eeuo pipefail

mount_sd2() {
  if [[ "${ROMS2_DEMO:-0}" == 1 ]]; then
    mkdir -p "$ROMS2_ROOT"
    sync_manifest_cache
    return 0
  fi
  local part uuid
  part="$(find_sd2_partition || true)"
  [[ -n "$part" ]] || fail "ROMS2 card not found."

  mkdir -p "$ROMS2_ROOT"
  if findmnt -rn "$ROMS2_ROOT" >/dev/null 2>&1; then
    local src
    src="$(findmnt -n -o SOURCE "$ROMS2_ROOT")"
    if [[ "$src" == "$part" ]]; then
      sync_manifest_cache
      return 0
    fi
    fail "$ROMS2_ROOT is already mounted from $src"
  fi

  run_root mount -t exfat -o uid=1000,gid=1000,fmask=0000,dmask=0000,noatime "$part" "$ROMS2_ROOT"
  uuid="$(blkid -s UUID -o value "$part" 2>/dev/null || true)"
  [[ -n "$uuid" ]] && save_config_value ROMS2_UUID "$uuid"
  save_config_value ROMS2_PARTITION "$part"
  sync_manifest_cache
  log "Mounted SD2 $part at $ROMS2_ROOT"
}

unbind_one() {
  local target="$1"
  if [[ "${ROMS2_DEMO:-0}" == 1 && -L "$target" ]]; then
    rm -f -- "$target"
    log "Demo bind removed $target"
    return 0
  fi
  if mountpoint -q "$target" 2>/dev/null; then
    run_root umount "$target"
    log "Unmounted bind $target"
  fi
}

unmount_all_binds() {
  if [[ "${ROMS2_DEMO:-0}" == 1 ]]; then
    local rel
    while IFS=$'\t' read -r rel _; do
      [[ -L "$ROMS_ROOT/$rel" ]] && rm -f -- "$ROMS_ROOT/$rel"
    done < <(manifest_list)
    return 0
  fi
  findmnt -rn -R "$ROMS_ROOT" -o TARGET,SOURCE 2>/dev/null | tac | while read -r target source; do
    [[ "$target" == "$ROMS_ROOT" ]] && continue
    case "$source" in
      *"[/"*)
        if [[ "$source" == *"mmc"* || "$source" == *"sd"* ]]; then
          # Only unmount targets whose source resolves to SD2's block device.
          local_part="$(find_sd2_partition || true)"
          [[ -n "$local_part" ]] || continue
          srcdev="$(findmnt -n -o SOURCE "$target" 2>/dev/null || true)"
          [[ "$srcdev" == "$local_part"* ]] && run_root umount "$target" || true
        fi
        ;;
    esac
  done
}

unmount_sd2() {
  sync_manifest_cache
  unmount_all_binds || true
  [[ "${ROMS2_DEMO:-0}" == 1 ]] && { log "Demo SD2 unmounted"; return 0; }
  if findmnt -rn "$ROMS2_ROOT" >/dev/null 2>&1; then
    run_root umount "$ROMS2_ROOT"
    log "Unmounted SD2"
  fi
}

bind_item() {
  local source="$1" target="$2"
  [[ -e "$source" ]] || return 1
  mkdir -p "$(dirname "$target")"

  if [[ "${ROMS2_DEMO:-0}" == 1 ]]; then
    rm -rf -- "$target"
    ln -s -- "$source" "$target"
    log "Demo bind $source -> $target"
    return 0
  fi

  if mountpoint -q "$target" 2>/dev/null; then
    return 0
  fi

  if [[ -d "$source" ]]; then
    [[ -d "$target" ]] || { rm -f -- "$target" 2>/dev/null || true; mkdir -p "$target"; }
  else
    [[ -e "$target" ]] || : > "$target"
  fi

  run_root mount --bind "$source" "$target"
  log "Bind mounted $source -> $target"
}

rebuild_binds() {
  mount_sd2
  sync_manifest_cache
  local manifest="$ROMS2_ROOT/.roms2-manifest.tsv"
  [[ -f "$manifest" ]] || return 0

  while IFS=$'\t' read -r rel kind; do
    [[ -n "$rel" ]] || continue
    [[ "$rel" == \#* ]] && continue
    local src="$ROMS2_ROOT/$rel" dst="$ROMS_ROOT/$rel"
    [[ -e "$src" ]] || { log "Missing manifest source: $src"; continue; }
    bind_item "$src" "$dst" || log "Failed bind: $rel"
  done < "$manifest"
}
